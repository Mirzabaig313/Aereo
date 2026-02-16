// MARK: - SettingsView.swift
// AereoUI
//
// App settings panel for configuring global behavior,
// per-display options, and power management preferences.

import SwiftUI
import AereoCore

public struct SettingsView: View {
    @ObservedObject var configManager: ConfigurationManager
    @ObservedObject var coordinator: DisplayCoordinator

    public init(configManager: ConfigurationManager, coordinator: DisplayCoordinator) {
        self.configManager = configManager
        self.coordinator = coordinator
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(configManager: configManager)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            PowerSettingsTab(configManager: configManager, powerManager: coordinator.powerManager)
                .tabItem {
                    Label("Power", systemImage: "battery.100.bolt")
                }

            DisplaySettingsTab(coordinator: coordinator, configManager: configManager)
                .tabItem {
                    Label("Displays", systemImage: "display.2")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 350)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @ObservedObject var configManager: ConfigurationManager

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { configManager.config.globalSettings.launchAtLogin },
                    set: { newValue in
                        configManager.update { $0.globalSettings.launchAtLogin = newValue }
                    }
                ))
            }

            Section("Liquid Glass Compatibility") {
                Toggle("Sync static wallpaper snapshot", isOn: Binding(
                    get: { configManager.config.globalSettings.syncStaticWallpaper },
                    set: { newValue in
                        configManager.update { $0.globalSettings.syncStaticWallpaper = newValue }
                    }
                ))

                HStack {
                    Text("Sync interval:")
                    Picker("", selection: Binding(
                        get: { configManager.config.globalSettings.syncIntervalMinutes },
                        set: { newValue in
                            configManager.update { $0.globalSettings.syncIntervalMinutes = newValue }
                        }
                    )) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    .frame(width: 150)
                }

                Text("Periodically captures a frame from the video and sets it as the system wallpaper. This helps macOS Liquid Glass UI elements match the video's colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Power Settings

struct PowerSettingsTab: View {
    @ObservedObject var configManager: ConfigurationManager
    @ObservedObject var powerManager: PowerManager

    var body: some View {
        Form {
            Section("Battery") {
                Toggle("Pause on battery power", isOn: Binding(
                    get: { configManager.config.globalSettings.pauseOnBattery },
                    set: { newValue in
                        configManager.update { $0.globalSettings.pauseOnBattery = newValue }
                        powerManager.pauseOnBattery = newValue
                    }
                ))

                HStack {
                    Text("Low battery threshold:")
                    Picker("", selection: Binding(
                        get: { configManager.config.globalSettings.lowBatteryThreshold },
                        set: { newValue in
                            configManager.update { $0.globalSettings.lowBatteryThreshold = newValue }
                            powerManager.lowBatteryThreshold = newValue
                        }
                    )) {
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                    .frame(width: 100)
                }

                Text("Playback always pauses automatically when the screen sleeps, locks, or reaches critical thermal state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Current Status") {
                LabeledContent("Power Source") {
                    Text(powerManager.powerState.isOnBattery ? "Battery" : "AC Power")
                }
                if powerManager.powerState.batteryLevel >= 0 {
                    LabeledContent("Battery Level") {
                        Text("\(powerManager.powerState.batteryLevel)%")
                    }
                }
                LabeledContent("Thermal State") {
                    Text(thermalStateText)
                }
                LabeledContent("Playback") {
                    HStack {
                        Circle()
                            .fill(powerManager.shouldPlay ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(powerManager.shouldPlay ? "Active" : "Paused")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var thermalStateText: String {
        switch powerManager.powerState.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Display Settings

struct DisplaySettingsTab: View {
    @ObservedObject var coordinator: DisplayCoordinator
    @ObservedObject var configManager: ConfigurationManager

    var body: some View {
        Form {
            Section("Connected Displays (\(coordinator.activeDisplayCount))") {
                ForEach(Array(coordinator.displays.values), id: \.id) { entry in
                    HStack {
                        Image(systemName: "display")
                        VStack(alignment: .leading) {
                            Text("Display \(entry.id)")
                                .font(.subheadline)
                            if let url = entry.videoURL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No wallpaper set")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()

                        Picker("Scale", selection: Binding(
                            get: {
                                configManager.displayConfig(for: entry.id).scaleMode
                            },
                            set: { newMode in
                                var config = configManager.displayConfig(for: entry.id)
                                config.scaleMode = newMode
                                configManager.setDisplayConfig(config)
                            }
                        )) {
                            ForEach(ScaleMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .frame(width: 120)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles.tv")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Aereo")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Open-source video wallpaper for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Built with Swift 6, AVFoundation & SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Desktop wallpaper only — lock screen not supported by macOS public APIs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Link("View on GitHub", destination: URL(string: "https://github.com")!)
                .font(.subheadline)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
