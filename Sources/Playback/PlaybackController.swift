// PlaybackController.swift
//
// The Mac app's main playback manager, sitting between the screens and the audio player. It
// manages the play queue, shuffle, repeat, volume, gapless playback and live radio, counts plays
// and sends them to Last.fm. It also remembers where you left off between launches and asks the
// library to recheck a song whose file has gone missing.

import Foundation
import Combine
import GRDB

enum RepeatMode: String, CaseIterable {
    case off, one, all
}

private struct PendingFileRecovery {
    let track: Track
    let tracks: [Track]
    let shouldIncrementPlayCount: Bool
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentRadioStation: RadioStation?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int = 0
    @Published var repeatMode: RepeatMode = .off {
        didSet { configurePreparedNextItem() }
    }
    @Published var isShuffled: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var playbackError: String?
    @Published private(set) var unavailableTrackForPlayback: Track?
    @Published private(set) var playbackFolderUnavailable = false
    @Published private(set) var isRecoveringUnavailableFile = false
    @Published private(set) var volume: Float = 1.0
    @Published private(set) var volumeMode: PlaybackVolumeMode = .playerVolume
    @Published var gaplessPlaybackEnabled: Bool = true {
        didSet {
            persistGaplessPlaybackSetting()
            configurePreparedNextItem()
        }
    }

    let engine: any PlaybackEngine
    private let db: DatabaseManager
    private let routeVolumeController: RouteVolumeControlling
    private let lastFMScrobbler: LastFMScrobbleCoordinator?
    private let fileExists: (URL) -> Bool
    private var playerVolume: Float = 1.0
    private var externalPlaybackActive = false
    private var audioOutputDeviceUniqueID: String?
    private var cancellables = Set<AnyCancellable>()
    private var nowPlayingUpdater: NowPlayingUpdater?
    private var mediaKeyMonitor: MediaKeyMonitor?
    private var preparedNextTrack: Track?
    private var unshuffledQueue: [Track]?
    private var pendingRestorePosition: (trackId: Int64, position: TimeInterval)?
    private var hasStartedPlayback = false
    private var lastMediaCommand: (command: MediaKeyCommand, time: TimeInterval)?
    private let duplicateMediaCommandInterval: TimeInterval = 0.35
    private var pendingFileRecovery: PendingFileRecovery?

    /// Set by AppState so playback can request a library reconciliation without
    /// coupling the controller to folder bookmarks or the scanner.
    var unavailableFileRecoveryHandler: ((Track) -> Void)?

    init(
        db: DatabaseManager,
        engine: any PlaybackEngine = AVFoundationPlayer(),
        enableMediaKeyMonitor: Bool = true,
        routeVolumeController: RouteVolumeControlling = HybridRouteVolumeController(),
        lastFMScrobbler: LastFMScrobbleCoordinator? = nil,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.db = db
        self.engine = engine
        self.routeVolumeController = routeVolumeController
        self.lastFMScrobbler = lastFMScrobbler
        self.fileExists = fileExists
        self.gaplessPlaybackEnabled = Self.loadGaplessPlaybackSetting(db: db)
        subscribeToEngineState()
        subscribeToEngineTransitions()
        subscribeToPlaybackTimeForScrobbling()
        subscribeToRouteVolume()
        subscribeToAirPlayRoute()
        nowPlayingUpdater = NowPlayingUpdater(controller: self)
        if enableMediaKeyMonitor {
            mediaKeyMonitor = MediaKeyMonitor { [weak self] command in
                self?.performMediaCommand(command)
            }
        }
    }

    func play(track: Track, in tracks: [Track] = []) {
        startPlayback(track: track, in: tracks, shouldIncrementPlayCount: true)
    }

