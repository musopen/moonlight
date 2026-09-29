// IdentityRepository.swift
//
// Keeps track of which audio files are really the same song, so plays, ratings and playlist
// entries follow the song even across copies, moves or devices. It merges or relinks songs only
// when the user confirms, and suggests possible matches for files that have gone missing.

import Foundation
import GRDB

enum IdentityRepositoryError: LocalizedError, Equatable {
    case unknownTrack(String)
    case cyclicMerge(String)
    case sameTrack

    var errorDescription: String? {
        switch self {
        case .unknownTrack(let id): "Unknown Moonlight track identity: \(id)"
        case .cyclicMerge(let id): "A corrupt identity merge cycle contains \(id)"
        case .sameTrack: "These files already belong to the same logical track."
        }
    }
}

enum IdentityRepository {
    static func resolveTerminal(_ identity: String, in db: Database) throws -> String {
        var current = identity
        var visited = Set<String>()
        while true {
            guard visited.insert(current).inserted else { throw IdentityRepositoryError.cyclicMerge(current) }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT merged_into FROM logical_tracks WHERE track_sync_id = ?",
                arguments: [current]
            ) else { throw IdentityRepositoryError.unknownTrack(current) }
            let next: String? = row["merged_into"]
            guard let next, !next.isEmpty else { return current }
            current = next
        }
    }

    /// Explicit equivalence only. Preserve original embedded identities and
    /// counter component keys; moving/summing components is not replay-safe.
    @discardableResult
    static func merge(_ first: String, _ second: String, in db: Database) throws -> String {
        let terminalA = try resolveTerminal(first, in: db)
        let terminalB = try resolveTerminal(second, in: db)
        let survivor = min(terminalA, terminalB)
        if terminalA != terminalB {
            let loser = max(terminalA, terminalB)
            try db.execute(sql: "UPDATE logical_tracks SET merged_into=? WHERE track_sync_id=?", arguments: [survivor, loser])
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(loser)", in: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(survivor)", in: db)
        }
        try refreshComponent(for: survivor, in: db)
        return survivor
    }

    static func componentIDs(for identity: String, in db: Database) throws -> [String] {
        let terminal = try resolveTerminal(identity, in: db)
        return try String.fetchAll(db, sql: """
            WITH RECURSIVE component(id) AS (
                SELECT ? UNION SELECT lt.track_sync_id FROM logical_tracks lt
                JOIN component c ON lt.merged_into=c.id
            ) SELECT id FROM component ORDER BY id
            """, arguments: [terminal])
    }

    /// Annotations use revisions across the component. Counters remain MAX
    /// registers under (original embedded ID, writer), and are only summed for
    /// display. Late origin records therefore update a register, never add again.
    static func refreshComponent(for identity: String, in db: Database) throws {
        let ids = try componentIDs(for: identity, in: db)
        guard ids.count > 1 else { return }
        let terminal = try resolveTerminal(identity, in: db)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(ids)
        let ratingRow = try Row.fetchOne(db, sql: "SELECT rating, rating_rev FROM track_annotations WHERE track_sync_id IN (\(placeholders)) ORDER BY rating_rev DESC, track_sync_id LIMIT 1", arguments: args)
        let favoriteRow = try Row.fetchOne(db, sql: "SELECT favorite, favorite_rev FROM track_annotations WHERE track_sync_id IN (\(placeholders)) ORDER BY favorite_rev DESC, track_sync_id LIMIT 1", arguments: args)
        let rating: Int? = ratingRow?["rating"]
        let ratingRev: String? = ratingRow?["rating_rev"]
        let favorite: Bool? = favoriteRow?["favorite"]
        let favoriteRev: String? = favoriteRow?["favorite_rev"]
        try db.execute(sql: "INSERT INTO track_annotations (track_sync_id,rating,rating_rev,favorite,favorite_rev) VALUES (?,?,?,?,?) ON CONFLICT(track_sync_id) DO UPDATE SET rating=excluded.rating,rating_rev=excluded.rating_rev,favorite=excluded.favorite,favorite_rev=excluded.favorite_rev", arguments: [terminal,rating,ratingRev,favorite,favoriteRev])
        let count = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(count),0) FROM play_counters WHERE track_sync_id IN (\(placeholders))", arguments: args) ?? 0
        let last = try Date.fetchOne(db, sql: "SELECT MAX(last_played_at) FROM play_counters WHERE track_sync_id IN (\(placeholders))", arguments: args)
        for id in ids {
            try db.execute(sql: "UPDATE tracks SET rating=?,rating_rev=?,is_favorite=COALESCE(?,0),favorite_rev=?,play_count=?,last_played_at=?,merged_into=? WHERE track_sync_id=?", arguments: [rating,ratingRev,favorite,favoriteRev,count,last,id == terminal ? nil : terminal,id])
        }
        // Keep membership's original portable identity before choosing another
        // available physical file as its local UI/playback representation.
        try db.execute(sql: """
            INSERT OR IGNORE INTO synced_playlist_entries
                (playlist_entry_id,playlist_sync_id,track_sync_id,ordering_key,ordering_key_rev,created_at,deleted_at)
            SELECT pt.playlist_entry_id,p.playlist_sync_id,t.track_sync_id,
                   pt.ordering_key,pt.ordering_key_rev,COALESCE(pt.created_at,p.date_created),pt.deleted_at
            FROM playlist_tracks pt JOIN playlists p ON p.id=pt.playlist_id JOIN tracks t ON t.id=pt.track_id
            WHERE t.track_sync_id IN (\(placeholders)) AND pt.playlist_entry_id != ''
            """, arguments: args)
        if let preferred = try preferredLocalTrack(for: identity, in: db) {
            try db.execute(sql: "UPDATE playlist_tracks SET track_id=? WHERE track_id IN (SELECT id FROM tracks WHERE track_sync_id IN (\(placeholders)))", arguments: StatementArguments([preferred]) + args)
        }
    }

    static func refreshRedirectedComponents(in db: Database) throws {
        let aliases = try String.fetchAll(db, sql: "SELECT track_sync_id FROM logical_tracks WHERE merged_into IS NOT NULL")
        var refreshed = Set<String>()
        for alias in aliases {
            let root = try resolveTerminal(alias, in: db)
            if refreshed.insert(root).inserted { try refreshComponent(for: root, in: db) }
        }
    }

    static func preferredLocalTrack(for identity: String, in db: Database) throws -> Int64? {
        let ids = try componentIDs(for: identity, in: db)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE track_sync_id IN (\(placeholders)) ORDER BY availability_status='available' DESC, track_sync_id, id LIMIT 1", arguments: StatementArguments(ids))
    }

    static func compactMergeChains(in db: Database) throws {
        let identities = try String.fetchAll(db, sql: "SELECT track_sync_id FROM logical_tracks WHERE merged_into IS NOT NULL")
        for identity in identities {
            let terminal = try resolveTerminal(identity, in: db)
            try db.execute(sql: "UPDATE logical_tracks SET merged_into = ? WHERE track_sync_id = ?", arguments: [terminal, identity])
            try db.execute(sql: "UPDATE tracks SET merged_into = ? WHERE track_sync_id = ?", arguments: [terminal, identity])
        }
    }

    /// Explicitly associates one physical file with an existing logical track.
    /// The caller owns user confirmation; this method never performs fuzzy matching.
    static func relink(physicalFileID: String, to targetIdentity: String, in db: Database) throws {
        let target = try resolveTerminal(targetIdentity, in: db)
        try db.execute(sql: "UPDATE physical_files SET track_sync_id = ?, id_state = 'absent' WHERE physical_file_id = ?", arguments: [target, physicalFileID])
        guard db.changesCount == 1 else { throw IdentityRepositoryError.unknownTrack(physicalFileID) }
        try db.execute(sql: "UPDATE tracks SET track_sync_id = ?, id_state = 'absent' WHERE physical_file_id = ?", arguments: [target, physicalFileID])
        try db.execute(sql: """
            INSERT INTO tagging_jobs (physical_file_id, state, may_replace_existing_identity, attempts)
            VALUES (?, 'pending', 1, 0)
            ON CONFLICT(physical_file_id) DO UPDATE SET
                state = 'pending', may_replace_existing_identity = 1, last_error = NULL
        """, arguments: [physicalFileID])
    }

}

