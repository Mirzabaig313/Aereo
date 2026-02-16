// MARK: - VideoPlayer.swift
// AereoCore
//
// AVQueuePlayer + AVPlayerLooper for seamless gapless video wallpaper playback.
// Based on reverse-engineered Wallper.app approach: uses AVQueuePlayer with
// AVPlayerLooper for true gapless looping (no seek-to-zero stutter).
// Includes resource monitors for CPU/battery/fullscreen-aware playback.

import AVFoundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "VideoPlayer")

// MARK: - Playback State

/// Represents the playback state of a video wallpaper.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case error(String)
}

// MARK: - VideoPlayer

/// Hardware-accelerated video player designed for wallpaper rendering.
///
/// Uses `AVQueuePlayer` + `AVPlayerLooper` for seamless gapless looping,
/// which eliminates the brief stutter that occurs with seek-to-zero looping.
/// This is the same approach used by Wallper.app (discovered via RE).
@MainActor
public final class VideoPlayer: NSObject, ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var currentVideoURL: URL?
    @Published public var preferredFrameRate: Float = 0  // 0 = native

    // MARK: - AVFoundation (AVQueuePlayer + Looper)

    public let player: AVQueuePlayer
    public let playerLayer: AVPlayerLayer

    /// The looper that manages gapless playback.
    private var looper: AVPlayerLooper?

    /// Template item used by the looper.
    private var templateItem: AVPlayerItem?

    private var statusObservation: NSKeyValueObservation?

    // MARK: - Configuration

    /// Video fill mode for the player layer.
    public var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    // MARK: - Init

    public override init() {
        self.player = AVQueuePlayer()
        self.playerLayer = AVPlayerLayer(player: player)

        super.init()

        // Silent playback — wallpapers should never produce audio
        player.isMuted = true
        player.volume = 0.0

        // Prevent automatic waiting (play immediately when ready)
        player.automaticallyWaitsToMinimizeStalling = false

        // Configure layer
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        logger.info("VideoPlayer initialized (AVQueuePlayer + Looper)")
    }

    deinit {
        statusObservation?.invalidate()
        looper?.disableLooping()
    }

    // MARK: - Public API

    /// Load and start playing a video file with gapless looping.
    /// - Parameter url: File URL to the video (MP4, MOV, M4V).
    public func load(url: URL) {
        guard url != currentVideoURL else {
            logger.debug("Same video already loaded, skipping")
            return
        }

        stop()
        state = .loading
        currentVideoURL = url

        logger.info("Loading video: \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        let item = AVPlayerItem(asset: asset)

        // Apply preferred frame rate if set
        if preferredFrameRate > 0 {
            item.preferredPeakBitRate = Double(preferredFrameRate) * 1_000_000
        }

        self.templateItem = item

        // Observe item status
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleItemStatus(item.status)
            }
        }

        // Create the looper — this is the key difference from seek-to-zero.
        // AVPlayerLooper pre-buffers the next iteration for gapless transitions.
        looper = AVPlayerLooper(player: player, templateItem: item)

        player.play()
        logger.info("Looper created, playback starting")
    }

    /// Load and play from a list of URLs (shuffle/playlist mode).
    /// - Parameter urls: Array of video file URLs to play in sequence, looping.
    public func loadPlaylist(urls: [URL]) {
        guard !urls.isEmpty else { return }

        // For a single item, use standard looper
        if urls.count == 1 {
            load(url: urls[0])
            return
        }

        stop()
        state = .loading
        currentVideoURL = urls.first

        logger.info("Loading playlist with \(urls.count) items")

        // Create items for all URLs
        let items = urls.map { url in
            AVPlayerItem(asset: AVURLAsset(url: url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]))
        }

        // AVQueuePlayer handles sequential playback
        player.removeAllItems()
        for item in items {
            if player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
            }
        }

        // Observe the first item's status
        if let firstItem = items.first {
            statusObservation = firstItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    self?.handleItemStatus(item.status)
                }
            }
        }

        // Note: For playlist mode we don't use AVPlayerLooper (it only supports single items).
        // Instead we re-queue items as they finish via actionAtItemEnd.
        player.actionAtItemEnd = .advance
        setupPlaylistLoopObserver(allURLs: urls)

        player.play()
    }

    /// Resume playback.
    public func play() {
        guard currentVideoURL != nil else { return }
        player.play()
        state = .playing
        logger.debug("Playback resumed")
    }

    /// Pause playback.
    public func pause() {
        player.pause()
        state = .paused
        logger.debug("Playback paused")
    }

    /// Toggle between play and pause.
    public func togglePlayback() {
        switch state {
        case .playing:
            pause()
        case .paused:
            play()
        default:
            break
        }
    }

    /// Stop playback and release resources.
    public func stop() {
        statusObservation?.invalidate()
        statusObservation = nil

        looper?.disableLooping()
        looper = nil

        player.pause()
        player.removeAllItems()
        templateItem = nil
        currentVideoURL = nil
        state = .idle

        logger.info("Playback stopped")
    }

    /// Capture a snapshot of the current video frame.
    /// - Returns: NSImage of the current frame, or nil if unavailable.
    public func captureCurrentFrame() async -> NSImage? {
        guard let item = player.currentItem,
              let asset = item.asset as? AVURLAsset else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = item.currentTime()

        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            logger.error("Frame capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            state = .playing
            logger.info("Video ready to play")
        case .failed:
            let message = player.currentItem?.error?.localizedDescription ?? "Unknown error"
            state = .error(message)
            logger.error("Video failed to load: \(message)")
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// For playlist mode, re-queue completed items at the end to create infinite loop.
    private nonisolated(unsafe) var playlistObserver: NSObjectProtocol?

    /// Index tracker for playlist looping — accessed only from .main queue.
    private nonisolated(unsafe) var playlistIndex: Int = 0

    private func setupPlaylistLoopObserver(allURLs: [URL]) {
        removePlaylistObserver()
        playlistIndex = 0
        playlistObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let finishedURL = allURLs[self.playlistIndex % allURLs.count]
            self.playlistIndex += 1
            Task { @MainActor in
                self.handlePlaylistItemEnd(finishedURL: finishedURL, allURLs: allURLs)
            }
        }
    }

    private func handlePlaylistItemEnd(finishedURL: URL, allURLs: [URL]) {
        // Re-queue the finished item at the end for infinite playlist looping
        let newItem = AVPlayerItem(asset: AVURLAsset(url: finishedURL))
        if player.canInsert(newItem, after: nil) {
            player.insert(newItem, after: nil)
        }
        logger.debug("Playlist: re-queued \(finishedURL.lastPathComponent)")
    }

    private func removePlaylistObserver() {
        if let observer = playlistObserver {
            NotificationCenter.default.removeObserver(observer)
            playlistObserver = nil
        }
    }
}

