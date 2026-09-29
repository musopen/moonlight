// ComposersView.swift
//
// The Composers page. A list of composers runs down the left; choosing one shows every song
// credited to that composer on the right, ready to play.

import SwiftUI
import GRDB

struct ComposersView: View {
    @EnvironmentObject var appState: AppState
    @State private var composers: [String] = []
    @State private var selected: String?

    var body: some View {
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
                ComposerTracksView(composer: composer)
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

private struct ComposerTracksView: View {
    let composer: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var tracks: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Serif name header
                VStack(alignment: .leading, spacing: 4) {
                    Text(composer)
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .tracking(-0.4)
                        .foregroundStyle(Color.textPrimary)
                    Text("\(tracks.count.formatted()) tracks")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

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
            }
        }
        .task { await loadTracks() }
        .onChange(of: composer) { _, _ in Task { await loadTracks() } }
    }

    private func loadTracks() async {
        tracks = (try? appState.db.read { db in
            try LibraryBrowseQuery.tracks(composedBy: composer, in: db)
        }) ?? []
    }
}
