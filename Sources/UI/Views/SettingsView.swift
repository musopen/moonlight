// SettingsView.swift
//
// The Settings window. A sidebar leads to pages for music folders, iCloud sync, backups and
// recovery, identity, appearance and themes, playback, integrations, keyboard shortcuts,
// privacy, missing files, scan errors and acknowledgements. Folders can be added here by
// dragging them in.

import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable {
    case folders = "Folders"
    case sync = "iCloud Sync"
    case backups = "Backups & Recovery"
    case identity = "Identity & Recovery"
    case appearance = "Appearance"
    case playback = "Playback"
    case integrations = "Integrations"
    case shortcuts = "Shortcuts"
    case privacy = "Privacy"
    case missingFiles = "Missing Files"
    case scanErrors = "Scan Errors"
    case acknowledgements = "Acknowledgements"

    var systemImage: String {
        switch self {
        case .folders: "folder"
        case .sync: "icloud"
        case .backups: "externaldrive.badge.timemachine"
        case .identity: "link"
        case .appearance: "paintpalette"
        case .playback: "play.circle"
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised"
        case .missingFiles: "link.badge.plus"
        case .scanErrors: "exclamationmark.triangle"
        case .acknowledgements: "shippingbox"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SettingsTab = .folders
    @State private var folderToRemove: Int64?
    @State private var showingThemeSuggestion = false
    @State private var isFolderDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 980, height: 660)
        .background(Color.bgBase)
        .preferredColorScheme(appState.selectedTheme.colorScheme)
        .id(appState.selectedTheme)
        .confirmationDialog(
            "Remove this folder from your library?",
            isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Folder", role: .destructive) {
                if let id = folderToRemove { appState.removeFolder(id: id) }
                folderToRemove = nil
            }
            Button("Cancel", role: .cancel) { folderToRemove = nil }
        } message: {
            Text("Tracks from this folder will be removed from your library. Your files won't be deleted.")
        }
        .sheet(isPresented: $showingThemeSuggestion) {
            ContactFeedbackView(
                topic: .themeSuggestion,
                onSubmissionSuccess: appState.showContactFeedbackSuccess
            )
            .frame(width: 560, height: 430)
        }
        .onAppear {
            selectRequestedTab()
            presentRequestedThemeSuggestion()
        }
        .onChange(of: appState.requestedSettingsTab) { _ in
            selectRequestedTab()
        }
        .onChange(of: appState.requestedThemeSuggestion) { _ in
            presentRequestedThemeSuggestion()
        }
    }

    // MARK: - Sidebar

    private func selectRequestedTab() {
        guard let requestedTab = appState.requestedSettingsTab else { return }
        selectedTab = requestedTab
        appState.requestedSettingsTab = nil
    }

    private func presentRequestedThemeSuggestion() {
        guard appState.requestedThemeSuggestion else { return }
        showingThemeSuggestion = true
        appState.requestedThemeSuggestion = false
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            VStack(spacing: 1) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsSidebarRow(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .frame(width: 232)
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
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.borderSoft.opacity(0.7))
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .folders: foldersContent
        case .sync: SyncSettingsView(appState: appState)
        case .backups: BackupSettingsView(appState: appState)
        case .identity: IdentityRecoveryView(appState: appState)
        case .appearance: appearanceContent
        case .playback: playbackContent
        case .integrations: LastFMSettingsView(integration: appState.lastFMIntegration)
        case .shortcuts: shortcutsContent
        case .privacy: privacyContent
        case .missingFiles: MissingFilesSettingsView(appState: appState)
        case .scanErrors: scanErrorsContent
        case .acknowledgements: acknowledgementsContent
        }
    }

    // MARK: - Folders tab

    private var foldersContent: some View {
        VStack(spacing: 0) {
            foldersHeader
            Divider().overlay(Color.borderSoft)
            folderList
                .frame(maxHeight: .infinity)
            Divider().overlay(Color.borderSoft)
            foldersFooter
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: $isFolderDropTargeted,
            perform: appState.addDroppedFolders
        )
        .overlay {
            if isFolderDropTargeted {
                SettingsFolderDropOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isFolderDropTargeted)
    }

    private var foldersHeader: some View {
        HStack {
            Text("Music Folders")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(appState.folders.isEmpty ? "No folders" : "\(appState.folders.count) folder\(appState.folders.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var folderList: some View {
        if appState.folders.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.textTertiary)
                Text("No music folders added yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgContent)
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(appState.folders, id: \.id) { folder in
                        FolderRow(
                            folder: folder,
                            issue: appState.folderIssue(for: folder.id),
                            isScanning: appState.isScanning,
                            trackCount: appState.trackCount(inFolder: folder.id),
                            onRescan: { appState.rescanFolder(folder) },
                            onReconnect: { appState.showReconnectFolderPicker(for: folder.id) },
                            onFullRebuild: { appState.fullRebuildFolder(folder) },
                            onRemove: { folderToRemove = folder.id }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color.bgContent)
        }
    }

    private var foldersFooter: some View {
        VStack(spacing: 0) {
            portableIdentityBanner

            HStack {
                Spacer()

                if !appState.folders.isEmpty {
                    Menu {
                        Button {
                            appState.rescanAllFolders()
                        } label: {
                            Label("Check for Music Updates", systemImage: "arrow.clockwise")
                        }

                        Divider()

                        Button {
                            appState.fullRebuildAllFolders()
                        } label: {
                            Label("Full Rebuild Library", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(ButtonMenuStyle())
                    .tint(appState.isScanning ? Color.textTertiary : Color.dAccent)
                    .disabled(appState.isScanning)
                    .help("Check your music folders for additions or changes.")
                }

                Button {
                    appState.showFolderPicker()
                } label: {
                    Label("Add Music Folder…", systemImage: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dAccent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var portableIdentityBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Add a unique ID to imported or scanned files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("(Recommended)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)

                Spacer(minLength: 12)

                Text(appState.portableIdentityEnabled() ? "Enabled" : "Disabled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                Toggle("Store Moonlight Track IDs in compatible files", isOn: Binding(
                        get: { appState.portableIdentityEnabled() },
                        set: { appState.setPortableIdentityEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color.dAccent)
                    .labelsHidden()
            }

            Text("When enabled, Moonlight adds a small Track ID to supported file metadata—ID3 in MP3s and equivalent tag fields in other formats. This keeps ratings, favorites, playlists, and play counts linked across moves, renames, and your other devices. Audio and existing descriptive tags stay unchanged. [Learn more](https://moonlight.local/help/music-library)")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textSecondary)
                .tint(Color.dAccent)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.host == "moonlight.local", url.path == "/help/music-library" else {
                        return .systemAction
                    }
                    appState.showHelp(articleID: "music-library")
                    return .handled
                })
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dAccent.opacity(0.075))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.dAccent.opacity(0.18))
                .frame(height: 0.75)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.dAccent.opacity(0.18))
                .frame(height: 0.75)
        }
    }

    // MARK: - Appearance tab

    private var appearanceContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Theme")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(appState.selectedTheme.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeOptionRow(
                            theme: theme,
                            isSelected: appState.selectedTheme == theme
                        ) {
                            appState.selectedTheme = theme
                        }
                    }

                    ThemeSuggestionRow {
                        showingThemeSuggestion = true
                    }
                }
                .padding(20)
            }
            .background(Color.bgContent)

            if appState.selectedTheme.defaultArtworkTreatment != .color {
                Divider().overlay(Color.borderSoft)

                Toggle(isOn: $appState.applyThemeArtworkToThumbnails) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apply theme effect to album thumbnails")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("Renders album art in the grid using the theme's display style (e.g. phosphor green for Terminal).")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Playback tab

    private var playbackContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playback")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            VStack(spacing: 1) {
                Toggle(isOn: Binding(
                    get: { appState.playbackController.gaplessPlaybackEnabled },
                    set: { appState.playbackController.gaplessPlaybackEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gapless Playback")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("Preload the next track to avoid artificial pauses between queued songs.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.bgContent)
        }
    }

    // MARK: - Shortcuts tab

    private var shortcutsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("Playback and window controls")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(spacing: 18) {
                    ShortcutSection(title: "Views") {
                        ShortcutRow(
                            icon: "music.note.house",
                            title: "Toggle Now Playing",
                            detail: "Switch between the library and the full Now Playing view.",
                            keys: ["⌘", "⇧", "P"]
                        )
                        ShortcutRow(
                            icon: "pip.enter",
                            title: "Toggle Mini Player",
                            detail: "Shrink to the mini player or return to the main window.",
                            keys: ["⌘", "⇧", "M"]
                        )
                        ShortcutRow(
                            icon: "escape",
                            title: "Exit Playback View",
                            detail: "Leave mini player, or collapse Now Playing when it is open.",
                            keys: ["Esc"]
                        )
                    }

                    ShortcutSection(title: "Playback") {
                        ShortcutRow(
                            icon: "playpause.fill",
                            title: "Play / Pause",
                            detail: "Toggle the current track.",
                            keys: ["Space"]
                        )
                        ShortcutRow(
                            icon: "forward.end.fill",
                            title: "Next Track",
                            detail: "Skip forward in the queue.",
                            keys: ["⌘", "→"]
                        )
                        ShortcutRow(
                            icon: "backward.end.fill",
                            title: "Previous Track",
                            detail: "Skip backward in the queue.",
                            keys: ["⌘", "←"]
                        )
                    }

                    ShortcutSection(title: "Library") {
                        ShortcutRow(
                            icon: "folder.badge.plus",
                            title: "Add Music Folder",
                            detail: "Choose another folder to scan.",
                            keys: ["⌘", "O"]
                        )
                        ShortcutRow(
                            icon: "arrow.clockwise",
                            title: "Rescan Library",
                            detail: "Scan known folders for changes.",
                            keys: ["⌘", "⇧", "R"]
                        )
                    }
                }
                .padding(20)
            }
            .background(Color.bgContent)
        }
    }

    // MARK: - Privacy tab

    private var privacyContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            VStack(spacing: 1) {
                Toggle(isOn: Binding(
                    get: { UsageAnalytics.isEnabled },
                    set: { UsageAnalytics.isEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Google Analytics")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("Anonymous usage statistics. No personal information or advertising identifier is sent or used.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.bgContent)
        }
    }

    // MARK: - Scan Errors tab

    private var scanErrorsContent: some View {
        VStack(spacing: 0) {
            scanErrorsHeader
            Divider().overlay(Color.borderSoft)
            scanSummaryContent
            Divider().overlay(Color.borderSoft)
            ScanErrorsView(errors: appState.lastScanErrors)
        }
    }

    private var scanErrorsHeader: some View {
        HStack {
            Text("Scan Errors")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(appState.lastScanErrors.isEmpty
                 ? "No errors"
                 : "\(appState.lastScanErrors.count) error\(appState.lastScanErrors.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(appState.lastScanErrors.isEmpty ? Color.textTertiary : .orange)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var scanSummaryContent: some View {
        if let summary = appState.lastScanSummary {
            HStack(spacing: 16) {
                ScanSummaryMetric(label: "Scanned", value: "\(summary.processedFiles)")
                ScanSummaryMetric(label: "Skipped", value: "\(summary.skippedFiles)")
                ScanSummaryMetric(label: "Changed", value: "\(summary.changedFiles)")
                ScanSummaryMetric(label: "Relinked", value: "\(summary.relinkedFiles)")
                ScanSummaryMetric(label: "Missing", value: "\(summary.missingFiles)")
                ScanSummaryMetric(label: "Removed", value: "\(summary.removedFiles)")
                ScanSummaryMetric(label: "Errors", value: "\(summary.errorCount)", isWarning: summary.errorCount > 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.bgContent)
        }
    }

    // MARK: - Acknowledgements tab

    private var acknowledgementsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open Source Acknowledgements")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(ThirdPartyAcknowledgements.all.count) packages")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            AcknowledgementsView()
        }
    }
}