    private func startPlayback(track: Track, in tracks: [Track] = [], shouldIncrementPlayCount: Bool) {
        playbackError = nil
        unavailableTrackForPlayback = nil
        playbackFolderUnavailable = false

        let currentTrackRecord = refreshedTrack(for: track) ?? track
        guard let url = URL(string: currentTrackRecord.fileURL) else {
            playbackError = "This track's file is unavailable."
            return
        }
        guard currentTrackRecord.isAvailable, fileExists(url) else {
            beginFileRecovery(
                track: currentTrackRecord,
                tracks: tracks,
                shouldIncrementPlayCount: shouldIncrementPlayCount
            )
            return
        }

        let requestedQueue = refreshedQueue(tracks.isEmpty ? [currentTrackRecord] : tracks)
        if isShuffled, !requestedQueue.hasSameTrackOrder(as: queue) {
            unshuffledQueue = requestedQueue
            queue = shuffledQueue(from: requestedQueue, keeping: currentTrackRecord)
        } else {
            if !isShuffled {
                unshuffledQueue = nil
            }
            queue = requestedQueue
        }
        currentIndex = queue.firstIndex(where: { $0.hasSameIdentity(as: currentTrackRecord) }) ?? 0
        currentRadioStation = nil
        currentTrack = currentTrackRecord
        let nextTrack = nextTrackAfterCurrent()
        preparedNextTrack = gaplessPlaybackEnabled ? nextTrack : nil
        do {
            try engine.play(url: url, nextURL: preparedNextTrack.flatMap { URL(string: $0.fileURL) })
        } catch {
            playbackError = error.localizedDescription
            isPlaying = false
            return
        }
        let restoredPosition = consumePendingRestorePosition(for: currentTrackRecord)
        if let restoredPosition {
            engine.seek(to: restoredPosition)
        }
        hasStartedPlayback = true
        isPlaying = true
        lastFMScrobbler?.trackDidStart(currentTrackRecord, position: engine.currentTime)
        persistSession(positionOverride: restoredPosition)
        if shouldIncrementPlayCount {
            incrementPlayCount(for: track)
            UsageAnalytics.logPlaybackStarted(queueSize: queue.count, shuffled: isShuffled)
        }
    }

    func playRadio(station: RadioStation, streamURL: URL) {
        playbackError = nil
        unavailableTrackForPlayback = nil
        playbackFolderUnavailable = false
        pendingFileRecovery = nil
        isRecoveringUnavailableFile = false

        do {
            try engine.play(url: streamURL, nextURL: nil)
        } catch {
            playbackError = error.localizedDescription
            isPlaying = false
            return
        }

        lastFMScrobbler?.playbackDidStop()
        queue = []
        unshuffledQueue = nil
        currentIndex = 0
        currentTrack = nil
        currentRadioStation = station
        preparedNextTrack = nil
        pendingRestorePosition = nil
        hasStartedPlayback = true
        isPlaying = true
    }

    func playOrToggle(track: Track, in tracks: [Track] = []) {
        guard currentTrack?.hasSameIdentity(as: track) == true else {
            play(track: track, in: tracks)
            return
        }

        switch engine.state {
        case .playing, .paused, .loading:
            togglePlayPause()
        default:
            play(track: track, in: tracks)
        }
    }

    func seek(to time: TimeInterval) {
        engine.seek(to: time)
        if currentTrack != nil {
            lastFMScrobbler?.playbackDidSeek(to: time)
        }
    }

    func setVolume(_ volume: Float) {
        let clampedVolume = max(0, min(1, volume))
        switch volumeMode {
        case .playerVolume:
            playerVolume = clampedVolume
            self.volume = clampedVolume
            engine.setVolume(clampedVolume)
        case .routeVolume:
            if routeVolumeController.setVolume(clampedVolume) {
                self.volume = clampedVolume
            }
        case .unavailableRouteVolume:
            break
        }
    }

    func skipNext() {
        guard !queue.isEmpty else { return }
        if let nextIndex = nextAvailableIndex(after: currentIndex, wrapping: repeatMode == .all) {
            play(track: queue[nextIndex], in: queue)
        }
    }

    func skipPrevious() {
        if engine.currentTime > 3 { engine.seek(to: 0); return }
        skipToPreviousTrack()
    }

    func skipToPreviousTrack() {
        guard let previousIndex = previousAvailableIndex(before: currentIndex) else {
            engine.seek(to: 0)
            return
        }
        play(track: queue[previousIndex], in: queue)
    }

    func performMediaCommand(_ command: MediaKeyCommand) {
        guard shouldAcceptMediaCommand(command) else { return }

        switch command {
        case .play:
            resumePlayback()
        case .pause:
            pausePlayback()
        case .playPause:
            togglePlayPause()
        case .next:
            skipNext()
        case .previous:
            skipToPreviousTrack()
        }
    }

