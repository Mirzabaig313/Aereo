// MARK: - ConfigEditor.swift
// AereoCore
//
// Manages macOS wallpaper configuration and static wallpaper synchronization.
// Handles setting the desktop wallpaper via NSWorkspace when the video wallpaper
// is paused, and manages WallpaperAgent lifecycle.
//
// This replaces the previous Index.plist manipulation approach with the simpler
// NSWorkspace-based approach discovered via reverse engineering.

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "ConfigEditor")

// MARK: - Config Editor Error

public enum ConfigEditorError: LocalizedError {
    case wallpaperSetFailed(String)
    case screenshotFailed(String)
    case agentReloadFailed(String)
    case manifestNotFound

    public var errorDescription: String? {
        switch self {
        case .wallpaperSetFailed(let r): return "Failed to set desktop wallpaper: \(r)"
        case .screenshotFailed(let r): return "Failed to capture wallpaper frame: \(r)"
        case .agentReloadFailed(let r): return "WallpaperAgent reload failed: \(r)"
        case .manifestNotFound: return "Aerial entries.json manifest not found"
        }
    }
}

// MARK: - Cached Wallpaper Info

/// Stores information about the last applied wallpaper per screen.
public struct CachedWallpaperInfo: Codable, Sendable {
    public var screenIndex: Int
    public var videoID: String?
    public var aerialUUID: String?
    public var staticFrameURL: URL?
    public var lastApplied: Date
}

// MARK: - Config Editor

/// Manages desktop wallpaper configuration and static frame synchronization.
///
/// When the video wallpaper is active, this class can:
/// - Capture a frame from the video and set it as the static desktop wallpaper
///   (so the desktop looks correct when the video window is hidden)
/// - Track which wallpaper was last applied per screen
/// - Signal WallpaperAgent to reload after manifest changes
public struct ConfigEditor: Sendable {

    // MARK: - Paths

    /// Directory for cached static wallpaper frames.
    private static let cacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Aereo/CachedWallpapers", isDirectory: true)
    }()

    /// Persisted record of last applied wallpapers per screen.
    private static let lastAppliedURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Aereo/LastAppliedWallpapers.json", isDirectory: false)
    }()

    /// Path to the Aerial manifest.
    private static var manifestURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
        )
    }

    // MARK: - Desktop Wallpaper Management

    /// Set the static desktop wallpaper for a specific screen.
    /// Used to sync the desktop image when the video wallpaper pauses or hides.
    ///
    /// - Parameters:
    ///   - imageURL: File URL to the wallpaper image (PNG, JPEG, HEIC).
    ///   - screen: Target screen. If nil, uses main screen.
    @MainActor
    public static func setDesktopWallpaper(imageURL: URL, for screen: NSScreen? = nil) throws {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!

        do {
            try NSWorkspace.shared.setDesktopImageURL(
                imageURL,
                for: targetScreen,
                options: [:]
            )
            logger.info("Set desktop wallpaper to \(imageURL.lastPathComponent) for screen \(targetScreen.localizedName)")
        } catch {
            throw ConfigEditorError.wallpaperSetFailed(error.localizedDescription)
        }
    }

    /// Get the current desktop wallpaper URL for a screen.
    @MainActor
    public static func currentDesktopWallpaper(for screen: NSScreen? = nil) -> URL? {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        return NSWorkspace.shared.desktopImageURL(for: targetScreen)
    }

    /// Save a video frame as a static wallpaper image and set it as the desktop.
    /// This ensures the desktop matches the video wallpaper when the video is hidden.
    ///
    /// - Parameters:
    ///   - image: The captured video frame.
    ///   - videoID: Identifier for the video (used for caching).
    ///   - screen: Target screen.
    @MainActor
    public static func syncStaticWallpaper(
        image: NSImage,
        videoID: String,
        for screen: NSScreen? = nil,
        screenIndex: Int = 0
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Save frame as PNG
        let frameURL = cacheDir.appendingPathComponent("\(videoID)_\(screenIndex).png")
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ConfigEditorError.screenshotFailed("Could not convert frame to PNG")
        }
        try pngData.write(to: frameURL)

        // Set as desktop wallpaper
        try setDesktopWallpaper(imageURL: frameURL, for: screen)

        // Record the application
        var records = loadLastApplied()
        records.removeAll { $0.screenIndex == screenIndex }
        records.append(CachedWallpaperInfo(
            screenIndex: screenIndex,
            videoID: videoID,
            aerialUUID: nil,
            staticFrameURL: frameURL,
            lastApplied: Date()
        ))
        saveLastApplied(records)

        logger.info("Synced static wallpaper for screen \(screenIndex)")
    }

    // MARK: - WallpaperAgent Control

    /// Signal WallpaperAgent to reload configuration.
    /// The agent auto-relaunches after being killed, re-reading the manifest.
    public static func reloadWallpaperAgent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorStr = String(data: errorData, encoding: .utf8) ?? ""
                if !errorStr.contains("No matching processes") {
                    logger.warning("killall WallpaperAgent: \(errorStr)")
                }
            }
            logger.info("WallpaperAgent reload signaled")
        } catch {
            throw ConfigEditorError.agentReloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Manifest Inspection

    /// Read the current Aerial manifest and return the number of assets.
    public static func manifestAssetCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ConfigEditorError.manifestNotFound
        }

        let data = try Data(contentsOf: manifestURL)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = json["assets"] as? [[String: Any]] {
            return assets.count
        }
        return 0
    }

    /// List all custom (non-Apple) asset IDs in the manifest.
    /// Custom assets have fake `sylvan.apple.com/custom/` URLs.
    public static func listCustomAssets() throws -> [(id: String, name: String)] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return []
        }

        let data = try Data(contentsOf: manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            return []
        }

        return assets.compactMap { asset in
            guard let url = asset["url-4K-SDR-240FPS"] as? String,
                  url.contains("sylvan.apple.com/custom/"),
                  let id = asset["id"] as? String,
                  let name = asset["accessibilityLabel"] as? String else {
                return nil
            }
            return (id: id, name: name)
        }
    }

    // MARK: - Persistence

    private static func loadLastApplied() -> [CachedWallpaperInfo] {
        guard FileManager.default.fileExists(atPath: lastAppliedURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: lastAppliedURL)
            return try JSONDecoder().decode([CachedWallpaperInfo].self, from: data)
        } catch {
            return []
        }
    }

    private static func saveLastApplied(_ records: [CachedWallpaperInfo]) {
        do {
            let dir = lastAppliedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: lastAppliedURL)
        } catch {
            logger.error("Failed to save LastAppliedWallpapers: \(error.localizedDescription)")
        }
    }
}

// MARK: - Convenience Extension

extension ConfigEditor {

    /// High-level: inject a video and configure it as a lock screen wallpaper.
    /// Combines AssetInjector transcoding with manifest modification.
    @MainActor
    public static func activateForLockScreen(
        sourceVideo: URL,
        displayName: String? = nil,
        injector: AssetInjector
    ) async throws {
        // 1. Inject the video into the Aerial manifest
        let assetID = try await injector.injectVideo(
            sourceURL: sourceVideo,
            displayName: displayName
        )

        logger.info("Activated \(sourceVideo.lastPathComponent) for lock screen as \(assetID)")
    }
}
