// SongsTableView.swift
//
// The Songs page, listing every song in the library in the songs table. A toolbar menu filters
// by star rating, and when songs are selected an Edit Tags button appears.

import SwiftUI
import GRDB

struct SongsTableView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var tracks: [Track] = []
    @State private var selection = OrderedSelection<Int64>()
    @State private var columnLayout = SongsTableColumnLayout.load()
    @State private var ratingFilter: SongsRatingFilter = .all
    @State private var sortOrder: SongsSortOrder = .title

    private var selectedTracks: [Track] {
        tracks.filter { $0.dbId.map(selection.contains) == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            ContentToolbarView(
                title: "Songs",
                subtitle: tracks.isEmpty ? nil : "\(tracks.count.formatted()) tracks",
                trailing: AnyView(toolbarActions)
            )

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
        .task { await loadTracks() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadTracks() } }
        .onChange(of: ratingFilter) { _, _ in Task { await loadTracks() } }
        .onChange(of: sortOrder) { _, _ in Task { await loadTracks() } }
    }

    private func loadTracks() async {
        tracks = (try? appState.db.read { db in
            try SongsTrackQuery.fetch(in: db, ratingFilter: ratingFilter, sortOrder: sortOrder)
        }) ?? []
        selection.retain(validIds: Set(tracks.compactMap(\.dbId)))
    }

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All Ratings") { ratingFilter = .all }
                Button("Unrated") { ratingFilter = .unrated }
                Divider()
                Menu("Exact Rating") {
                    ForEach(1...5, id: \.self) { rating in
                        Button(rating == 1 ? "1 Star" : "\(rating) Stars") {
                            ratingFilter = .exact(rating)
                        }
                    }
                }
                Menu("At Least") {
                    ForEach(1...5, id: \.self) { rating in
                        Button("\(rating)+ Stars") {
                            ratingFilter = .atLeast(rating)
                        }
                    }
                }
            } label: {
                Label(ratingFilter.displayName, systemImage: "line.3.horizontal.decrease.circle")
                    .font(AppTheme.current.font(.control, size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)

            if !selection.isEmpty {
                Button {
                    appState.editAlbumTags(title: "Edit Selected Tags", tracks: selectedTracks)
                } label: {
                    Label("Edit Tags", systemImage: "tag")
                        .font(AppTheme.current.font(.control, size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
        }
    }

}

enum SongsRatingFilter: Hashable {
    case all
    case unrated
    case exact(Int)
    case atLeast(Int)

    var displayName: String {
        switch self {
        case .all: "All Ratings"
        case .unrated: "Unrated"
        case .exact(let rating): rating == 1 ? "1 Star" : "\(rating) Stars"
        case .atLeast(let rating): "\(rating)+ Stars"
        }
    }
}

enum SongsSortOrder: Equatable {
    case title
    case ratingAscending
    case ratingDescending
}

enum SongsTrackQuery {
    static func fetch(
        in database: Database,
        ratingFilter: SongsRatingFilter,
        sortOrder: SongsSortOrder
    ) throws -> [Track] {
        let filterSQL: String
        let arguments: StatementArguments
        switch ratingFilter {
        case .all:
            filterSQL = LibraryTrackQuery.catalogPredicate()
            arguments = StatementArguments()
        case .unrated:
            filterSQL = "rating IS NULL AND \(LibraryTrackQuery.catalogPredicate())"
            arguments = StatementArguments()
        case .exact(let rating):
            filterSQL = "rating = ? AND \(LibraryTrackQuery.catalogPredicate())"
            arguments = [rating]
        case .atLeast(let rating):
            filterSQL = "rating >= ? AND \(LibraryTrackQuery.catalogPredicate())"
            arguments = [rating]
        }

        let orderSQL = orderSQL(for: sortOrder)

        return try Track.fetchAll(
            database,
            sql: "SELECT * FROM tracks WHERE \(filterSQL) ORDER BY \(orderSQL)",
            arguments: arguments
        )
    }

    static func orderSQL(for sortOrder: SongsSortOrder) -> String {
        switch sortOrder {
        case .title:
            "COALESCE(title, '') COLLATE NOCASE ASC, id ASC"
        case .ratingAscending:
            "CASE WHEN rating IS NULL THEN 0 ELSE 1 END ASC, rating ASC, COALESCE(title, '') COLLATE NOCASE ASC, id ASC"
        case .ratingDescending:
            "CASE WHEN rating IS NULL THEN 1 ELSE 0 END ASC, rating DESC, COALESCE(title, '') COLLATE NOCASE ASC, id ASC"
        }
    }
}