private struct SettingsFolderDropOverlay: View {
    var body: some View {
        ZStack {
            Color.dAccent.opacity(0.1)

            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                Text("Add Music Folder")
                    .font(.system(size: 14, weight: .semibold))
                Text("Drop a folder to add it to your library")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.dAccent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            }
        }
    }
}

// MARK: - Settings sidebar row

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Color.dAccent : Color.textTertiary)
                    .frame(width: 18, height: 18)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .fill(isSelected ? Color.bgSelectedActive : (isHovered ? Color.bgHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Folder row

private struct FolderRow: View {
    let folder: (url: URL, id: Int64)
    let issue: LibraryFolderIssue?
    let isScanning: Bool
    let trackCount: Int
    let onRescan: () -> Void
    let onReconnect: () -> Void
    let onFullRebuild: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.dAccent.opacity(0.85))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(folder.url.path(percentEncoded: false))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(trackCount.formatted()) \(trackCount == 1 ? "track" : "tracks") indexed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()

            Menu {
                if issue != nil {
                    Button("Reconnect Folder…", action: onReconnect)
                    Divider()
                }
                Button("Rescan This Folder", action: onRescan)
                    .disabled(isScanning)
                Button("Full Rebuild This Folder", action: onFullRebuild)
                    .disabled(isScanning)
                Divider()
                Button("Remove Folder", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(
            isHovered ? Color.white.opacity(0.04) : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct SyncSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var status: CloudSyncStatus
    @State private var showingCloudResetConfirmation = false

    init(appState: AppState) {
        self.appState = appState
        _status = ObservedObject(wrappedValue: appState.cloudSync.status)
    }

    private var coordinator: CloudKitSyncCoordinator { appState.cloudSync }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("iCloud Sync").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Spacer()
                if status.isSyncing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    syncIntroduction
                    syncControls

                    if status.problem == .accountChanged || status.problem == .zoneDeleted || status.requiresFullResync {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recovery required")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text(status.problem == .accountChanged
                                 ? "Choose whether this Mac's metadata or the current iCloud account should be authoritative."
                                 : "Choose whether to recreate iCloud from this Mac or accept the server reset.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.textTertiary)
                            HStack {
                                Button("Upload This Mac’s Metadata") {
                                    Task { await coordinator.recoverKeepingLocalState() }
                                }
                                Button("Use iCloud State…", role: .destructive) {
                                    showingCloudResetConfirmation = true
                                }
                            }
                        }
                    }

                    Spacer(minLength: 4)
                }
                .padding(20)
                .background(Color.bgContent)
            }
        }
        .confirmationDialog(
            "Replace this Mac’s synchronized metadata with iCloud?",
            isPresented: $showingCloudResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Use iCloud State", role: .destructive) {
                Task { await coordinator.recoverUsingCloudState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moonlight creates a local recovery snapshot first. Ratings, favorites, playlists, and aggregate play counts are then replaced by the current iCloud state.")
        }
    }

    private var syncIntroduction: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "icloud.and.arrow.up.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.dAccent)
                .frame(width: 44, height: 44)
                .background(Color.dAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your library preferences with you.")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("iCloud Sync keeps your ratings, favorites, playlists, playlist order, and play counts available across your Moonlight devices. It is optional, uses your own private iCloud account, and never uploads audio files or artwork.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("Private to your iCloud account", systemImage: "lock.fill")
                    Label("No audio uploaded", systemImage: "music.note")
                    Label("Turn off anytime", systemImage: "power")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private var syncControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("iCloud Sync")
                        .font(.system(size: 13, weight: .semibold))
                    Text(status.isEnabled ? "Sync metadata across your signed-in Moonlight devices." : "Off — your library remains local to this Mac.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textTertiary)
                }
                Spacer()
                Toggle("Sync Moonlight metadata with iCloud", isOn: Binding(
                    get: { status.isEnabled },
                    set: { enabled in Task { await coordinator.setEnabled(enabled) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Sync Moonlight metadata with iCloud")
                .disabled(status.isSyncing)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.problem == nil ? (status.isEnabled ? "icloud.fill" : "icloud.slash") : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.problem == nil ? (status.isEnabled ? Color.dAccent : Color.textTertiary) : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.textPrimary)
                    Text(status.explanation).font(.system(size: 10.5)).foregroundStyle(Color.textSecondary)
                    if status.isEnabled, let date = status.lastSuccessfulSync {
                        Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 9.5)).foregroundStyle(Color.textTertiary)
                    }
                    if let protectionProblem = status.protectionProblem {
                        Label("Metadata protection failed: \(protectionProblem)", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 8)
                if status.isSyncing { ProgressView().controlSize(.small) }
            }

            if status.isEnabled {
                HStack {
                    Button(status.problem == nil ? "Sync Now" : "Try Again") { Task { await coordinator.synchronize() } }
                        .disabled(status.isSyncing)
                }
                .controlSize(.small)
            }
        }
    }
}

