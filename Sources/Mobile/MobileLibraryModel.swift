// MobileLibraryModel.swift
//
// The central source of library data for the iPhone and iPad app. It loads and searches tracks,
// manages playlists, favorites and ratings, deletes songs, reports storage used and records plays.
// It also starts iCloud syncing of library information and takes periodic safety snapshots of that
// information, connecting the screens to the database.

import Foundation
import GRDB
import SwiftUI

enum MobileLibraryQuery {
    static func fetchPage(limit: Int, onDeviceOnly: Bool = false, in db: Database) throws -> [Track] {
        let availability = onDeviceOnly ? "availability_status = 'available'" : "availability_status != 'deleted'"
        return try Track.fetchAll(db, sql: """
            SELECT * FROM tracks
            WHERE \(availability) AND \(LibraryTrackQuery.catalogPredicate())
            ORDER BY title COLLATE NOCASE, id
            LIMIT ?
        """, arguments: [max(1, limit)])
    }

    static func search(_ text: String, limit: Int, onDeviceOnly: Bool = false, in db: Database) throws -> [Track] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let expression = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
        let availability = onDeviceOnly ? "tracks.availability_status = 'available'" : "tracks.availability_status != 'deleted'"
        return try Track.fetchAll(db, sql: """
            SELECT tracks.*
            FROM tracks_fts
            JOIN tracks ON tracks.id = tracks_fts.rowid
            WHERE tracks_fts MATCH ? AND \(availability) AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
            ORDER BY rank
            LIMIT ?
        """, arguments: [expression, max(1, limit)])
    }
}

enum MobilePlaybackPersistence {
    static func recordPlay(
        localTrackID: Int64,
        in database: DatabaseManager,
        writerID: (Database) throws -> String = SyncDeviceIdentity.id
    ) throws {
        try database.write { db in
            guard let id = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: localTrackID, in: db) else { return }
            let deviceID = try writerID(db)
            let now = Date()
            try db.execute(sql: "INSERT INTO play_events (event_id, track_sync_id, played_at, played_ms) VALUES (?, ?, ?, 0)", arguments: [UUID().uuidString.uppercased(), id, now])
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, ?, 1, ?) ON CONFLICT(track_sync_id, device_id) DO UPDATE SET count=count+1, last_played_at=excluded.last_played_at", arguments: [id, deviceID, now])
            _ = try SyncEligibility.promote(id, in: db)
            try IdentityRepository.refreshComponent(for: id, in: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(id)", in: db, delivery: .playbackBatch)
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(id)_\(deviceID)", in: db, delivery: .playbackBatch)
        }
    }
}

