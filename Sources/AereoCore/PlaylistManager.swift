// MARK: - PlaylistManager.swift
// AereoCore
//
// Manages video wallpaper playlists with time-based scheduling,
// sequential or shuffled playback, and duration-based rotation.

import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "PlaylistManager")

// MARK: - PlaylistManager

/// Manages playlist rotation for a single display.
@MainActor
public final class PlaylistManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var isPlaying: Bool = false

    // MARK: - Properties

    public var playlist: [PlaylistEntry] = []
    public var isShuffled: Bool = false
    public var rotationInterval: TimeInterval = 300 // 5 minutes default

    // MARK: - Callbacks

    /// Called when the playlist advances to a new video.
    public var onVideoChange: ((URL) -> Void)?

    // MARK: - Private

    private var rotationTimer: Timer?
    private var shuffledOrder: [Int] = []

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Start playlist rotation.
    public func start() {
        guard !playlist.isEmpty else {
            logger.warning("Cannot start empty playlist")
            return
        }

        isPlaying = true

        if isShuffled {
            shuffledOrder = Array(0..<playlist.count).shuffled()
            currentIndex = 0
        }

        playCurrentEntry()
        scheduleNextRotation()

        logger.info("Playlist started with \(self.playlist.count) entries")
    }

    /// Stop playlist rotation.
    public func stop() {
        isPlaying = false
        rotationTimer?.invalidate()
        rotationTimer = nil
        logger.info("Playlist stopped")
    }

    /// Advance to the next video.
    public func next() {
        guard !playlist.isEmpty else { return }

        if isShuffled {
            currentIndex = (currentIndex + 1) % shuffledOrder.count
        } else {
            currentIndex = (currentIndex + 1) % playlist.count
        }

        playCurrentEntry()
        scheduleNextRotation()
    }

    /// Go to the previous video.
    public func previous() {
        guard !playlist.isEmpty else { return }

        if isShuffled {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : shuffledOrder.count - 1
        } else {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : playlist.count - 1
        }

        playCurrentEntry()
        scheduleNextRotation()
    }

    /// Set playlist entries.
    public func setPlaylist(_ entries: [PlaylistEntry]) {
        playlist = entries
        currentIndex = 0
        if isShuffled {
            shuffledOrder = Array(0..<entries.count).shuffled()
        }
    }

    /// Add a video to the playlist.
    public func addVideo(url: URL) {
        let entry = PlaylistEntry(videoURL: url)
        playlist.append(entry)
        if isShuffled {
            shuffledOrder.append(playlist.count - 1)
            shuffledOrder.shuffle()
        }
    }

    /// Remove a video from the playlist.
    public func removeVideo(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        playlist.remove(at: index)
        if currentIndex >= playlist.count {
            currentIndex = max(0, playlist.count - 1)
        }
        if isShuffled {
            shuffledOrder = Array(0..<playlist.count).shuffled()
        }
    }

    // MARK: - Private

    private func playCurrentEntry() {
        let actualIndex: Int
        if isShuffled && !shuffledOrder.isEmpty {
            actualIndex = shuffledOrder[currentIndex]
        } else {
            actualIndex = currentIndex
        }

        guard playlist.indices.contains(actualIndex) else { return }
        let entry = playlist[actualIndex]
        onVideoChange?(entry.videoURL)
        logger.debug("Playing playlist entry \(actualIndex): \(entry.displayName)")
    }

    private func scheduleNextRotation() {
        rotationTimer?.invalidate()

        let actualIndex: Int
        if isShuffled && !shuffledOrder.isEmpty {
            actualIndex = shuffledOrder[currentIndex]
        } else {
            actualIndex = currentIndex
        }

        let interval: TimeInterval
        if playlist.indices.contains(actualIndex), let duration = playlist[actualIndex].duration {
            interval = duration
        } else {
            interval = rotationInterval
        }

        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
        }
    }
}
