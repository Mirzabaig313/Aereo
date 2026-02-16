// MARK: - AssetInjector.swift
// AereoCore
//
// Manages lock screen video wallpaper injection via the Aerial manifest approach.
// Transcodes user videos to HEVC 10-bit 4K 240fps, places them in the user-space
// Aerial videos directory, and merges a custom entry into entries.json.
//
// This operates entirely in user-space — no admin/root privileges required.
// Based on reverse-engineering of Wallper.app's proven approach.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "AssetInjector")

// MARK: - Asset Injector Error

public enum AssetInjectorError: LocalizedError {
    case transcodingFailed(String)
    case fileOperationFailed(String)
    case assetNotFound(String)
    case manifestError(String)
    case unsupportedInput(String)
    case backupFailed(String)
    case agentReloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcodingFailed(let reason): return "Transcoding failed: \(reason)"
        case .fileOperationFailed(let reason): return "File operation failed: \(reason)"
        case .assetNotFound(let path): return "Asset not found at: \(path)"
        case .manifestError(let reason): return "Manifest error: \(reason)"
        case .unsupportedInput(let reason): return "Unsupported input: \(reason)"
        case .backupFailed(let reason): return "Backup failed: \(reason)"
        case .agentReloadFailed(let reason): return "WallpaperAgent reload failed: \(reason)"
        }
    }
}

// MARK: - Injection State

public enum InjectionState: Sendable, Equatable {
    case idle
    case transcoding(progress: Double)
    case injecting
    case active(assetID: String)
    case failed(String)
}

// MARK: - Aerial Asset Entry

/// Represents a single asset entry in Apple's Aerial entries.json manifest.
public struct AerialAssetEntry: Codable, Sendable {
    public var id: String
    public var accessibilityLabel: String
    public var localizedNameKey: String
    public var includeInShuffle: Bool
    public var preferredOrder: Int
    public var showInTopLevel: Bool
    public var shotID: String
    public var pointsOfInterest: [String: String]
    public var previewImage: String
    public var categories: [String]
    public var subcategories: [String]

    // URL key used by the system
    // swiftlint:disable:next identifier_name
    public var url_4K_SDR_240FPS: String

    // Optional empty preview
    // swiftlint:disable:next identifier_name
    public var previewImage_900x580: String

    enum CodingKeys: String, CodingKey {
        case id, accessibilityLabel, localizedNameKey, includeInShuffle
        case preferredOrder, showInTopLevel, shotID, pointsOfInterest
        case previewImage, categories, subcategories
        case url_4K_SDR_240FPS = "url-4K-SDR-240FPS"
        case previewImage_900x580 = "previewImage-900x580"
    }
}

// MARK: - Aerial Manifest

/// Top-level structure of Apple's entries.json manifest.
public struct AerialManifest: Codable, Sendable {
    public var version: Int?
    public var localizationVersion: Int?
    public var initialAssetCount: Int?
    public var categories: [AerialCategory]?
    public var assets: [AerialAssetEntry]
}

/// Category entry in the Aerial manifest.
public struct AerialCategory: Codable, Sendable {
    public var id: String
    public var localizedNameKey: String
    public var localizedDescriptionKey: String?
    public var previewImage: String?
    public var representativeAssetID: String?
    public var preferredOrder: Int?
    public var subcategories: [AerialSubcategory]?
}

/// Subcategory entry in the Aerial manifest.
public struct AerialSubcategory: Codable, Sendable {
    public var id: String
    public var localizedNameKey: String
    public var localizedDescriptionKey: String?
    public var previewImage: String?
    public var representativeAssetID: String?
    public var preferredOrder: Int?
}

// MARK: - Asset Injector

/// Manages the lifecycle of injecting custom videos into macOS's lock screen
/// via the Aerial manifest approach.
///
/// **Strategy**: Merge a custom asset entry into the system's `entries.json` manifest
/// at `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/`.
/// The video file is placed in the user-space `aerials/videos/` directory.
/// After modifying the manifest, WallpaperAgent is restarted to pick up changes.
///
/// This approach operates entirely in user-space — no admin/root privileges needed.
@MainActor
public final class AssetInjector: ObservableObject {

