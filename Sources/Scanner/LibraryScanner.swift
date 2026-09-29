// LibraryScanner.swift
//
// Reads through a music folder on the Mac and brings the library up to date. It finds every audio
// file, reads each one's song details, adds new or changed tracks to the database and marks tracks
// whose files have disappeared. It then rebuilds the album and artist lists and the search index,
// and keeps a record of each scan and any errors.

import Foundation
import GRDB

actor LibraryScanner {
    private let db: DatabaseManager
    private(set) var isScanning = false

    init(db: DatabaseManager) {
        self.db = db
    }

    func scan(
        folderURL: URL,
        folderId: Int64? = nil,
        mode: ScanMode = .incremental,
        trigger: ScanTrigger = .manual,
        onProgress: @escaping @Sendable (ScanSummary) -> Void
    ) async -> ScanSummary? {
        guard !isScanning else { return nil }
        isScanning = true
        defer { isScanning = false }

        let scanJobId = createScanJob(folderId: folderId, mode: mode, trigger: trigger)
        var summary = ScanSummary(
            jobId: scanJobId,
            mode: mode,
            trigger: trigger,
            totalFiles: 0,
            processedFiles: 0,
            skippedFiles: 0,
            changedFiles: 0,
            removedFiles: 0,
            missingFiles: 0,
            relinkedFiles: 0,
            errorCount: 0,
            failureMessage: nil
        )

        guard folderURL.startAccessingSecurityScopedResource() else {
            let message = "Could not access security-scoped folder"
            summary.failureMessage = message
            markScanFailed(jobId: scanJobId, message: message, summary: summary)
            return summary
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        // A process kill cannot run the tagger's defer cleanup. Launch scans
        // remove only UUID-shaped Moonlight rewrite temps old enough that no live
        // tagging operation can still own them.
        _ = try? PortableIdentityTagger.sweepOrphanedTemporaryFiles(
            in: folderURL,
            olderThan: 24 * 60 * 60
        )

        guard let urls = enumerateAudioFiles(in: folderURL) else {
            let message = "Could not completely enumerate library folder"
            summary.failureMessage = message
            markScanFailed(jobId: scanJobId, message: message, summary: summary)
            return summary
        }
        summary.totalFiles = urls.count
        updateScanTotals(jobId: scanJobId, summary: summary)
        onProgress(summary)

        let localDB = db
        let jobId = scanJobId
        let shouldSkipUnchanged = mode.skipsUnchangedFiles

        let maxConcurrent = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        var inFlight = 0

        await withTaskGroup(of: ScanFileResult.self) { group in
            for url in urls {
                if inFlight >= maxConcurrent {
                    if let result = await group.next() {
                        summary.apply(result)
                        onProgress(summary)
                        inFlight -= 1
                    }
                }

                inFlight += 1
                group.addTask {
                    await Self.scanFile(
                        url: url,
                        db: localDB,
                        folderId: folderId,
                        jobId: jobId,
                        shouldSkipUnchanged: shouldSkipUnchanged
                    )
                }
            }

            for await result in group {
                summary.apply(result)
                onProgress(summary)
            }
        }

        guard !Task.isCancelled else {
            let message = "Scan cancelled"
            summary.failureMessage = message
            markScanFailed(jobId: scanJobId, message: message, summary: summary)
            return summary
        }

        if let folderId, let scanJobId {
            summary.missingFiles = Self.markMissingTracks(
                folderId: folderId,
                excludingScanJobId: scanJobId,
                db: db
            )
        }

        do {
            try db.write { db in
                // CloudKit may have already downloaded annotations before this
                // device sees the corresponding audio file. A scan turns the
                // sync placeholder into an available track, so reapply the
                // durable annotation read model before views are refreshed.
                try Self.materializeSynchronizedAnnotations(db)
                try IdentityRepository.refreshRedirectedComponents(in: db)
                try SyncRecordApplier.materializeResolvablePlaylistEntries(in: db)
                try Self.deriveAlbumsAndArtists(db)
                try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')")
            }
        } catch {
            summary.errorCount += 1
            Self.recordScanError(
                db: db,
                jobId: scanJobId,
                fileURL: folderURL.absoluteString,
                stage: "derived-data",
                category: "database",
                reason: "\(type(of: error)): \(error.localizedDescription)"
            )
        }

        completeScanJob(jobId: scanJobId, summary: summary)
        onProgress(summary)
        return summary
    }

    func rebuildDerivedData() async {
        do {
            try db.write { db in
                try Self.materializeSynchronizedAnnotations(db)
                try IdentityRepository.refreshRedirectedComponents(in: db)
                try SyncRecordApplier.materializeResolvablePlaylistEntries(in: db)
                try Self.deriveAlbumsAndArtists(db)
                try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')")
            }
        } catch {
            print("⚠️ rebuildDerivedData failed: \(error)")
        }
    }

    // MARK: - Scan helpers

    private func createScanJob(folderId: Int64?, mode: ScanMode, trigger: ScanTrigger) -> Int64? {
        try? db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO scan_jobs (folder_id, started_at, status, mode, trigger)
                VALUES (?, ?, 'running', ?, ?)
            """, arguments: [folderId, Date(), mode.rawValue, trigger.rawValue])
            return db.lastInsertedRowID
        }
    }

    private func updateScanTotals(jobId: Int64?, summary: ScanSummary) {
        guard let jobId else { return }
        try? db.write { db in
            try db.execute(sql: """
                UPDATE scan_jobs
                SET total_files = ?
                WHERE id = ?
            """, arguments: [summary.totalFiles, jobId])
        }
    }

    private func markScanFailed(jobId: Int64?, message: String, summary: ScanSummary) {
        guard let jobId else { return }
        try? db.write { db in
            try db.execute(sql: """
                UPDATE scan_jobs
                SET completed_at = ?, status = 'failed', failure_message = ?,
                    files_processed = ?, total_files = ?, skipped_files = ?,
                    changed_files = ?, removed_files = ?, missing_files = ?,
                    relinked_files = ?, error_count = ?
                WHERE id = ?
            """, arguments: [
                Date(),
                message,
                summary.processedFiles,
                summary.totalFiles,
                summary.skippedFiles,
                summary.changedFiles,
                summary.removedFiles,
                summary.missingFiles,
                summary.relinkedFiles,
                summary.errorCount,
                jobId
            ])
        }
    }

    private func completeScanJob(jobId: Int64?, summary: ScanSummary) {
        guard let jobId else { return }
        try? db.write { db in
            let folderId = try Int64.fetchOne(db, sql: "SELECT folder_id FROM scan_jobs WHERE id = ?", arguments: [jobId])
            try db.execute(sql: """
                UPDATE scan_jobs
                SET completed_at = ?, files_processed = ?, total_files = ?,
                    skipped_files = ?, changed_files = ?, removed_files = ?, missing_files = ?,
                    relinked_files = ?, error_count = ?, status = 'completed'
                WHERE id = ?
            """, arguments: [
                Date(),
                summary.processedFiles,
                summary.totalFiles,
                summary.skippedFiles,
                summary.changedFiles,
                summary.removedFiles,
                summary.missingFiles,
                summary.relinkedFiles,
                summary.errorCount,
                jobId
            ])
            try pruneScanHistory(folderId: folderId, db: db)
        }
    }

    private func pruneScanHistory(folderId: Int64?, db: Database) throws {
        try db.execute(sql: """
            DELETE FROM scan_jobs
            WHERE folder_id IS ?
              AND status != 'running'
              AND id NOT IN (
                  SELECT id FROM scan_jobs
                  WHERE folder_id IS ?
                  ORDER BY started_at DESC, id DESC
                  LIMIT 100
              )
        """, arguments: [folderId, folderId])
    }

    static func recordScanError(db: DatabaseManager, jobId: Int64?, fileURL: String, stage: String, category: String, reason: String) {
        guard let jobId else { return }
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO scan_errors (scan_job_id, file_url, stable_file_url, stage, category, created_at, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [jobId, fileURL, fileURL, stage, category, Date(), reason])
        }
    }

    private static func scanFile(
        url: URL,
        db: DatabaseManager,
        folderId: Int64?,
        jobId: Int64?,
        shouldSkipUnchanged: Bool
    ) async -> ScanFileResult {
        let embeddedTrackSyncID = PortableIdentityTag.read(from: url)
        let attrs = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .documentIdentifierKey,
            .volumeUUIDStringKey
        ])
        let identity = FileIdentity(resourceValues: attrs)
        let observation = observeFile(
            url: url,
            attrs: attrs,
            identity: identity,
            folderId: folderId,
            jobId: jobId,
            db: db
        )

        if shouldSkipUnchanged,
           isUnchanged(url: url, attrs: attrs, embeddedTrackSyncID: embeddedTrackSyncID, db: db) {
            return observation.didReconnect ? .relinked : .skipped
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { inner in
                inner.addTask {
                    let meta = try await MetadataExtractor.extract(from: url)
                    try Self.upsertTrack(
                        url: url,
                        meta: meta,
                        attrs: attrs,
                        identity: identity,
                        folderId: folderId,
                        jobId: jobId,
                        embeddedTrackSyncID: embeddedTrackSyncID,
                        db: db
                    )
                }
                inner.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw CancellationError()
                }
                try await inner.next()
                inner.cancelAll()
            }
            return observation.didReconnect ? .relinked : .processed
        } catch {
            if let jobId {
                let reason: String
                let category: String
                if error is CancellationError {
                    reason = "Timed out after 30 seconds while scanning metadata"
                    category = "timeout"
                } else {
                    reason = "\(type(of: error)): \(error.localizedDescription)"
                    category = "metadata"
                }
                Self.recordScanError(
                    db: db,
                    jobId: jobId,
                    fileURL: url.absoluteString,
                    stage: "metadata",
                    category: category,
                    reason: reason
                )
            }
            return .failed
        }
    }

    static func requiresIdentityRefresh(
        embeddedTrackSyncID: String?,
        storedTrackSyncID: String?,
        storedIdentityState: String?
    ) -> Bool {
        if let embeddedTrackSyncID {
            return embeddedTrackSyncID != storedTrackSyncID
        }
        // A tag can also disappear while a copy preserves its size and mtime.
        // Revisit embedded rows so the normal tagging/conflict safeguards decide
        // what to do, instead of treating the stale database identity as truth.
        return storedIdentityState == PortableIdentityState.embedded.rawValue
    }

    private static func isUnchanged(
        url: URL,
        attrs: URLResourceValues?,
        embeddedTrackSyncID: String?,
        db: DatabaseManager
    ) -> Bool {
        guard let size = attrs?.fileSize,
              let modifiedAt = attrs?.contentModificationDate
        else { return false }

        return (try? db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT file_size, file_modified_at, track_sync_id, physical_file_id, id_state,
                       artwork_source_url, artwork_source_file_size, artwork_source_modified_at
                FROM tracks
                WHERE file_url = ?
            """, arguments: [url.absoluteString]) else { return false }

            guard let physicalID: String = row["physical_file_id"], UUID(uuidString: physicalID) != nil else { return false }
            let existingSize: Int64? = row["file_size"]
            let existingModifiedAt: Date? = row["file_modified_at"]
            guard existingSize == Int64(size),
                  let existingModifiedAt else { return false }
            guard abs(existingModifiedAt.timeIntervalSince(modifiedAt)) < 0.001 else { return false }
            let storedTrackSyncID: String? = row["track_sync_id"]
            let storedIdentityState: String? = row["id_state"]
            if let embeddedTrackSyncID, try !SyncEligibility.isVerified(embeddedTrackSyncID, in: db) { return false }
            guard !requiresIdentityRefresh(
                embeddedTrackSyncID: embeddedTrackSyncID,
                storedTrackSyncID: storedTrackSyncID,
                storedIdentityState: storedIdentityState
            ) else { return false }

            let artworkSourceURL: String? = row["artwork_source_url"]
            guard let artworkSourceURL, let sourceURL = URL(string: artworkSourceURL) else { return true }
            guard let sourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  sourceValues.isRegularFile != false else { return false }

            let existingSourceSize: Int64? = row["artwork_source_file_size"]
            let existingSourceModifiedAt: Date? = row["artwork_source_modified_at"]
            guard existingSourceSize == Int64(sourceValues.fileSize ?? -1),
                  let existingSourceModifiedAt,
                  let sourceModifiedAt = sourceValues.contentModificationDate else { return false }
            return abs(existingSourceModifiedAt.timeIntervalSince(sourceModifiedAt)) < 0.001
        }) ?? false
    }

    // MARK: - Private helpers (nonisolated so they run off-actor)

    private static func observeFile(
        url: URL,
        attrs: URLResourceValues?,
        identity: FileIdentity,
        folderId: Int64?,
        jobId: Int64?,
        db: DatabaseManager
    ) -> FileObservation {
        let urlString = url.absoluteString
        let now = Date()

        let existingAtPath = try? db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, availability_status
                FROM tracks
                WHERE file_url = ?
            """, arguments: [urlString])
        }

        if let existingAtPath,
           let trackId: Int64 = existingAtPath["id"] {
            let previousStatus: String = existingAtPath["availability_status"] ?? "available"
            try? db.write { db in
                try stampObservedTrack(
                    trackId: trackId,
                    folderId: folderId,
                    jobId: jobId,
                    identity: identity,
                    observedAt: now,
                    db: db
                )
            }
            return FileObservation(didReconnect: previousStatus != "available")
        }

        guard let volumeUUID = identity.volumeUUID else {
            return FileObservation(didReconnect: false)
        }

        let candidates: [Row]
        if let fileResourceIdentifier = identity.fileResourceIdentifier {
            candidates = (try? db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, file_url
                    FROM tracks
                    WHERE volume_uuid = ? AND file_resource_identifier = ?
                """, arguments: [volumeUUID, fileResourceIdentifier])
            }) ?? []
        } else if let documentIdentifier = identity.documentIdentifier {
            candidates = (try? db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, file_url
                    FROM tracks
                    WHERE volume_uuid = ? AND document_identifier = ?
                """, arguments: [volumeUUID, documentIdentifier])
            }) ?? []
        } else {
            return FileObservation(didReconnect: false)
        }

        let missingPathCandidates = candidates.filter { row in
            guard let oldURLString: String = row["file_url"],
                  let oldURL = URL(string: oldURLString) else { return false }
            return !FileManager.default.fileExists(atPath: oldURL.path)
        }
        guard missingPathCandidates.count == 1,
              let trackId: Int64 = missingPathCandidates[0]["id"] else {
            return FileObservation(didReconnect: false)
        }

        let didUpdate = (try? db.write { db -> Bool in
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tracks WHERE file_url = ?",
                arguments: [urlString]
            ) == 0 else { return false }

            try db.execute(sql: """
                UPDATE tracks
                SET file_url = ?, folder_id = ?, availability_status = 'available',
                    file_resource_identifier = ?, document_identifier = ?,
                    volume_uuid = ?, last_seen_at = ?,
                    last_seen_scan_id = ?, missing_since = NULL
                WHERE id = ?
            """, arguments: [
                urlString,
                folderId,
                identity.fileResourceIdentifier,
                identity.documentIdentifier,
                volumeUUID,
                now,
                jobId,
                trackId
            ])
            return db.changesCount == 1
        }) ?? false

        return FileObservation(didReconnect: didUpdate)
    }

    private static func stampObservedTrack(
        trackId: Int64,
        folderId: Int64?,
        jobId: Int64?,
        identity: FileIdentity,
        observedAt: Date,
        db: Database
    ) throws {
        try db.execute(sql: """
            UPDATE tracks
            SET folder_id = COALESCE(?, folder_id),
                availability_status = 'available',
                file_resource_identifier = ?,
                document_identifier = ?,
                volume_uuid = ?,
                last_seen_at = ?,
                last_seen_scan_id = ?,
                missing_since = NULL
            WHERE id = ?
        """, arguments: [
            folderId,
            identity.fileResourceIdentifier,
            identity.documentIdentifier,
            identity.volumeUUID,
            observedAt,
            jobId,
            trackId
        ])
    }

    /// Remote compatibility placeholders have no local physical UUID. Reuse a
    /// real missing file's UUID, but allocate one when audio replaces a stub.
    /// Rekey earlier incorrectly materialized stubs atomically with local refs.
    private static func localPhysicalIdentity(replacing oldID: String?, in db: Database) throws -> String {
        if let oldID, UUID(uuidString: oldID) != nil { return oldID }
        let newID = UUID().uuidString
        guard let oldID else { return newID }
        let job = try Row.fetchOne(db, sql: "SELECT * FROM tagging_jobs WHERE physical_file_id=?", arguments: [oldID])
        // The job FK is immediate (without ON UPDATE CASCADE). Preserve it
        // across the parent rekey inside the surrounding scan transaction.
        try db.execute(sql: "DELETE FROM tagging_jobs WHERE physical_file_id=?", arguments: [oldID])
        try db.execute(sql: "UPDATE physical_files SET physical_file_id=? WHERE physical_file_id=?", arguments: [newID, oldID])
        try db.execute(sql: "UPDATE tracks SET physical_file_id=? WHERE physical_file_id=?", arguments: [newID, oldID])
        try db.execute(sql: "UPDATE identity_conflicts SET physical_file_id=? WHERE physical_file_id=?", arguments: [newID, oldID])
        if let job {
            try db.execute(sql: """
                INSERT INTO tagging_jobs (physical_file_id,state,may_replace_existing_identity,attempts,last_error,last_attempt_at,next_attempt_at)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [newID, job["state"] as String, job["may_replace_existing_identity"] as Bool,
                                  job["attempts"] as Int, job["last_error"] as String?,
                                  job["last_attempt_at"] as Date?, job["next_attempt_at"] as Date?])
        }
        return newID
    }

    private static func upsertTrack(
        url: URL,
        meta: ExtractedMetadata,
        attrs: URLResourceValues?,
        identity: FileIdentity,
        folderId: Int64?,
        jobId: Int64?,
        embeddedTrackSyncID: String?,
        db: DatabaseManager
    ) throws {
        var artworkId: Int64? = nil
        var artworkSourceURL: String?
        var artworkSourceFileSize: Int64?
        var artworkSourceModifiedAt: Date?
        let folderArtwork = ArtworkExtractor.folderArtwork(for: url)

        if let artworkData = meta.artworkData {
            artworkId = try ArtworkStore.store(sourceData: artworkData, sourceURL: nil, db: db)
        }
        if artworkId == nil, let folderArtwork {
            artworkId = try ArtworkStore.store(
                sourceData: folderArtwork.data,
                sourceURL: folderArtwork.url.absoluteString,
                db: db
            )
        }
        // AVFoundation may surface nearby folder artwork as common metadata (notably
        // for WAV files). Keep its on-disk source fingerprint whenever one exists so
        // an edited cover invalidates this otherwise unchanged track.
        if artworkId != nil, let folderArtwork {
            artworkSourceURL = folderArtwork.url.absoluteString
            artworkSourceFileSize = folderArtwork.fileSize
            artworkSourceModifiedAt = folderArtwork.modifiedAt
        }

        try db.write { db in
            let now = Date()
            let deviceID = try SyncDeviceIdentity.id(in: db)
            let existing = try Row.fetchOne(db, sql: "SELECT id, track_sync_id, physical_file_id, title, artist, album, album_artist, genre, track_number, disc_number, year FROM tracks WHERE file_url = ?", arguments: [url.absoluteString])
            var trackSyncID: String = embeddedTrackSyncID ?? (existing?["track_sync_id"] as String?) ?? UUID().uuidString.uppercased()
            var physicalFileID = try localPhysicalIdentity(replacing: existing?["physical_file_id"], in: db)
            var idState = embeddedTrackSyncID == nil ? PortableIdentityState.absent.rawValue : PortableIdentityState.embedded.rawValue

            // A tagged move reconnects the previous compatibility row. Multiple
            // physical copies remain separate rows sharing the same logical UUID.
            if existing == nil, embeddedTrackSyncID != nil {
                let missingRows = try Row.fetchAll(db, sql: "SELECT id, physical_file_id, file_url FROM tracks WHERE track_sync_id = ? AND availability_status != 'available'", arguments: [trackSyncID])
                if missingRows.count == 1, let movedID: Int64 = missingRows[0]["id"] {
                    physicalFileID = try localPhysicalIdentity(replacing: missingRows[0]["physical_file_id"], in: db)
                    try db.execute(sql: "UPDATE tracks SET file_url = ? WHERE id = ?", arguments: [url.absoluteString, movedID])
                }
            }

            let descriptiveChanged: Bool = existing == nil ||
                (existing?["title"] as String?) != meta.title ||
                (existing?["artist"] as String?) != meta.artist ||
                (existing?["album"] as String?) != meta.album ||
                (existing?["album_artist"] as String?) != meta.albumArtist ||
                (existing?["genre"] as String?) != meta.genre ||
                (existing?["track_number"] as Int?) != meta.trackNumber ||
                (existing?["disc_number"] as Int?) != meta.discNumber ||
                (existing?["year"] as Int?) != meta.year
            let existingMetadataRev: String? = try String.fetchOne(db, sql: "SELECT metadata_rev FROM logical_tracks WHERE track_sync_id = ?", arguments: [trackSyncID])
            let metadataRev = descriptiveChanged ? SyncRevision.make(at: now, writerID: deviceID).rawValue : existingMetadataRev

            try db.execute(sql: """
                INSERT INTO logical_tracks
                    (track_sync_id, title, artist, album, album_artist, genre, track_number,
                     disc_number, year, duration_ms, is_promoted, metadata_rev, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(track_sync_id) DO UPDATE SET
                    title = excluded.title, artist = excluded.artist, album = excluded.album,
                    album_artist = excluded.album_artist, genre = excluded.genre,
                    track_number = excluded.track_number, disc_number = excluded.disc_number,
                    year = excluded.year, duration_ms = excluded.duration_ms,
                    metadata_rev = CASE WHEN excluded.metadata_rev > COALESCE(logical_tracks.metadata_rev, '')
                                        THEN excluded.metadata_rev ELSE logical_tracks.metadata_rev END
            """, arguments: [trackSyncID, meta.title, meta.artist, meta.album, meta.albumArtist, meta.genre, meta.trackNumber, meta.discNumber, meta.year, Int((meta.duration ?? 0) * 1_000), metadataRev, now])

            try db.execute(sql: """
                INSERT INTO tracks
                  (file_url, folder_id, availability_status, file_resource_identifier,
                   document_identifier, volume_uuid,
                   last_seen_at, last_seen_scan_id, file_size, file_modified_at,
                   title, artist, album_artist, album,
                   composer, genre, year, track_number, disc_number, duration,
                   bit_rate, sample_rate, channel_count, format, date_added, artwork_id,
                   artwork_source_url, artwork_source_file_size, artwork_source_modified_at,
                   track_sync_id, physical_file_id, metadata_rev, id_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_url) DO UPDATE SET
                  folder_id = COALESCE(excluded.folder_id, tracks.folder_id),
                  availability_status = 'available',
                  file_resource_identifier = excluded.file_resource_identifier,
                  document_identifier = excluded.document_identifier,
                  volume_uuid = excluded.volume_uuid,
                  last_seen_at = excluded.last_seen_at,
                  last_seen_scan_id = excluded.last_seen_scan_id,
                  missing_since = NULL,
                  file_size = excluded.file_size,
                  file_modified_at = excluded.file_modified_at,
                  title = excluded.title,
                  artist = excluded.artist,
                  album_artist = excluded.album_artist,
                  album = excluded.album,
                  composer = excluded.composer,
                  genre = excluded.genre,
                  year = excluded.year,
                  track_number = excluded.track_number,
                  disc_number = excluded.disc_number,
                  duration = excluded.duration,
                  bit_rate = excluded.bit_rate,
                  sample_rate = excluded.sample_rate,
                  channel_count = excluded.channel_count,
                  format = excluded.format,
                  artwork_id = excluded.artwork_id,
                  artwork_source_url = excluded.artwork_source_url,
                  artwork_source_file_size = excluded.artwork_source_file_size,
                  artwork_source_modified_at = excluded.artwork_source_modified_at,
                  track_sync_id = excluded.track_sync_id,
                  physical_file_id = excluded.physical_file_id,
                  metadata_rev = excluded.metadata_rev,
                  id_state = excluded.id_state
            """, arguments: [
                url.absoluteString,
                folderId,
                "available",
                identity.fileResourceIdentifier,
                identity.documentIdentifier,
                identity.volumeUUID,
                now,
                jobId,
                attrs?.fileSize,
                attrs?.contentModificationDate,
                meta.title,
                meta.artist,
                meta.albumArtist,
                meta.album,
                meta.composer,
                meta.genre,
                meta.year,
                meta.trackNumber,
                meta.discNumber,
                meta.duration,
                meta.bitRate,
                meta.sampleRate,
                meta.channelCount,
                meta.format,
                Date(),
                artworkId,
                artworkSourceURL,
                artworkSourceFileSize,
                artworkSourceModifiedAt,
                trackSyncID,
                physicalFileID,
                metadataRev,
                idState
            ])

            let rootRow = try folderId.flatMap { id in
                try Row.fetchOne(db, sql: "SELECT url, library_root_id FROM folders WHERE id = ?", arguments: [id])
            }
            let rootString: String? = rootRow?["url"]
            let rootURL = rootString.flatMap(URL.init(string:))
            let relativePath = rootURL.map { root in
                let rootPath = root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
            } ?? url.absoluteString
            let libraryRootID: String = rootRow?["library_root_id"] ?? "legacy-unscoped"
            try db.execute(sql: """
                INSERT INTO physical_files
                    (physical_file_id, track_sync_id, library_root_id, relative_path, file_size,
                     mtime, format, id_state, is_preferred, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(physical_file_id) DO UPDATE SET
                    track_sync_id = excluded.track_sync_id,
                    library_root_id = excluded.library_root_id,
                    relative_path = excluded.relative_path,
                    file_size = excluded.file_size, mtime = excluded.mtime,
                    format = excluded.format, id_state = excluded.id_state,
                    last_seen_at = excluded.last_seen_at
            """, arguments: [physicalFileID, trackSyncID, libraryRootID, relativePath, attrs?.fileSize, attrs?.contentModificationDate, meta.format, idState, now])

            if embeddedTrackSyncID == trackSyncID {
                try SyncEligibility.verifyFile(url, physicalFileID: physicalFileID, in: db)
            } else {
                try SyncEligibility.revokeUnembedded(trackSyncID, in: db)
            }
            try IdentityRepository.refreshComponent(for: trackSyncID, in: db)
            let portableIdentity = try PortableIdentitySettings.isEnabled(in: db)
            if embeddedTrackSyncID == nil, portableIdentity {
                try db.execute(sql: """
                    INSERT INTO tagging_jobs (physical_file_id, state, attempts)
                    VALUES (?, 'pending', 0)
                    ON CONFLICT(physical_file_id) DO NOTHING
                """, arguments: [physicalFileID])
            } else if idState == PortableIdentityState.absent.rawValue, portableIdentity {
                try db.execute(sql: "INSERT INTO tagging_jobs (physical_file_id, state, attempts) VALUES (?, 'pending', 0) ON CONFLICT(physical_file_id) DO UPDATE SET state = 'pending'", arguments: [physicalFileID])
            }
        }
    }

    /// Restores the denormalized track fields used by the library UI after a
    /// scanner adds a local file for an identity that sync had already learned.
    /// Do this as one batch after scanning, rather than once per file, to avoid
    /// contention with concurrent metadata extraction.
    private static func materializeSynchronizedAnnotations(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE tracks
            SET rating = (
                    SELECT rating FROM track_annotations
                    WHERE track_sync_id = tracks.track_sync_id
                ),
                rating_rev = (
                    SELECT rating_rev FROM track_annotations
                    WHERE track_sync_id = tracks.track_sync_id
                ),
                is_favorite = COALESCE((
                    SELECT favorite FROM track_annotations
                    WHERE track_sync_id = tracks.track_sync_id
                ), 0),
                favorite_rev = (
                    SELECT favorite_rev FROM track_annotations
                    WHERE track_sync_id = tracks.track_sync_id
                )
            WHERE EXISTS (
                SELECT 1 FROM track_annotations
                WHERE track_sync_id = tracks.track_sync_id
            )
        """)
    }

    private static func deriveAlbumsAndArtists(_ db: Database) throws {
        // Clear derived FKs so albums/artists can be deleted without constraint violations
        try db.execute(sql: "UPDATE tracks SET album_id = NULL, artist_id = NULL")
        try db.execute(sql: "DELETE FROM albums")
        try db.execute(sql: "DELETE FROM artists")

        // Clear stale track→artwork references (artwork_id pointing to deleted artwork rows)
        try db.execute(sql: """
            UPDATE tracks SET artwork_id = NULL
            WHERE artwork_id IS NOT NULL AND artwork_id NOT IN (SELECT id FROM artwork)
        """)

        // Albums are derived from tracks below, so a track reference is the sole source
        // of truth for artwork retention. This also clears the final orphan when a
        // library no longer has any tracks with artwork.
        try db.execute(sql: """
            DELETE FROM artwork
            WHERE id NOT IN (SELECT DISTINCT artwork_id FROM tracks WHERE artwork_id IS NOT NULL)
        """)

        // Populate artists
        try db.execute(sql: """
            INSERT INTO artists (name)
            SELECT DISTINCT COALESCE(album_artist, artist)
            FROM tracks
            WHERE COALESCE(album_artist, artist) IS NOT NULL
              AND COALESCE(album_artist, artist) != ''
              AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
        """)

        // Populate albums as one row per album title. For classical albums, track-level
        // album artist often names a performer/conductor, so it must not split the album.
        try db.execute(sql: """
            INSERT INTO albums (title, album_artist, year, genre)
            SELECT album,
                   CASE
                       WHEN COUNT(*) = COUNT(resolved_artist)
                        AND COUNT(DISTINCT resolved_artist) = 1
                       THEN MIN(resolved_artist)
                       ELSE NULL
                   END,
                   MIN(year),
                   MIN(genre)
            FROM (
                SELECT album, COALESCE(album_artist, artist) AS resolved_artist, year, genre
                FROM tracks
                WHERE album IS NOT NULL AND album != ''
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
            )
            GROUP BY album
        """)

        // Link tracks → albums
        try db.execute(sql: """
            UPDATE tracks
            SET album_id = (
                SELECT id FROM albums
                WHERE albums.title = tracks.album
                LIMIT 1
            )
            WHERE album IS NOT NULL
              AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
        """)

        // Link tracks → artists
        try db.execute(sql: """
            UPDATE tracks
            SET artist_id = (
                SELECT id FROM artists
                WHERE artists.name = COALESCE(tracks.album_artist, tracks.artist)
                LIMIT 1
            )
            WHERE COALESCE(album_artist, artist) IS NOT NULL
              AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
        """)

        // Link albums → artwork (pick artwork from their first track, only if the artwork row still exists)
        try db.execute(sql: """
            UPDATE albums
            SET artwork_id = (
                SELECT tracks.artwork_id FROM tracks
                WHERE tracks.album_id = albums.id
                  AND tracks.artwork_id IS NOT NULL
                  AND tracks.artwork_id IN (SELECT id FROM artwork)
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
                LIMIT 1
            )
        """)
    }

    private static func markMissingTracks(
        folderId: Int64,
        excludingScanJobId scanJobId: Int64,
        db: DatabaseManager
    ) -> Int {
        (try? db.write { db -> Int in
            try db.execute(sql: """
                UPDATE tracks
                SET availability_status = 'missing',
                    missing_since = COALESCE(missing_since, ?)
                WHERE folder_id = ?
                  AND availability_status = 'available'
                  AND (last_seen_scan_id IS NULL OR last_seen_scan_id != ?)
            """, arguments: [Date(), folderId, scanJobId])
            return db.changesCount
        }) ?? 0
    }

    private func enumerateAudioFiles(in folder: URL) -> [URL]? {
        var encounteredError = false
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey,
                .documentIdentifierKey,
                .volumeUUIDStringKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                encounteredError = true
                return false
            }
        ) else { return nil }

        let urls = (enumerator.allObjects as? [URL] ?? []).filter {
            guard MetadataExtractor.supportedExtensions.contains($0.pathExtension.lowercased()),
                  let values = try? $0.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }
        return encounteredError ? nil : urls
    }
}

private enum ScanFileResult {
    case processed
    case skipped
    case relinked
    case failed
}

private struct FileIdentity {
    let fileResourceIdentifier: Data?
    let documentIdentifier: Int64?
    let volumeUUID: String?

    init(resourceValues: URLResourceValues?) {
        fileResourceIdentifier = resourceValues?.fileResourceIdentifier as? Data
        documentIdentifier = resourceValues?.documentIdentifier.flatMap(Int64.init(exactly:))
        volumeUUID = resourceValues?.volumeUUIDString
    }
}

private struct FileObservation {
    let didReconnect: Bool
}

private extension ScanSummary {
    mutating func apply(_ result: ScanFileResult) {
        switch result {
        case .processed:
            processedFiles += 1
            changedFiles += 1
        case .skipped:
            skippedFiles += 1
        case .relinked:
            processedFiles += 1
            relinkedFiles += 1
        case .failed:
            processedFiles += 1
            errorCount += 1
        }
    }
}