struct RecoveryCandidate: Identifiable, Equatable, Sendable {
    let physicalFileID: String
    let trackSyncID: String
    let relativePath: String
    let score: Int
    var id: String { physicalFileID }
}

enum RecoveryCandidateFinder {
    /// Produces suggestions only. No candidate is ever applied automatically.
    static func candidates(for unavailableTrackID: String, in db: Database, limit: Int = 20) throws -> [RecoveryCandidate] {
        guard let source = try Row.fetchOne(db, sql: "SELECT * FROM logical_tracks WHERE track_sync_id = ?", arguments: [unavailableTrackID]) else {
            throw IdentityRepositoryError.unknownTrack(unavailableTrackID)
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT pf.physical_file_id, pf.track_sync_id, pf.relative_path,
                   lt.title, lt.artist, lt.album, lt.track_number, lt.disc_number, lt.duration_ms
            FROM physical_files pf JOIN logical_tracks lt USING(track_sync_id)
            WHERE pf.track_sync_id != ? AND pf.id_state IN ('absent', 'unsupported', 'unwritable', 'unknown')
        """, arguments: [unavailableTrackID])

        func normalized(_ value: String?) -> String { value?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? "" }
        return rows.map { row in
            var score = 0
            if normalized(row["title"] as String?) == normalized(source["title"] as String?) { score += 30 }
            if normalized(row["artist"] as String?) == normalized(source["artist"] as String?) { score += 20 }
            if normalized(row["album"] as String?) == normalized(source["album"] as String?) { score += 20 }
            if (row["track_number"] as Int?) == (source["track_number"] as Int?) { score += 10 }
            if (row["disc_number"] as Int?) == (source["disc_number"] as Int?) { score += 5 }
            let lhs: Int = row["duration_ms"] ?? 0
            let rhs: Int = source["duration_ms"] ?? 0
            if abs(lhs - rhs) <= 2_000 { score += 30 }
            return RecoveryCandidate(
                physicalFileID: row["physical_file_id"],
                trackSyncID: row["track_sync_id"],
                relativePath: row["relative_path"],
                score: score
            )
        }
        .filter { $0.score > 0 }
        .sorted { $0.score == $1.score ? $0.physicalFileID < $1.physicalFileID : $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}
