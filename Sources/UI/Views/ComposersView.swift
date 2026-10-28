// ComposersView.swift
//
// The Composers page. Choosing a composer shows their albums by default, with a switch to
// browse individual songs. Opening an album keeps the composer selection ready to return to.

import SwiftUI
import GRDB

struct ComposersView: View {
    @EnvironmentObject var appState: AppState
    @State private var composers: [String] = []
    @State private var selected: String?
    @State private var selectedAlbum: Album?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ContentToolbarView(
                    title: selected ?? "Composers",
                    subtitle: selected == nil ? (composers.isEmpty ? nil : "\(composers.count.formatted()) \(composers.count == 1 ? "composer" : "composers")") : nil
                )

                HStack(spacing: 0) {
                    composerList
                    Rectangle().fill(Color.borderSoft).frame(width: 0.5)
                    composerDetail
                }
            }
            .opacity(selectedAlbum == nil ? 1 : 0)
            .allowsHitTesting(selectedAlbum == nil)
            .accessibilityHidden(selectedAlbum != nil)

            if let album = selectedAlbum {
                AlbumDetailView(album: album, backLabel: "Composers", onBack: { selectedAlbum = nil })
            }
        }
        .task { await loadComposers() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadComposers() } }
    }

    private var composerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(composers, id: \.self) { composer in
                    ComposerListRow(
                        name: composer,
                        isSelected: selected == composer,
                        onTap: { selected = composer }
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.bgElevated)
        .frame(width: 240)
    }

    private var composerDetail: some View {
        ZStack {
            Color.bgContent
            if let composer = selected {
                ComposerLibraryView(composer: composer, onAlbumTap: { selectedAlbum = $0 })
            } else {
                ContentUnavailableView("Select a Composer", systemImage: "person.and.background.dotted")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadComposers() async {
        composers = (try? appState.db.read { db in
            try LibraryBrowseQuery.composers(in: db)
        }) ?? []
    }
}

private struct ComposerListRow: View {
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

private struct ComposerLibraryView: View {
    let composer: String
    let onAlbumTap: (Album) -> Void
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @AppStorage("composerShowsSongs") private var showsSongs = false
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    private var itemCount: String {
        if showsSongs {
            return "\(tracks.count.formatted()) \(tracks.count == 1 ? "song" : "songs")"
        }
        return "\(albums.count.formatted()) \(albums.count == 1 ? "album" : "albums")"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(composer)
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .tracking(-0.4)
                        .foregroundStyle(Color.textPrimary)
                    Text(itemCount)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Composer view", selection: $showsSongs) {
                    Text("Albums").tag(false)
                    Text("Songs").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                if showsSongs {
                    LazyVStack(spacing: 0) {
                        ForEach(tracks, id: \.dbId) { track in
                            TrackRow(
                                track: track,
                                isCurrent: controller.currentTrack?.hasSameIdentity(as: track) == true,
                                isPlaying: controller.currentTrack?.hasSameIdentity(as: track) == true && controller.isPlaying,
                                onPlay: { controller.playOrToggle(track: track, in: tracks) },
                                onPlayNow: { controller.play(track: track, in: tracks) }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            AlbumCell(album: album, onTap: { onAlbumTap(album) })
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .id("\(composer)-\(showsSongs)")
        }
        .task(id: composer) { await loadLibrary() }
        .onChange(of: appState.libraryVersion) { _, _ in Task { await loadLibrary() } }
    }

    private func loadLibrary() async {
        let result = try? appState.db.read { db in
            (
                albums: try LibraryBrowseQuery.albums(composedBy: composer, in: db),
                tracks: try LibraryBrowseQuery.tracks(composedBy: composer, in: db)
            )
        }
        albums = result?.albums ?? []
        tracks = result?.tracks ?? []
    }
}