    func togglePlayPause() {
        switch engine.state {
        case .playing, .loading:
            pausePlayback()
        case .paused:
            resumePlayback()
        default:
            if let currentTrack {
                play(track: currentTrack, in: queue.isEmpty ? [currentTrack] : queue)
            }
        }
    }

    func dismissPlaybackError() {
        playbackError = nil
        unavailableTrackForPlayback = nil
        playbackFolderUnavailable = false
    }

    /// Completes the single reconciliation attempt requested by playback. AppState
    /// calls this after its queued scan has either refreshed the track or established
    /// that the containing folder cannot currently be read.
    func completeUnavailableFileRecovery(folderUnavailable: Bool) {
        guard let pending = pendingFileRecovery else { return }
        pendingFileRecovery = nil
        isRecoveringUnavailableFile = false

        if !folderUnavailable,
           let refreshed = refreshedTrack(for: pending.track),
           refreshed.isAvailable,
           let url = URL(string: refreshed.fileURL),
           fileExists(url) {
            startPlayback(
                track: refreshed,
                in: pending.tracks,
                shouldIncrementPlayCount: pending.shouldIncrementPlayCount
            )
            return
        }

        let unresolvedTrack = refreshedTrack(for: pending.track) ?? pending.track
        unavailableTrackForPlayback = unresolvedTrack
        playbackFolderUnavailable = folderUnavailable
        if folderUnavailable {
            playbackError = "This track can’t be played because its music folder is unavailable. Reconnect the folder and try again."
        } else {
            playbackError = "Moonlight couldn’t find “\(unresolvedTrack.displayTitle)”. It may have been renamed, moved, or deleted."
        }
    }

    private func beginFileRecovery(
        track: Track,
        tracks: [Track],
        shouldIncrementPlayCount: Bool
    ) {
        guard !isRecoveringUnavailableFile else { return }
        guard let unavailableFileRecoveryHandler else {
            unavailableTrackForPlayback = track
            playbackError = "This track's file is unavailable."
            return
        }

        pendingFileRecovery = PendingFileRecovery(
            track: track,
            tracks: tracks.isEmpty ? [track] : tracks,
            shouldIncrementPlayCount: shouldIncrementPlayCount
        )
        isRecoveringUnavailableFile = true
        unavailableFileRecoveryHandler(track)
    }

    private func refreshedTrack(for track: Track) -> Track? {
        guard let id = track.dbId else { return track }
        return try? db.read { db in try Track.fetchOne(db, key: id) }
    }

    private func refreshedQueue(_ tracks: [Track]) -> [Track] {
        tracks.map { refreshedTrack(for: $0) ?? $0 }
    }

    private func shouldAcceptMediaCommand(_ command: MediaKeyCommand) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        defer { lastMediaCommand = (command, now) }

        guard let lastMediaCommand else { return true }
        guard now - lastMediaCommand.time < duplicateMediaCommandInterval else { return true }

        if command.isPlayPauseRelated && lastMediaCommand.command.isPlayPauseRelated {
            return false
        }

