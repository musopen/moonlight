// SidebarView.swift
//
// The left-hand sidebar of the main window. It lists the library sections (Now Playing, Albums,
// Artists, Songs, Favorites, Composers, Genres), Live Radio, and the user's playlists, which can
// be created, renamed, duplicated, exported or deleted from here. It also shows a notice when
// the music folder cannot be reached, with a button to reconnect it.

import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case nowPlaying
    case albums
    case artists
    case songs
    case favorites
    case composers
    case genres
    case radio
    case playlist(Int64)
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    @State private var showingCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylist: Playlist?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    librarySection
                    discoverySection
                    playlistSection
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            unavailableFolderNotice
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: DS.sidebarWidth)
        .background(
            ZStack {
                SidebarVibrancy()
                Color.bgSidebar
                LinearGradient(
                    stops: [
                        .init(color: Color.bgSidebarSheen, location: 0),
                        .init(color: .clear, location: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea(.all, edges: [.top, .leading])
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.borderSoft.opacity(0.7))
                .frame(width: 0.5)
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)
        }
        .alert("New Playlist", isPresented: $showingCreatePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    if let p = appState.createPlaylist(name: name), let id = p.id {
                        appState.selectedSidebarItem = .playlist(id)
                    }
                }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renamingPlaylist != nil },
            set: { if !$0 { renamingPlaylist = nil } }
        )) {
            TextField("Playlist name", text: $renameText)
            Button("Rename") {
                if let id = renamingPlaylist?.id {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { appState.renamePlaylist(id: id, name: name) }
                }
                renamingPlaylist = nil
            }
            Button("Cancel", role: .cancel) { renamingPlaylist = nil }
        }
        // The sidebar can be attached after AppState's initial database refresh
        // (notably while the launch view transitions out). Refresh once it is
        // visible and after navigating to a playlist so the detail and sidebar
        // cannot get out of step.
        .task { appState.refreshPlaylists() }
        .onChange(of: appState.selectedSidebarItem) { _, item in
            if case .playlist = item { appState.refreshPlaylists() }
        }
    }

    @ViewBuilder
    private var unavailableFolderNotice: some View {
        let issues = appState.visibleUnavailableLibraryFolders
        if let issue = issues.first {
            LibraryFolderUnavailableNotice(
                additionalIssueCount: issues.count - 1,
                onReconnect: { appState.showReconnectFolderPicker(for: issue.folderId) },
                onDismiss: { appState.dismissUnavailableLibraryFolderNotice() }
            )
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    // MARK: - Library section

    private var librarySection: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader(
                title: "Library",
                onCollapse: { appState.setSidebarCollapsed(true) }
            )

            VStack(spacing: 1) {
                SidebarRow(icon: "music.note.house", label: "Now Playing",
                           isActive: appState.selectedSidebarItem == .nowPlaying) {
                    appState.showNowPlaying()
                }
                SidebarRow(icon: "square.grid.2x2", label: "Albums",
                           isActive: appState.selectedSidebarItem == .albums) {
                    appState.selectedSidebarItem = .albums
                }
                SidebarRow(icon: "music.mic", label: "Artists",
                           isActive: appState.selectedSidebarItem == .artists) {
                    appState.selectedSidebarItem = .artists
                }
                SidebarRow(icon: "music.note.list", label: "Songs",
                           isActive: appState.selectedSidebarItem == .songs) {
                    appState.selectedSidebarItem = .songs
                }
                SidebarRow(icon: "heart", label: "Favorites",
                           isActive: appState.selectedSidebarItem == .favorites) {
                    appState.selectedSidebarItem = .favorites
                }
                SidebarRow(icon: "person.and.background.dotted", label: "Composers",
                           isActive: appState.selectedSidebarItem == .composers) {
                    appState.selectedSidebarItem = .composers
                }
                SidebarRow(icon: "guitars", label: "Genres",
                           isActive: appState.selectedSidebarItem == .genres) {
                    appState.selectedSidebarItem = .genres
                }
            }
        }
    }

    private var discoverySection: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader(title: "Discover")

            VStack(spacing: 1) {
                SidebarRow(icon: "radio", label: "Live Radio",
                           isActive: appState.selectedSidebarItem == .radio) {
                    appState.selectedSidebarItem = .radio
                }
            }
        }
    }

    // MARK: - Playlist section

    private var playlistSection: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader(
                title: "Playlists",
                onAdd: { showingCreatePlaylist = true }
            )
                .contextMenu {
                    Button("New Smart Playlist…") { appState.showingSmartPlaylistEditor = true }
                }

            VStack(spacing: 1) {
                ForEach(appState.playlists) { playlist in
                    PlaylistSidebarRow(
                        playlist: playlist,
                        isActive: appState.selectedSidebarItem == .playlist(playlist.id ?? -1),
                        onSelect: {
                            appState.selectedSidebarItem = .playlist(playlist.id ?? -1)
                        },
                        onRename: {
                            renamingPlaylist = playlist
                            renameText = playlist.name
                        },
                        onDuplicate: {
                            if let copy = playlist.id.flatMap({ appState.duplicatePlaylist(id: $0) }), let id = copy.id {
                                appState.selectedSidebarItem = .playlist(id)
                            }
                        },
                        onDelete: {
                            if let id = playlist.id { appState.deletePlaylist(id: id) }
                        }
                    )
                }
            }
        }
    }
}

