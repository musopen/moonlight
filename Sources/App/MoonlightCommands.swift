// MoonlightCommands.swift
//
// Defines the Mac menu bar items and their keyboard shortcuts, such as Play/Pause, Next Track,
// theme switching, adding music folders, rescanning the library, importing and exporting
// playlists, and opening help or feedback. Each menu item simply calls into the shared app state.

import AppKit
import SwiftUI

struct MoonlightCommands: Commands {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Moonlight") {
                appState.showingAbout = true
            }
        }
        CommandMenu("Controls") {
            Button("Exit Playback View") { appState.exitPlaybackSurface() }
                .keyboardShortcut(.escape, modifiers: [])
            Divider()
            Button("Play / Pause") { appState.playbackController.togglePlayPause() }
                .keyboardShortcut(" ", modifiers: [])
            Divider()
            Button("Next Track") { appState.playbackController.skipNext() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { appState.playbackController.skipPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Toggle Now Playing") { appState.toggleNowPlaying() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Toggle Mini Player") { appState.toggleMiniPlayer() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandMenu("Appearance") {
            Button("Browse Themes…") {
                appState.prepareAppearanceSettings()
                openSettings()
            }
            Button("Submit Theme Idea…") {
                appState.prepareAppearanceSettings(showThemeSuggestion: true)
                openSettings()
            }
            Divider()
            Button("Next Theme") {
                appState.selectAdjacentTheme(offset: 1)
            }
            Button("Previous Theme") {
                appState.selectAdjacentTheme(offset: -1)
            }
            Divider()
            Button("Current Theme: \(appState.selectedTheme.displayName)") {}
                .disabled(true)
        }
        CommandGroup(replacing: .newItem) {
            Button("Library") {}
                .disabled(true)
            Button("Add Music Folder…") { appState.showFolderPicker() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Rescan Library") { appState.rescanAllFolders() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Full Rebuild Library") { appState.fullRebuildAllFolders() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Divider()
            Button("Playlists") {}
                .disabled(true)
            Button("Import Playlists…") { appState.showPlaylistImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export Current Playlist…") {
                guard case .playlist(let id) = appState.selectedSidebarItem else { return }
                appState.exportPlaylist(id: id)
            }
            .disabled(!isPlaylistSelected)
            Button("New Smart Playlist…") { appState.showingSmartPlaylistEditor = true }
        }
        CommandGroup(replacing: .help) {
            Button("Moonlight Help") {
                appState.showingHelp = true
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
            Divider()
            Button("Contact Us…") {
                appState.showContactFeedback()
            }
            .disabled(!ContactService.isConfigured)
            Button("Feedback") {
                NSWorkspace.shared.open(URL(string: "https://moonlightapp.org/feedback")!)
            }
        }
    }

    private var isPlaylistSelected: Bool {
        if case .playlist = appState.selectedSidebarItem { return true }
        return false
    }
}
