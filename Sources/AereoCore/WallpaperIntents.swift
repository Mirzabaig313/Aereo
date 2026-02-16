// MARK: - WallpaperIntents.swift
// AereoCore
//
// AppIntents for Shortcuts integration.
// Provides "Pause", "Resume", "Next Wallpaper" actions.

import AppIntents
import Foundation

// MARK: - Pause Wallpaper Intent

@available(macOS 13.0, *)
public struct PauseWallpaperIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause Live Wallpaper"
    public static let description: IntentDescription = "Pauses the live wallpaper playback."

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.aereo.pause"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

// MARK: - Resume Wallpaper Intent

@available(macOS 13.0, *)
public struct ResumeWallpaperIntent: AppIntent {
    public static let title: LocalizedStringResource = "Resume Live Wallpaper"
    public static let description: IntentDescription = "Resumes the live wallpaper playback."

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.aereo.resume"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

// MARK: - Next Wallpaper Intent

@available(macOS 13.0, *)
public struct NextWallpaperIntent: AppIntent {
    public static let title: LocalizedStringResource = "Next Wallpaper"
    public static let description: IntentDescription = "Advances to the next video in the wallpaper playlist."

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.aereo.next"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

// MARK: - App Shortcuts Provider

@available(macOS 13.0, *)
public struct AereoShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseWallpaperIntent(),
            phrases: [
                "Pause \(.applicationName) wallpaper",
                "Pause live wallpaper"
            ],
            shortTitle: "Pause Wallpaper",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeWallpaperIntent(),
            phrases: [
                "Resume \(.applicationName) wallpaper",
                "Play live wallpaper"
            ],
            shortTitle: "Resume Wallpaper",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: NextWallpaperIntent(),
            phrases: [
                "Next \(.applicationName) wallpaper",
                "Change wallpaper"
            ],
            shortTitle: "Next Wallpaper",
            systemImageName: "forward.fill"
        )
    }
}