private struct LibraryFolderUnavailableNotice: View {
    let additionalIssueCount: Int
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(AppTheme.current.font(.icon, size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 15, height: 16)

                Text("Music folder unavailable")
                    .font(AppTheme.current.font(.sidebar, size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: 2)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(AppTheme.current.font(.icon, size: 9, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss for this session")
                .accessibilityLabel("Dismiss unavailable music folder notice")
            }

            Text(detailText)
                .font(AppTheme.current.font(.caption, size: 10.5))
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reconnect…", action: onReconnect)
                .buttonStyle(.plain)
                .font(AppTheme.current.font(.sidebar, size: 10.5, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(Color.orange.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.22), lineWidth: 0.5)
                }
        )
    }

    private var detailText: String {
        if additionalIssueCount > 0 {
            return "This folder and \(additionalIssueCount) more may have moved or disconnected. Your library data is safe."
        }
        return "It may have moved, been renamed, or disconnected. Your library data is safe."
    }
}

private struct PlaylistSidebarRow: View {
    @EnvironmentObject var appState: AppState

    let playlist: Playlist
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        SidebarRow(
            icon: "music.note.list",
            label: playlist.name,
            isActive: isActive,
            action: onSelect
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusControl)
                .stroke(isDropTargeted ? Color.dAccent.opacity(0.75) : .clear, lineWidth: 1)
        }
        // A single provider-based drop target handles both payload types. Two
        // adjacent `dropDestination` modifiers compete for the same sidebar
        // row in SwiftUI, which made album drops get rejected before the album
        // handler received them.
        .onDrop(
            of: [.moonlightTrackDragPayload, .moonlightAlbumDragPayload],
            isTargeted: $isDropTargeted,
            perform: { providers in
                // SwiftUI otherwise keeps the targeting state until the next
                // pointer movement, leaving a stale '+' affordance after drop.
                isDropTargeted = false
                return handlePlaylistDrop(providers)
            }
        )
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Duplicate Playlist", action: onDuplicate)
            Button("Export M3U…") {
                guard let id = playlist.id else { return }
                appState.exportPlaylist(id: id)
            }
            Divider()
            Button("Delete Playlist", role: .destructive, action: onDelete)
        }
    }

    private func handlePlaylistDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let playlistId = playlist.id else { return false }

        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.moonlightAlbumDragPayload.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.moonlightAlbumDragPayload.identifier) { data, _ in
                    guard let data, let payload = try? JSONDecoder().decode(AlbumDragPayload.self, from: data) else { return }
                    let albumIDs = payload.albumIDs
                    guard !albumIDs.isEmpty else { return }
                    DispatchQueue.main.async {
                        appState.addAlbums(albumIDs, toPlaylist: playlistId)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.moonlightTrackDragPayload.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.moonlightTrackDragPayload.identifier) { data, _ in
                    guard let data, let payload = try? JSONDecoder().decode(TrackDragPayload.self, from: data) else { return }
                    DispatchQueue.main.async {
                        appState.addDraggedTracks([payload], toPlaylist: playlistId)
                    }
                }
            }
        }
        return handled
    }
}
