// PlaylistDetailView.swift
//
// The page for a single playlist. It lists the playlist's songs in the songs table, where they
// can be played, reordered by dragging, or removed (the files themselves stay in the library).
// Songs can be dropped in from elsewhere. Smart playlists, which fill themselves from rules, are
// shown read-only.

import SwiftUI
import GRDB

struct PlaylistDetailView: View {
    let playlistId: Int64

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var entries: [PlaylistEntry] = []
    @State private var smartTracks: [Track] = []
    @State private var playlist: Playlist?
    @State private var isDropTargeted = false
    @State private var selection = OrderedSelection<Int64>()
    @State private var columnLayout = SongsTableColumnLayout.load()
    @State private var sortOrder: SongsSortOrder = .title
    @State private var pendingRemovalEntryIDs: [Int64] = []

    private var isSmartPlaylist: Bool { playlist?.kind == "smart" }
    private var tracks: [Track] { isSmartPlaylist ? smartTracks : entries.map(\.track) }

    var body: some View {
        VStack(spacing: 0) {
            ContentToolbarView(
                title: playlist?.name ?? "Playlist",
                subtitle: tracks.isEmpty ? nil : "\(tracks.count.formatted()) tracks",
                trailing: AnyView(playlistActions)
            )

            if tracks.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text(isSmartPlaylist
                        ? "Adjust this playlist’s rules to find matching music."
                        : "Drag tracks here or right-click any track and choose Add to Playlist.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgContent)
                .playlistDropTarget(isTargeted: $isDropTargeted, onDrop: handleDrop)
                .overlay(dropOverlay)
            } else {
                SongsNSTableView(
                    tracks: tracks,
                    currentTrackID: controller.currentTrack?.dbId,
                    isPlaying: controller.isPlaying,
                    selection: $selection,
                    columnLayout: $columnLayout,
                    sortOrder: $sortOrder,
                    appState: appState,
                    controller: controller,
                    rowIDs: isSmartPlaylist ? tracks.compactMap(\.dbId) : entries.map(\.id),
                    allowsSorting: false,
                    onReorder: isSmartPlaylist ? nil : { entryIDs, row in
                        appState.reorderPlaylistEntries(entryIDs, inPlaylist: playlistId, toRow: row)
                    },
                    onInsert: isSmartPlaylist ? nil : { trackIDs, row in
                        appState.insertTrackIds(trackIDs, intoPlaylist: playlistId, atRow: row)
                    },
                    onRequestRemove: isSmartPlaylist ? nil : requestEntryRemoval,
                    dragSourcePlaylistID: isSmartPlaylist ? nil : playlistId
                )
                .overlay(dropOverlay)
            }
        }
        .task(id: playlistId) { await loadData() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadData() } }
        .alert("Remove from Playlist?", isPresented: Binding(
            get: { !pendingRemovalEntryIDs.isEmpty },
            set: { if !$0 { pendingRemovalEntryIDs = [] } }
        )) {
            Button("Remove", role: .destructive) {
                appState.removePlaylistEntries(pendingRemovalEntryIDs, fromPlaylist: playlistId)
                selection.clear()
                pendingRemovalEntryIDs = []
            }
            Button("Cancel", role: .cancel) { pendingRemovalEntryIDs = [] }
        } message: {
            let count = pendingRemovalEntryIDs.count
            Text("Remove \(count) track\(count == 1 ? "" : "s") from this playlist? The music files will remain in your library.")
        }
    }

    @ViewBuilder
    private var playlistActions: some View {
        HStack(spacing: 4) {
            if !tracks.isEmpty {
                if !isSmartPlaylist {
                    Label("Drag to reorder", systemImage: "arrow.up.arrow.down")
                        .font(AppTheme.current.font(.control, size: 11.5, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
                ToolbarIconButton(icon: "play.fill") {
                    if let first = tracks.first(where: \.isAvailable) { controller.play(track: first, in: tracks) }
                }
                if !isSmartPlaylist && !selection.isEmpty {
                    ToolbarIconButton(icon: "trash") {
                        requestEntryRemoval(Array(selection.ids))
                    }
                }
            }
        }
    }

    private func loadData() async {
        playlist = try? appState.db.read { db in try Playlist.fetchOne(db, key: playlistId) }
        guard let playlist else {
            entries = []
            smartTracks = []
            return
        }
        if playlist.kind == "smart" {
            smartTracks = (try? appState.db.read { db in
                guard let encodedRule = playlist.rule else { return [] }
                return try SmartPlaylistEvaluator.tracks(matching: SmartPlaylistRule.decoded(encodedRule), in: db)
            }) ?? []
            entries = []
            selection.retain(validIds: Set(smartTracks.compactMap(\.dbId)))
            return
        }
        entries = (try? appState.db.read { db in
            try PlaylistEntry.fetchVisible(in: playlistId, from: db)
        }) ?? []
        smartTracks = []
        selection.retain(validIds: Set(entries.map(\.id)))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: DS.radiusCard)
            .stroke(isDropTargeted ? Color.dAccent.opacity(0.75) : .clear, lineWidth: 1)
            .padding(8)
    }

    private func handleDrop(_ payloads: [TrackDragPayload]) -> Bool {
        guard !isSmartPlaylist, !payloads.isEmpty else { return false }
        // AppKit owns an in-place drag and commits it as a row move. Do not let
        // SwiftUI's external playlist drop target append a duplicate copy too.
        guard !payloads.contains(where: { $0.sourcePlaylistId == playlistId }) else { return false }
        appState.addDraggedTracks(payloads, toPlaylist: playlistId)
        return true
    }

    private func requestEntryRemoval(_ entryIDs: [Int64]) {
        pendingRemovalEntryIDs = entryIDs
    }

}

private extension View {
    func playlistDropTarget(
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([TrackDragPayload]) -> Bool
    ) -> some View {
        dropDestination(for: TrackDragPayload.self, action: { payloads, _ in
            onDrop(payloads)
        }, isTargeted: { isTargeted.wrappedValue = $0 })
    }
}