enum MobileLibraryMaintenance {
    static func revalidateAvailableFiles(in database: DatabaseManager) throws -> Int {
        let rows: [(Int64, String)] = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, file_url FROM tracks WHERE availability_status='available'").map {
                ($0["id"] as Int64, $0["file_url"] as String)
            }
        }
        let missing = rows.filter { ContainerPathResolver.existingURL(forStoredFileURL: $0.1) == nil }.map(\.0)
        guard !missing.isEmpty else { return 0 }
        try database.write { db in
            for id in missing {
                try db.execute(sql: "UPDATE tracks SET availability_status='unavailable', missing_since=COALESCE(missing_since, ?) WHERE id=?", arguments: [Date(), id])
            }
        }
        return missing.count
    }

    static func storageUsage(in database: DatabaseManager) throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(physical_files.file_size), 0)
                FROM physical_files
                JOIN tracks ON tracks.physical_file_id = physical_files.physical_file_id
                WHERE tracks.availability_status = 'available'
            """) ?? 0
        }
    }

    static func delete(track: Track, in database: DatabaseManager) throws {
        guard let trackID = track.dbId else { return }
        let fileURL = ContainerPathResolver.existingURL(forStoredFileURL: track.fileURL)
        try database.write { db in
            let memberships = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_tracks WHERE track_id=? AND deleted_at IS NULL", arguments: [trackID])
            let grouped = Dictionary(grouping: memberships) { membershipID in
                (try? Int64.fetchOne(db, sql: "SELECT playlist_id FROM playlist_tracks WHERE id=?", arguments: [membershipID])) ?? -1
            }
            for (playlistID, entryIDs) in grouped where playlistID >= 0 {
                try PlaylistEntry.softDelete(entryIDs: entryIDs, inPlaylist: playlistID, in: db)
            }
            try db.execute(sql: "DELETE FROM physical_files WHERE physical_file_id=?", arguments: [track.physicalFileId])
            try db.execute(sql: """
                UPDATE tracks
                SET availability_status='deleted', missing_since=?, file_size=NULL,
                    file_url='moonlight-deleted://' || physical_file_id
                WHERE id=?
            """, arguments: [Date(), trackID])
        }
        if let fileURL { try FileManager.default.removeItem(at: fileURL) }
    }
}

@MainActor
final class MobileLibraryModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var searchResults: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var hasMoreTracks = false
    @Published private(set) var storageUsageBytes: Int64 = 0
    @Published var showOnDeviceOnly = false {
        didSet { restartTracksObservation(); search(lastSearchText) }
    }
    @Published var importProgress: String?
    @Published var presentedError: String?

    let database: DatabaseManager
    let cloudSync: CloudKitSyncCoordinator
    let playback: MobilePlaybackController

    private let importService: MobileImportService
    private var tracksObservation: AnyDatabaseCancellable?
    private var playlistsObservation: AnyDatabaseCancellable?
    private var pageLimit = 250
    private var searchTask: Task<Void, Never>?
    private var lastSearchText = ""

    init(database: DatabaseManager) {
        self.database = database
        self.cloudSync = CloudKitSyncCoordinator(manager: database)
        self.playback = MobilePlaybackController()
        self.importService = MobileImportService(database: database)
        playback.didBeginTrack = { [weak self] track in self?.recordPlay(track) }
        playback.didFailTrack = { [weak self] track, message in self?.handlePlaybackFailure(track, message: message) }
        playback.artworkDataProvider = { [weak database] track in
            guard let database, let artworkID = track.artworkId else { return nil }
            return (try? database.read { try Data.fetchOne($0, sql: "SELECT data_large FROM artwork WHERE id=?", arguments: [artworkID]) }) ?? nil
        }
        observeLibrary()
        refreshStorageUsage()
        Task {
            await cloudSync.start()
            do { _ = try MetadataSnapshotStore.createIfDue(from: database) }
            catch { presentedError = "Metadata protection failed: \(error.localizedDescription)" }
        }
    }

    deinit {
        tracksObservation?.cancel()
        playlistsObservation?.cancel()
        searchTask?.cancel()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            let database = self.database
            Task {
                do {
                    _ = try await MobileBackgroundWork.runThrowing { try MobileLibraryMaintenance.revalidateAvailableFiles(in: database) }
                    refreshStorageUsage()
                } catch { presentedError = error.localizedDescription }
            }
        } else {
            Task { await cloudSync.flushForLifecycleTransition() }
        }
    }

    func importFiles(_ urls: [URL]) {
        let importService = self.importService
        Task {
            importProgress = "Importing 1 of \(urls.count)…"
            let failures = await MobileBackgroundWork.run {
                await importService.importFiles(urls) { progress in
                    Task { @MainActor [weak self] in
                        self?.importProgress = "Importing \(min(progress.completed + 1, progress.total)) of \(progress.total)…"
                    }
                }
            }
            importProgress = nil
            if !failures.isEmpty { presentedError = failures.joined(separator: "\n") }
            refreshStorageUsage()
        }
    }

    func loadMoreTracks() {
        pageLimit += 250
        restartTracksObservation()
    }

    func search(_ text: String) {
        lastSearchText = text
        searchTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        let database = self.database
        let onDeviceOnly = showOnDeviceOnly
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let results = try await MobileBackgroundWork.runThrowing {
                    try database.read { try MobileLibraryQuery.search(text, limit: 250, onDeviceOnly: onDeviceOnly, in: $0) }
                }
                guard !Task.isCancelled, text == lastSearchText else { return }
                searchResults = results
            } catch { presentedError = error.localizedDescription }
        }
    }

    func delete(_ track: Track) {
        do {
            try MobileLibraryMaintenance.delete(track: track, in: database)
            refreshStorageUsage()
        } catch { presentedError = error.localizedDescription }
    }

    /// Playback could not open the file behind a row the library still advertises
    /// as available. Flip it to unavailable so the UI stops offering it, rather
    /// than leaving an enabled play button that silently does nothing.
    private func handlePlaybackFailure(_ track: Track, message: String) {
        presentedError = message
        guard let localID = track.dbId else { return }
        try? database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET availability_status='unavailable', missing_since=COALESCE(missing_since, ?) WHERE id=?",
                arguments: [Date(), localID]
            )
        }
    }

    func setFavorite(_ value: Bool, track: Track) {
        guard let localID = track.dbId else { return }
        do {
            try database.write { db in
                guard let id = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: localID, in: db) else { return }
                let revision = SyncRevision.make(writerID: try SyncDeviceIdentity.id(in: db)).rawValue
                try db.execute(sql: "UPDATE tracks SET is_favorite=?, favorite_rev=? WHERE track_sync_id=?", arguments: [value, revision, id])
                try db.execute(sql: "INSERT INTO track_annotations (track_sync_id, favorite, favorite_rev) VALUES (?, ?, ?) ON CONFLICT(track_sync_id) DO UPDATE SET favorite=excluded.favorite, favorite_rev=excluded.favorite_rev", arguments: [id, value, revision])
                _ = try SyncEligibility.promote(id, in: db)
            try IdentityRepository.refreshComponent(for: id, in: db)
                try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(id)", in: db)
            }
        } catch { presentedError = error.localizedDescription }
    }

    func setRating(_ value: Int?, track: Track) {
        guard let localID = track.dbId else { return }
        do {
            try database.write { db in
                guard let id = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: localID, in: db) else { return }
                let revision = SyncRevision.make(writerID: try SyncDeviceIdentity.id(in: db)).rawValue
                try db.execute(sql: "UPDATE tracks SET rating=?, rating_rev=? WHERE track_sync_id=?", arguments: [value, revision, id])
                try db.execute(sql: "INSERT INTO track_annotations (track_sync_id, rating, rating_rev) VALUES (?, ?, ?) ON CONFLICT(track_sync_id) DO UPDATE SET rating=excluded.rating, rating_rev=excluded.rating_rev", arguments: [id, value, revision])
                _ = try SyncEligibility.promote(id, in: db)
            try IdentityRepository.refreshComponent(for: id, in: db)
                try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(id)", in: db)
            }
        } catch { presentedError = error.localizedDescription }
    }

    func createPlaylist(named name: String) {
        let trimmed = name.singleLineText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try database.write { db in
                let now = Date()
                let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
                var playlist = Playlist(name: trimmed, dateCreated: now, dateModified: now, nameRev: revision, sortModeRev: revision)
                try playlist.insert(db)
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(playlist.playlistSyncId)", in: db)
            }
        } catch { presentedError = error.localizedDescription }
    }

    func add(_ track: Track, to playlist: Playlist) {
        guard let trackID = track.dbId, let playlistID = playlist.id else { return }
        do {
            try database.write { db in
                let position = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id=? AND deleted_at IS NULL", arguments: [playlistID]) ?? 0
                let entryID = UUID().uuidString.uppercased()
                let revision = SyncRevision.make(writerID: try SyncDeviceIdentity.id(in: db)).rawValue
                let lastKey = try String.fetchOne(db, sql: "SELECT ordering_key FROM playlist_tracks WHERE playlist_id=? AND deleted_at IS NULL ORDER BY ordering_key DESC LIMIT 1", arguments: [playlistID])
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [playlistID, trackID, position, entryID, FractionalOrderingKey.between(lastKey, nil), revision, Date()])
                try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entryID)", in: db)
                _ = try SyncEligibility.promote(track.trackSyncId, in: db)
                try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(track.trackSyncId)", in: db)
            }
        } catch { presentedError = error.localizedDescription }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        guard let id = playlist.id else { return [] }
        return (try? database.read { db in
            try Track.fetchAll(db, sql: "SELECT t.* FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE pt.playlist_id=? AND pt.deleted_at IS NULL ORDER BY pt.ordering_key, pt.position", arguments: [id])
        }) ?? []
    }

    func entries(in playlist: Playlist) -> [PlaylistEntry] {
        guard let id = playlist.id else { return [] }
        return (try? database.read { try PlaylistEntry.fetchVisible(in: id, from: $0) }) ?? []
    }

    func remove(entry: PlaylistEntry, from playlist: Playlist) {
        guard let playlistID = playlist.id else { return }
        do {
            try database.write { try PlaylistEntry.softDelete(entryIDs: [entry.id], inPlaylist: playlistID, in: $0) }
        } catch { presentedError = error.localizedDescription }
    }

    func metadataSnapshots() -> [MetadataArchiveSummary] {
        (try? MetadataSnapshotStore.snapshots()) ?? []
    }

    func protectMetadataNow() {
        do {
            _ = try MetadataSnapshotStore.createRecoveryPoint(from: database, label: "mobile-manual")
            cloudSync.status.lastProtected = Date()
            cloudSync.status.protectionProblem = nil
        } catch { presentedError = error.localizedDescription }
    }

    func restore(_ snapshot: MetadataArchiveSummary) {
        do {
            try MetadataArchive.restore(from: snapshot.url, to: database)
            Task { [cloudSync] in await cloudSync.noteSynchronizedStateReplacement() }
        }
        catch { presentedError = error.localizedDescription }
    }

    private func observeLibrary() {
        restartTracksObservation()

        playlistsObservation = ValueObservation.tracking { db in
            try Playlist.filter(Column("deleted_at") == nil).order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }.start(in: database.dbQueue, scheduling: .async(onQueue: .main), onError: { [weak self] error in
            self?.presentedError = error.localizedDescription
        }, onChange: { [weak self] value in self?.playlists = value })
    }

    private func restartTracksObservation() {
        tracksObservation?.cancel()
        let requestedLimit = pageLimit + 1
        let onDeviceOnly = showOnDeviceOnly
        tracksObservation = ValueObservation.tracking { db in
            try MobileLibraryQuery.fetchPage(limit: requestedLimit, onDeviceOnly: onDeviceOnly, in: db)
        }.start(in: database.dbQueue, scheduling: .async(onQueue: .main), onError: { [weak self] error in
            self?.presentedError = error.localizedDescription
        }, onChange: { [weak self] value in
            guard let self else { return }
            hasMoreTracks = value.count > pageLimit
            tracks = Array(value.prefix(pageLimit))
        })
    }

    private func recordPlay(_ track: Track) {
        guard let localID = track.dbId else { return }
        do {
            try MobilePlaybackPersistence.recordPlay(localTrackID: localID, in: database)
        } catch { presentedError = error.localizedDescription }
    }

    private func refreshStorageUsage() {
        storageUsageBytes = (try? MobileLibraryMaintenance.storageUsage(in: database)) ?? 0
    }

}
