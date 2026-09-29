// MobileRootView.swift
//
// Lays out the main screens of the iPhone and iPad app: Library, Search, Playlists, Now Playing
// and Settings. iPads get a sidebar and phones get tabs. The Settings screen covers importing
// music, storage use, iCloud sync of library information, and restoring earlier snapshots of that
// information.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MobileLayoutPolicy {
    static func usesSidebar(for idiom: UIUserInterfaceIdiom) -> Bool { idiom == .pad }
}

private enum MobileSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case search = "Search"
    case playlists = "Playlists"
    case nowPlaying = "Now Playing"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        case .playlists: "music.note.house"
        case .nowPlaying: "play.circle"
        case .settings: "gear"
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var library: MobileLibraryModel
    @State private var selectedSection: MobileSection? = .library
    @State private var importing = false

    var body: some View {
        Group {
            if MobileLayoutPolicy.usesSidebar(for: UIDevice.current.userInterfaceIdiom) {
                NavigationSplitView {
                    List(MobileSection.allCases, selection: $selectedSection) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                    .navigationTitle("Moonlight")
                } detail: {
                    NavigationStack { sectionView(selectedSection ?? .library) }
                }
            } else {
                TabView {
                    NavigationStack { sectionView(.library) }.tabItem { Label("Library", systemImage: MobileSection.library.icon) }
                    NavigationStack { sectionView(.search) }.tabItem { Label("Search", systemImage: MobileSection.search.icon) }
                    NavigationStack { sectionView(.playlists) }.tabItem { Label("Playlists", systemImage: MobileSection.playlists.icon) }
                    NavigationStack { sectionView(.nowPlaying) }.tabItem { Label("Playing", systemImage: MobileSection.nowPlaying.icon) }
                    NavigationStack { sectionView(.settings) }.tabItem { Label("Settings", systemImage: MobileSection.settings.icon) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls)
            case .failure(let error): library.presentedError = error.localizedDescription
            }
        }
        .alert("Moonlight", isPresented: Binding(get: { library.presentedError != nil }, set: { if !$0 { library.presentedError = nil } })) {
            Button("OK") { library.presentedError = nil }
        } message: { Text(library.presentedError ?? "") }
        .overlay {
            if let progress = library.importProgress {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView(progress).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MobileSection) -> some View {
        switch section {
        case .library: MobileLibraryView(importAction: { importing = true })
        case .search: MobileSearchView()
        case .playlists: MobilePlaylistsView()
        case .nowPlaying: MobileNowPlayingView()
        case .settings: MobileSettingsView(importAction: { importing = true })
        }
    }
}

private struct MobileLibraryView: View {
    @EnvironmentObject private var library: MobileLibraryModel
    let importAction: () -> Void

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                ContentUnavailableView("Your library is empty", systemImage: "music.note", description: Text("Import music from Files, iCloud Drive, a NAS provider, or an external drive."))
            } else {
                List {
                    ForEach(library.tracks) { track in MobileTrackRow(track: track, queue: library.tracks) }
                    if library.hasMoreTracks {
                        Button("Load More", action: library.loadMoreTracks)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("On This Device Only", isOn: $library.showOnDeviceOnly)
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                Button(action: importAction) { Label("Import Music", systemImage: "square.and.arrow.down") }
            }
        }
    }
}

private struct MobileSearchView: View {
    @EnvironmentObject private var library: MobileLibraryModel
    @State private var query = ""
    var body: some View {
        Group {
            if query.isEmpty { ContentUnavailableView("Search your library", systemImage: "magnifyingglass") }
            else if library.searchResults.isEmpty { ContentUnavailableView.search(text: query) }
            else { List(library.searchResults) { MobileTrackRow(track: $0, queue: library.searchResults) } }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Title, artist, album, composer")
        .onChange(of: query) { _, value in library.search(value) }
    }
}

private struct MobileTrackRow: View {
    @EnvironmentObject private var library: MobileLibraryModel
    @EnvironmentObject private var playback: MobilePlaybackController
    let track: Track
    let queue: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.play(track, queue: queue) } label: {
                Image(systemName: track.isAvailable ? "play.fill" : "icloud")
                    .frame(width: 44, height: 44).background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain).disabled(!track.isAvailable)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle).lineLimit(1)
                Text("\(track.displayArtist) · \(track.displayAlbum)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !track.isAvailable {
                    Text("Available on another device").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let rating = track.rating { Text(String(repeating: "★", count: rating)).font(.caption2).foregroundStyle(.yellow).accessibilityLabel("\(rating) stars") }
            Menu {
                Button(track.isFavorite ? "Remove Favorite" : "Favorite") { library.setFavorite(!track.isFavorite, track: track) }
                Menu("Rating") {
                    Button("No Rating") { library.setRating(nil, track: track) }
                    ForEach(1...5, id: \.self) { value in Button("\(value) Star\(value == 1 ? "" : "s")") { library.setRating(value, track: track) } }
                }
                if !library.playlists.isEmpty {
                    Menu("Add to Playlist") { ForEach(library.playlists) { playlist in Button(playlist.name) { library.add(track, to: playlist) } } }
                }
                if track.isAvailable {
                    Button("Delete from This Device", role: .destructive) { library.delete(track) }
                }
            } label: { Image(systemName: track.isFavorite ? "heart.fill" : "ellipsis.circle").foregroundStyle(track.isFavorite ? .pink : .secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if track.isAvailable { playback.play(track, queue: queue) } }
        .accessibilityHint(track.isAvailable ? "Double-tap to play" : "The audio file is not stored on this device")
    }
}

private struct MobilePlaylistsView: View {
    @EnvironmentObject private var library: MobileLibraryModel
    @State private var showingNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        Group {
            if library.playlists.isEmpty { ContentUnavailableView("No Playlists", systemImage: "music.note.house", description: Text("Create a playlist, then add tracks from their menus.")) }
            else {
                List(library.playlists) { playlist in
                    NavigationLink(playlist.name) { MobilePlaylistDetail(playlist: playlist) }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar { Button { showingNewPlaylist = true } label: { Image(systemName: "plus") } }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(named: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

private struct MobilePlaylistDetail: View {
    @EnvironmentObject private var library: MobileLibraryModel
    let playlist: Playlist
    private var entries: [PlaylistEntry] { library.entries(in: playlist) }
    private var tracks: [Track] { entries.map(\.track) }
    var body: some View {
        List(entries) { entry in
            MobileTrackRow(track: entry.track, queue: tracks)
                .swipeActions {
                    Button("Remove", role: .destructive) { library.remove(entry: entry, from: playlist) }
                }
        }
            .navigationTitle(playlist.name)
            .overlay { if tracks.isEmpty { ContentUnavailableView("Empty Playlist", systemImage: "music.note") } }
    }
}

private struct MobileNowPlayingView: View {
    @EnvironmentObject private var playback: MobilePlaybackController
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "moon.stars.fill").font(.system(size: 88)).foregroundStyle(.indigo.gradient)
            VStack(spacing: 6) {
                Text(playback.currentTrack?.displayTitle ?? "Nothing Playing").font(.title2.bold()).multilineTextAlignment(.center)
                Text(playback.currentTrack?.displayArtist ?? "Choose a track from your library").foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { playback.currentTime }, set: playback.seek), in: 0...max(playback.duration, 1))
            HStack(spacing: 42) {
                Button(action: playback.previous) { Image(systemName: "backward.fill") }
                Button(action: playback.togglePlayPause) { Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                Button(action: playback.next) { Image(systemName: "forward.fill") }
            }.buttonStyle(.plain).font(.title2)
            Spacer()
        }.padding(28).navigationTitle("Now Playing")
    }
}

private struct MobileSettingsView: View {
    @EnvironmentObject private var library: MobileLibraryModel
    let importAction: () -> Void
    var body: some View {
        List {
            Section("Library") {
                Button("Import Music", action: importAction)
                LabeledContent("Stored tracks", value: "\(library.tracks.filter(\.isAvailable).count)")
                LabeledContent("Audio storage", value: ByteCountFormatter.string(fromByteCount: library.storageUsageBytes, countStyle: .file))
                Text("Imported audio is copied into Moonlight’s Files-visible Music folder and excluded from iCloud Backup. Keep another copy: deleting the app deletes its local audio.").font(.caption).foregroundStyle(.secondary)
            }
            MobileSyncSettingsSection(coordinator: library.cloudSync)
            MobileRecoverySection(library: library)
        }.navigationTitle("Settings")
    }
}

private struct MobileRecoverySection: View {
    @ObservedObject var library: MobileLibraryModel
    @State private var snapshots: [MetadataArchiveSummary] = []
    @State private var candidate: MetadataArchiveSummary?

    var body: some View {
        Section("Historical Recovery") {
            Button("Protect Metadata Now") { library.protectMetadataNow(); reload() }
            if snapshots.isEmpty {
                Text("No snapshots yet").foregroundStyle(.secondary)
            } else {
                ForEach(snapshots) { snapshot in
                    Button { candidate = snapshot } label: {
                        VStack(alignment: .leading) {
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(snapshot.recordCount) records").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error = library.cloudSync.status.protectionProblem { Text("Protection failed: \(error)").foregroundStyle(.red) }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Restore this metadata snapshot?", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let candidate { library.restore(candidate); reload() }
                candidate = nil
            }
            Button("Cancel", role: .cancel) { candidate = nil }
        } message: { Text("Moonlight creates another recovery point first. Audio files are not changed.") }
    }

    private func reload() { snapshots = library.metadataSnapshots() }
}

private struct MobileSyncSettingsSection: View {
    let coordinator: CloudKitSyncCoordinator
    @ObservedObject private var status: CloudSyncStatus
    @State private var confirmingCloudReset = false
    init(coordinator: CloudKitSyncCoordinator) {
        self.coordinator = coordinator
        _status = ObservedObject(wrappedValue: coordinator.status)
    }
    var body: some View {
        Section("iCloud Metadata") {
            Toggle("Sync metadata", isOn: Binding(get: { status.isEnabled }, set: { value in Task { await coordinator.setEnabled(value) } }))
            LabeledContent("Status", value: status.problem?.rawValue ?? (status.isSyncing ? "Syncing" : "Up to date"))
            LabeledContent("Pending", value: "\(status.pendingChangeCount)")
            if let last = status.lastSuccessfulSync { LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened)) }
            Button("Sync Now") { Task { await coordinator.synchronize() } }.disabled(!status.isEnabled || status.isSyncing)
            if status.problem == .accountChanged || status.problem == .zoneDeleted || status.requiresFullResync {
                Button("Upload This Device’s Metadata") { Task { await coordinator.recoverKeepingLocalState() } }
                Button("Use iCloud State…", role: .destructive) { confirmingCloudReset = true }
            }
        }
        .confirmationDialog("Replace synchronized metadata with iCloud?", isPresented: $confirmingCloudReset, titleVisibility: .visible) {
            Button("Use iCloud State", role: .destructive) { Task { await coordinator.recoverUsingCloudState() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Moonlight creates a local recovery snapshot first. Audio files are not changed.") }
    }
}