private struct BackupSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var snapshots: [MetadataArchiveSummary] = []
    @State private var restoreCandidate: MetadataArchiveSummary?
    @State private var operationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Backups & Recovery").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep a way back.")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Create local copies of your library metadata before a major change, or export a copy to keep somewhere else. Backups include ratings, favorites, playlists, playlist order, and play history—not audio files or artwork.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button("Create Recovery Copy") {
                            operationError = nil
                            do {
                                try appState.createMetadataRecoveryPoint()
                                reloadSnapshots()
                            } catch {
                                operationError = error.localizedDescription
                            }
                        }
                        Button("Export Metadata…", action: appState.exportMetadata)
                    }

                    Divider().overlay(Color.borderSoft)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Local recovery copies").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text("\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.textTertiary)
                    }

                    if snapshots.isEmpty {
                        Text("No recovery copies yet.").font(.system(size: 11.5)).foregroundStyle(Color.textTertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(snapshots) { snapshot in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 11.5, weight: .medium))
                                        Text("\(snapshot.recordCount) records")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(Color.textTertiary)
                                    }
                                    Spacer()
                                    Button("Restore Copy…") { restoreCandidate = snapshot }.controlSize(.small)
                                }
                                .padding(.vertical, 8)
                                if snapshot.id != snapshots.last?.id {
                                    Divider().overlay(Color.borderSoft)
                                }
                            }
                        }
                    }

                    if let operationError {
                        Text(operationError).font(.system(size: 10.5)).foregroundStyle(.red)
                    }
                    Spacer(minLength: 4)
                }
                .padding(20)
                .background(Color.bgContent)
            }
        }
        .background(Color.bgContent)
        .onAppear(perform: reloadSnapshots)
        .confirmationDialog(
            "Restore this metadata snapshot?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore Snapshot", role: .destructive) {
                guard let snapshot = restoreCandidate else { return }
                operationError = nil
                Task {
                    do {
                        try await appState.restoreMetadataSnapshot(snapshot)
                        reloadSnapshots()
                    } catch {
                        operationError = error.localizedDescription
                    }
                    restoreCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text("Moonlight creates another recovery point before restoring. Audio files are not changed.")
        }
    }

    private func reloadSnapshots() {
        Task { snapshots = await appState.metadataSnapshots() }
    }
}

