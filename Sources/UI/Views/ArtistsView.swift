// ArtistsView.swift
//
// The Artists page. A list of artists runs down the left; choosing one shows their albums as a
// grid of covers on the right, and clicking an album opens its album page with a back button to
// return.

import SwiftUI
import GRDB

struct ArtistsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var artists: [Artist] = []
    @State private var selected: Artist?
    @State private var selectedAlbum: Album?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ContentToolbarView(
                    title: selected?.name ?? "Artists",
                    subtitle: selected == nil ? (artists.isEmpty ? nil : "\(artists.count.formatted()) \(artists.count == 1 ? "artist" : "artists")") : nil
                )

                HStack(spacing: 0) {
                    artistList
                    Rectangle().fill(Color.borderSoft).frame(width: 0.5)
                    artistDetail
                }
            }
            .opacity(selectedAlbum == nil ? 1 : 0)
            .allowsHitTesting(selectedAlbum == nil)
            .accessibilityHidden(selectedAlbum != nil)

            if let album = selectedAlbum {
                AlbumDetailView(album: album, backLabel: "Artists", onBack: { selectedAlbum = nil })
            }
        }
        .task { await loadArtists() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadArtists() } }
    }

    private var artistList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(artists) { artist in
                    ArtistListRow(
                        artist: artist,
                        isSelected: selected?.id == artist.id,
                        onTap: { selected = artist }
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.bgElevated)
        .frame(width: 220)
    }

    private var artistDetail: some View {
        ZStack {
            Color.bgContent
            if let artist = selected {
                ArtistAlbumsView(artist: artist, onAlbumTap: { selectedAlbum = $0 })
            } else {
                ContentUnavailableView("Select an Artist", systemImage: "music.mic")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadArtists() async {
        artists = (try? appState.db.read { db in
            try Artist.fetchAll(db, sql: """
                SELECT artists.*
                FROM artists
                WHERE EXISTS (
                    SELECT 1 FROM tracks
                    WHERE tracks.artist_id = artists.id
                      AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
                )
                ORDER BY artists.name
            """)
        }) ?? []
    }
}

private struct ArtistListRow: View {
    let artist: Artist
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Initials avatar
                ZStack {
                    Circle()
                        .fill(Color.dAccent.opacity(0.15))
                    Text(initials)
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.dAccent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.bgSelectedActive : (isHovered ? Color.bgHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var initials: String {
        artist.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}

private struct ArtistAlbumsView: View {
    let artist: Artist
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
                    Text(artist.name)
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
        .onChange(of: artist.id) { _, _ in Task { await loadAlbums() } }
    }

    private func loadAlbums() async {
        albums = (try? appState.db.read { db in
            try Album.fetchAll(db, sql: """
                SELECT DISTINCT albums.*
                FROM albums
                JOIN tracks ON tracks.album_id = albums.id
                WHERE COALESCE(tracks.album_artist, tracks.artist) = ?
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
                ORDER BY albums.year, albums.title
            """, arguments: [artist.name])
        }) ?? []
    }
}
