// MARK: - MenuBarApp.swift
// AereoUI
//
// Menu bar extra providing quick access to wallpaper controls.
// Shows current status, play/pause, and opens settings/library.

import SwiftUI
import AereoCore

// MARK: - Menu Bar View

public struct MenuBarView: View {
    @ObservedObject var coordinator: DisplayCoordinator
    @ObservedObject var configManager: ConfigurationManager
    @Binding var showLibrary: Bool
    var onCheckForUpdates: (() -> Void)?

    public init(coordinator: DisplayCoordinator,
                configManager: ConfigurationManager,
                showLibrary: Binding<Bool>,
                onCheckForUpdates: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.configManager = configManager
        self._showLibrary = showLibrary
        self.onCheckForUpdates = onCheckForUpdates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "sparkles.tv")
                    .font(.title3)
                Text("Aereo")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)

            Divider()

            // Status
            statusSection

            Divider()

            // Controls
            controlsSection

            Divider()

            // Quick Actions
            actionsSection
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if coordinator.activeDisplayCount > 1 {
                Text("\(coordinator.activeDisplayCount) displays active")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Power state indicator
            if coordinator.powerManager.powerState.isOnBattery {
                HStack(spacing: 4) {
                    Image(systemName: "battery.25")
                        .foregroundStyle(.orange)
                    Text("Battery: \(coordinator.powerManager.powerState.batteryLevel)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button(action: { coordinator.resumeAll() }) {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!hasActiveVideo)

            Button(action: { coordinator.pauseAll() }) {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!hasActiveVideo)

            Button(action: { coordinator.stopAll() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!hasActiveVideo)

            Spacer()
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Button(action: { showLibrary = true }) {
            Label("Video Library", systemImage: "photo.on.rectangle.angled")
        }
        .buttonStyle(.borderless)

        Button(action: {
            Task { await coordinator.syncStaticWallpaper() }
        }) {
            Label("Sync Wallpaper Snapshot", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless)

        if let onCheckForUpdates {
            Button(action: onCheckForUpdates) {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
        }

        Divider()

        Button(action: { NSApplication.shared.terminate(nil) }) {
            Label("Quit Aereo", systemImage: "power")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Computed

    private var hasActiveVideo: Bool {
        coordinator.displays.values.contains { $0.videoURL != nil }
    }

    private var statusColor: Color {
        if !coordinator.powerManager.shouldPlay {
            return .orange
        }
        if hasActiveVideo {
            return .green
        }
        return .gray
    }

    private var statusText: String {
        if !coordinator.powerManager.shouldPlay {
            return "Paused (power saving)"
        }
        if hasActiveVideo {
            return "Playing"
        }
        return "No wallpaper set"
    }
}
