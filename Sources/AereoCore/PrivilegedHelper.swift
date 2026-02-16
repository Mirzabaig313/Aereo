// MARK: - LoginItemManager.swift (was PrivilegedHelper.swift)
// AereoCore
//
// Login item management using SMAppService (macOS 13+).
// Handles auto-start at login, which is essential for a wallpaper app
// that should persist across reboots.
//
// The privileged helper approach was replaced after reverse engineering
// revealed the lock screen injection operates entirely in user-space,
// making admin/root privileges unnecessary.

import AppKit
import CoreGraphics
import Foundation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: "com.aereo.core", category: "LoginItem")

// MARK: - Login Item Status

public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case error(String)
}

// MARK: - Login Item Manager

/// Manages the app's login item registration via SMAppService.
///
/// Ensures the wallpaper app starts automatically when the user logs in,
/// which is critical for maintaining the wallpaper experience across reboots.
@MainActor
public final class LoginItemManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var status: LoginItemStatus = .disabled
    @Published public var wantsStartAtLogin: Bool = false {
        didSet {
            guard wantsStartAtLogin != oldValue else { return }
            updateLoginItem(enabled: wantsStartAtLogin)
        }
    }

    // MARK: - Private

    private let service: SMAppService

    // MARK: - Init

    public init() {
        self.service = SMAppService.mainApp
        syncStatus()

        // Load preference
        wantsStartAtLogin = UserDefaults.standard.bool(forKey: "launchedFromLoginItem")
    }

    // MARK: - Public API

    /// Sync the current status from the system.
    public func syncStatus() {
        let serviceStatus = service.status

        switch serviceStatus {
        case .notRegistered:
            status = .disabled
            logger.info("LoginItem: sync status = notRegistered")
        case .enabled:
            status = .enabled
            logger.info("LoginItem: synced to enabled")
        case .requiresApproval:
            status = .requiresApproval
            logger.info("LoginItem: synced to disabled (requires approval)")
        case .notFound:
            status = .notFound
            logger.info("LoginItem: sync status = notFound")
        @unknown default:
            status = .error("Unknown status: \(serviceStatus)")
        }
    }

    /// Register the app as a login item.
    public func register() {
        do {
            try service.register()
            status = .enabled
            UserDefaults.standard.set(true, forKey: "launchedFromLoginItem")
            logger.info("LoginItem: registered successfully")
        } catch {
            if (error as NSError).domain == "SMAppServiceErrorDomain" {
                status = .requiresApproval
                logger.info("LoginItem: failed to register — requires approval in System Settings")
            } else {
                status = .error(error.localizedDescription)
                logger.error("LoginItem: failed to register: \(error.localizedDescription)")
            }
        }
    }

    /// Unregister the app as a login item.
    public func unregister() {
        do {
            try service.unregister()
            status = .disabled
            UserDefaults.standard.set(false, forKey: "launchedFromLoginItem")
            logger.info("LoginItem: unregistered successfully")
        } catch {
            status = .error(error.localizedDescription)
            logger.error("LoginItem: failed to unregister: \(error.localizedDescription)")
        }
    }

    /// Open System Settings to the Login Items page.
    /// Used when the user needs to manually approve the login item.
    public func openLoginItemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
            logger.info("LoginItem: opened Login Items settings")
        }
    }

    // MARK: - Private

    private func updateLoginItem(enabled: Bool) {
        logger.info("LoginItem: updateLoginItem enabled=\(enabled)")
        if enabled {
            register()
        } else {
            unregister()
        }
    }
}

// MARK: - Screen Lock Observer

/// Observes screen lock/unlock events via DistributedNotificationCenter.
/// Used to handle post-unlock wallpaper restoration.
public final class ScreenLockObserver: Sendable {

    private let onLock: @Sendable () -> Void
    private let onUnlock: @Sendable () -> Void
    private nonisolated(unsafe) var lockObserver: NSObjectProtocol?
    private nonisolated(unsafe) var unlockObserver: NSObjectProtocol?

    /// Create a screen lock observer.
    /// - Parameters:
    ///   - onLock: Called when the screen is locked.
    ///   - onUnlock: Called when the screen is unlocked.
    public init(
        onLock: @escaping @Sendable () -> Void,
        onUnlock: @escaping @Sendable () -> Void
    ) {
        self.onLock = onLock
        self.onUnlock = onUnlock
    }

    /// Start observing lock/unlock events.
    public func startObserving() {
        let dnc = DistributedNotificationCenter.default()

        lockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [onLock] _ in
            onLock()
        }

        unlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [onUnlock] _ in
            onUnlock()
        }
    }

    /// Stop observing lock/unlock events.
    public func stopObserving() {
        let dnc = DistributedNotificationCenter.default()
        if let obs = lockObserver {
            dnc.removeObserver(obs)
            lockObserver = nil
        }
        if let obs = unlockObserver {
            dnc.removeObserver(obs)
            unlockObserver = nil
        }
    }

    deinit {
        stopObserving()
    }
}

// MARK: - Fullscreen App Monitor

/// Monitors whether any fullscreen apps are running to pause the wallpaper.
/// Uses CGWindowListCopyWindowInfo to detect fullscreen windows.
@MainActor
public final class FullscreenMonitor: ObservableObject {

    @Published public private(set) var hasFullscreenApp: Bool = false
    @Published public var pauseOnFullscreen: Bool = true

    private var timer: Timer?

    public init() {}

    /// Start monitoring for fullscreen apps.
    public func startMonitoring(interval: TimeInterval = 2.0) {
        logger.info("FullscreenMonitor: started monitoring")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkFullscreen()
            }
        }
    }

    /// Stop monitoring.
    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        logger.info("FullscreenMonitor: stopped monitoring")
    }

    private func checkFullscreen() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return
        }

        let wasFullscreen = hasFullscreenApp

        // Check if any window occupies the entire screen
        hasFullscreenApp = windowList.contains { window in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let windowLayer = window[kCGWindowLayer as String] as? Int,
                  windowLayer == 0 else {
                return false
            }

            let width = bounds["Width"] as? CGFloat ?? 0
            let height = bounds["Height"] as? CGFloat ?? 0

            // Check against main screen size
            if let mainScreen = NSScreen.main {
                let screenSize = mainScreen.frame.size
                return width >= screenSize.width && height >= screenSize.height
            }
            return false
        }

        if hasFullscreenApp && !wasFullscreen {
            logger.info("FullscreenMonitor: paused wallpaper due to fullscreen app")
        } else if !hasFullscreenApp && wasFullscreen {
            logger.info("FullscreenMonitor: resumed wallpaper, no fullscreen apps")
        }
    }
}
