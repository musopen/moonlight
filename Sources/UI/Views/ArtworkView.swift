// ArtworkView.swift
//
// Shows an album cover image anywhere in the app. It loads the picture from the library database
// in the background, keeps recently used images in memory so scrolling stays smooth, and shows a
// music-note placeholder while loading or when there is no artwork.

import SwiftUI
import AppKit
import GRDB

private final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 600
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct ArtworkView: View {
    let albumId: Int64?
    var artworkId: Int64?
    var large: Bool = false
    var decodeMaxPixelSize: Int?
    var cornerRadius: CGFloat = 8
    var iconFont: Font = .title2
    var retainsPreviousImageWhileLoading = false

    @EnvironmentObject var appState: AppState
    @State private var image: NSImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(iconFont)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .onAppear { startLoad() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: taskKey) { _, _ in
            if !retainsPreviousImageWhileLoading {
                image = nil
            }
            startLoad()
        }
    }

    private var taskKey: String {
        "\(artworkId.map(String.init) ?? albumId.map { "album-\($0)" } ?? "nil")-\(large)-\(decodeMaxPixelSize ?? 0)-\(appState.libraryVersion)"
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    @MainActor
    private func load() async {
        let key = taskKey
        if let cached = ArtworkImageCache.shared.image(for: key) {
            image = cached
            return
        }

        let albumId = albumId
        let artworkId = artworkId
        let dbManager = appState.db
        let loadedImage = await Task.detached(priority: .userInitiated) {
            try? dbManager.read { db -> NSImage? in
                let resolvedArtworkId: Int64?
                if let artworkId {
                    resolvedArtworkId = artworkId
                } else if let albumId {
                    resolvedArtworkId = try Album.fetchOne(db, key: albumId)?.artworkId
                } else {
                    resolvedArtworkId = nil
                }

                guard let resolvedArtworkId else { return nil }
                let column = large ? "data_large" : "data_small"
                guard let data = try Data.fetchOne(
                    db,
                    sql: "SELECT \(column) FROM artwork WHERE id = ?",
                    arguments: [resolvedArtworkId]
                ) else { return nil }
                return Artwork.image(from: data, maxPixelSize: decodeMaxPixelSize)
            }
        }.value ?? nil

        guard !Task.isCancelled else { return }
        if let loadedImage {
            ArtworkImageCache.shared.set(loadedImage, for: key)
        }
        image = loadedImage
    }
}
