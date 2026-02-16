// MARK: - AereoApp.swift
// AereoApp
//
// Main app entry point. Runs as a menu bar app (no Dock icon).
// Coordinates all modules: rendering, power management, UI.

import SwiftUI
import AereoCore
import AereoUI

@main
struct AereoApp: App {

    // MARK: - State

    @StateObject private var configManager = ConfigurationManager()
    @StateObject private var coordinator = DisplayCoordinator()

    @State private var showLibrary = false
    @State private var showSettings = false

    // MARK: - Lifecycle

    init() {
        // Hide from Dock — menu bar only app
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Menu Bar Extra
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                configManager: configManager,
                showLibrary: $showLibrary
            )
        } label: {
            Image(systemName: "sparkles.tv")
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView(
                configManager: configManager,
                coordinator: coordinator
            )
        }

        // Library Window
        Window("Video Library", id: "library") {
            LibraryView(
                coordinator: coordinator,
                configManager: configManager
            )
        }
        .defaultSize(width: 700, height: 500)
    }
}

// MARK: - App Delegate Adapter

/// Handles app lifecycle events that SwiftUI doesn't cover.
@MainActor
final class AppDelegateAdapter: NSObject, NSApplicationDelegate {
    var coordinator: DisplayCoordinator?
    var configManager: ConfigurationManager?
    var playlistManager: PlaylistManager?
    private var snapshotTimer: Timer?
    private var intentObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup displays on launch
        Task { @MainActor in
            coordinator?.setupAllDisplays()

            // Restore last wallpaper from config
            restoreWallpapers()

            // Start Liquid Glass sync timer
            startSnapshotSync()

            // Register for Shortcuts intent notifications
            registerIntentObservers()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapshotTimer?.invalidate()
        for observer in intentObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        intentObservers.removeAll()
        Task { @MainActor in
            coordinator?.stopAll()
        }
    }

    private func restoreWallpapers() {
        guard let coordinator, let configManager else { return }

        Task { @MainActor in
            for (displayID, _) in coordinator.displays {
                let config = configManager.displayConfig(for: displayID)
                if let url = config.videoURL, FileManager.default.fileExists(atPath: url.path) {
                    coordinator.setVideo(url: url, for: displayID)
                }
            }
        }
    }

    private func startSnapshotSync() {
        guard let configManager else { return }

        let interval = TimeInterval(configManager.config.globalSettings.syncIntervalMinutes * 60)
        guard configManager.config.globalSettings.syncStaticWallpaper else { return }

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let coordinator = self?.coordinator else { return }
                await coordinator.syncStaticWallpaper()
            }
        }
    }

    // MARK: - Intent Notification Handling

    private func registerIntentObservers() {
        let center = DistributedNotificationCenter.default()

        let pauseObs = center.addObserver(
            forName: NSNotification.Name("com.aereo.pause"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator?.pauseAll()
            }
        }
        intentObservers.append(pauseObs)

        let resumeObs = center.addObserver(
            forName: NSNotification.Name("com.aereo.resume"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator?.resumeAll()
            }
        }
        intentObservers.append(resumeObs)

        let nextObs = center.addObserver(
            forName: NSNotification.Name("com.aereo.next"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playlistManager?.next()
            }
        }
        intentObservers.append(nextObs)
    }
}
