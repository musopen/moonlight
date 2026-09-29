// AppState.swift
//
// The central "brain" of the Mac app's window. It holds what the user is currently looking at
// (sidebar selection, mini player, Now Playing) and carries out library actions: adding and
// scanning music folders, recovering missing files, editing tags, favorites and ratings,
// playlists, background scenes and metadata backups. Screens read from it and call into it.

import SwiftUI
import AppKit
import Combine
import GRDB
import UniformTypeIdentifiers

struct ScanErrorItem: Identifiable {
    let id: Int64
    let fileURL: String
    let stableFileURL: String
    let stage: String
    let category: String
    let createdAt: Date?
    let reason: String
}

struct LibraryFolderIssue: Identifiable, Equatable {
    let folderId: Int64
    let url: URL
    let message: String
    let detectedAt: Date?

    var id: Int64 { folderId }
    var displayName: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

struct IdentityConflictItem: Identifiable, Equatable {
    let id: String
    let claimedTrackSyncID: String
    let physicalFileID: String
    let relativePath: String
    let reason: String
    let createdAt: Date
}

enum TrackRatingError: LocalizedError, Equatable {
    case invalidValue(Int)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let value):
            "Track ratings must be between 1 and 5, or nil for unrated (received \(value))."
        }
    }
}

enum WindowMode {
    case library
    case miniPlayer
}

enum PlaylistDuplicateAddResolution {
    case add
    case skip
    case cancel
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSidebarItem: SidebarItem = .albums {
        didSet { updateSidebarChrome(from: oldValue, to: selectedSidebarItem) }
    }
    @Published var isSidebarCollapsed = false
    @Published var windowMode: WindowMode = .library
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress = .idle
    @Published var hasLibrary = false
    @Published var searchText = ""
    @Published var playlists: [Playlist] = []
    @Published var folders: [(url: URL, id: Int64)] = []
    // Incremented whenever user-library metadata changes so views can reload.
    @Published var libraryVersion: Int = 0
    @Published var lastScanErrors: [ScanErrorItem] = []
    @Published var lastScanSummary: ScanSummary?
    @Published private(set) var unavailableLibraryFolders: [Int64: LibraryFolderIssue] = [:]
    @Published private var dismissedUnavailableLibraryFolderIDs: Set<Int64> = []
    @Published var showingScanErrors = false
    @Published var showingContactFeedback = false
    @Published var contactFeedbackTopic: ContactFeedbackTopic = .general
    @Published var requestedSettingsTab: SettingsTab?
    @Published var requestedThemeSuggestion = false
    @Published var showingAbout = false
    @Published var showingHelp = false
    @Published var requestedHelpArticleID: String?
    @Published var contactFeedbackToastMessage: String?
    @Published var presentedAlbum: Album?
    @Published var presentedAlbumTrackID: Int64?
    @Published var selectedScene: BuiltInScene?
    @Published var sceneURL: URL?
    @Published var sceneEnabled = false
    @Published var selectedTheme: AppTheme = AppTheme.current {
        didSet { selectedTheme.persist() }
    }
    @Published var applyThemeArtworkToThumbnails: Bool = UserDefaults.standard.bool(forKey: "applyThemeArtworkToThumbnails") {
        didSet { UserDefaults.standard.set(applyThemeArtworkToThumbnails, forKey: "applyThemeArtworkToThumbnails") }
    }

    let db: DatabaseManager
    let lastFMIntegration: LastFMIntegration
    let playbackController: PlaybackController
    let libraryScanner: LibraryScanner
    let bookmarkStore: FolderBookmarkStore
    let metadataEditingService: MetadataEditingService
    let missingFileResolver: MissingFileResolver
    let portableIdentityTagger: PortableIdentityTagger
    let cloudSync: CloudKitSyncCoordinator
    @Published var tagEditorContext: TagEditorContext?
    @Published var playlistImportReview: PlaylistImportReview?
    @Published var playlistImportCompletion: String?
    @Published var playlistImportError: String?
    @Published var playlistExportCompletion: String?
    @Published var playlistExportError: String?
    @Published var showingSmartPlaylistEditor = false
    private let folderChangeMonitor = LibraryFolderChangeMonitor()
    private var pendingScanRequests: [PendingScanRequest] = []
    private var pendingScanCompletionHandlers: [PendingScanRequest: [(ScanSummary?) -> Void]] = [:]
    private var isProcessingScanQueue = false
    private var scheduledScanTask: Task<Void, Never>?
    private var contactFeedbackToastTask: Task<Void, Never>?
    private var liveDebounceTasks: [Int64: Task<Void, Never>] = [:]
    private var liveScanCooldownUntil: [Int64: Date] = [:]
    private var sidebarCollapseStateBeforeNowPlaying: Bool?
    private var sidebarItemBeforeNowPlaying: SidebarItem?
    private var cloudSyncChangeCancellable: AnyCancellable?
    private let playlistDuplicateAddResolver: (Int) -> PlaylistDuplicateAddResolution

    convenience init() throws {
        self.init(db: try DatabaseManager(), startBackgroundTasks: true)
    }