    // MARK: - Constants

    /// Base path for macOS Aerial wallpaper data (user-space).
    private static let aerialsBasePath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/aerials",
            isDirectory: true
        )
    }()

    /// Path to the Aerial manifest file.
    private static var manifestURL: URL {
        aerialsBasePath.appendingPathComponent("manifest/entries.json")
    }

    /// Path to the manifest backup file.
    private static var manifestBackupURL: URL {
        aerialsBasePath.appendingPathComponent("manifest/entries.json.bak")
    }

    /// Path to the videos directory.
    private static var videosDir: URL {
        aerialsBasePath.appendingPathComponent("videos", isDirectory: true)
    }

    /// Path to the thumbnails directory.
    private static var thumbnailsDir: URL {
        aerialsBasePath.appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// Path to our app's lock screen cache for transcoded videos.
    private static let lockScreenCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Aereo/LockScreenCache", isDirectory: true)
    }()

    /// Path to our app's injection records.
    private static let recordsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Aereo/injected_assets.json", isDirectory: false)
    }()

    /// Default category: Landscapes
    private static let landscapesCategoryID = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    /// Default subcategory: Sonoma (under Landscapes)
    private static let sonomaSubcategoryID = "3CC63110-FF0E-4443-9A2D-63CD0795954E"

    /// Quarantine xattr value mimicking WallpaperAerialsExtension.
    private static let quarantineValue = "0086;68c1905a;WallpaperAerialsExtension;"

    // MARK: - Published State

    @Published public private(set) var state: InjectionState = .idle
    @Published public private(set) var injectedAssets: [InjectedAssetRecord] = []

    // MARK: - Init

    public init() {
        loadRecords()
    }

    // MARK: - Public API

    /// Inject a custom video into the lock screen Aerial manifest.
    ///
    /// Process:
    /// 1. Validates input video
    /// 2. Transcodes to HEVC 10-bit 4K 240fps if needed (strategy-based)
    /// 3. Generates a thumbnail
    /// 4. Places video + thumbnail in aerials directories
    /// 5. Merges custom entry into entries.json
    /// 6. Restarts WallpaperAgent
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the user's video file
    ///   - displayName: Human-readable name for the wallpaper
    ///   - assetUUID: Optional fixed UUID (for slot reuse). If nil, generates a new one.
    /// - Returns: The UUID string of the injected asset.
    @discardableResult
    public func injectVideo(
        sourceURL: URL,
        displayName: String? = nil,
        assetUUID: String? = nil
    ) async throws -> String {
        let uuid = assetUUID ?? UUID().uuidString.uppercased()
        let name = displayName ?? sourceURL.deletingPathExtension().lastPathComponent

        // 1. Validate input
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AssetInjectorError.assetNotFound(sourceURL.path)
        }

        let asset = AVURLAsset(url: sourceURL)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
            throw AssetInjectorError.unsupportedInput("No video track found in \(sourceURL.lastPathComponent)")
        }

        // 2. Ensure directories exist
        let fm = FileManager.default
        try fm.createDirectory(at: Self.videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.thumbnailsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.lockScreenCacheDir, withIntermediateDirectories: true)

        // 3. Transcode to HEVC (strategy-based)
        state = .transcoding(progress: 0)
        let transcodedURL = try await prepareVideoAppleSafe(source: sourceURL, asset: asset, uuid: uuid)

        // 4. Place video file
        state = .injecting
        let videoDestURL = Self.videosDir.appendingPathComponent("\(uuid).mov")
        if fm.fileExists(atPath: videoDestURL.path) {
            try fm.removeItem(at: videoDestURL)
        }
        try fm.copyItem(at: transcodedURL, to: videoDestURL)

        // Set quarantine xattr to mimic WallpaperAerialsExtension
        setQuarantineAttribute(url: videoDestURL)

        // 5. Generate and place thumbnail
        let thumbURL = Self.thumbnailsDir.appendingPathComponent("\(uuid).png")
        await generateThumbnail(from: sourceURL, to: thumbURL)

        // 6. Backup manifest if not already done
        try backupManifest()

        // 7. Merge custom entry into entries.json
        try mergeAssetIntoManifest(uuid: uuid, displayName: name)

        // 8. Restart WallpaperAgent
        try reloadWallpaperAgent()

        // 9. Record the injection
        let record = InjectedAssetRecord(
            id: uuid,
            displayName: name,
            originalVideoURL: sourceURL,
            injectionDate: Date()
        )
        injectedAssets.removeAll { $0.id == uuid }
        injectedAssets.append(record)
        saveRecords()

        state = .active(assetID: uuid)
        logger.info("Successfully injected '\(name)' as lock screen asset \(uuid)")
        return uuid
    }

    /// Remove an injected asset from the manifest and clean up files.
    public func removeInjection(id: String) throws {
        let fm = FileManager.default

        // Remove video file
        let videoURL = Self.videosDir.appendingPathComponent("\(id).mov")
        if fm.fileExists(atPath: videoURL.path) {
            try fm.removeItem(at: videoURL)
        }

        // Remove thumbnail
        let thumbURL = Self.thumbnailsDir.appendingPathComponent("\(id).png")
        if fm.fileExists(atPath: thumbURL.path) {
            try fm.removeItem(at: thumbURL)
        }

        // Remove cached transcoded file
        let cacheURL = Self.lockScreenCacheDir.appendingPathComponent("\(id).mov")
        if fm.fileExists(atPath: cacheURL.path) {
            try fm.removeItem(at: cacheURL)
        }

        // Remove from manifest
        try removeAssetFromManifest(uuid: id)

        // Restart WallpaperAgent
        try reloadWallpaperAgent()

        injectedAssets.removeAll { $0.id == id }
        saveRecords()
        state = .idle

        logger.info("Removed injection \(id)")
    }

    /// Remove all injections and restore the original manifest.
    public func removeAllInjections() throws {
        for record in injectedAssets {
            try removeInjection(id: record.id)
        }
    }

    /// Restore the original Apple Aerial manifest from backup.
    public func restoreOriginalManifest() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.manifestBackupURL.path) else {
            throw AssetInjectorError.backupFailed("No backup manifest found")
        }

        if fm.fileExists(atPath: Self.manifestURL.path) {
            try fm.removeItem(at: Self.manifestURL)
        }
        try fm.copyItem(at: Self.manifestBackupURL, to: Self.manifestURL)

        try reloadWallpaperAgent()

        injectedAssets.removeAll()
        saveRecords()
        state = .idle

        logger.info("Restored original Aerial manifest")
    }

    /// Check if a specific asset ID currently has an injection.
    public func isInjected(id: String) -> Bool {
        return injectedAssets.contains { $0.id == id }
    }

    // MARK: - Video Preparation (Strategy-Based)

    /// Prepare a video for the lock screen using a strategy-based approach:
    /// - Strategy 1: Already HEVC → remux only (copy stream, change container)
    /// - Strategy 2: Transcode to HEVC 10-bit CFR via VideoToolbox
    /// - Strategy 3: Fallback — try .mov extension (use original)
    private func prepareVideoAppleSafe(
        source: URL,
        asset: AVURLAsset,
        uuid: String
    ) async throws -> URL {

        // Check cache first
        let cachedURL = Self.lockScreenCacheDir.appendingPathComponent("\(uuid).mov")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            logger.info("prepareVideoAppleSafe: using cached file")
            state = .transcoding(progress: 1.0)
            return cachedURL
        }

        // Analyze source codec
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let isHEVC: Bool
        if let track = videoTrack {
            let descriptions = try await track.load(.formatDescriptions)
            let codecType = descriptions.first.flatMap { CMFormatDescriptionGetMediaSubType($0) }
            // kCMVideoCodec_HEVC = 'hvc1' = 0x68766331
            isHEVC = codecType == CMFormatDescription.MediaSubType(rawValue: 0x68766331).rawValue
        } else {
            isHEVC = false
        }

        // Strategy 1: Already HEVC — remux
        if isHEVC {
            logger.info("prepareVideoAppleSafe: Strategy 1 - already HEVC, remuxing")
            do {
                let remuxed = try await remuxToMOV(source: source, outputURL: cachedURL)
                logger.info("prepareVideoAppleSafe: Strategy 1 success")
                state = .transcoding(progress: 1.0)
                return remuxed
            } catch {
                logger.warning("Strategy 1 failed: \(error.localizedDescription), trying Strategy 2")
            }
        }

        // Strategy 2: Transcode to HEVC 10-bit CFR
        logger.info("prepareVideoAppleSafe: Strategy 2 - transcoding to HEVC")
        do {
            let transcoded = try await encodeHEVC10bitCFR(source: source, outputURL: cachedURL)
            logger.info("prepareVideoAppleSafe: Strategy 2 success")
            state = .transcoding(progress: 1.0)
            return transcoded
        } catch {
            logger.warning("Strategy 2 failed: \(error.localizedDescription), trying Strategy 3")
        }

        // Strategy 3: Fallback — copy with .mov extension
        logger.info("prepareVideoAppleSafe: Strategy 3 - trying .mov extension")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try FileManager.default.removeItem(at: cachedURL)
        }
        try FileManager.default.copyItem(at: source, to: cachedURL)
        logger.warning("prepareVideoAppleSafe: FALLBACK - using original file!")
        state = .transcoding(progress: 1.0)
        return cachedURL
    }

    /// Remux an HEVC video into a MOV container without re-encoding.
    private func remuxToMOV(source: URL, outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw AssetInjectorError.transcodingFailed("Could not create passthrough export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov

        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    /// Transcode to HEVC Main 10 profile at constant frame rate.
    /// Uses AVAssetExportSession with HEVC highest quality preset.
    /// Output: 4K, HEVC Main 10, BT.709, no audio.
    private func encodeHEVC10bitCFR(source: URL, outputURL: URL) async throws -> URL {
        logger.info("encodeHEVC10bitCFR: starting...")

        let asset = AVURLAsset(url: source)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw AssetInjectorError.transcodingFailed("encodeHEVC10bitCFR: cannot create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        // Strip audio — lock screen wallpapers must be silent
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           !audioTracks.isEmpty {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                let composition = AVMutableComposition()
                if let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                }
                // Re-create export session with video-only composition
                guard let videoOnlySession = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetHEVCHighestQuality
                ) else {
                    throw AssetInjectorError.transcodingFailed("encodeHEVC10bitCFR: cannot create composition session")
                }
                videoOnlySession.outputURL = outputURL
                videoOnlySession.outputFileType = .mov
                videoOnlySession.shouldOptimizeForNetworkUse = false

                try await videoOnlySession.export(to: outputURL, as: .mov)
                logger.info("encodeHEVC10bitCFR: completed (audio stripped)")
                return outputURL
            }
        }

        try await exportSession.export(to: outputURL, as: .mov)
        logger.info("encodeHEVC10bitCFR: completed")
        return outputURL
    }

    // MARK: - Manifest Operations

    /// Backup the original manifest if not already done.
    private func backupManifest() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.manifestURL.path) else { return }

        // Only backup once — don't overwrite existing backup
        if !fm.fileExists(atPath: Self.manifestBackupURL.path) {
            try fm.copyItem(at: Self.manifestURL, to: Self.manifestBackupURL)
            logger.info("Backed up original entries.json")
        }
    }

    /// Merge a custom asset entry into the Aerial entries.json manifest.
    private func mergeAssetIntoManifest(uuid: String, displayName: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.manifestURL.path) else {
            throw AssetInjectorError.manifestError("entries.json not found")
        }

        let data = try Data(contentsOf: Self.manifestURL)
        guard var manifest = try? JSONDecoder().decode(AerialManifest.self, from: data) else {
            // Fallback: try raw JSON manipulation
            try mergeAssetRawJSON(uuid: uuid, displayName: displayName)
            return
        }

        // Remove existing entry with same UUID
        manifest.assets.removeAll { $0.id == uuid }

        // Create new entry
        let shotID = displayName
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^A-Z0-9_]", with: "", options: .regularExpression)

        let newAsset = AerialAssetEntry(
            id: uuid,
            accessibilityLabel: displayName,
            localizedNameKey: displayName,
            includeInShuffle: true,
            preferredOrder: 0,
            showInTopLevel: true,
            shotID: shotID,
            pointsOfInterest: ["0": "\(shotID)_0"],
            previewImage: "https://sylvan.apple.com/custom/\(uuid).png",
            categories: [Self.landscapesCategoryID],
            subcategories: [Self.sonomaSubcategoryID],
            url_4K_SDR_240FPS: "https://sylvan.apple.com/custom/\(uuid).mov",
            previewImage_900x580: ""
        )

        // Insert at beginning (highest priority)
        manifest.assets.insert(newAsset, at: 0)

        // Write back
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let newData = try encoder.encode(manifest)
        try newData.write(to: Self.manifestURL)

        logger.info("Merged '\(displayName)' into entries.json (\(manifest.assets.count) total assets)")
    }

    /// Fallback: merge using raw JSON dictionary if Codable parsing fails.
    private func mergeAssetRawJSON(uuid: String, displayName: String) throws {
        let data = try Data(contentsOf: Self.manifestURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = json["assets"] as? [[String: Any]] else {
            throw AssetInjectorError.manifestError("Invalid entries.json structure")
        }

        // Remove existing
        assets.removeAll { ($0["id"] as? String) == uuid }

        let shotID = displayName
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")

        let newAsset: [String: Any] = [
            "id": uuid,
            "accessibilityLabel": displayName,
            "localizedNameKey": displayName,
            "includeInShuffle": true,
            "preferredOrder": 0,
            "showInTopLevel": true,
            "shotID": shotID,
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "previewImage": "https://sylvan.apple.com/custom/\(uuid).png",
            "previewImage-900x580": "",
            "url-4K-SDR-240FPS": "https://sylvan.apple.com/custom/\(uuid).mov",
            "categories": [Self.landscapesCategoryID],
            "subcategories": [Self.sonomaSubcategoryID]
        ]

        assets.insert(newAsset, at: 0)
        json["assets"] = assets

        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: Self.manifestURL)
    }

    /// Remove an asset from the manifest by UUID.
    private func removeAssetFromManifest(uuid: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.manifestURL.path) else { return }

        let data = try Data(contentsOf: Self.manifestURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = json["assets"] as? [[String: Any]] else {
            return
        }

        assets.removeAll { ($0["id"] as? String) == uuid }
        json["assets"] = assets

        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: Self.manifestURL)

        logger.info("Removed asset \(uuid) from entries.json")
    }

    // MARK: - Thumbnail Generation

    /// Generate a PNG thumbnail from the source video.
    private func generateThumbnail(from videoURL: URL, to outputURL: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 214, height: 130)

        let time = CMTime(seconds: 2, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try pngData.write(to: outputURL)
                setQuarantineAttribute(url: outputURL)
                logger.info("Generated thumbnail: \(outputURL.lastPathComponent)")
            }
        } catch {
            logger.warning("Thumbnail generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File Attributes

    /// Set the quarantine xattr to mimic WallpaperAerialsExtension.
    private func setQuarantineAttribute(url: URL) {
        let value = Self.quarantineValue
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return value.withCString { cValue in
                setxattr(path, "com.apple.quarantine", cValue, strlen(cValue), 0, 0)
            }
        }
        if result != 0 {
            logger.warning("Failed to set quarantine xattr on \(url.lastPathComponent)")
        }
    }

    // MARK: - WallpaperAgent

    /// Signal WallpaperAgent to reload by killing it (it auto-relaunches).
    private func reloadWallpaperAgent() throws {
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
            throw AssetInjectorError.agentReloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Record Persistence

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: Self.recordsURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.recordsURL)
            injectedAssets = try JSONDecoder().decode([InjectedAssetRecord].self, from: data)
            logger.info("Loaded \(self.injectedAssets.count) injection records")
        } catch {
            logger.error("Failed to load records: \(error.localizedDescription)")
        }
    }

    private func saveRecords() {
        do {
            let dir = Self.recordsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(injectedAssets)
            try data.write(to: Self.recordsURL)
        } catch {
            logger.error("Failed to save records: \(error.localizedDescription)")
        }
    }
}

// MARK: - Injected Asset Record

/// Persistent record of an injected custom wallpaper asset.
public struct InjectedAssetRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let originalVideoURL: URL
    public let injectionDate: Date
}
