// GenresView.swift
//
// The Genres page. A list of genres runs down the left; choosing one shows the albums in that
// genre as a grid of covers, and clicking an album opens its album page with a back button to
// return.

import SwiftUI
import GRDB

struct GenresView: View {
    @EnvironmentObject var appState: AppState
    @State private var genres: [String] = []
    @State private var selected: String?
    @State private var selectedAlbum: Album?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ContentToolbarView(
                    title: selected ?? "Genres",
                    subtitle: selected == nil ? (genres.isEmpty ? nil : "\(genres.count.formatted()) \(genres.count == 1 ? "genre" : "genres")") : nil
                )

                HStack(spacing: 0) {
                    genreList
                    Rectangle().fill(Color.borderSoft).frame(width: 0.5)
                    genreDetail
                }
            }
            .opacity(selectedAlbum == nil ? 1 : 0)
            .allowsHitTesting(selectedAlbum == nil)
            .accessibilityHidden(selectedAlbum != nil)

            if let album = selectedAlbum {
                AlbumDetailView(album: album, backLabel: "Genres", onBack: { selectedAlbum = nil })
            }
        }
        .task { await loadGenres() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadGenres() } }
    }

    private var genreList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(genres, id: \.self) { genre in
                    ListRow(
                        name: genre,
                        isSelected: selected == genre,
                        onTap: { selected = genre }
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.bgElevated)
        .frame(width: 200)
    }

    private var genreDetail: some View {
        ZStack {
            Color.bgContent
            if let genre = selected {
                GenreAlbumsView(genre: genre, onAlbumTap: { selectedAlbum = $0 })
            } else {
                ContentUnavailableView("Select a Genre", systemImage: "guitars")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadGenres() async {
        genres = (try? appState.db.read { db in
            try LibraryBrowseQuery.genres(in: db)
        }) ?? []
    }
}

private struct ListRow: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(name)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .padding(.horizontal, 16)
                .background(isSelected ? Color.bgSelectedActive : (isHovered ? Color.bgHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct GenreAlbumsView: View {
    let genre: String
    let onAlbumTap: (Album) -> Void
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var albums: [Album] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Serif name header
                VStack(alignment: .leading, spacing: 4) {
                    Text(genre)
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .tracking(-0.4)
                        .foregroundStyle(Color.textPrimary)
                    Text("\(albums.count.formatted()) \(albums.count == 1 ? "album" : "albums")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        AlbumCell(album: album, onTap: { onAlbumTap(album) })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .task { await loadAlbums() }
        .onChange(of: genre) { _, _ in Task { await loadAlbums() } }
    }

    private func loadAlbums() async {
        albums = (try? appState.db.read { db in
            try Album.fetchAll(db, sql: """
                SELECT DISTINCT albums.*
                FROM albums
                JOIN tracks ON tracks.album_id = albums.id
                WHERE tracks.genre = ?
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
                ORDER BY albums.title
            """, arguments: [genre])
        }) ?? []
    }
}
