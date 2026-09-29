// AlbumsGridView.swift
//
// The Albums page: a grid of album covers for the whole library. Clicking a cover opens that
// album; several albums can be selected (including by dragging a rectangle) to play, shuffle,
// queue, edit tags or remove together, or dragged onto a playlist. The album tile shared by the
// Artists and Genres pages is defined here too.

import AppKit
import SwiftUI
import GRDB
import UniformTypeIdentifiers

struct AlbumsGridView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var albums: [Album] = []
    @State private var selectedAlbum: Album?
    @State private var selection = OrderedSelection<Int64>()
    @State private var keyMonitor: Any?
    @State private var albumFrames: [Int64: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var pendingPlaybackAlbumId: Int64?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)]

    private var selectedAlbums: [Album] {
        albums.filter { album in
            guard let id = album.id else { return false }
            return selection.contains(id)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ContentToolbarView(
                    title: "Albums",
                    subtitle: albums.isEmpty ? nil : "\(albums.count.formatted()) albums",
                    trailing: selectedAlbums.isEmpty ? nil : AnyView(selectedAlbumActions)
                )
                albumGrid
            }
            .opacity(selectedAlbum == nil ? 1 : 0)
            .allowsHitTesting(selectedAlbum == nil)
            .accessibilityHidden(selectedAlbum != nil)

            if let album = selectedAlbum {
                AlbumDetailView(album: album, onBack: { selectedAlbum = nil })
            }
        }
        .task { await loadAlbums() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadAlbums() } }
        .onChange(of: controller.currentTrack?.fileURL) { _, _ in reconcilePendingPlaybackAlbum() }
        .onChange(of: controller.isPlaying) { _, _ in reconcilePendingPlaybackAlbum() }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func loadAlbums() async {
        albums = (try? appState.db.read { db in
            try LibraryAlbumQuery.fetchVisible(in: db)
        }) ?? []
        selection.retain(validIds: Set(albums.compactMap(\.id)))
    }

    private func tracksFor(_ album: Album) async -> [Track] {
        (try? await appState.db.read { db in
            try LibraryAlbumQuery.tracks(for: album, in: db)
        }) ?? []
    }

    private func tracksFor(_ albums: [Album]) async -> [Track] {
        var result: [Track] = []
        for album in albums {
            result.append(contentsOf: await tracksFor(album))
        }
        return result
    }

    private func tracksForEdit(_ albums: [Album]) -> [Track] {
        (try? appState.db.read { db in
            var result: [Track] = []
            for album in albums {
                result.append(contentsOf: try LibraryAlbumQuery.tracks(for: album, in: db))
            }
            return result
        }) ?? []
    }

    private var selectedAlbumActions: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "play.fill") {
                Task {
                    let tracks = await tracksFor(selectedAlbums)
                    guard let first = tracks.first else { return }
                    controller.play(track: first, in: tracks)
                }
            }
            ToolbarIconButton(icon: "shuffle") {
                Task {
                    let tracks = (await tracksFor(selectedAlbums)).shuffled()
                    guard let first = tracks.first else { return }
                    controller.play(track: first, in: tracks)
                }
            }
            ToolbarIconButton(icon: "tag") {
                let tracks = tracksForEdit(selectedAlbums)
                appState.editAlbumTags(title: "Edit Selected Album Tags", tracks: tracks)
            }
        }
    }

    @ViewBuilder
    private func albumContextMenu(for album: Album) -> some View {
        let targetAlbums = album.id.map { selection.contains($0) } == true ? selectedAlbums : [album]
        let labelSuffix = targetAlbums.count == 1 ? "\"\(album.title)\"" : "\(targetAlbums.count) Albums"

        Button {
            Task {
                let tracks = await tracksFor(targetAlbums)
                guard let first = tracks.first else { return }
                controller.play(track: first, in: tracks)
            }
        } label: { Label("Play \(labelSuffix)", systemImage: "play.fill") }

        Button {
            Task {
                var tracks = await tracksFor(targetAlbums)
                tracks.shuffle()
                guard let first = tracks.first else { return }
                controller.play(track: first, in: tracks)
            }
        } label: { Label("Shuffle \(labelSuffix)", systemImage: "shuffle") }

        Divider()

        Button {
            Task {
                let tracks = await tracksFor(targetAlbums)
                controller.playNext(tracks: tracks)
            }
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }

        Button {
            Task {
                let tracks = await tracksFor(targetAlbums)
                controller.playLater(tracks: tracks)
            }
        } label: { Label("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward") }

        if !appState.playlists.isEmpty {
            Divider()
            Menu("Add to Playlist") {
                ForEach(appState.playlists) { playlist in
                    Button(playlist.name) {
                        Task {
                            let tracks = await tracksFor(targetAlbums)
                            if let id = playlist.id { appState.addTracks(tracks, toPlaylist: id) }
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            let tracks = tracksForEdit(targetAlbums)
            let title = targetAlbums.count == 1 ? "Edit Album Tags" : "Edit Selected Album Tags"
            DispatchQueue.main.async {
                appState.editAlbumTags(title: title, tracks: tracks)
            }
        } label: { Label("Edit Tags…", systemImage: "tag") }

        Divider()

        Button("Remove from Library", role: .destructive) {
            appState.removeAlbumsFromLibrary(albumIds: targetAlbums.compactMap(\.id))
        }
    }

    private var albumGrid: some View {
        Group {
            if albums.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.stack",
                    description: Text("Albums appear here once tracks have album metadata.\nCheck that your files have album tags set.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgContent)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            // Marquee selection belongs only to empty grid space.
                            // Keeping it on this background prevents it from
                            // competing with album-card taps, buttons, and drags.
                            Color.bgContent
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection.clear()
                                }
                                .gesture(albumMarqueeGesture)

                            LazyVGrid(columns: columns, spacing: 30) {
                                ForEach(albums) { album in
                                    AlbumCard(
                                        album: album,
                                        isSelected: album.id.map { selection.contains($0) } ?? false,
                                        isPlaying: isAlbumShowingPlayback(album),
                                        onTap: { handleAlbumTap(album) },
                                        onPlay: {
                                            if isCurrentAlbum(album) {
                                                pendingPlaybackAlbumId = controller.isPlaying ? nil : album.id
                                                controller.togglePlayPause()
                                                return
                                            }

                                            pendingPlaybackAlbumId = album.id
                                            Task {
                                                let tracks = await tracksFor(album)
                                                guard let first = tracks.first else {
                                                    await MainActor.run {
                                                        if pendingPlaybackAlbumId == album.id {
                                                            pendingPlaybackAlbumId = nil
                                                        }
                                                    }
                                                    return
                                                }
                                                await MainActor.run { controller.play(track: first, in: tracks) }
                                            }
                                        }
                                    )
                                    .albumFrame(id: album.id)
                                    .contextMenu { albumContextMenu(for: album) }
                                    // Use AppKit's provider-backed drag path on macOS.
                                    // It is more reliable in a ScrollView than the
                                    // generic Transferable bridge, particularly when
                                    // a multi-selection is being dragged.
                                    .onDrag {
                                        albumDragProvider(for: album)
                                    } preview: {
                                        albumDragPreview(for: album)
                                    }
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            if let marqueeRect {
                                Rectangle()
                                    .fill(Color.dAccent.opacity(0.14))
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color.dAccent.opacity(0.7), lineWidth: 1)
                                    )
                                    .frame(width: marqueeRect.width, height: marqueeRect.height)
                                    .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        .coordinateSpace(name: "albumsGrid")
                        .background(Color.bgContent)
                        .onPreferenceChange(AlbumFramePreferenceKey.self) { albumFrames = $0 }
                    }
                    .background(Color.bgContent)
                }
                .background(Color.bgContent)
            }
        }
    }

    private func isAlbumShowingPlayback(_ album: Album) -> Bool {
        if controller.isPlaying, isCurrentAlbum(album) {
            return true
        }
        return pendingPlaybackAlbumId == album.id
    }

    private func albumDragPayload(for album: Album) -> AlbumDragPayload {
        let ids: [Int64]
        if let id = album.id, selection.contains(id) {
            ids = selectedAlbums.compactMap(\.id)
        } else {
            ids = album.id.map { [$0] } ?? []
        }
        return AlbumDragPayload(albumIDs: ids)
    }

    private func albumDragProvider(for album: Album) -> NSItemProvider {
        let payload = albumDragPayload(for: album)
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(payload) else { return provider }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.moonlightAlbumDragPayload.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func albumDragPreview(for album: Album) -> some View {
        let itemCount = albumDragPayload(for: album).albumIDs.count
        let image = albumDragPreviewImage(for: album)

        return Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .artworkTreatment(
            appState.applyThemeArtworkToThumbnails
                ? AppTheme.current.defaultArtworkTreatment
                : .color
        )
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(0.78)
        .overlay(alignment: .topTrailing) {
            if itemCount > 1 {
                Text("\(itemCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }

    private func albumDragPreviewImage(for album: Album) -> NSImage? {
        try? appState.db.read { db in
            let resolvedArtworkId: Int64?
            if let artworkId = album.artworkId {
                resolvedArtworkId = artworkId
            } else if let albumId = album.id {
                resolvedArtworkId = try Album.fetchOne(db, key: albumId)?.artworkId
            } else {
                resolvedArtworkId = nil
            }

            guard let resolvedArtworkId,
                  let artwork = try Artwork.fetchOne(db, key: resolvedArtworkId)
            else { return nil }

            return artwork.image(large: false, maxPixelSize: 208)
                ?? artwork.image(large: true, maxPixelSize: 208)
        }
    }

    private func isCurrentAlbum(_ album: Album) -> Bool {
        guard let track = controller.currentTrack else { return false }
        if let albumId = album.id, track.albumId == albumId {
            return true
        }
        return track.album == album.title
    }

    private func reconcilePendingPlaybackAlbum() {
        guard let pendingPlaybackAlbumId else { return }
        let pendingAlbum = albums.first { $0.id == pendingPlaybackAlbumId }
        if controller.isPlaying,
           let pendingAlbum,
           isCurrentAlbum(pendingAlbum) {
            return
        }
        if !controller.isPlaying || pendingAlbum.map({ !isCurrentAlbum($0) }) ?? true {
            self.pendingPlaybackAlbumId = nil
        }
    }

    private var marqueeRect: CGRect? {
        guard let marqueeStart, let marqueeCurrent else { return nil }
        return CGRect(
            x: min(marqueeStart.x, marqueeCurrent.x),
            y: min(marqueeStart.y, marqueeCurrent.y),
            width: abs(marqueeStart.x - marqueeCurrent.x),
            height: abs(marqueeStart.y - marqueeCurrent.y)
        )
    }

    private var albumMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("albumsGrid"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                updateMarqueeSelection()
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    private func updateMarqueeSelection() {
        guard let marqueeRect else { return }
        let selectedIds = albumFrames.compactMap { id, frame -> Int64? in
            frame.intersects(marqueeRect) ? id : nil
        }
        selection.replace(with: Set(selectedIds))
    }

    private func handleAlbumTap(_ album: Album) {
        let modifiers = currentSelectionModifiers()
        if modifiers.isEmpty {
            selectedAlbum = album
        } else {
            select(album, modifiers: modifiers)
        }
    }

    private func select(_ album: Album) {
        select(album, modifiers: currentSelectionModifiers())
    }

    private func select(_ album: Album, modifiers: SelectionModifiers) {
        guard let id = album.id else { return }
        selection.select(id, in: albums.compactMap(\.id), modifiers: modifiers)
    }

    private func currentSelectionModifiers() -> SelectionModifiers {
        var modifiers: SelectionModifiers = []
        if NSEvent.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if NSEvent.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 36, selectedAlbum == nil, let album = selectedAlbums.first {
                selectedAlbum = album
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

// MARK: - Album card (Doppler style)

struct AlbumCard: View {
    let album: Album
    let isSelected: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlay: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    private var thumbnailTreatment: ArtworkTreatment {
        appState.applyThemeArtworkToThumbnails ? AppTheme.current.defaultArtworkTreatment : .color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Artwork with hover overlay
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(albumId: album.id, artworkId: album.artworkId, large: true, decodeMaxPixelSize: 400, cornerRadius: 5)
                    .artworkTreatment(thumbnailTreatment)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.dAccent.opacity(0.85) : .clear, lineWidth: 2)
                    )

                // VU meter badge when playing (and not hovered)
                if isPlaying && !isHovered {
                    VUMeterBadge()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // Hover play button
                Button(action: onPlay) {
                    AlbumPlayOverlayIcon(systemName: isPlaying ? "pause.fill" : "play.fill", size: 36, iconSize: 14)
                }
                .buttonStyle(.plain)
                .padding(8)
                .opacity(isHovered || isPlaying ? 1 : 0)
                .allowsHitTesting(isHovered || isPlaying)
            }

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .tracking(-0.1)

                Text(album.displayArtist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .padding(.top, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
    }
}

// MARK: - VU meter (animated bars)

struct VUMeterBadge: View {
    @State private var phase: Double = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 2, height: barHeight(i))
            }
        }
        .frame(width: 12, height: 11)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        )
        .onReceive(timer) { _ in phase += 0.15 }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let offsets: [Double] = [0, 0.9, 0.45]
        let h = (sin(phase + offsets[i]) + 1) / 2
        return max(2, h * 9)
    }
}

// MARK: - Legacy AlbumCell (used by ArtistAlbums, GenreAlbums)

struct AlbumCell: View {
    let album: Album
    var onTap: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController

    @State private var isHovered = false
    @State private var pendingPlayback = false

    var isPlaying: Bool {
        if controller.currentTrack?.albumId == album.id && controller.isPlaying {
            return true
        }
        return pendingPlayback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(albumId: album.id, artworkId: album.artworkId, large: true, decodeMaxPixelSize: 400, cornerRadius: 5)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

                if isPlaying && !isHovered {
                    VUMeterBadge()
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Button {
                    if controller.currentTrack?.albumId == album.id {
                        pendingPlayback = !controller.isPlaying
                        controller.togglePlayPause()
                        return
                    }

                    pendingPlayback = true
                    Task {
                        guard let tracks = try? await appState.db.read({ db in
                            try LibraryAlbumQuery.tracks(for: album, in: db)
                        }), let first = tracks.first else {
                            await MainActor.run { pendingPlayback = false }
                            return
                        }
                        await MainActor.run { controller.play(track: first, in: tracks) }
                    }
                } label: {
                    AlbumPlayOverlayIcon(systemName: isPlaying ? "pause.fill" : "play.fill", size: 32, iconSize: 13)
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(isHovered || isPlaying ? 1 : 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .tracking(-0.1)

                Text(album.displayArtist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .padding(.top, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { isHovered = $0 }
        .onChange(of: controller.currentTrack?.fileURL) { _, _ in reconcilePendingPlayback() }
        .onChange(of: controller.isPlaying) { _, _ in reconcilePendingPlayback() }
        .contextMenu {
            Button {
                Task {
                    guard let tracks = try? await appState.db.read({ db in
                        try LibraryAlbumQuery.tracks(for: album, in: db)
                    }) else { return }
                    appState.editAlbumTags(title: "Edit Album Tags", tracks: tracks)
                }
            } label: { Label("Edit Tags…", systemImage: "tag") }
        }
    }

    private func reconcilePendingPlayback() {
        guard pendingPlayback else { return }
        if controller.isPlaying, controller.currentTrack?.albumId == album.id {
            return
        }
        if !controller.isPlaying || controller.currentTrack?.albumId != album.id {
            pendingPlayback = false
        }
    }
}

private struct AlbumPlayOverlayIcon: View {
    let systemName: String
    let size: CGFloat
    let iconSize: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

private struct AlbumFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    @ViewBuilder
    func albumFrame(id: Int64?) -> some View {
        if let id {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: AlbumFramePreferenceKey.self,
                        value: [id: proxy.frame(in: .named("albumsGrid"))]
                    )
                }
            )
        } else {
            self
        }
    }
}