    init(
        db: DatabaseManager,
        startBackgroundTasks: Bool = false,
        playlistDuplicateAddResolver: @escaping (Int) -> PlaylistDuplicateAddResolution = AppState.presentPlaylistDuplicateAlert
    ) {
        let lastFMIntegration = LastFMIntegration(db: db)
        self.db = db
        self.playlistDuplicateAddResolver = playlistDuplicateAddResolver
        self.lastFMIntegration = lastFMIntegration
        self.playbackController = PlaybackController(
            db: db,
            lastFMScrobbler: lastFMIntegration.coordinator
        )
        self.libraryScanner = LibraryScanner(db: db)
        self.bookmarkStore = FolderBookmarkStore(db: db)
        self.metadataEditingService = MetadataEditingService(db: db, bookmarkStore: bookmarkStore)
        self.missingFileResolver = MissingFileResolver(db: db)
        self.portableIdentityTagger = PortableIdentityTagger(db: db)
        self.cloudSync = CloudKitSyncCoordinator(manager: db)
        cloudSyncChangeCancellable = cloudSync.synchronizedLibraryChanges.$generation
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPlaylists()
                self.playbackController.refreshPersistedTracks()
                self.checkLibrary()
                self.libraryVersion += 1
            }
        self.playbackController.unavailableFileRecoveryHandler = { [weak self] track in
            self?.recoverUnavailableFileForPlayback(track)
        }
        loadSceneSettings()
        checkLibrary()
        refreshPlaylists()
        refreshFolders()
        if startBackgroundTasks {
            Task {
                await portableIdentityTagger.recoverInterruptedJobs()
                await portableIdentityTagger.drainPending()
            }
            Task { await cloudSync.start() }
            Task { [weak self] in
                guard let self else { return }
                do {
                    if let _ = try MetadataSnapshotStore.createIfDue(from: db) {
                        await MainActor.run { self.cloudSync.status.lastProtected = Date() }
                    }
                } catch {
                    await MainActor.run { self.cloudSync.status.protectionProblem = error.localizedDescription }
                }
            }
            startScheduledScanning()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.scanAllFolders(trigger: .launch)
            }
        }
    }

    deinit {
        scheduledScanTask?.cancel()
        contactFeedbackToastTask?.cancel()
        liveDebounceTasks.values.forEach { $0.cancel() }
    }

    func showContactFeedbackSuccess() {
        contactFeedbackToastTask?.cancel()
        contactFeedbackToastMessage = "Thanks—your feedback has been sent."
        contactFeedbackToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.contactFeedbackToastMessage = nil
        }
    }

    func showContactFeedback(topic: ContactFeedbackTopic = .general) {
        contactFeedbackTopic = topic
        showingContactFeedback = true
    }

    func dismissContactFeedback() {
        contactFeedbackTopic = .general
    }

    func prepareAppearanceSettings(showThemeSuggestion: Bool = false) {
        requestedSettingsTab = .appearance
        requestedThemeSuggestion = showThemeSuggestion
    }

    func selectAdjacentTheme(offset: Int) {
        let themes = AppTheme.allCases
        guard let currentIndex = themes.firstIndex(of: selectedTheme), !themes.isEmpty else { return }
        let nextIndex = (currentIndex + offset % themes.count + themes.count) % themes.count
        selectedTheme = themes[nextIndex]
    }

    // MARK: - Library scanning

    func refreshFolders() {
        Task {
            let loaded = await bookmarkStore.resolvedFolders()
            self.folders = loaded
            self.refreshUnavailableLibraryFolders()
            self.folderChangeMonitor.start(folders: loaded) { [weak self] url, id in
                self?.folderDidChange(url: url, id: id)
            }
        }
    }

    func addAndScanFolder(
        _ url: URL,
        showDuplicateAlert: Bool = false
    ) {
        Task {
            do {
                let registration = try await bookmarkStore.addFolder(url: url)
                guard case let .added(folderID, _) = registration else {
                    if showDuplicateAlert, case let .duplicate(_, duplicateURL) = registration {
                        showFolderAlreadyAddedAlert(for: duplicateURL)
                    }
                    return
                }

                let folder = await bookmarkStore.resolvedFolders().first { $0.id == folderID }
                refreshFolders()
                // An incremental scan retains existing indexed tracks and only
                // imports new or changed files in this newly-added folder.
                enqueueScan(url: folder?.url ?? url, folderId: folderID, mode: .incremental, trigger: .folderAdded)
            } catch {
                print("Bookmark error: \(error)")
            }
        }
    }

    /// Accepts Finder folder drops from any library window surface. Loading the
    /// provider is asynchronous, so report acceptance immediately and register
    /// each URL once it has been delivered by the pasteboard.
    func addDroppedFolders(from providers: [NSItemProvider]) -> Bool {
        let folderProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !folderProviders.isEmpty else { return false }

        for provider in folderProviders {
            provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self?.addAndScanFolder(url)
                }
            }
        }
        return true
    }

    func removeFolder(id: Int64) {
        let url = folders.first(where: { $0.id == id })?.url
        Task {
            do {
                try await bookmarkStore.removeFolder(id: id)
            } catch {
                print("Remove folder failed: \(error)")
                return
            }
            if let url {
                let folderPrefix = url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
                try? db.write { db in
                    try db.execute(
                        sql: "DELETE FROM tracks WHERE substr(file_url, 1, ?) = ?",
                        arguments: [folderPrefix.count, folderPrefix]
                    )
                }
            }
            await libraryScanner.rebuildDerivedData()
            refreshFolders()
            checkLibrary()
            libraryVersion += 1
        }
    }

    func removeAlbumFromLibrary(albumId: Int64?) {
        guard let albumId else { return }
        try? db.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE album_id = ?", arguments: [albumId])
        }
        Task {
            await libraryScanner.rebuildDerivedData()
            checkLibrary()
            libraryVersion += 1
        }
    }

    func removeAlbumsFromLibrary(albumIds: [Int64]) {
        guard !albumIds.isEmpty else { return }
        try? db.write { db in
            for albumId in albumIds {
                try db.execute(sql: "DELETE FROM tracks WHERE album_id = ?", arguments: [albumId])
            }
        }
        Task {
            await libraryScanner.rebuildDerivedData()
            checkLibrary()
            libraryVersion += 1
        }
    }

    /// Removes local library entries while leaving the source audio files in
    /// place, matching the existing album-level removal behavior.
    func removeTracksFromLibrary(trackIDs: [Int64]) {
        let uniqueTrackIDs = Set(trackIDs)
        guard !uniqueTrackIDs.isEmpty else { return }
        try? db.write { db in
            for trackID in uniqueTrackIDs {
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [trackID])
            }
        }
        Task {
            await libraryScanner.rebuildDerivedData()
            checkLibrary()
            libraryVersion += 1
        }
    }

    func trackCount(inFolder folderID: Int64) -> Int {
        (try? db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE folder_id = ?", arguments: [folderID])
        }) ?? 0
    }

    func scanAllFolders() {
        scanAllFolders(trigger: .manual)
    }

    func rescanAllFolders() {
        scanAllFolders(trigger: .manual)
    }

    func fullRebuildAllFolders() {
        Task {
            let folders = await bookmarkStore.resolvedFolders()
            for (url, id) in folders {
                enqueueScan(url: url, folderId: id, mode: .fullRebuild, trigger: .manual)
            }
        }
    }

    func rescanFolder(_ folder: (url: URL, id: Int64)) {
        enqueueScan(url: folder.url, folderId: folder.id, mode: .incremental, trigger: .manual)
    }

    func fullRebuildFolder(_ folder: (url: URL, id: Int64)) {
        enqueueScan(url: folder.url, folderId: folder.id, mode: .fullRebuild, trigger: .manual)
    }

    func scanAllFolders(trigger: ScanTrigger) {
        Task {
            let folders = await bookmarkStore.resolvedFolders()
            for (url, id) in folders {
                enqueueScan(url: url, folderId: id, mode: .incremental, trigger: trigger)
            }
        }
    }

    private func enqueueScan(
        url: URL,
        folderId: Int64?,
        mode: ScanMode,
        trigger: ScanTrigger,
        completion: ((ScanSummary?) -> Void)? = nil
    ) {
        let request = PendingScanRequest(url: url, folderId: folderId, mode: mode, trigger: trigger)
        if let completion {
            pendingScanCompletionHandlers[request, default: []].append(completion)
        }
        if !pendingScanRequests.contains(request) {
            pendingScanRequests.append(request)
        }

        guard !isProcessingScanQueue else { return }
        Task { await processScanQueue() }
    }

    private func processScanQueue() async {
        guard !isProcessingScanQueue else { return }
        isProcessingScanQueue = true
        defer { isProcessingScanQueue = false }

        while !pendingScanRequests.isEmpty {
            let request = pendingScanRequests.removeFirst()
            let summary = await performScan(request)
            let handlers = pendingScanCompletionHandlers.removeValue(forKey: request) ?? []
            handlers.forEach { $0(summary) }
        }
    }

    @discardableResult
    private func performScan(_ request: PendingScanRequest) async -> ScanSummary? {
        isScanning = true
        let summary = await libraryScanner.scan(
            folderURL: request.url,
            folderId: request.folderId,
            mode: request.mode,
            trigger: request.trigger
        ) { [weak self] summary in
            Task { @MainActor [weak self] in
                guard self?.shouldSurfaceScanProgress(for: request) == true else { return }
                self?.scanProgress = .scanning(summary)
            }
        }
        isScanning = false

        if let summary {
            lastScanSummary = summary
            UsageAnalytics.logScanCompleted(summary)
            updateFolderIssue(for: request, summary: summary)
            if summary.hasLibraryChanges {
                playbackController.refreshPersistedTracks()
            }
            if shouldSurfaceScanCompletion(summary, for: request) {
                scanProgress = .completed(summary)
            } else if case .scanning = scanProgress {
                scanProgress = .idle
            }
            lastScanErrors = fetchScanErrors(for: summary.jobId.map { [$0] } ?? [])
            if !summary.failed {
                // Deliberately tiny batches keep identity writes behind scanning
                // and playback. Remaining jobs resume on later scans/launches.
                Task { await portableIdentityTagger.drainPending() }
            }
        }

        checkLibrary()
        if summary?.hasLibraryChanges == true {
            libraryVersion += 1
        }
        if case .completed = scanProgress {
            Task {
                try? await Task.sleep(for: .seconds(2))
                // Only auto-dismiss if the user hasn't already interacted with the banner.
                if case .completed = self.scanProgress { self.scanProgress = .idle }
            }
        }
        return summary
    }

    private func shouldSurfaceScanProgress(for request: PendingScanRequest) -> Bool {
        request.trigger == .manual || request.trigger == .folderAdded || request.mode == .fullRebuild
    }

    private func shouldSurfaceScanCompletion(_ summary: ScanSummary, for request: PendingScanRequest) -> Bool {
        if request.trigger == .manual || request.trigger == .folderAdded || request.mode == .fullRebuild {
            return true
        }
        return summary.hasLibraryChanges || summary.errorCount > 0 || summary.failed
    }

    func dismissScanResult() { scanProgress = .idle }

    func showScanErrors() {
        showingScanErrors = true
    }

    private func fetchScanErrors(for jobIds: [Int64]) -> [ScanErrorItem] {
        guard !jobIds.isEmpty else { return [] }
        let placeholders = jobIds.map { _ in "?" }.joined(separator: ",")
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, file_url, stable_file_url, stage, category, created_at, reason FROM scan_errors
                WHERE scan_job_id IN (\(placeholders))
                ORDER BY id ASC
                LIMIT 200
            """, arguments: StatementArguments(jobIds)).map {
                ScanErrorItem(
                    id: $0["id"],
                    fileURL: $0["file_url"],
                    stableFileURL: $0["stable_file_url"],
                    stage: $0["stage"],
                    category: $0["category"],
                    createdAt: $0["created_at"],
                    reason: $0["reason"]
                )
            }
        }) ?? []
    }

    private func startScheduledScanning() {
        scheduledScanTask?.cancel()
        scheduledScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                guard !Task.isCancelled else { break }
                await self?.scanAllFolders(trigger: .scheduled)
            }
        }
    }

    private func folderDidChange(url: URL, id: Int64) {
        let cooldownDelay = liveScanCooldownUntil[id]?.timeIntervalSinceNow ?? 0
        let delay = max(2, cooldownDelay)
        liveDebounceTasks[id]?.cancel()
        liveDebounceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.liveDebounceTasks[id] = nil
                self?.liveScanCooldownUntil[id] = Date().addingTimeInterval(5)
                self?.enqueueScan(url: url, folderId: id, mode: .liveIncremental, trigger: .live)
            }
        }
    }

    private func refreshUnavailableLibraryFolders() {
        let issues = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT folders.id AS folder_id, folders.url, latest.failure_message,
                       latest.completed_at
                FROM folders
                JOIN scan_jobs AS latest ON latest.id = (
                    SELECT id FROM scan_jobs
                    WHERE folder_id = folders.id
                    ORDER BY started_at DESC, id DESC
                    LIMIT 1
                )
                WHERE latest.status = 'failed'
            """).compactMap { row -> LibraryFolderIssue? in
                guard let folderId: Int64 = row["folder_id"],
                      let urlString: String = row["url"],
                      let url = URL(string: urlString) else { return nil }
                return LibraryFolderIssue(
                    folderId: folderId,
                    url: url,
                    message: row["failure_message"] ?? "Moonlight could not read this folder.",
                    detectedAt: row["completed_at"]
                )
            }
        }) ?? []
        unavailableLibraryFolders = Dictionary(uniqueKeysWithValues: issues.map { ($0.folderId, $0) })
        dismissedUnavailableLibraryFolderIDs.formIntersection(unavailableLibraryFolders.keys)
    }

    private func updateFolderIssue(for request: PendingScanRequest, summary: ScanSummary) {
        guard let folderId = request.folderId else { return }
        if let failureMessage = summary.failureMessage {
            // Keep a notice dismissed while the same outage continues. A
            // successful scan clears the dismissal, so a later outage surfaces.
            if unavailableLibraryFolders[folderId] == nil {
                dismissedUnavailableLibraryFolderIDs.remove(folderId)
            }
            unavailableLibraryFolders[folderId] = LibraryFolderIssue(
                folderId: folderId,
                url: request.url,
                message: failureMessage,
                detectedAt: Date()
            )
        } else {
            unavailableLibraryFolders.removeValue(forKey: folderId)
            dismissedUnavailableLibraryFolderIDs.remove(folderId)
        }
    }

    var visibleUnavailableLibraryFolders: [LibraryFolderIssue] {
        unavailableLibraryFolders.values
            .filter { !dismissedUnavailableLibraryFolderIDs.contains($0.folderId) }
            .sorted { $0.folderId < $1.folderId }
    }

    func dismissUnavailableLibraryFolderNotice() {
        dismissedUnavailableLibraryFolderIDs.formUnion(unavailableLibraryFolders.keys)
    }

    func folderIssue(for id: Int64) -> LibraryFolderIssue? {
        unavailableLibraryFolders[id]
    }

    func prepareMissingFilesSettings() {
        requestedSettingsTab = .missingFiles
    }

    private func recoverUnavailableFileForPlayback(_ track: Track) {
        guard let folderId = track.folderId,
              let folder = folders.first(where: { $0.id == folderId }) else {
            playbackController.completeUnavailableFileRecovery(folderUnavailable: true)
            return
        }

        enqueueScan(
            url: folder.url,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { [weak self] summary in
            guard let self else { return }
            self.playbackController.completeUnavailableFileRecovery(
                folderUnavailable: summary?.failed != false
            )
        }
    }

    func showReconnectFolderPicker(for folderId: Int64) {
        let issueURL = unavailableLibraryFolders[folderId]?.url
            ?? folders.first(where: { $0.id == folderId })?.url
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the current location of “\(issueURL?.lastPathComponent ?? "this music folder")”. Moonlight will preserve track IDs where relative paths match."
        panel.prompt = "Reconnect"
        if let issueURL {
            panel.directoryURL = FileManager.default.fileExists(atPath: issueURL.path)
                ? issueURL
                : issueURL.deletingLastPathComponent()
        }
        panel.begin { [weak self] response in
            guard response == .OK, let selectedURL = panel.url, let self else { return }
            self.reconnectFolder(id: folderId, to: selectedURL)
        }
    }

    private func reconnectFolder(id: Int64, to newURL: URL) {
        Task {
            do {
                let oldURL = try await bookmarkStore.reconnectFolder(id: id, to: newURL)
                _ = try missingFileResolver.reconnectLibraryRoot(
                    folderId: id,
                    from: oldURL,
                    to: newURL
                )
                refreshFolders()
                enqueueScan(
                    url: newURL,
                    folderId: id,
                    mode: .incremental,
                    trigger: .folderAdded
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Reconnect Music Folder"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your music"
        panel.prompt = "Add Folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.addAndScanFolder(url, showDuplicateAlert: true)
        }
    }

    func portableIdentityEnabled() -> Bool {
        (try? db.read { try PortableIdentitySettings.isEnabled(in: $0) }) ?? true
    }

    func setPortableIdentityEnabled(_ enabled: Bool) {
        Task {
            try? db.write { database in
                try database.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [PortableIdentitySettings.enabledKey, enabled ? "1" : "0"]
                )
                guard enabled else { return }
                try database.execute(sql: """
                    UPDATE tagging_jobs SET state = 'pending', next_attempt_at = NULL
                    WHERE physical_file_id IN (
                        SELECT physical_file_id FROM physical_files
                        WHERE id_state IN ('absent', 'unknown')
                    )
                """)
            }
            libraryVersion += 1
            if enabled { await portableIdentityTagger.drainPending() }
        }
    }

    private func showFolderAlreadyAddedAlert(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Folder Already Added"
        alert.informativeText = "\"\(url.lastPathComponent)\" is already in your library."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func exportMetadata() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moonlight Metadata.ndjson"
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try MetadataArchive.export(to: url, from: self.db) }
            catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func metadataSnapshots() async -> [MetadataArchiveSummary] {
        (try? await MetadataArchiveWorker.run {
            try MetadataSnapshotStore.snapshots()
        }) ?? []
    }

    func createMetadataRecoveryPoint() throws {
        let url = try MetadataSnapshotStore.createRecoveryPoint(from: db, label: "manual")
        cloudSync.status.lastProtected = (try? MetadataArchive.summary(of: url).createdAt) ?? Date()
        cloudSync.status.protectionProblem = nil
    }

    func restoreMetadataSnapshot(_ snapshot: MetadataArchiveSummary) async throws {
        let manager = db
        try await MetadataArchiveWorker.run {
            try MetadataArchive.restore(from: snapshot.url, to: manager)
        }
        await cloudSync.noteSynchronizedStateReplacement()
    }

    func identityConflicts() -> [IdentityConflictItem] {
        (try? db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT ic.*, COALESCE(pf.relative_path, ic.physical_file_id) AS relative_path
                FROM identity_conflicts ic LEFT JOIN physical_files pf USING(physical_file_id)
                WHERE ic.resolved_at IS NULL ORDER BY ic.created_at
            """).map { row in
                IdentityConflictItem(id: row["id"], claimedTrackSyncID: row["track_sync_id"], physicalFileID: row["physical_file_id"], relativePath: row["relative_path"], reason: row["reason"], createdAt: row["created_at"])
            }
        }) ?? []
    }

    func resolveIdentityConflict(_ conflictID: String, confirmSameTrack: Bool) throws {
        try db.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT track_sync_id, physical_file_id FROM identity_conflicts WHERE id = ? AND resolved_at IS NULL", arguments: [conflictID]) else { return }
            let claimed: String = row["track_sync_id"]
            let physicalID: String = row["physical_file_id"]
            if confirmSameTrack,
               let current = try String.fetchOne(database, sql: "SELECT track_sync_id FROM physical_files WHERE physical_file_id = ?", arguments: [physicalID]) {
                _ = try IdentityRepository.merge(claimed, current, in: database)
            } else {
                try database.execute(sql: """
                    INSERT INTO tagging_jobs
                        (physical_file_id, state, may_replace_existing_identity, attempts)
                    VALUES (?, 'pending', 1, 0)
                    ON CONFLICT(physical_file_id) DO UPDATE SET
                        state = 'pending', may_replace_existing_identity = 1
                    """, arguments: [physicalID])
            }
            try database.execute(sql: "UPDATE identity_conflicts SET resolved_at = ? WHERE id = ?", arguments: [Date(), conflictID])
        }
        Task { await portableIdentityTagger.drainPending() }
        libraryVersion += 1
    }

    // MARK: - Missing-file recovery

    func missingFileRecoveryRows() throws -> [MissingFileRecoveryRow] {
        try missingFileResolver.recoveryRows()
    }

    func resolveMissingTrack(id: Int64, to url: URL) async throws {
        let standardizedPath = url.standardizedFileURL.path
        let folder = folders
            .filter { folder in
                var rootPath = folder.url.standardizedFileURL.path
                while rootPath.count > 1 && rootPath.hasSuffix("/") {
                    rootPath.removeLast()
                }
                let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
                return standardizedPath == rootPath || standardizedPath.hasPrefix(descendantPrefix)
            }
            .max { $0.url.path.count < $1.url.path.count }

        try missingFileResolver.resolve(missingTrackId: id, to: url, folderId: folder?.id)
        await libraryScanner.rebuildDerivedData()
        playbackController.refreshPersistedTracks()
        refreshPlaylists()
        checkLibrary()
        libraryVersion += 1
    }

    private func checkLibrary() {
        let count = (try? db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks")
        }) ?? 0
        hasLibrary = count > 0
    }

    // MARK: - Scenes

    func loadSceneSettings() {
        selectedScene = nil
        sceneURL = nil
        sceneEnabled = false
    }

    func toggleSceneEnabled() {
        if sceneEnabled {
            sceneEnabled = false
            return
        }

        guard let scene = selectedScene ?? BuiltInScenes.defaultScene else { return }
        selectedScene = scene
        sceneURL = scene.url
        sceneEnabled = sceneURL != nil
    }

    func selectNextScene() {
        let availableScenes = BuiltInScenes.all.filter { $0.url != nil }
        guard !availableScenes.isEmpty else {
            selectedScene = nil
            sceneURL = nil
            sceneEnabled = false
            return
        }

        let currentIndex = selectedScene.flatMap { selected in
            availableScenes.firstIndex(where: { $0.id == selected.id })
        } ?? -1
        let nextIndex = (currentIndex + 1) % availableScenes.count
        selectedScene = availableScenes[nextIndex]
        sceneURL = selectedScene?.url
        sceneEnabled = sceneURL != nil
    }

    func selectScene(_ scene: BuiltInScene) {
        selectedScene = scene
        sceneURL = scene.url
        sceneEnabled = sceneURL != nil
    }

    func disableScene() {
        sceneEnabled = false
    }

    // MARK: - Navigation

    func showNowPlaying() {
        searchText = ""
        presentedAlbum = nil
        presentedAlbumTrackID = nil
        if selectedSidebarItem == .nowPlaying {
            sidebarCollapseStateBeforeNowPlaying = sidebarCollapseStateBeforeNowPlaying ?? isSidebarCollapsed
            isSidebarCollapsed = true
        } else {
            selectedSidebarItem = .nowPlaying
        }
    }

    func exitNowPlaying() {
        guard selectedSidebarItem == .nowPlaying else { return }
        searchText = ""
        presentedAlbum = nil
        presentedAlbumTrackID = nil
        selectedSidebarItem = sidebarItemBeforeNowPlaying ?? .albums
    }

    func toggleNowPlaying() {
        if windowMode == .miniPlayer {
            exitMiniPlayer()
            showNowPlaying()
        } else if selectedSidebarItem == .nowPlaying {
            exitNowPlaying()
        } else {
            showNowPlaying()
        }
    }

    func showAlbum(albumId: Int64?, revealingTrackID trackID: Int64? = nil) {
        guard let albumId,
              let album = try? db.read({ db in try Album.fetchOne(db, key: albumId) })
        else { return }

        searchText = ""
        presentedAlbumTrackID = trackID
        selectedSidebarItem = .albums
        presentedAlbum = album
    }

    func dismissPresentedAlbum() {
        presentedAlbum = nil
        presentedAlbumTrackID = nil
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        isSidebarCollapsed = collapsed
    }

    private func updateSidebarChrome(from oldSelection: SidebarItem, to newSelection: SidebarItem) {
        guard oldSelection != newSelection else { return }

        if newSelection == .nowPlaying {
            sidebarItemBeforeNowPlaying = oldSelection
            sidebarCollapseStateBeforeNowPlaying = sidebarCollapseStateBeforeNowPlaying ?? isSidebarCollapsed
            isSidebarCollapsed = true
        } else if oldSelection == .nowPlaying {
            if let previousState = sidebarCollapseStateBeforeNowPlaying {
                isSidebarCollapsed = previousState
            }
            sidebarCollapseStateBeforeNowPlaying = nil
            sidebarItemBeforeNowPlaying = nil
        }
    }

    func revealInFinder(track: Track) {
        guard let url = URL(string: track.fileURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showHelp(articleID: String? = nil) {
        requestedHelpArticleID = articleID
        showingHelp = true
    }

    // MARK: - Tag editing

    func editTags(for track: Track) {
        tagEditorContext = TagEditorContext(title: "Edit Tags", tracks: [track])
    }

    func editAlbumTags(title: String, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        tagEditorContext = TagEditorContext(title: title, tracks: tracks)
    }

    func saveTagEdits(_ patch: TagEditPatch, for tracks: [Track]) async -> [TagEditResult] {
        let results = await metadataEditingService.apply(patch, to: tracks)
        if results.contains(where: {
            if case .saved = $0.status { return true }
            return false
        }) {
            await libraryScanner.rebuildDerivedData()
            checkLibrary()
            libraryVersion += 1
        }
        return results
    }

    // MARK: - Window mode

    func enterMiniPlayer() {
        guard playbackController.currentRadioStation == nil else {
            selectedSidebarItem = .radio
            return
        }
        windowMode = .miniPlayer
    }

    func exitMiniPlayer() {
        windowMode = .library
    }

    func toggleMiniPlayer() {
        if windowMode == .miniPlayer {
            exitMiniPlayer()
        } else {
            enterMiniPlayer()
        }
    }

    func exitPlaybackSurface() {
        if windowMode == .miniPlayer {
            exitMiniPlayer()
        } else {
            exitNowPlaying()
        }
    }

    // MARK: - Favorites

    func toggleFavorite(track: Track) {
        guard let trackId = track.dbId else { return }
        try? setFavorite(!track.isFavorite, forTrackID: trackId)
    }

    func setFavorite(_ isFavorite: Bool, forTrackID trackID: Int64) throws {
        try setFavorite(isFavorite, forTrackIDs: [trackID])
    }

    /// Updates all supplied durable track identities in one database transaction and
    /// publishes exactly one library refresh after the transaction succeeds.
    func setFavorite(_ isFavorite: Bool, forTrackIDs trackIDs: [Int64]) throws {
        let uniqueTrackIDs = Array(Set(trackIDs))
        guard !uniqueTrackIDs.isEmpty else { return }

        try db.write { database in
            try Self.setFavorite(isFavorite, forTrackIDs: uniqueTrackIDs, in: database)
        }
        libraryVersion += 1
        synchronizeUserEdit()
    }

    nonisolated static func setFavorite(_ isFavorite: Bool, forTrackIDs trackIDs: [Int64], in database: Database) throws {
        guard !trackIDs.isEmpty else { return }

        let deviceID = try SyncDeviceIdentity.id(in: database)
        let revision = SyncRevision.make(writerID: deviceID).rawValue
        for trackID in trackIDs {
            guard let syncID = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: trackID, in: database) else { continue }
            try database.execute(sql: "UPDATE tracks SET is_favorite = ?, favorite_rev = ? WHERE track_sync_id = ?", arguments: [isFavorite, revision, syncID])
            try database.execute(sql: """
                INSERT INTO track_annotations (track_sync_id, favorite, favorite_rev)
                VALUES (?, ?, ?)
                ON CONFLICT(track_sync_id) DO UPDATE SET favorite = excluded.favorite, favorite_rev = excluded.favorite_rev
            """, arguments: [syncID, isFavorite, revision])
            _ = try SyncEligibility.promote(syncID, in: database)
            try IdentityRepository.refreshComponent(for: syncID, in: database)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(syncID)", in: database)
        }
    }

    // MARK: - Ratings

    /// Updates all supplied durable track identities in one database transaction and
    /// publishes exactly one library refresh after the transaction succeeds.
    func setRating(_ rating: Int?, forTrackID trackID: Int64) throws {
        try setRating(rating, forTrackIDs: [trackID])
    }

    func setRating(_ rating: Int?, forTrackIDs trackIDs: [Int64]) throws {
        let uniqueTrackIDs = Array(Set(trackIDs))
        guard !uniqueTrackIDs.isEmpty else { return }

        try db.write { database in
            try Self.setRating(rating, forTrackIDs: uniqueTrackIDs, in: database)
        }
        libraryVersion += 1
        synchronizeUserEdit()
    }

    nonisolated static func setRating(_ rating: Int?, forTrackIDs trackIDs: [Int64], in database: Database) throws {
        if let rating, !(1...5).contains(rating) {
            throw TrackRatingError.invalidValue(rating)
        }
        guard !trackIDs.isEmpty else { return }

        let deviceID = try SyncDeviceIdentity.id(in: database)
        let revision = SyncRevision.make(writerID: deviceID).rawValue
        for trackID in trackIDs {
            guard let syncID = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: trackID, in: database) else { continue }
            try database.execute(sql: "UPDATE tracks SET rating = ?, rating_rev = ? WHERE track_sync_id = ?", arguments: [rating, revision, syncID])
            try database.execute(sql: """
                INSERT INTO track_annotations (track_sync_id, rating, rating_rev)
                VALUES (?, ?, ?)
                ON CONFLICT(track_sync_id) DO UPDATE SET rating = excluded.rating, rating_rev = excluded.rating_rev
            """, arguments: [syncID, rating, revision])
            _ = try SyncEligibility.promote(syncID, in: database)
            try IdentityRepository.refreshComponent(for: syncID, in: database)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(syncID)", in: database)
        }
    }

    // MARK: - Playlists

    func refreshPlaylists() {
        do {
            // Some pre-sync libraries contain playlist rows created before the
            // revision columns existed. Normalize nullable legacy fields in the
            // read model so one old row cannot make the entire sidebar disappear.
            playlists = try db.read { db in
                try Playlist.fetchAll(db, sql: """
                    SELECT id, name, date_created, date_modified,
                           COALESCE(playlist_sync_id, '') AS playlist_sync_id,
                           COALESCE(kind, 'manual') AS kind,
                           COALESCE(name_rev, '') AS name_rev,
                           COALESCE(sort_mode, 'manual') AS sort_mode,
                           COALESCE(sort_mode_rev, '') AS sort_mode_rev,
                           rule, rule_rev, deleted_at
                    FROM playlists
                    WHERE deleted_at IS NULL
                    ORDER BY name COLLATE NOCASE
                """)
            }
            // A fetched parent tombstone can remove the selected playlist while
            // its historical membership rows remain stored for sync/recovery.
            if case .playlist(let selectedID) = selectedSidebarItem,
               !playlists.contains(where: { $0.id == selectedID }) {
                selectedSidebarItem = .albums
            }
        } catch {
            print("Refresh playlists failed: \(error)")
        }
    }

    func showPlaylistImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Playlists"
        panel.message = "Choose M3U or M3U8 playlists that reference music already in your library."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "m3u") ?? .plainText,
            UTType(filenameExtension: "m3u8") ?? .plainText
        ]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            do {
                let previews = try self.db.read { try PlaylistImportService.preview(urls: panel.urls, in: $0) }
                self.playlistImportReview = PlaylistImportReview(previews: previews)
            } catch {
                self.playlistImportError = error.localizedDescription
            }
        }
    }

    func commitPlaylistImport(_ review: PlaylistImportReview, removeRepeatedTracks: Bool) throws {
        let summary = try db.write {
            try PlaylistImportService.commit(
                previews: review.previews,
                removeRepeatedTracks: removeRepeatedTracks,
                in: $0
            )
        }
        refreshPlaylists()
        libraryVersion += 1
        if let first = summary.playlistIDs.first { selectedSidebarItem = .playlist(first) }
        playlistImportCompletion = "Imported \(summary.importedTrackCount) track\(summary.importedTrackCount == 1 ? "" : "s") into \(summary.playlistIDs.count) playlist\(summary.playlistIDs.count == 1 ? "" : "s").\(summary.unresolvedEntryCount == 0 ? "" : " \(summary.unresolvedEntryCount) entr\(summary.unresolvedEntryCount == 1 ? "y was" : "ies were") not found in this library.")"
    }

    func exportPlaylist(id playlistID: Int64) {
        do {
            let export = try db.read { db -> (name: String, tracks: [Track]) in
                guard let playlist = try Playlist.fetchOne(db, key: playlistID) else {
                    throw CocoaError(.fileNoSuchFile)
                }

                let tracks: [Track]
                if playlist.kind == "smart" {
                    guard let rule = playlist.rule else { return (playlist.name, []) }
                    tracks = try SmartPlaylistEvaluator.tracks(matching: SmartPlaylistRule.decoded(rule), in: db)
                } else {
                    tracks = try PlaylistEntry.fetchVisible(in: playlistID, from: db).map(\.track)
                }
                return (playlist.name, tracks)
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = export.name + ".m3u"
            panel.allowedContentTypes = [
                UTType(filenameExtension: "m3u") ?? .plainText,
                UTType(filenameExtension: "m3u8") ?? .plainText
            ]
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { return }
                do {
                    let report = try M3UExporter.export(tracks: export.tracks, to: url)
                    self.playlistExportCompletion = "Exported \(report.exportedTrackCount) track\(report.exportedTrackCount == 1 ? "" : "s").\(report.unavailableTrackCount == 0 ? "" : " \(report.unavailableTrackCount) unavailable track\(report.unavailableTrackCount == 1 ? " was" : "s were") not included.")"
                } catch {
                    self.playlistExportError = error.localizedDescription
                }
            }
        } catch {
            playlistExportError = error.localizedDescription
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> Playlist? {
        let name = name.singleLineText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let now = Date()
        var playlist = Playlist(name: name, dateCreated: now, dateModified: now)
        try? db.write { db in
            let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
            playlist.nameRev = revision
            playlist.sortModeRev = revision
            try playlist.insert(db)
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(playlist.playlistSyncId)", in: db)
        }
        refreshPlaylists()
        synchronizeUserEdit()
        return playlist
    }

    @discardableResult
    func createSmartPlaylist(name: String, rule: SmartPlaylistRule) -> Playlist? {
        let name = name.singleLineText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let now = Date()
        var playlist = Playlist(name: name, dateCreated: now, dateModified: now, kind: "smart")
        try? db.write { db in
            let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
            playlist.nameRev = revision
            playlist.sortModeRev = revision
            playlist.rule = try rule.encoded()
            playlist.ruleRev = revision
            try playlist.insert(db)
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(playlist.playlistSyncId)", in: db)
        }
        refreshPlaylists()
        synchronizeUserEdit()
        return playlist
    }

    func renamePlaylist(id: Int64, name: String) {
        let name = name.singleLineText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? db.write { db in
            let now = Date()
            let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
            try db.execute(sql: "UPDATE playlists SET name = ?, name_rev = ?, date_modified = ? WHERE id = ?",
                           arguments: [name, revision, now, id])
            if let syncID = try String.fetchOne(db, sql: "SELECT playlist_sync_id FROM playlists WHERE id = ?", arguments: [id]) {
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(syncID)", in: db)
            }
        }
        refreshPlaylists()
        libraryVersion += 1
        synchronizeUserEdit()
    }

    @discardableResult
    func duplicatePlaylist(id: Int64) -> Playlist? {
        var duplicate: Playlist?
        do {
            try db.write { db in
                guard let source = try Playlist.fetchOne(db, key: id), source.deletedAt == nil else { return }
                let now = Date()
                let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
                var copy = Playlist(
                    name: source.name + " Copy",
                    dateCreated: now,
                    dateModified: now,
                    kind: source.kind,
                    nameRev: revision,
                    sortMode: source.sortMode,
                    sortModeRev: revision,
                    rule: source.rule,
                    ruleRev: source.rule == nil ? nil : revision
                )
                try copy.insert(db)
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(copy.playlistSyncId)", in: db)
                if source.kind != "smart", let copyID = copy.id {
                    let trackIDs = try Int64.fetchAll(db, sql: """
                        SELECT track_id FROM playlist_tracks
                        WHERE playlist_id = ? AND deleted_at IS NULL
                        ORDER BY position, id
                    """, arguments: [id])
                    try PlaylistMutation.append(trackIDs, to: copyID, in: db)
                }
                duplicate = copy
            }
        } catch {
            return nil
        }
        refreshPlaylists()
        if duplicate != nil { synchronizeUserEdit() }
        return duplicate
    }

    func deletePlaylist(id: Int64) {
        try? db.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE playlists SET deleted_at = ?, date_modified = ? WHERE id = ?", arguments: [now, now, id])
            try db.execute(sql: "UPDATE playlist_tracks SET deleted_at = COALESCE(deleted_at, ?) WHERE playlist_id = ?", arguments: [now, id])
            if let syncID = try String.fetchOne(db, sql: "SELECT playlist_sync_id FROM playlists WHERE id = ?", arguments: [id]) {
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(syncID)", in: db)
            }
        }
        if case .playlist(id) = selectedSidebarItem { selectedSidebarItem = .albums }
        refreshPlaylists()
        synchronizeUserEdit()
    }

    func addTrack(_ track: Track, toPlaylist playlistId: Int64) {
        guard let trackId = track.dbId else { return }
        addTrackIDs([trackId], toPlaylist: playlistId)
    }

    func addTracks(_ tracks: [Track], toPlaylist playlistId: Int64) {
        addTrackIDs(tracks.compactMap(\.dbId), toPlaylist: playlistId)
    }

    /// Adds full albums in the order dragged. Each album's tracks retain their
    /// disc and track-number order. Existing playlist entries are surfaced to
    /// the user so they can choose whether to repeat or skip them.
    func addAlbums(_ albumIDs: [Int64], toPlaylist playlistId: Int64) {
        var seenAlbumIDs = Set<Int64>()
        let orderedAlbumIDs = albumIDs.filter { seenAlbumIDs.insert($0).inserted }
        guard !orderedAlbumIDs.isEmpty else { return }
        do {
            let trackIDs = try db.read { db -> [Int64] in
                var trackIDs: [Int64] = []
                for albumID in orderedAlbumIDs {
                    trackIDs.append(contentsOf: try Int64.fetchAll(db, sql: """
                        SELECT id FROM tracks
                        WHERE album_id = ?
                          AND \(LibraryTrackQuery.catalogPredicate())
                        ORDER BY disc_number, track_number, id
                    """, arguments: [albumID]))
                }
                return trackIDs
            }
            addTrackIDs(trackIDs, toPlaylist: playlistId)
        } catch {
            print("Add albums to playlist failed: \(error)")
        }
    }

    func addDraggedTracks(_ payloads: [TrackDragPayload], toPlaylist playlistId: Int64) {
        let trackIds = payloads.flatMap(\.trackIds)
        guard !trackIds.isEmpty else { return }
        addTrackIDs(trackIds, toPlaylist: playlistId)
    }

    func insertTrackIds(_ trackIDs: [Int64], intoPlaylist playlistId: Int64, atRow row: Int) {
        addTrackIDs(trackIDs, toPlaylist: playlistId, atRow: row)
    }

    private func addTrackIDs(_ trackIDs: [Int64], toPlaylist playlistId: Int64, atRow row: Int? = nil) {
        var seenTrackIDs = Set<Int64>()
        let uniqueTrackIDs = trackIDs.filter { seenTrackIDs.insert($0).inserted }
        guard !uniqueTrackIDs.isEmpty else { return }

        do {
            let existingTrackIDs = Set(try db.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT track_id FROM playlist_tracks
                    WHERE playlist_id = ? AND deleted_at IS NULL
                """, arguments: [playlistId])
            })
            let duplicateTrackIDs = uniqueTrackIDs.filter(existingTrackIDs.contains)
            let trackIDsToAdd: [Int64]
            if duplicateTrackIDs.isEmpty {
                trackIDsToAdd = uniqueTrackIDs
            } else {
                switch playlistDuplicateAddResolver(duplicateTrackIDs.count) {
                case .add:
                    trackIDsToAdd = uniqueTrackIDs
                case .skip:
                    trackIDsToAdd = uniqueTrackIDs.filter { !existingTrackIDs.contains($0) }
                case .cancel:
                    return
                }
            }
            guard !trackIDsToAdd.isEmpty else { return }
            try db.write { db in
                let entryIDs = try PlaylistMutation.append(trackIDsToAdd, to: playlistId, in: db)
                if let row {
                    try Self.reorderPlaylistEntries(entryIDs, inPlaylist: playlistId, toRow: row, in: db)
                }
            }
            refreshPlaylists()
            libraryVersion += 1
            synchronizeUserEdit()
        } catch {
            print("Add tracks to playlist failed: \(error)")
        }
    }

    private static func presentPlaylistDuplicateAlert(duplicateTrackCount: Int) -> PlaylistDuplicateAddResolution {
        let alert = NSAlert()
        alert.messageText = "There are duplicates being added to the playlist."
        alert.informativeText = duplicateTrackCount == 1
            ? "Would you like to add the duplicate or skip it?"
            : "Would you like to add the duplicates or skip them?"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .add
        case .alertSecondButtonReturn: return .skip
        default: return .cancel
        }
    }

    /// Moves one or more playlist memberships to a row position in the playlist's
    /// current custom order. Membership IDs preserve the intent when a track occurs
    /// more than once in a playlist.
    func reorderPlaylistEntries(_ entryIDs: [Int64], inPlaylist playlistId: Int64, toRow row: Int) {
        guard !entryIDs.isEmpty else { return }
        do {
            try db.write { db in
                try Self.reorderPlaylistEntries(entryIDs, inPlaylist: playlistId, toRow: row, in: db)
            }
            libraryVersion += 1
            synchronizeUserEdit()
        } catch {
            print("Reorder playlist failed: \(error)")
        }
    }

    func removePlaylistEntries(_ entryIDs: [Int64], fromPlaylist playlistId: Int64) {
        guard !entryIDs.isEmpty else { return }
        do {
            try db.write { database in
                try PlaylistEntry.softDelete(entryIDs: entryIDs, inPlaylist: playlistId, in: database)
            }
            libraryVersion += 1
            synchronizeUserEdit()
        } catch {
            print("Remove playlist entries failed: \(error)")
        }
    }

    nonisolated static func reorderPlaylistEntries(
        _ entryIDs: [Int64],
        inPlaylist playlistId: Int64,
        toRow row: Int,
        in db: Database
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, ordering_key FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL ORDER BY position, id",
            arguments: [playlistId]
        )
        let orderedIDs: [Int64] = rows.map { $0["id"] }
        let requestedIDs = Set(entryIDs)
        let movingIDs = orderedIDs.filter(requestedIDs.contains)
        guard !movingIDs.isEmpty else { return }

        let normalizedRow = min(max(row, 0), orderedIDs.count)
        let movingSet = Set(movingIDs)
        let insertionIndex = orderedIDs.prefix(normalizedRow).filter { !movingSet.contains($0) }.count
        var reorderedIDs = orderedIDs.filter { !movingSet.contains($0) }
        reorderedIDs.insert(contentsOf: movingIDs, at: insertionIndex)

        guard reorderedIDs != orderedIDs else { return }
        var originalKeys: [Int64: String] = [:]
        for (position, row) in rows.enumerated() {
            let entryID: Int64 = row["id"]
            let stored: String = row["ordering_key"]
            let key = stored.isEmpty ? FractionalOrderingKey.initial(at: position) : stored
            originalKeys[entryID] = key
            if stored.isEmpty {
                try db.execute(sql: "UPDATE playlist_tracks SET ordering_key = ? WHERE id = ?", arguments: [key, entryID])
            }
        }
        let writerID = try SyncDeviceIdentity.id(in: db)
        let revision = SyncRevision.make(writerID: writerID).rawValue
        let firstMovingIndex = reorderedIDs.firstIndex(where: movingSet.contains)!
        let lastMovingIndex = reorderedIDs.lastIndex(where: movingSet.contains)!
        let lowerKey = firstMovingIndex > 0 ? originalKeys[reorderedIDs[firstMovingIndex - 1]] : nil
        let upperKey = lastMovingIndex + 1 < reorderedIDs.count ? originalKeys[reorderedIDs[lastMovingIndex + 1]] : nil
        var generatedKeys: [Int64: String] = [:]
        var prior = lowerKey
        for entryID in reorderedIDs[firstMovingIndex...lastMovingIndex] where movingSet.contains(entryID) {
            let key = FractionalOrderingKey.between(prior, upperKey)
            generatedKeys[entryID] = key
            prior = key
        }
        for (position, entryID) in reorderedIDs.enumerated() {
            if let orderingKey = generatedKeys[entryID] {
                try db.execute(sql: "UPDATE playlist_tracks SET position = ?, ordering_key = ?, ordering_key_rev = ? WHERE id = ?", arguments: [position, orderingKey, revision, entryID])
                if let entrySyncID = try String.fetchOne(db, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE id = ?", arguments: [entryID]), !entrySyncID.isEmpty {
                    try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entrySyncID)", in: db)
                }
            } else {
                try db.execute(sql: "UPDATE playlist_tracks SET position = ? WHERE id = ?", arguments: [position, entryID])
            }
        }
        if generatedKeys.values.contains(where: { $0.count > 40 }) {
            for (position, entryID) in reorderedIDs.enumerated() {
                try db.execute(sql: "UPDATE playlist_tracks SET ordering_key = ?, ordering_key_rev = ? WHERE id = ?", arguments: [FractionalOrderingKey.initial(at: position), revision, entryID])
                if let entrySyncID = try String.fetchOne(db, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE id = ?", arguments: [entryID]), !entrySyncID.isEmpty {
                    try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entrySyncID)", in: db)
                }
            }
        }
        try db.execute(
            sql: "UPDATE playlists SET date_modified = ? WHERE id = ?",
            arguments: [Date(), playlistId]
        )
    }

    nonisolated static func appendTrackIds(_ trackIds: [Int64], toPlaylist playlistId: Int64, in db: Database) throws {
        try PlaylistMutation.append(trackIds, to: playlistId, in: db)
    }

    /// User edits should not wait for the outbox observer's burst-coalescing
    /// timer. The observer remains the durable fallback if the engine is busy,
    /// offline, or has not finished starting.
    private func synchronizeUserEdit() {
        Task { [cloudSync] in
            await cloudSync.synchronize(force: false)
        }
    }
}

private struct PendingScanRequest: Hashable {
    let url: URL
    let folderId: Int64?
    let mode: ScanMode
    let trigger: ScanTrigger
}

enum ScanProgress: Equatable {
    case idle
    case scanning(ScanSummary)
    case completed(ScanSummary)
}