// MARK: - Power Monitor

/// Monitors battery state to pause wallpaper on battery power.
/// Wallper uses IOKit for this; we use IOPSCopyPowerSourcesInfo for simplicity.
@MainActor
public final class PowerMonitor: ObservableObject {

    @Published public private(set) var isOnBattery: Bool = false
    @Published public var pauseOnBattery: Bool = false

    private var timer: Timer?

    public init() {}

    /// Start monitoring power source.
    public func startMonitoring(interval: TimeInterval = 10.0) {
        checkPowerState()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPowerState()
            }
        }
        logger.info("PowerMonitor: started")
    }

    /// Stop monitoring.
    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        logger.info("PowerMonitor: stopped")
    }

    private func checkPowerState() {
        // Use ProcessInfo for simplicity — checks if Mac has a battery and
        // thermal state, although for full accuracy IOPSCopyPowerSourcesInfo is preferred.
        let thermalState = ProcessInfo.processInfo.thermalState
        let wasOnBattery = isOnBattery

        // Simple heuristic: check if we're on battery via IOKit
        // For now, use Process to call pmset
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            isOnBattery = output.contains("Battery Power")
        } catch {
            // Cannot determine — assume plugged in
            isOnBattery = false
        }

        if isOnBattery != wasOnBattery {
            logger.info("PowerMonitor: power state changed to \(self.isOnBattery ? "battery" : "AC")")
        }

        // Also check thermal state
        if thermalState == .critical || thermalState == .serious {
            logger.warning("PowerMonitor: thermal state is \(String(describing: thermalState)) — consider pausing")
        }
    }
}
