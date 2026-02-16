# Aereo

**Open-source video wallpaper for macOS 15+**

A hardware-accelerated live video wallpaper app that runs in your menu bar. Built with Swift 6, AVFoundation, and SwiftUI. Supports lock screen video wallpapers on macOS 26+ via native Aerial manifest injection — no admin privileges required.

## Features

- **4K Video Wallpapers** — Hardware-accelerated playback via AVFoundation
- **Gapless Looping** — AVQueuePlayer + AVPlayerLooper for seamless playback
- **Multi-Monitor Support** — Independent wallpaper per display
- **Power Aware** — Auto-pauses on battery, screen sleep, thermal throttling
- **Fullscreen Detection** — Pauses when apps go fullscreen
- **Liquid Glass Compatible** — Periodic snapshot sync for macOS 26 UI transparency
- **Playlist Support** — Timed rotation with shuffle
- **Lock Screen Wallpapers** — Aerial manifest injection (macOS 26+, user-space, no root)
- **Siri Shortcuts** — Pause, Resume, Next via AppIntents
- **Auto-Updates** — Sparkle integration for seamless updates
- **Menu Bar App** — No Dock icon, minimal footprint
- **Drag & Drop** — Drop videos into the library
- **Launch at Login** — SMAppService-based login item

## Architecture

```
Aereo/
├── AereoCore/               # Rendering engine & system integration
│   ├── WallpaperWindow       # Borderless NSWindow at desktop level
│   ├── VideoPlayer            # AVQueuePlayer + AVPlayerLooper (gapless)
│   ├── DisplayCoordinator     # Multi-monitor management
│   ├── PowerManager           # Battery/thermal/occlusion awareness
│   ├── PlaylistManager        # Timed rotation & shuffle
│   ├── Configuration          # Persistent settings (JSON)
│   ├── AssetInjector          # HEVC transcoding & Aerial manifest injection
│   ├── ConfigEditor           # Desktop wallpaper sync via NSWorkspace
│   ├── LoginItemManager       # SMAppService login item + ScreenLockObserver
│   └── WallpaperIntents       # AppIntents for Siri Shortcuts
├── AereoUI/                  # SwiftUI interface
│   ├── MenuBarView            # Menu bar controls + Check for Updates
│   ├── LibraryView            # Video browser with thumbnails
│   └── SettingsView           # Settings panel
├── AereoApp/                 # App entry point + Sparkle updater
├── .github/workflows/         # CI/CD, signing, notarization, release
└── Casks/                     # Homebrew cask formula
```

## How It Works

### Desktop Wallpaper
The app creates invisible borderless windows at `kCGDesktopWindowLevel - 1` — positioned above the system wallpaper but below desktop icons. Each window hosts an `AVPlayerLayer` with hardware-accelerated video decoding.

```
┌─────────────────────────────────┐
│  Normal Windows        (0)      │
├─────────────────────────────────┤
│  Desktop Icons  (-2147483603)   │
├─────────────────────────────────┤
│  ▶ VIDEO LAYER  (-2147483622)   │  ← Our window
├─────────────────────────────────┤
│  System Wallpaper (-2147483623) │
└─────────────────────────────────┘
```

### Lock Screen (macOS 26+)
Lock screen video wallpapers use **Aerial Manifest Injection** — a user-space technique requiring no admin privileges:

1. **Transcode** — Convert user's video to HEVC Main 10, 4K, 240fps matching Apple's Aerial format
2. **Inject** — Place video at `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<UUID>.mov`
3. **Manifest** — Merge a custom entry into `~/Library/.../aerials/manifest/entries.json`
4. **Thumbnail** — Generate a PNG thumbnail alongside the video
5. **Xattr** — Set quarantine attribute to match system expectations
6. **Reload** — `killall WallpaperAgent` to pick up the new asset

The system's own `WallpaperVideoExtension` then plays the file natively — zero CPU usage from our app. This persists across screen lock/unlock cycles.

> **Note**: Entirely user-space — no admin privileges, no root, no system directory writes. Clean uninstall removes injected entries from the manifest and deletes the video files.

### Siri Shortcuts
Three AppIntents are registered: **Pause**, **Resume**, **Next Wallpaper**. They communicate with the running app via `DistributedNotificationCenter`.

## Requirements

- macOS 15.0+ (Sequoia) for desktop wallpaper
- macOS 26+ (Tahoe) for lock screen wallpaper
- Xcode 16+ (for tests; `swift build` works with CommandLineTools)
- Swift 6

## Build

```bash
cd Aereo
swift build
swift run Aereo
```

## Install via Homebrew

```bash
brew install --cask aereo
```

## Distribution

Distributed outside the Mac App Store (requires filesystem access for lock screen features):
- **GitHub Releases** — Signed & notarized DMG via GitHub Actions
- **Homebrew Cask** — `brew install --cask aereo`
- **Sparkle** — Automatic update checks from the menu bar

### CI/CD Pipeline
The GitHub Actions workflow handles:
1. Build (debug + release)
2. Code signing with Developer ID certificate
3. DMG creation
4. Apple notarization + stapling
5. GitHub Release with changelog

## Supported Formats

| Format | Container | Notes |
|--------|-----------|-------|
| H.264  | .mp4, .mov, .m4v | Universal compatibility |
| HEVC   | .mp4, .mov | Better compression, hardware decoded on Apple Silicon |
| HEVC Main 10 (4K SDR 240fps) | .mov | Required format for lock screen injection |

## License

MIT
