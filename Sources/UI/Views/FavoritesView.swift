// FavoritesView.swift
//
// The Favorites page, listing every song the user has marked as a favorite in the standard songs
// table. If there are none yet, it shows a short message explaining where favorites will appear.

import SwiftUI
import GRDB

struct FavoritesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var tracks: [Track] = []
    @State private var selection = OrderedSelection<Int64>()
    @State private var columnLayout = SongsTableColumnLayout.load()
    @State private var sortOrder: SongsSortOrder = .title

    var body: some View {
        VStack(spacing: 0) {
            ContentToolbarView(title: "Favorites", subtitle: tracks.isEmpty ? nil : "\(tracks.count.formatted()) tracks")

            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "heart",
                    description: Text("Tracks you love will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgContent)
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
                    onRequestLibraryRemoval: appState.removeTracksFromLibrary
                )
            }
        }
        .task { await loadTracks() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadTracks() } }
        .onChange(of: sortOrder) { _, _ in Task { await loadTracks() } }
    }

    private func loadTracks() async {
        tracks = (try? appState.db.read { db in
            try LibraryBrowseQuery.favoriteTracks(sortedBy: sortOrder, in: db)
        }) ?? []
        selection.retain(validIds: Set(tracks.compactMap(\.dbId)))
    }
}