private struct IdentityRecoveryView: View {
    @ObservedObject var appState: AppState
    @State private var conflicts: [IdentityConflictItem] = []
    @State private var resolutionError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Identity & Recovery").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(conflicts.isEmpty ? "No conflicts" : "\(conflicts.count) to review").foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Color.borderSoft)
            if conflicts.isEmpty {
                ContentUnavailableView("No Identity Conflicts", systemImage: "checkmark.seal", description: Text("Moonlight has not found two materially different files claiming the same track ID."))
            } else {
                List(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.relativePath).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(conflict.reason).font(.system(size: 10.5)).foregroundStyle(Color.textTertiary)
                        HStack {
                            Button("They’re the Same Track") { resolve(conflict, same: true) }
                            Button("Keep Separate") { resolve(conflict, same: false) }
                        }.controlSize(.small)
                    }.padding(.vertical, 4)
                }
            }
            if let resolutionError { Text(resolutionError).foregroundStyle(.red).font(.system(size: 10.5)).padding(8) }
        }
        .background(Color.bgContent)
        .onAppear(perform: reload)
        .onChange(of: appState.libraryVersion) { reload() }
    }

    private func reload() { conflicts = appState.identityConflicts() }
    private func resolve(_ conflict: IdentityConflictItem, same: Bool) {
        do { try appState.resolveIdentityConflict(conflict.id, confirmSameTrack: same); reload() }
        catch { resolutionError = error.localizedDescription }
    }
}

