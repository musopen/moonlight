// ContentView.swift
//
// The top-level layout of the main Mac window. It decides whether to show the library, the empty
// "add your music" screen or the mini player, and layers on shared extras such as scan progress
// banners, the feedback form, error sheets, the Escape key shortcut and dropping folders onto the
// window.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var escapeKeyMonitor: Any?
    @State private var isFolderDropTargeted = false

    var body: some View {
        Group {
            if appState.windowMode == .miniPlayer {
                MiniPlayerView()
            } else if appState.hasLibrary {
                libraryView
            } else {
                EmptyLibraryView()
                    .frame(minWidth: 600, minHeight: 400)
                    .background(Color.bgContent.ignoresSafeArea())
            }
        }
        .preferredColorScheme(appState.selectedTheme.colorScheme)
        .background(WindowModeWindowConfigurator(
            mode: appState.windowMode,
            theme: appState.selectedTheme,
            showsWindowButtons: showsWindowButtons,
            isEmptyLibrary: !appState.hasLibrary
        ))
        .overlay(alignment: .top) {
            if appState.isScanning, case .scanning(let summary) = appState.scanProgress {
                ScanProgressBanner(summary: summary,
                                   isCompleted: false, onDismiss: nil,
                                   onErrorTap: summary.errorCount > 0 ? { appState.showScanErrors() } : nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if case .completed(let summary) = appState.scanProgress, !summary.failed {
                ScanProgressBanner(summary: summary,
                                   isCompleted: true,
                                   onDismiss: { appState.dismissScanResult() },
                                   onErrorTap: summary.errorCount > 0 ? { appState.showScanErrors() } : nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let message = appState.contactFeedbackToastMessage {
                ContactFeedbackToast(message: message)
                    .padding(.bottom, appState.windowMode == .miniPlayer ? 20 : 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(30)
            }
        }
        .sheet(isPresented: $appState.showingScanErrors) {
            ScanErrorsSheet(errors: appState.lastScanErrors)
        }
        .sheet(isPresented: $appState.showingContactFeedback, onDismiss: {
            appState.dismissContactFeedback()
        }) {
            ContactFeedbackView(
                topic: appState.contactFeedbackTopic,
                onSubmissionSuccess: appState.showContactFeedbackSuccess
            )
                .frame(width: 560, height: 430)
        }
        .sheet(isPresented: $appState.showingAbout) {
            AboutMoonlightView {
                appState.showingAbout = false
                DispatchQueue.main.async {
                    appState.showContactFeedback()
                }
            }
            .frame(width: 460)
        }
        .sheet(isPresented: $appState.showingHelp, onDismiss: {
            appState.requestedHelpArticleID = nil
        }) {
            HelpCenterView(initialArticleID: appState.requestedHelpArticleID)
                .environmentObject(appState)
                .frame(width: 980, height: 680)
        }
        .sheet(item: $appState.tagEditorContext) { context in
            TagEditorSheet(context: context)
                .environmentObject(appState)
        }
        .sheet(item: $appState.playlistImportReview) { review in
            PlaylistImportReviewSheet(review: review)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingSmartPlaylistEditor) {
            SmartPlaylistEditorSheet()
                .environmentObject(appState)
        }
        .alert("Playlist Import", isPresented: Binding(
            get: { appState.playlistImportCompletion != nil },
            set: { if !$0 { appState.playlistImportCompletion = nil } }
        )) {
            Button("OK", role: .cancel) { appState.playlistImportCompletion = nil }
        } message: {
            Text(appState.playlistImportCompletion ?? "")
        }
        .alert("Could Not Open Playlist", isPresented: Binding(
            get: { appState.playlistImportError != nil },
            set: { if !$0 { appState.playlistImportError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.playlistImportError = nil }
        } message: {
            Text(appState.playlistImportError ?? "")
        }
        .alert("Playlist Export", isPresented: Binding(
            get: { appState.playlistExportCompletion != nil },
            set: { if !$0 { appState.playlistExportCompletion = nil } }
        )) {
            Button("OK", role: .cancel) { appState.playlistExportCompletion = nil }
        } message: {
            Text(appState.playlistExportCompletion ?? "")
        }
        .alert("Could Not Export Playlist", isPresented: Binding(
            get: { appState.playlistExportError != nil },
            set: { if !$0 { appState.playlistExportError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.playlistExportError = nil }
        } message: {
            Text(appState.playlistExportError ?? "")
        }
        .onAppear {
            installEscapeKeyMonitor()
        }
        .onDisappear {
            removeEscapeKeyMonitor()
        }
        .onExitCommand {
            appState.exitPlaybackSurface()
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: $isFolderDropTargeted,
            perform: appState.addDroppedFolders
        )
        .overlay {
            if isFolderDropTargeted {
                FolderDropOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isScanning)
        .animation(.easeInOut(duration: 0.3), value: appState.scanProgress)
        .animation(.easeInOut(duration: 0.3), value: appState.hasLibrary)
        .animation(.easeInOut(duration: 0.2), value: appState.windowMode)
    }

    private func installEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, shouldExitPlaybackSurfaceForEscape else {
                return event
            }

            appState.exitPlaybackSurface()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        escapeKeyMonitor = nil
    }

    private var shouldExitPlaybackSurfaceForEscape: Bool {
        appState.windowMode == .miniPlayer || appState.selectedSidebarItem == .nowPlaying
    }

    private var showsWindowButtons: Bool {
        appState.windowMode == .library && appState.selectedSidebarItem != .nowPlaying
    }

    private var libraryView: some View {
        HStack(spacing: 0) {
            if appState.selectedSidebarItem != .nowPlaying && !appState.isSidebarCollapsed {
                SidebarView()
            }

            ZStack {
                Color.bgContent.ignoresSafeArea()
                DetailRouter(
                    selection: appState.selectedSidebarItem
                )

                if let album = appState.presentedAlbum {
                    AlbumDetailView(
                        album: album,
                        revealTrackID: appState.presentedAlbumTrackID,
                        onBack: { appState.dismissPresentedAlbum() }
                    )
                    .transition(.move(edge: .trailing))
                    .background(Color.bgContent)
                    .zIndex(1)
                }
            }
            .ignoresSafeArea(.all, edges: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ZStack {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .onTapGesture {
                            appState.searchText = ""
                        }

                    SearchResultsView(query: appState.searchText) {
                        appState.searchText = ""
                    }
                    .frame(width: 760, height: 520)
                    .shadow(color: .black.opacity(0.34), radius: 30, y: 18)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
                .zIndex(20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if appState.selectedSidebarItem != .nowPlaying {
                TransportBarView()
            }
        }
        .background(Color.clear)
        .id(appState.selectedTheme)
        .frame(
            minWidth: appState.hasLibrary ? 900 : 600,
            minHeight: appState.hasLibrary ? 560 : 500
        )
        .animation(.easeInOut(duration: 0.18), value: appState.isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.18), value: appState.selectedSidebarItem)
    }
}

private struct FolderDropOverlay: View {
    var body: some View {
        ZStack {
            Color.dAccent.opacity(0.12)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30, weight: .medium))
                Text("Add Music Folder")
                    .font(.system(size: 15, weight: .semibold))
                Text("Drop a folder to add it to your library")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.dAccent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            }
        }
    }
}

private struct DetailRouter: View {
    let selection: SidebarItem

    var body: some View {
        switch selection {
        case .nowPlaying:       NowPlayingView()
        case .albums:           AlbumsGridView()
        case .artists:          ArtistsView()
        case .songs:            SongsTableView()
        case .favorites:        FavoritesView()
        case .composers:        ComposersView()
        case .genres:           GenresView()
        case .radio:            RadioView()
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        }
    }
}
