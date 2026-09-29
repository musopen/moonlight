// SyncApplyLayer.swift
//
// Takes changes that arrived from the user's other devices (through iCloud sync) and merges them
// into the local library, such as ratings, favorites, playlists, playlist order and play counts.
// When two devices changed the same thing, it applies consistent rules so every device ends up
// agreeing.

import Foundation
import GRDB

/// The single merge/materialization path for both CloudKit and the deterministic
/// SQLite convergence harness.
enum SyncRecordApplier {
    private static let queryChunkSize = 1_000

    typealias RevisionFilter = (
        _ raw: String?,
        _ recordName: String,
        _ field: String,
        _ receivedAt: Date,
        _ db: Database
    ) throws -> String?

    private struct MaterializationScope {
        var entryIDs = Set<String>()
        var playlistIDs = Set<String>()
        var trackIDs = Set<String>()

        mutating func include(_ record: SyncTransportRecord) {
            switch record {
            case .track(let value):
                trackIDs.insert(value.id)
                if let mergedInto = value.mergedInto { trackIDs.insert(mergedInto) }
            case .playlist(let value):
                playlistIDs.insert(value.id)
            case .entry(let value):
                entryIDs.insert(value.id)
            case .counter:
                break
            }
        }
    }

    static func apply(
        _ records: [SyncTransportRecord],
        to db: Database,
        receivedAt: Date = Date(),
        revisionFilter: RevisionFilter? = nil
    ) throws {
        let filter = revisionFilter ?? defaultRevisionFilter
        var scope = MaterializationScope()
        for record in records {
            scope.include(record)
            switch record {
            case .track(let value):
                try apply(value, recordName: record.recordName, to: db, receivedAt: receivedAt, revisionFilter: filter)
            case .playlist(let value):
                try apply(value, recordName: record.recordName, to: db, receivedAt: receivedAt, revisionFilter: filter)
            case .entry(let value):
                try apply(value, recordName: record.recordName, to: db, receivedAt: receivedAt, revisionFilter: filter)
            case .counter(let value):
                try apply(value, to: db)
            }
        }
        try materializeEntries(in: scope, to: db)
    }

    /// A local scan can make an already-synced playlist entry resolvable after
    /// its CloudKit event was processed. Rebuild those read-model rows once the
    /// matching audio tracks exist on this device.
    static func materializeResolvablePlaylistEntries(in db: Database) throws {
        let entryIDs = Set(try String.fetchAll(
            db,
            sql: "SELECT playlist_entry_id FROM synced_playlist_entries"
        ))
        guard !entryIDs.isEmpty else { return }
        try materializeEntries(in: MaterializationScope(entryIDs: entryIDs), to: db)
    }

