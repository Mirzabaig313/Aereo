// MARK: - WallpaperWindow.swift
// AereoCore
//
// Borderless NSWindow positioned at desktop level for video wallpaper rendering.
// Sits above system wallpaper, below desktop icons and Dock.

import AppKit
import os.log

private let logger = Logger(subsystem: "com.aereo.core", category: "WallpaperWindow")

/// A borderless, non-interactive window positioned at the desktop wallpaper level.
/// This window hosts the video player layer and is invisible to Mission Control,
/// application switcher, and mouse events.
@MainActor
public final class WallpaperWindow: NSWindow {

    /// The display this window is assigned to.
    public let targetScreen: NSScreen

    /// The unique display ID for this screen.
    public let displayID: CGDirectDisplayID

    /// Initialize a wallpaper window for the given screen.
    /// - Parameter screen: The NSScreen this window covers.
    public init(screen: NSScreen) {
        self.targetScreen = screen
        self.displayID = screen.displayID

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        configureWindow()
        logger.info("WallpaperWindow created for display \(self.displayID)")
    }

    // MARK: - Configuration

    private func configureWindow() {
        // Position below desktop icons, above system wallpaper
        // kCGDesktopWindowLevel = -2147483623, we use -2147483622 (one above)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

        // Make it span the entire screen
        setFrame(targetScreen.frame, display: true)

        // Transparent, borderless
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Don't show in Mission Control, Exposé, or Cmd-Tab
        collectionBehavior = [
            .canJoinAllSpaces,   // Visible on all Spaces
            .stationary,          // Don't move during Exposé
            .ignoresCycle,        // Skip in Cmd-Tab
            .fullScreenAuxiliary  // Don't interfere with full-screen apps
        ]

        // Don't steal focus or interact with mouse
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Ensure it's always visible
        orderBack(nil)
    }

    // MARK: - Window Behavior Overrides

    /// Prevent this window from ever becoming key.
    override public var canBecomeKey: Bool { false }

    /// Prevent this window from ever becoming main.
    override public var canBecomeMain: Bool { false }

    // MARK: - Screen Updates

    /// Reposition the window when screen geometry changes.
    public func updateFrame(for screen: NSScreen) {
        setFrame(screen.frame, display: true, animate: false)
        logger.debug("WallpaperWindow repositioned for display \(self.displayID)")
    }

    /// Show the window on screen.
    public func show() {
        orderBack(nil)
        logger.info("WallpaperWindow shown on display \(self.displayID)")
    }

    /// Hide the window.
    public func hide() {
        orderOut(nil)
        logger.info("WallpaperWindow hidden on display \(self.displayID)")
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    public var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
