// MARK: - DisplayCoordinator.swift
// AereoCore
//
// Manages video wallpaper windows across all connected displays.
// Handles multi-monitor setup, screen changes, and per-display configuration.
// Coordinates with PowerManager for intelligent resource management.

@preconcurrency import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "DisplayCoordinator")

// MARK: - Display Entry

/// Represents a single display's wallpaper state.
@MainActor
public final class DisplayEntry: ObservableObject, Identifiable {
    public let id: CGDirectDisplayID
    public let window: WallpaperWindow
    public let videoPlayer: VideoPlayer

    @Published public var videoURL: URL?
    @Published public var isActive: Bool = true

    init(screen: NSScreen) {
        self.id = screen.displayID
        self.window = WallpaperWindow(screen: screen)
        self.videoPlayer = VideoPlayer()

        // Attach player layer to window
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer?.addSublayer(videoPlayer.playerLayer)
        videoPlayer.playerLayer.frame = contentView.bounds

        // Auto-resize player layer with view
        contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.videoPlayer.playerLayer.frame = contentView.bounds
            }
        }

        window.contentView = contentView
    }

    func updateFrame(for screen: NSScreen) {
        window.updateFrame(for: screen)
        if let contentView = window.contentView {
            videoPlayer.playerLayer.frame = contentView.bounds
        }
    }
}

// MARK: - DisplayCoordinator

/// Coordinates video wallpaper windows across all connected displays.
/// Monitors display configuration changes and manages per-display playback.
@MainActor
public final class DisplayCoordinator: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var displays: [CGDirectDisplayID: DisplayEntry] = [:]
    @Published public private(set) var activeDisplayCount: Int = 0

    // MARK: - Dependencies

    public let powerManager: PowerManager

    // MARK: - Private

    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(powerManager: PowerManager = PowerManager()) {
        self.powerManager = powerManager

        setupObservers()
        setupPowerManagement()

        logger.info("DisplayCoordinator initialized")
    }

    deinit {
        // Observers are auto-removed when the object is deallocated
    }

    // MARK: - Public API

    /// Initialize wallpaper windows for all connected displays.
    public func setupAllDisplays() {
        logger.info("Setting up wallpaper windows for all displays")

        let screens = NSScreen.screens
        var newDisplays: [CGDirectDisplayID: DisplayEntry] = [:]

        for screen in screens {
            let displayID = screen.displayID

            if let existing = displays[displayID] {
                // Reuse existing entry, update frame
                existing.updateFrame(for: screen)
                newDisplays[displayID] = existing
            } else {
                // Create new entry
                let entry = DisplayEntry(screen: screen)
                powerManager.observeOcclusion(of: entry.window)
                newDisplays[displayID] = entry
                logger.info("Created wallpaper window for display \(displayID)")
            }
        }

        // Remove windows for disconnected displays
        for (displayID, entry) in displays where newDisplays[displayID] == nil {
            entry.videoPlayer.stop()
            entry.window.close()
            logger.info("Removed wallpaper window for disconnected display \(displayID)")
        }

        displays = newDisplays
        activeDisplayCount = displays.count
    }

    /// Set a video wallpaper for a specific display.
    /// - Parameters:
    ///   - url: File URL to the video.
    ///   - displayID: Target display ID. If nil, applies to the main display.
    public func setVideo(url: URL, for displayID: CGDirectDisplayID? = nil) {
        let targetID = displayID ?? NSScreen.main?.displayID ?? 0

        guard let entry = displays[targetID] else {
            logger.error("No display entry for ID \(targetID)")
            return
        }

        entry.videoURL = url
        entry.videoPlayer.load(url: url)
        entry.window.show()

        logger.info("Set video \(url.lastPathComponent) for display \(targetID)")
    }

    /// Set the same video wallpaper on all displays.
    /// - Parameter url: File URL to the video.
    public func setVideoForAllDisplays(url: URL) {
        for (displayID, _) in displays {
            setVideo(url: url, for: displayID)
        }
    }

    /// Pause playback on all displays.
    public func pauseAll() {
        for (_, entry) in displays {
            entry.videoPlayer.pause()
        }
        logger.info("All displays paused")
    }

    /// Resume playback on all displays.
    public func resumeAll() {
        for (_, entry) in displays {
            entry.videoPlayer.play()
        }
        logger.info("All displays resumed")
    }

    /// Stop playback and hide all wallpaper windows.
    public func stopAll() {
        for (_, entry) in displays {
            entry.videoPlayer.stop()
            entry.window.hide()
        }
        logger.info("All displays stopped")
    }

    /// Capture a snapshot of the current frame and set it as the static wallpaper.
    /// This ensures Liquid Glass blur sampling matches the video content.
    public func syncStaticWallpaper() async {
        for (_, entry) in displays {
            guard let image = await entry.videoPlayer.captureCurrentFrame() else { continue }

            // Save snapshot to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("aereo_snapshot_\(entry.id).jpg")

            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                continue
            }

            do {
                try jpegData.write(to: tempURL)
                if let screen = NSScreen.screens.first(where: { $0.displayID == entry.id }) {
                    try NSWorkspace.shared.setDesktopImageURL(tempURL, for: screen, options: [:])
                    logger.debug("Static wallpaper synced for display \(entry.id)")
                }
            } catch {
                logger.error("Failed to sync static wallpaper: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func setupObservers() {
        // Monitor display configuration changes (connect/disconnect/rearrange)
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }

        // Monitor Space changes
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSpaceChange()
            }
        }
    }

    private func setupPowerManagement() {
        powerManager.onPlaybackStateChange = { [weak self] shouldPlay in
            Task { @MainActor in
                if shouldPlay {
                    self?.resumeAll()
                } else {
                    self?.pauseAll()
                }
            }
        }
        powerManager.startMonitoring()
    }

    private func handleScreenChange() {
        logger.info("Screen configuration changed, updating displays")
        setupAllDisplays()

        // Re-apply videos to updated displays
        for (_, entry) in displays {
            if let url = entry.videoURL {
                entry.videoPlayer.load(url: url)
                entry.window.show()
            }
        }
    }

    private func handleSpaceChange() {
        logger.debug("Space changed, ensuring window visibility")
        // Windows with .canJoinAllSpaces should persist, but verify
        for (_, entry) in displays {
            if entry.videoURL != nil {
                entry.window.orderBack(nil)
            }
        }
    }
}
