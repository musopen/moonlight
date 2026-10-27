// MoonlightCommands.swift
//
// Defines the Mac menu bar items and their keyboard shortcuts, such as Play/Pause, Next Track,
// theme switching, adding music folders, rescanning the library, importing and exporting
// playlists, opening help or feedback, and recording or exporting local interaction diagnostics.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MoonlightCommands: Commands {
    let appState: AppState
    @ObservedObject private var diagnostics = InteractionDiagnostics.shared
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
            Button(diagnostics.isRecording ? "Stop Diagnostic Recording" : "Start Diagnostic Recording") {
                if diagnostics.isRecording {
                    diagnostics.stop()
                } else {
                    diagnostics.start()
                }
            }
            Button("Export Diagnostics…") { diagnostics.export() }
                .disabled(!diagnostics.hasEvents)
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


// Records a bounded, opt-in interaction trace in memory until quit or the next recording.
// Only explicit event names, numeric state and session-local album tokens are recorded.
@MainActor
final class InteractionDiagnostics: ObservableObject {
    static let shared = InteractionDiagnostics()
    @Published private(set) var isRecording = false
    @Published private(set) var hasEvents = false
    private var events: [String] = []
    private var tokens: [Int64: Int] = [:]
    private var monitor: Any?
    private var started = Date()
    private var dropped = 0
    private let limit = 4000

    func start() {
        let alert = NSAlert()
        alert.messageText = "Record interaction diagnostics?"
        alert.informativeText = "Records mouse clicks, control types, and album actions locally until you stop or quit. No music metadata, file paths, typed text, screenshots, or account details are recorded. Only the latest 4,000 events are kept. Diagnostics are never uploaded automatically. After reproducing the problem, choose Help > Export Diagnostics to save a text file you can review and send to support. Starting a new recording clears the previous one."
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] event in
            // Observe only. Returning the original event preserves normal event dispatch.
            guard let self, self.isRecording else { return event }
            let point = event.locationInWindow
            let content = event.window?.contentView
            let hit = content?.hitTest(content?.convert(point, from: nil) ?? .zero)
            let typeName = hit.map { String(String(describing: type(of: $0)).prefix(160)) } ?? "none"
            self.record("mouse type=\(event.type.rawValue) window=\(event.windowNumber) x=\(Int(point.x)) y=\(Int(point.y)) clicks=\(event.clickCount) modifiers=\(event.modifierFlags.rawValue) hit=\(typeName)")
            return event
        }
    }

    // Separate session setup from the consent dialog so retention can be verified without UI.
    func beginRecording() {
        stop()
        events.removeAll(keepingCapacity: true)
        tokens.removeAll()
        dropped = 0
        started = Date()
        hasEvents = false
        isRecording = true
        record("recording.started")
    }

    func stop() {
        record("recording.stopped")
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func record(_ event: String, albumID: Int64? = nil) {
        guard isRecording else { return }
        var suffix = ""
        if let albumID {
            // Never export database IDs or album metadata.
            if tokens[albumID] == nil {
                guard tokens.count < limit else { return }
                tokens[albumID] = tokens.count + 1
            }
            suffix = " album=\(tokens[albumID]!)"
        }
        if events.count == limit { events.removeFirst(); dropped += 1 }
        events.append(String(format: "%.3f", Date().timeIntervalSince(started)) + " " + event + suffix)
        if !hasEvents { hasEvents = true }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moonlight-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export diagnostics"
            alert.informativeText = "Choose another writable location and try again. The recording is still available until you quit."
            alert.runModal()
        }
    }

    var report: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let header = """
        Moonlight interaction diagnostics, schema 1
        App: \(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(Self.architecture)
        Recording started: \(ISO8601DateFormatter().string(from: started))
        Recording active: \(isRecording)
        Earlier events discarded: \(dropped)
        Album tokens are temporary and have no meaning outside this recording.

        """
        return header + events.joined(separator: "\n") + "\n"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