    /// Rebuilds the legacy/read-model position column from synchronized order.
    /// Entry identity is the deterministic tie-break for equal concurrent keys.
    static func recomputePositions(in db: Database, playlistIDs: Set<Int64>? = nil) throws {
        if let playlistIDs {
            guard !playlistIDs.isEmpty else { return }
            let sortedIDs = playlistIDs.sorted()
            for start in stride(from: 0, to: sortedIDs.count, by: queryChunkSize) {
                let chunk = Array(sortedIDs[start..<min(start + queryChunkSize, sortedIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, playlist_id FROM playlist_tracks WHERE playlist_id IN (\(placeholders)) ORDER BY playlist_id, ordering_key, playlist_entry_id, id",
                    arguments: StatementArguments(chunk)
                )
                try writePositions(for: rows, in: db)
            }
            return
        }

        let rows = try Row.fetchAll(db, sql: "SELECT id, playlist_id FROM playlist_tracks ORDER BY playlist_id, ordering_key, playlist_entry_id, id")
        try writePositions(for: rows, in: db)
    }

    private static func writePositions(for rows: [Row], in db: Database) throws {
        var currentPlaylistID: Int64?
        var position = 0
        for row in rows {
            let playlistID: Int64 = row["playlist_id"]
            if playlistID != currentPlaylistID {
                currentPlaylistID = playlistID
                position = 0
            }
            try db.execute(sql: "UPDATE playlist_tracks SET position = ? WHERE id = ?", arguments: [position, row["id"] as Int64])
            position += 1
        }
    }

    private static func apply(
        _ incoming: SyncTransportRecord.TrackPayload,
        recordName: String,
        to db: Database,
        receivedAt: Date,
        revisionFilter: RevisionFilter
    ) throws {
        try ensureTrack(incoming.id, title: nil, artist: nil, album: nil, in: db)
        let row = try Row.fetchOne(db, sql: "SELECT lt.*, ta.rating, ta.rating_rev, ta.favorite, ta.favorite_rev FROM logical_tracks lt LEFT JOIN track_annotations ta USING(track_sync_id) WHERE lt.track_sync_id = ?", arguments: [incoming.id])
        var local = SyncedTrackState(
            trackSyncID: incoming.id,
            rating: row?["rating"], ratingRev: (row?["rating_rev"] as String?).map(SyncRevision.init),
            favorite: row?["favorite"], favoriteRev: (row?["favorite_rev"] as String?).map(SyncRevision.init),
            title: row?["title"], artist: row?["artist"], album: row?["album"],
            metadataRev: (row?["metadata_rev"] as String?).map(SyncRevision.init), mergedInto: row?["merged_into"]
        )
        let incomingState = SyncedTrackState(
            trackSyncID: incoming.id,
            rating: incoming.rating,
            ratingRev: try revisionFilter(incoming.ratingRev, recordName, "ratingRev", receivedAt, db).map(SyncRevision.init),
            favorite: incoming.favorite,
            favoriteRev: try revisionFilter(incoming.favoriteRev, recordName, "favoriteRev", receivedAt, db).map(SyncRevision.init),
            mergedInto: nil
        )
        local.merge(incomingState, receivedAt: receivedAt)
        try db.execute(sql: "INSERT INTO track_annotations (track_sync_id, rating, rating_rev, favorite, favorite_rev) VALUES (?, ?, ?, ?, ?) ON CONFLICT(track_sync_id) DO UPDATE SET rating=excluded.rating, rating_rev=excluded.rating_rev, favorite=excluded.favorite, favorite_rev=excluded.favorite_rev", arguments: [incoming.id, local.rating, local.ratingRev?.rawValue, local.favorite, local.favoriteRev?.rawValue])
        try db.execute(sql: "UPDATE tracks SET rating=?, rating_rev=?, is_favorite=COALESCE(?, 0), favorite_rev=? WHERE track_sync_id=?", arguments: [local.rating, local.ratingRev?.rawValue, local.favorite, local.favoriteRev?.rawValue, incoming.id])
        _ = try SyncEligibility.promote(incoming.id, in: db)
        if let merged = incoming.mergedInto, UUID(uuidString: merged) != nil {
            try ensureTrack(merged, title: nil, artist: nil, album: nil, in: db)
            _ = try IdentityRepository.merge(incoming.id, merged, in: db)
        }
        try IdentityRepository.refreshComponent(for: incoming.id, in: db)
    }

    private static func apply(
        _ incoming: SyncTransportRecord.PlaylistPayload,
        recordName: String,
        to db: Database,
        receivedAt: Date,
        revisionFilter: RevisionFilter
    ) throws {
        let nameRev = try revisionFilter(incoming.nameRev, recordName, "nameRev", receivedAt, db) ?? ""
        let sortRev = try revisionFilter(incoming.sortModeRev, recordName, "sortModeRev", receivedAt, db) ?? ""
        let ruleRev = try revisionFilter(incoming.ruleRev, recordName, "ruleRev", receivedAt, db)
        if let row = try Row.fetchOne(db, sql: "SELECT id, name_rev, sort_mode_rev, rule_rev, deleted_at FROM playlists WHERE playlist_sync_id = ?", arguments: [incoming.id]), let localID: Int64 = row["id"] {
            let nameWins = nameRev > (row["name_rev"] as String? ?? "")
            let sortWins = sortRev > (row["sort_mode_rev"] as String? ?? "")
            let ruleWins = (ruleRev ?? "") > (row["rule_rev"] as String? ?? "")
            let localDeleted: Date? = row["deleted_at"]
            let deleted = [localDeleted, incoming.deletedAt].compactMap { $0 }.max()
            try db.execute(sql: "UPDATE playlists SET name=CASE WHEN ? THEN ? ELSE name END, name_rev=MAX(name_rev, ?), kind=?, sort_mode=CASE WHEN ? THEN ? ELSE sort_mode END, sort_mode_rev=MAX(sort_mode_rev, ?), rule=CASE WHEN ? THEN ? ELSE rule END, rule_rev=CASE WHEN ? THEN ? ELSE rule_rev END, deleted_at=? WHERE id=?", arguments: [nameWins, incoming.name, nameRev, incoming.kind, sortWins, incoming.sortMode, sortRev, ruleWins, incoming.rule, ruleWins, ruleRev, deleted, localID])
        } else {
            try db.execute(sql: "INSERT INTO playlists (name, date_created, date_modified, playlist_sync_id, kind, name_rev, sort_mode, sort_mode_rev, rule, rule_rev, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [incoming.name, incoming.createdAt, incoming.createdAt, incoming.id, incoming.kind, nameRev, incoming.sortMode, sortRev, incoming.rule, ruleRev, incoming.deletedAt])
        }
    }

    private static func apply(
        _ incoming: SyncTransportRecord.EntryPayload,
        recordName: String,
        to db: Database,
        receivedAt: Date,
        revisionFilter: RevisionFilter
    ) throws {
        let revision = try revisionFilter(incoming.orderingKeyRev, recordName, "orderingKeyRev", receivedAt, db) ?? ""
        try db.execute(sql: """
            INSERT INTO synced_playlist_entries
                (playlist_entry_id, playlist_sync_id, track_sync_id, ordering_key, ordering_key_rev, created_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(playlist_entry_id) DO UPDATE SET
                ordering_key=CASE WHEN excluded.ordering_key_rev > ordering_key_rev THEN excluded.ordering_key ELSE ordering_key END,
                ordering_key_rev=MAX(ordering_key_rev, excluded.ordering_key_rev),
                deleted_at=CASE
                    WHEN deleted_at IS NULL THEN excluded.deleted_at
                    WHEN excluded.deleted_at IS NULL THEN deleted_at
                    ELSE MAX(deleted_at, excluded.deleted_at) END
        """, arguments: [incoming.id, incoming.playlistID, incoming.trackID, incoming.orderingKey, revision, incoming.createdAt, incoming.deletedAt])
    }

    private static func apply(_ incoming: SyncTransportRecord.CounterPayload, to db: Database) throws {
        try ensureTrack(incoming.trackID, title: nil, artist: nil, album: nil, in: db)
        try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, ?, ?, ?) ON CONFLICT(track_sync_id, device_id) DO UPDATE SET count=MAX(count, excluded.count), last_played_at=CASE WHEN last_played_at IS NULL THEN excluded.last_played_at WHEN excluded.last_played_at IS NULL THEN last_played_at ELSE MAX(last_played_at, excluded.last_played_at) END", arguments: [incoming.trackID, incoming.deviceID, incoming.count, incoming.lastPlayedAt])
        let count = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(count), 0) FROM play_counters WHERE track_sync_id = ?", arguments: [incoming.trackID]) ?? 0
        let last = try Date.fetchOne(db, sql: "SELECT MAX(last_played_at) FROM play_counters WHERE track_sync_id = ?", arguments: [incoming.trackID])
        try db.execute(sql: "UPDATE tracks SET play_count=?, last_played_at=? WHERE track_sync_id=?", arguments: [count, last, incoming.trackID])
        try IdentityRepository.refreshComponent(for: incoming.trackID, in: db)
    }

    private static func ensureTrack(_ id: String, title: String?, artist: String?, album: String?, in db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO logical_tracks (track_sync_id, title, artist, album, created_at, is_promoted) VALUES (?, ?, ?, ?, ?, 0)", arguments: [id, title, artist, album, Date()])
        guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE track_sync_id = ?", arguments: [id]) ?? 0) == 0 else { return }
        try db.execute(sql: "INSERT INTO tracks (file_url, availability_status, title, artist, album, date_added, track_sync_id, physical_file_id, id_state, is_promoted) VALUES (?, 'unavailable', ?, ?, ?, ?, ?, ?, 'unsupported', 0)", arguments: ["moonlight-unavailable://\(id)", title, artist, album, Date(), id, "STUB-\(id)"])
    }

    private static func materializeEntries(in scope: MaterializationScope, to db: Database) throws {
        let dimensions: [(column: String, values: [String])] = [
            ("playlist_entry_id", scope.entryIDs.sorted()),
            ("playlist_sync_id", scope.playlistIDs.sorted()),
            ("track_sync_id", scope.trackIDs.sorted())
        ]
        let scopedValues = dimensions.flatMap { dimension in
            dimension.values.map { (column: dimension.column, value: $0) }
        }
        var rowsByEntryID: [String: Row] = [:]
        for start in stride(from: 0, to: scopedValues.count, by: queryChunkSize) {
            let chunk = Array(scopedValues[start..<min(start + queryChunkSize, scopedValues.count)])
            var clauses: [String] = []
            var arguments = StatementArguments()
            for dimension in dimensions {
                let values = chunk.filter { $0.column == dimension.column }.map(\.value)
                guard !values.isEmpty else { continue }
                clauses.append("se.\(dimension.column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
                arguments += StatementArguments(values)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT se.*, p.id AS playlist_local_id, t.id AS track_local_id
                FROM synced_playlist_entries se
                JOIN playlists p ON p.playlist_sync_id=se.playlist_sync_id
                JOIN tracks t ON t.track_sync_id=se.track_sync_id
                WHERE \(clauses.joined(separator: " OR "))
            """, arguments: arguments)
            for row in rows {
                rowsByEntryID[row["playlist_entry_id"] as String] = row
            }
        }

        let rows = rowsByEntryID.values.sorted { lhs, rhs in
            let lhsPlaylist: Int64 = lhs["playlist_local_id"]
            let rhsPlaylist: Int64 = rhs["playlist_local_id"]
            if lhsPlaylist != rhsPlaylist { return lhsPlaylist < rhsPlaylist }
            let lhsKey: String = lhs["ordering_key"]
            let rhsKey: String = rhs["ordering_key"]
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return (lhs["playlist_entry_id"] as String) < (rhs["playlist_entry_id"] as String)
        }
        var affectedPlaylists = Set<Int64>()
        for row in rows {
            let playlistID: Int64 = row["playlist_local_id"]
            affectedPlaylists.insert(playlistID)
            // Local reorders write the upload/read-model row before their remote
            // echo reaches staging. A delayed entry, parent refresh, or rescan
            // must not materialize an older staged order over that local winner.
            try db.execute(sql: """
                INSERT INTO playlist_tracks
                    (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at, deleted_at)
                VALUES (?, ?, 0, ?, ?, ?, ?, ?)
                ON CONFLICT(playlist_entry_id) WHERE playlist_entry_id != '' DO UPDATE SET
                    playlist_id=excluded.playlist_id,
                    track_id=excluded.track_id,
                    ordering_key=CASE
                        WHEN excluded.ordering_key_rev > playlist_tracks.ordering_key_rev THEN excluded.ordering_key
                        ELSE playlist_tracks.ordering_key END,
                    ordering_key_rev=MAX(playlist_tracks.ordering_key_rev, excluded.ordering_key_rev),
                    deleted_at=CASE
                        WHEN playlist_tracks.deleted_at IS NULL THEN excluded.deleted_at
                        WHEN excluded.deleted_at IS NULL THEN playlist_tracks.deleted_at
                        ELSE MAX(playlist_tracks.deleted_at, excluded.deleted_at) END
                """, arguments: [playlistID, try IdentityRepository.preferredLocalTrack(for: row["track_sync_id"], in: db) ?? (row["track_local_id"] as Int64), row["playlist_entry_id"] as String, row["ordering_key"] as String, row["ordering_key_rev"] as String, row["created_at"] as Date, row["deleted_at"] as Date?])
        }
        try recomputePositions(in: db, playlistIDs: affectedPlaylists)
    }

    private static func defaultRevisionFilter(
        _ raw: String?,
        _ recordName: String,
        _ field: String,
        _ receivedAt: Date,
        _ db: Database
    ) -> String? {
        guard let raw, !raw.isEmpty, SyncRevision(rawValue: raw).isAcceptable(receivedAt: receivedAt) else { return nil }
        return raw
    }
}