        return command != lastMediaCommand.command
    }

    func pausePlayback() {
        guard engine.state == .playing || engine.state == .loading else { return }
        if currentTrack != nil {
            lastFMScrobbler?.playbackDidPause(position: engine.currentTime)
        }
        isPlaying = false
        engine.pause()
        persistSession()
    }

    func resumePlayback() {
        switch engine.state {
        case .paused:
            isPlaying = true
            engine.resume()
            if currentTrack != nil {
                lastFMScrobbler?.playbackDidResume(position: engine.currentTime)
            }
        default:
            if let currentTrack {
                play(track: currentTrack, in: queue.isEmpty ? [currentTrack] : queue)
            }
        }
    }

    func playNext(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            queue = tracks
        } else {
            queue.insert(contentsOf: tracks, at: min(currentIndex + 1, queue.count))
        }
        insertIntoUnshuffledQueueNext(tracks)
        configurePreparedNextItem()
    }

    func playLater(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            queue = tracks
        } else {
            queue.append(contentsOf: tracks)
        }
        unshuffledQueue?.append(contentsOf: tracks)
        configurePreparedNextItem()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard !queue.isEmpty else {
            configurePreparedNextItem()
            return
        }

        if isShuffled {
            unshuffledQueue = queue
            queue = shuffledQueue(from: queue, keeping: currentTrack)
        } else {
            restoreUnshuffledQueue()
        }
        configurePreparedNextItem()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    private func shuffledQueue(from tracks: [Track], keeping current: Track?) -> [Track] {
        var shuffled = tracks
        if let current,
           let idx = shuffled.firstIndex(where: { $0.hasSameIdentity(as: current) }) {
            shuffled.remove(at: idx)
            shuffled.shuffle()
            shuffled.insert(current, at: 0)
            currentIndex = 0
        } else {
            shuffled.shuffle()
        }
        return shuffled
    }

    private func restoreUnshuffledQueue() {
        guard let restoredQueue = unshuffledQueue else { return }
        queue = restoredQueue
        if let currentTrack,
           let restoredIndex = queue.firstIndex(where: { $0.hasSameIdentity(as: currentTrack) }) {
            currentIndex = restoredIndex
        } else {
            currentIndex = min(currentIndex, max(queue.count - 1, 0))
        }
        unshuffledQueue = nil
    }

    private func insertIntoUnshuffledQueueNext(_ tracks: [Track]) {
        guard !tracks.isEmpty, var restoredQueue = unshuffledQueue else { return }
        let insertIndex: Int
        if let currentTrack,
           let restoredCurrentIndex = restoredQueue.firstIndex(where: { $0.hasSameIdentity(as: currentTrack) }) {
            insertIndex = min(restoredCurrentIndex + 1, restoredQueue.count)
        } else {
            insertIndex = min(currentIndex + 1, restoredQueue.count)
        }
        restoredQueue.insert(contentsOf: tracks, at: insertIndex)
        unshuffledQueue = restoredQueue
    }

    // MARK: - Gapless playback

    private static func loadGaplessPlaybackSetting(db: DatabaseManager) -> Bool {
        let value = try? db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'gapless_playback_enabled'")
        }
        guard let value else { return true }
        return value != "false"
    }

    private func persistGaplessPlaybackSetting() {
        try? db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('gapless_playback_enabled', ?)",
                arguments: [gaplessPlaybackEnabled ? "true" : "false"]
            )
        }
    }

    private func nextTrackAfterCurrent() -> Track? {
        guard !queue.isEmpty, repeatMode != .one else { return nil }
        return nextAvailableIndex(after: currentIndex, wrapping: repeatMode == .all).map { queue[$0] }
    }

    private func nextAvailableIndex(after index: Int, wrapping: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }
        let later = ((index + 1)..<queue.count).first { queue[$0].isAvailable }
        if let later { return later }
        guard wrapping else { return nil }
        return (0..<min(index + 1, queue.count)).first { queue[$0].isAvailable }
    }

    private func previousAvailableIndex(before index: Int) -> Int? {
        guard index > 0 else { return nil }
        return stride(from: index - 1, through: 0, by: -1).first { queue[$0].isAvailable }
    }

    private func configurePreparedNextItem() {
        guard gaplessPlaybackEnabled, currentTrack != nil,
              let nextTrack = nextTrackAfterCurrent(),
              let url = URL(string: nextTrack.fileURL) else {
            preparedNextTrack = nil
            engine.prepareNext(url: nil)
            return
        }

        preparedNextTrack = nextTrack
        engine.prepareNext(url: url)
    }

    private func handlePreparedItemTransition() {
        guard gaplessPlaybackEnabled, let nextTrack = preparedNextTrack else {
            handleTrackFinished()
            return
        }

        currentTrack = nextTrack
        currentIndex = queue.firstIndex(where: { $0.hasSameIdentity(as: nextTrack) }) ?? currentIndex
        isPlaying = true
        lastFMScrobbler?.trackDidStart(nextTrack, position: engine.currentTime)
        persistSession()
        incrementPlayCount(for: nextTrack)
        configurePreparedNextItem()
    }

    // MARK: - Play count

    private func incrementPlayCount(for track: Track) {
        guard let trackId = track.dbId else { return }
        try? db.write { db in
            let now = Date()
            guard let syncID = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: trackId, in: db) else {
                try db.execute(sql: "UPDATE tracks SET play_count = play_count + 1, last_played_at = ? WHERE id = ?", arguments: [now, trackId])
                return
            }
            let deviceID = try SyncDeviceIdentity.id(in: db)
            try db.execute(sql: "INSERT INTO play_events (event_id, track_sync_id, played_at, played_ms) VALUES (?, ?, ?, 0)", arguments: [UUID().uuidString.uppercased(), syncID, now])
            try db.execute(sql: """
                INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(track_sync_id, device_id) DO UPDATE SET
                    count = play_counters.count + 1,
                    last_played_at = excluded.last_played_at
            """, arguments: [syncID, deviceID, now])
            let globalCount = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(count), 0) FROM play_counters WHERE track_sync_id = ?", arguments: [syncID]) ?? 0
            let globalLast = try Date.fetchOne(db, sql: "SELECT MAX(last_played_at) FROM play_counters WHERE track_sync_id = ?", arguments: [syncID])
            try db.execute(sql: "UPDATE tracks SET play_count = ?, last_played_at = ? WHERE track_sync_id = ?", arguments: [globalCount, globalLast, syncID])
            _ = try SyncEligibility.promote(syncID, in: db)
            try IdentityRepository.refreshComponent(for: syncID, in: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(syncID)", in: db, delivery: .playbackBatch)
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(syncID)_\(deviceID)", in: db, delivery: .playbackBatch)
        }
    }

    // MARK: - Session persistence

    private func persistSession(positionOverride: TimeInterval? = nil) {
        guard let track = currentTrack else { return }
        guard let trackId = track.dbId else { return }
        let position = positionOverride ?? engine.currentTime
        try? db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('last_track_id', ?)", arguments: [String(trackId)])
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('last_position', ?)", arguments: [String(position)])
        }
    }

    private func restoreLastSession() {
        let settings = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM settings WHERE key IN ('last_track_id', 'last_track_url', 'last_position')")
        }) ?? []

        var settingsMap: [String: String] = [:]
        for row in settings {
            if let key = row["key"] as? String, let value = row["value"] as? String {
                settingsMap[key] = value
            }
        }

        let track = try? db.read { db -> Track? in
            if let idString = settingsMap["last_track_id"], let trackId = Int64(idString) {
                return try Track.fetchOne(db, key: trackId)
            }
            if let fileURL = settingsMap["last_track_url"] {
                return try Track.filter(sql: "file_url = ?", arguments: [fileURL]).fetchOne(db)
            }
            return nil
        }

        guard let track, track.isAvailable, let trackId = track.dbId else { return }
        queue = restoreQueue(containing: track)
        currentIndex = queue.firstIndex(where: { $0.hasSameIdentity(as: track) }) ?? 0
        currentTrack = track

        if let posStr = settingsMap["last_position"], let pos = Double(posStr), pos > 0 {
            pendingRestorePosition = (trackId, pos)
        }
    }

    private func consumePendingRestorePosition(for track: Track) -> TimeInterval? {
        guard let pendingRestorePosition, let trackId = track.dbId,
              pendingRestorePosition.trackId == trackId else {
            return nil
        }

        self.pendingRestorePosition = nil
        return pendingRestorePosition.position
    }

    private func restoreQueue(containing track: Track) -> [Track] {
        guard let albumId = track.albumId else { return [track] }

        let albumTracks = (try? db.read { db in
            try Track.filter(sql: "album_id = ?", arguments: [albumId])
                .order(Column("disc_number"), Column("track_number"), Column("title"))
                .fetchAll(db)
        }) ?? []

        guard albumTracks.contains(where: { $0.hasSameIdentity(as: track) }) else { return [track] }
        return albumTracks
    }

    func refreshPersistedTracks() {
        let trackIds = Set((queue + (unshuffledQueue ?? []) + [currentTrack].compactMap { $0 }).compactMap(\.dbId))
        guard !trackIds.isEmpty else { return }
        let placeholders = trackIds.map { _ in "?" }.joined(separator: ",")
        let refreshed = (try? db.read { db in
            try Track.fetchAll(
                db,
                sql: "SELECT * FROM tracks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(trackIds))
            )
        }) ?? []
        let byId = Dictionary(uniqueKeysWithValues: refreshed.compactMap { track in
            track.dbId.map { ($0, track) }
        })

        queue = queue.compactMap { track in track.dbId.flatMap { byId[$0] } }
        unshuffledQueue = unshuffledQueue?.compactMap { track in track.dbId.flatMap { byId[$0] } }
        if let currentId = currentTrack?.dbId {
            currentTrack = byId[currentId]
            currentIndex = queue.firstIndex { $0.dbId == currentId } ?? min(currentIndex, max(queue.count - 1, 0))
        }
        configurePreparedNextItem()
    }

    // MARK: - Auto-advance

    private func subscribeToEngineState() {
        engine.statePublisher
            // PlaybackController starts with `isPlaying == false`; consuming the
            // engine's replayed initial `.stopped` value can otherwise race a
            // newly-started track and be mistaken for an end-of-track event.
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.isPlaying = (state == .playing)
                if case let .error(message) = state {
                    self.playbackError = message
                }
                if state == .stopped, self.currentTrack != nil, self.hasStartedPlayback {
                    self.handleTrackFinished()
                }
            }
            .store(in: &cancellables)
    }

    private func subscribeToEngineTransitions() {
        engine.itemTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handlePreparedItemTransition()
            }
            .store(in: &cancellables)
    }

    private func subscribeToPlaybackTimeForScrobbling() {
        engine.timePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                guard let self, self.currentTrack != nil else { return }
                self.lastFMScrobbler?.playbackPositionDidChange(position)
            }
            .store(in: &cancellables)
    }

    private func subscribeToRouteVolume() {
        routeVolumeController.volumePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                guard let self, self.volumeMode == .routeVolume else { return }
                self.volume = max(0, min(1, volume))
            }
            .store(in: &cancellables)

        routeVolumeController.routeChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.configureVolumeMode()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .moonlightAirPlayRoutePickerDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                RouteVolumeDiagnostics.log("AirPlay route picker did end; rechecking volume mode")
                self?.configureVolumeMode()
            }
            .store(in: &cancellables)
    }

    private func subscribeToAirPlayRoute() {
        guard let routeProvider = engine as? AirPlayRouteProviding else { return }
        externalPlaybackActive = routeProvider.externalPlaybackActive
        audioOutputDeviceUniqueID = routeProvider.audioOutputDeviceUniqueID
        configureVolumeMode()

        routeProvider.externalPlaybackActivePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.externalPlaybackActive = isActive
                self?.configureVolumeMode()
            }
            .store(in: &cancellables)

        routeProvider.audioOutputDeviceUniqueIDPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceUID in
                self?.audioOutputDeviceUniqueID = deviceUID
                self?.configureVolumeMode()
            }
            .store(in: &cancellables)
    }

    private func configureVolumeMode() {
        RouteVolumeDiagnostics.log("configureVolumeMode externalPlaybackActive=\(externalPlaybackActive) audioOutputDeviceUniqueID=\(audioOutputDeviceUniqueID ?? "nil") currentMode=\(volumeMode)")
        if let audioOutputDeviceUniqueID,
           routeVolumeController.activate(deviceUID: audioOutputDeviceUniqueID) {
            volumeMode = .routeVolume
            if let routeVolume = routeVolumeController.currentVolume {
                volume = max(0, min(1, routeVolume))
            }
            RouteVolumeDiagnostics.log("volumeMode=routeVolume displayedVolume=\(volume)")
            return
        }

        if routeVolumeController.activateRoute() {
            volumeMode = .routeVolume
            if let routeVolume = routeVolumeController.currentVolume {
                volume = max(0, min(1, routeVolume))
            }
            RouteVolumeDiagnostics.log("volumeMode=routeVolume outputContext displayedVolume=\(volume)")
            return
        }

        guard externalPlaybackActive else {
            routeVolumeController.deactivate()
            volumeMode = .playerVolume
            volume = playerVolume
            engine.setVolume(playerVolume)
            RouteVolumeDiagnostics.log("volumeMode=playerVolume displayedVolume=\(volume)")
            return
        }

        routeVolumeController.deactivate()
        volumeMode = .unavailableRouteVolume
        RouteVolumeDiagnostics.log("volumeMode=unavailableRouteVolume displayedVolume=\(volume)")
    }

    private func handleTrackFinished() {
        switch repeatMode {
        case .one:
            if let track = currentTrack { play(track: track, in: queue) }
        case .all, .off:
            skipNext()
        }
    }
}

private extension Array where Element == Track {
    func hasSameTrackOrder(as other: [Track]) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).allSatisfy { $0.hasSameIdentity(as: $1) }
    }
}