private struct ScanSummaryMetric: View {
    let label: String
    let value: String
    var isWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isWarning ? .orange : Color.textPrimary)
                .lineLimit(1)
        }
    }
}

private struct ThemeOptionRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ThemeSwatches(colors: theme.palette.swatches)

                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(theme.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.dAccent : Color.textQuaternary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(isSelected ? Color.bgSelectedActive : (isHovered ? Color.bgHover : Color.bgBase.opacity(0.72)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .stroke(isSelected ? Color.dAccent.opacity(0.58) : Color.borderSoft, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct ThemeSuggestionRow: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 50, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.borderSoft, lineWidth: 0.75)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggest a theme")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("Share a palette you’d love to see")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(isHovered ? Color.bgHover : Color.bgBase.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .stroke(Color.borderSoft.opacity(0.8), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityHint("Opens a form to suggest a new Moonlight theme.")
    }
}

private struct ThemeSwatches: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle()
                    .fill(color)
                    .frame(width: 10)
            }
        }
        .frame(width: 50, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        )
    }
}

private struct ShortcutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textTertiary)

            VStack(spacing: 1) {
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ShortcutRow: View {
    let icon: String
    let title: String
    let detail: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.dAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(key)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgBase.opacity(0.78))
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .frame(minWidth: key.count > 1 ? 38 : 24, minHeight: 24)
            .padding(.horizontal, key.count > 1 ? 2 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}
