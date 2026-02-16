// MARK: - WallpaperConfiguration.swift
// AereoCore
//
// Persistent configuration model for wallpaper settings.
// Supports per-display configuration, playlists, and scheduling.

import Foundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "Configuration")

// MARK: - Scale Mode

/// How the video fills the screen.
public enum ScaleMode: String, Codable, CaseIterable, Sendable {
    case aspectFill = "aspectFill"
    case aspectFit = "aspectFit"
    case stretch = "stretch"

    public var displayName: String {
        switch self {
        case .aspectFill: return "Fill Screen"
        case .aspectFit: return "Fit Screen"
        case .stretch: return "Stretch"
        }
    }
}

// MARK: - Playlist Entry

/// A single video in a playlist with optional scheduling.
public struct PlaylistEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var videoURL: URL
    public var displayName: String
    public var duration: TimeInterval?  // How long to show before switching (nil = until video ends)
    public var startTime: Date?         // For time-based scheduling

    public init(id: UUID = UUID(), videoURL: URL, displayName: String? = nil,
                duration: TimeInterval? = nil, startTime: Date? = nil) {
        self.id = id
        self.videoURL = videoURL
        self.displayName = displayName ?? videoURL.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.startTime = startTime
    }
}

// MARK: - Display Configuration

/// Configuration for a single display.
public struct DisplayConfiguration: Codable, Identifiable, Sendable {
    public var id: String  // CGDirectDisplayID as string
    public var videoURL: URL?
    public var scaleMode: ScaleMode
    public var playlist: [PlaylistEntry]
    public var playlistEnabled: Bool
    public var playlistShuffled: Bool

    public init(displayID: String = "main",
                videoURL: URL? = nil,
                scaleMode: ScaleMode = .aspectFill,
                playlist: [PlaylistEntry] = [],
                playlistEnabled: Bool = false,
                playlistShuffled: Bool = false) {
        self.id = displayID
        self.videoURL = videoURL
        self.scaleMode = scaleMode
        self.playlist = playlist
        self.playlistEnabled = playlistEnabled
        self.playlistShuffled = playlistShuffled
    }
}

// MARK: - App Configuration

/// Top-level app configuration.
public struct AppConfiguration: Codable, Sendable {
    public var displays: [DisplayConfiguration]
    public var globalSettings: GlobalSettings
    public var version: Int

    public static let currentVersion = 1

    public init(displays: [DisplayConfiguration] = [],
                globalSettings: GlobalSettings = .default) {
        self.displays = displays
        self.globalSettings = globalSettings
        self.version = Self.currentVersion
    }
}

// MARK: - Global Settings

/// Settings that apply across all displays.
public struct GlobalSettings: Codable, Sendable {
    public var launchAtLogin: Bool
    public var pauseOnBattery: Bool
    public var lowBatteryThreshold: Int  // 0-100
    public var syncStaticWallpaper: Bool // Liquid Glass compatibility
    public var syncIntervalMinutes: Int  // How often to sync static wallpaper

    public static let `default` = GlobalSettings(
        launchAtLogin: false,
        pauseOnBattery: false,
        lowBatteryThreshold: 20,
        syncStaticWallpaper: true,
        syncIntervalMinutes: 5
    )
}

// MARK: - Configuration Manager

/// Manages reading and writing app configuration.
@MainActor
public final class ConfigurationManager: ObservableObject {

    @Published public private(set) var config: AppConfiguration

    private let configURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("Aereo", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        self.configURL = appDir.appendingPathComponent("config.json")
        self.config = AppConfiguration()

        load()
    }

    // MARK: - Public API

    /// Load configuration from disk.
    public func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            logger.info("No config file found, using defaults")
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
            config = decoded
            logger.info("Configuration loaded successfully")
        } catch {
            logger.error("Failed to load config: \(error.localizedDescription)")
        }
    }

    /// Save current configuration to disk.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            logger.info("Configuration saved")
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    /// Update configuration and persist.
    public func update(_ modify: (inout AppConfiguration) -> Void) {
        modify(&config)
        save()
    }

    /// Get configuration for a specific display, or create default.
    public func displayConfig(for displayID: CGDirectDisplayID) -> DisplayConfiguration {
        let idString = String(displayID)
        return config.displays.first { $0.id == idString }
            ?? DisplayConfiguration(displayID: idString)
    }

    /// Update configuration for a specific display.
    public func setDisplayConfig(_ displayConfig: DisplayConfiguration) {
        if let index = config.displays.firstIndex(where: { $0.id == displayConfig.id }) {
            config.displays[index] = displayConfig
        } else {
            config.displays.append(displayConfig)
        }
        save()
    }

    /// Get the video library directory.
    public var videoLibraryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aereo/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
