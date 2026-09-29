// Playlist.swift
//
// Describes playlists and the songs in them as stored in the library database. It also contains
// the single approved way to add songs to or remove songs from a playlist, making sure each change
// is recorded so it can be synced (copied) to the user's other devices. A playlist may hold the
// same song more than once.

import Foundation
import GRDB

struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "playlists"

    var id: Int64?
    var name: String
    var dateCreated: Date
    var dateModified: Date
    var playlistSyncId: String = UUID().uuidString.uppercased()
    var kind: String = "manual"
    var nameRev: String = ""
    var sortMode: String = "manual"
    var sortModeRev: String = ""
    var rule: String?
    var ruleRev: String?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case dateCreated = "date_created"
        case dateModified = "date_modified"
        case playlistSyncId = "playlist_sync_id"
        case kind, rule
        case nameRev = "name_rev"
        case sortMode = "sort_mode"
        case sortModeRev = "sort_mode_rev"
        case ruleRev = "rule_rev"
        case deletedAt = "deleted_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct PlaylistTrack: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "playlist_tracks"

    var id: Int64?
    var playlistId: Int64
    var trackId: Int64
    var position: Int
    var playlistEntryId: String = UUID().uuidString.uppercased()
    var orderingKey: String = ""
    var orderingKeyRev: String = ""
    var createdAt: Date = Date()
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case playlistId = "playlist_id"
        case trackId = "track_id"
        case position
        case playlistEntryId = "playlist_entry_id"
        case orderingKey = "ordering_key"
        case orderingKeyRev = "ordering_key_rev"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A playlist membership paired with the library track it references.
///
/// The membership ID, rather than the track ID, is the row identity in a playlist:
/// a playlist may intentionally contain the same track more than once.
struct PlaylistEntry: Identifiable, Hashable, FetchableRecord {
    let id: Int64
    let playlistId: Int64
    let position: Int
    let track: Track

    init(row: Row) throws {
        id = row["playlist_track_id"]
        playlistId = row["playlist_id"]
        position = row["playlist_position"]
        track = try Track(row: row)
    }

    /// The read model used by the macOS playlist detail screen.
    static func fetchVisible(in playlistID: Int64, from db: Database) throws -> [PlaylistEntry] {
        try PlaylistEntry.fetchAll(db, sql: """
            SELECT playlist_tracks.id AS playlist_track_id,
                   playlist_tracks.playlist_id,
                   playlist_tracks.position AS playlist_position,
                   tracks.*
            FROM tracks
            JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
            JOIN playlists ON playlists.id = playlist_tracks.playlist_id
            WHERE playlist_tracks.playlist_id = ?
              AND playlists.deleted_at IS NULL
              AND playlist_tracks.deleted_at IS NULL
            ORDER BY playlist_tracks.position, playlist_tracks.id
        """, arguments: [playlistID])
    }

    /// Soft-deletes individual memberships so the removal is durable and can be
    /// exchanged with other devices. Membership IDs are used because one track may
    /// intentionally occur more than once in a playlist.
    static func softDelete(entryIDs: [Int64], inPlaylist playlistID: Int64, in db: Database) throws {
        guard !entryIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: entryIDs.count).joined(separator: ",")
        var arguments: StatementArguments = [playlistID]
        arguments += StatementArguments(entryIDs)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, playlist_entry_id
            FROM playlist_tracks
            WHERE playlist_id = ? AND id IN (\(placeholders)) AND deleted_at IS NULL
        """, arguments: arguments)
        guard !rows.isEmpty else { return }

        let now = Date()
        let matchedIDs: [Int64] = rows.map { $0["id"] }
        let matchedPlaceholders = Array(repeating: "?", count: matchedIDs.count).joined(separator: ",")
        try db.execute(
            sql: "UPDATE playlist_tracks SET deleted_at = ? WHERE id IN (\(matchedPlaceholders))",
            arguments: StatementArguments([now]) + StatementArguments(matchedIDs)
        )
        for row in rows {
            let entryID: String = row["playlist_entry_id"]
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entryID)", in: db)
        }
        try SyncRecordApplier.recomputePositions(in: db, playlistIDs: [playlistID])
        try db.execute(sql: "UPDATE playlists SET date_modified = ? WHERE id = ?", arguments: [now, playlistID])
    }
}

/// The single write path for manual-playlist memberships. Keeping it outside
/// AppState makes bulk import and future mobile callers sync-correct by default.
enum PlaylistMutation {
    @discardableResult
    static func append(_ trackIDs: [Int64], to playlistID: Int64, in db: Database) throws -> [Int64] {
        guard !trackIDs.isEmpty else { return [] }
        let maxPosition = try Int.fetchOne(
            db,
            sql: "SELECT MAX(position) FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL",
            arguments: [playlistID]
        ) ?? -1
        var entryIDs: [Int64] = []
        for (offset, trackID) in trackIDs.enumerated() {
            entryIDs.append(try insert(trackID: trackID, playlistID: playlistID, position: maxPosition + offset + 1, in: db))
        }
        try db.execute(sql: "UPDATE playlists SET date_modified = ? WHERE id = ?", arguments: [Date(), playlistID])
        return entryIDs
    }

    @discardableResult
    static func insert(trackID: Int64, playlistID: Int64, position: Int, in db: Database) throws -> Int64 {
        let now = Date()
        let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
        let entryID = UUID().uuidString.uppercased()
        let lastKey = try String.fetchOne(
            db,
            sql: "SELECT ordering_key FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL ORDER BY ordering_key DESC LIMIT 1",
            arguments: [playlistID]
        )
        try db.execute(sql: """
            INSERT INTO playlist_tracks
                (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [playlistID, trackID, position, entryID, FractionalOrderingKey.between(lastKey, nil), revision, now])
        let localEntryID = db.lastInsertedRowID
        try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entryID)", in: db)
        if let trackSyncID = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: trackID, in: db) {
            _ = try SyncEligibility.promote(trackSyncID, in: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackSyncID)", in: db)
        }
        return localEntryID
    }
}
