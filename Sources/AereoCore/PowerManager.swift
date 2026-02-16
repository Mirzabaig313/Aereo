// MARK: - PowerManager.swift
// AereoCore
//
// Intelligent power and resource management for video wallpaper playback.
// Monitors battery state, thermal pressure, screen sleep, full-screen apps,
// and window occlusion to pause/resume playback automatically.

import AppKit
import IOKit.ps
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "PowerManager")

// MARK: - Power State

/// Current system power conditions affecting wallpaper playback.
public struct PowerState: Sendable, Equatable {
    public var isOnBattery: Bool
    public var batteryLevel: Int  // 0-100, -1 if unknown
    public var thermalState: ProcessInfo.ThermalState
    public var isScreenAsleep: Bool
    public var isScreenLocked: Bool
    public var isDesktopOccluded: Bool

    public static let initial = PowerState(
        isOnBattery: false,
        batteryLevel: -1,
        thermalState: .nominal,
        isScreenAsleep: false,
        isScreenLocked: false,
        isDesktopOccluded: false
    )

    /// Whether playback should be paused based on current conditions.
    public var shouldPausePlayback: Bool {
        isScreenAsleep || isScreenLocked || isDesktopOccluded ||
        thermalState == .critical ||
        (isOnBattery && batteryLevel >= 0 && batteryLevel <= 20)
    }
}

// MARK: - PowerManager

/// Monitors system power conditions and notifies when playback should pause/resume.
@MainActor
public final class PowerManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var powerState: PowerState = .initial
    @Published public private(set) var shouldPlay: Bool = true

    // MARK: - Configuration

    /// Battery level threshold below which playback pauses (0-100).
    public var lowBatteryThreshold: Int = 20

    /// Whether to pause playback when running on battery power.
    public var pauseOnBattery: Bool = false

    // MARK: - Callbacks

    /// Called when playback should pause or resume.
    public var onPlaybackStateChange: ((Bool) -> Void)?

    // MARK: - Observers

    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private nonisolated(unsafe) var powerSourceObserver: CFRunLoopSource?
    private var occlusionObservers: [NSObjectProtocol] = []

    // MARK: - Init

    public init() {
        setupObservers()
        updateBatteryState()
        logger.info("PowerManager initialized")
    }

    deinit {
        // Observer cleanup: observers are invalidated when the object is deallocated
        // NotificationCenter observers with block-based API are auto-removed on dealloc
        if let source = powerSourceObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Public API

    /// Start monitoring system conditions.
    public func startMonitoring() {
        updateBatteryState()
        updateThermalState()
        logger.info("Power monitoring started")
    }

    /// Register a window for occlusion state monitoring.
    public func observeOcclusion(of window: NSWindow) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                self?.handleOcclusionChange(window: window)
            }
        }
        occlusionObservers.append(observer)
    }

    // MARK: - Setup

    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Screen sleep/wake
        screenSleepObserver = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenSleep()
            }
        }

        screenWakeObserver = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenWake()
            }
        }

        // Screen lock/unlock
        screenLockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenLock()
            }
        }

        screenUnlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenUnlock()
            }
        }

        // Thermal state
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateThermalState()
            }
        }

        // Battery power source changes
        setupPowerSourceObserver()
    }

    private func setupPowerSourceObserver() {
        // IOKit power source callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                manager.updateBatteryState()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.powerSourceObserver = source
        }
    }

    // MARK: - Event Handlers

    private func handleScreenSleep() {
        powerState.isScreenAsleep = true
        evaluatePlaybackState()
        logger.info("Screen went to sleep")
    }

    private func handleScreenWake() {
        powerState.isScreenAsleep = false
        evaluatePlaybackState()
        logger.info("Screen woke up")
    }

    private func handleScreenLock() {
        powerState.isScreenLocked = true
        evaluatePlaybackState()
        logger.info("Screen locked")
    }

    private func handleScreenUnlock() {
        powerState.isScreenLocked = false
        evaluatePlaybackState()
        logger.info("Screen unlocked")
    }

    private func handleOcclusionChange(window: NSWindow) {
        let isVisible = window.occlusionState.contains(.visible)
        powerState.isDesktopOccluded = !isVisible
        evaluatePlaybackState()
        logger.debug("Window occlusion changed: visible=\(isVisible)")
    }

    private func updateThermalState() {
        powerState.thermalState = ProcessInfo.processInfo.thermalState
        evaluatePlaybackState()
        logger.debug("Thermal state: \(String(describing: self.powerState.thermalState))")
    }

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let firstSource = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, firstSource)?.takeUnretainedValue() as? [String: Any] else {
            return
        }

        let isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        powerState.isOnBattery = !isCharging
        powerState.batteryLevel = info[kIOPSCurrentCapacityKey] as? Int ?? -1

        evaluatePlaybackState()
        logger.debug("Battery: \(self.powerState.batteryLevel)%, onBattery=\(self.powerState.isOnBattery)")
    }

    // MARK: - Evaluation

    private func evaluatePlaybackState() {
        let newShouldPlay: Bool

        if powerState.isScreenAsleep || powerState.isScreenLocked {
            newShouldPlay = false
        } else if powerState.isDesktopOccluded {
            newShouldPlay = false
        } else if powerState.thermalState == .critical || powerState.thermalState == .serious {
            newShouldPlay = false
        } else if pauseOnBattery && powerState.isOnBattery {
            newShouldPlay = false
        } else if powerState.isOnBattery && powerState.batteryLevel >= 0 && powerState.batteryLevel <= lowBatteryThreshold {
            newShouldPlay = false
        } else {
            newShouldPlay = true
        }

        if newShouldPlay != shouldPlay {
            shouldPlay = newShouldPlay
            onPlaybackStateChange?(newShouldPlay)
            logger.info("Playback state changed: shouldPlay=\(newShouldPlay)")
        }
    }

    // MARK: - Cleanup

    private func removeAllObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        [screenSleepObserver, screenWakeObserver].compactMap { $0 }.forEach {
            nc.removeObserver($0)
        }
        [screenLockObserver, screenUnlockObserver].compactMap { $0 }.forEach {
            dnc.removeObserver($0)
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        occlusionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        occlusionObservers.removeAll()

        if let source = powerSourceObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
