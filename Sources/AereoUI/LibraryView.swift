// MARK: - LibraryView.swift
// AereoUI
//
// Video library browser for selecting and managing wallpaper videos.
// Supports drag-and-drop, file picker, and thumbnail previews.

import SwiftUI
import AVFoundation
import AereoCore

// MARK: - Video Item

struct VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let duration: TimeInterval
    let resolution: CGSize
    var thumbnail: NSImage?

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var resolutionString: String {
        "\(Int(resolution.width))×\(Int(resolution.height))"
    }
}

// MARK: - Library View

public struct LibraryView: View {
    @ObservedObject var coordinator: DisplayCoordinator
    @ObservedObject var configManager: ConfigurationManager
    @State private var videos: [VideoItem] = []
    @State private var selectedVideo: VideoItem?
    @State private var isLoading = false
    @State private var showFilePicker = false
    @State private var dragOver = false

    public init(coordinator: DisplayCoordinator, configManager: ConfigurationManager) {
        self.coordinator = coordinator
        self.configManager = configManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding()

            Divider()

            // Video grid
            if videos.isEmpty {
                emptyState
            } else {
                videoGrid
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { loadVideos() }
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if dragOver {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                    .padding(8)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var toolbar: some View {
        HStack {
            Text("Video Library")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }

            Button(action: { showFilePicker = true }) {
                Label("Add Videos", systemImage: "plus")
            }

            Button(action: loadVideos) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Videos")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Drop video files here or click Add Videos")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Button("Add Videos") { showFilePicker = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
            ], spacing: 16) {
                ForEach(videos) { video in
                    VideoCard(
                        video: video,
                        isSelected: selectedVideo?.id == video.id,
                        onSelect: { selectedVideo = video },
                        onSetWallpaper: { setAsWallpaper(video) },
                        onDelete: { deleteVideo(video) }
                    )
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func loadVideos() {
        isLoading = true
        Task {
            let libraryURL = configManager.videoLibraryURL
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: [.contentTypeKey],
                options: [.skipsHiddenFiles]
            ) else {
                isLoading = false
                return
            }

            let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
            var items: [VideoItem] = []

            for url in contents where videoExtensions.contains(url.pathExtension.lowercased()) {
                if let item = await loadVideoMetadata(url: url) {
                    items.append(item)
                }
            }

            videos = items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            isLoading = false
        }
    }

    private func loadVideoMetadata(url: URL) async -> VideoItem? {
        let asset = AVURLAsset(url: url)

        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch {
            duration = 0
        }

        var resolution = CGSize(width: 1920, height: 1080)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = try? await track.load(.naturalSize)
            if let size { resolution = size }
        }

        // Generate thumbnail
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 225)

        var thumbnail: NSImage?
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            thumbnail = nil
        }

        return VideoItem(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            resolution: resolution,
            thumbnail: thumbnail
        )
    }

    private func setAsWallpaper(_ video: VideoItem) {
        coordinator.setVideoForAllDisplays(url: video.url)
    }

    private func deleteVideo(_ video: VideoItem) {
        try? FileManager.default.removeItem(at: video.url)
        videos.removeAll { $0.id == video.id }
        if selectedVideo?.id == video.id {
            selectedVideo = nil
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    self.copyToLibrary(url: url)
                }
            }
        }
        return true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            copyToLibrary(url: url)
        }
    }

    private func copyToLibrary(url: URL) {
        let destination = configManager.videoLibraryURL.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            loadVideos()
            return
        }

        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        try? FileManager.default.copyItem(at: url, to: destination)
        DispatchQueue.main.async { loadVideos() }
    }
}

// MARK: - Video Card

struct VideoCard: View {
    let video: VideoItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onSetWallpaper: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let thumbnail = video.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(16/9, contentMode: .fill)
                        .overlay {
                            Image(systemName: "film")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                        }
                }

                // Duration badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(video.formattedDuration)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(6)
            }
            .cornerRadius(8)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(video.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(video.resolutionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions
            HStack {
                Button("Set Wallpaper", action: onSetWallpaper)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Set as Wallpaper", action: onSetWallpaper)
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(video.url.path, inFileViewerRootedAtPath: "")
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
