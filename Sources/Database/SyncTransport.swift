// SyncTransport.swift
//
// Packages library changes (songs, playlists, playlist entries and play counts) into simple
// records that can be sent between devices, independent of iCloud itself. This lets sync behavior
// be tested on a computer without a real iCloud account, and feeds the records to the merge logic.

import Foundation
import GRDB

/// Cloud-provider-neutral records used by the deterministic two-store harness.
/// Keeping this layer free of CKRecord also makes conflict behavior testable in CI.
enum SyncTransportRecord: Equatable, Sendable {
    case track(TrackPayload)
    case playlist(PlaylistPayload)
    case entry(EntryPayload)
    case counter(CounterPayload)

    var key: String {
        switch self {
        case .track(let value): "SyncedTrack:track_\(value.id)"
        case .playlist(let value): "Playlist:playlist_\(value.id)"
        case .entry(let value): "PlaylistEntry:entry_\(value.id)"
        case .counter(let value): "PlayCounter:count_\(value.trackID)_\(value.deviceID)"
        }
    }

    var recordName: String {
        key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
    }

    struct TrackPayload: Equatable, Sendable {
        var id: String
        var rating: Int?
        var ratingRev: String?
        var favorite: Bool?
        var favoriteRev: String?
        var title: String?
        var artist: String?
        var album: String?
        var metadataRev: String?
        var mergedInto: String?
    }

    struct PlaylistPayload: Equatable, Sendable {
        var id: String
        var name: String
        var nameRev: String
        var kind: String
        var sortMode: String
        var sortModeRev: String
        var rule: String?
        var ruleRev: String?
        var createdAt: Date
        var deletedAt: Date?
    }

    struct EntryPayload: Equatable, Sendable {
        var id: String
        var playlistID: String
        var trackID: String
        var orderingKey: String
        var orderingKeyRev: String
        var createdAt: Date
        var deletedAt: Date?
    }

    struct CounterPayload: Equatable, Sendable {
        var trackID: String
        var deviceID: String
        var count: Int
        var lastPlayedAt: Date?
    }
}

struct PendingSyncTransportRecord: Equatable, Sendable {
    let record: SyncTransportRecord
    let outboxItem: SyncOutbox.PendingItem
}

enum SQLiteSyncTransport {
    static func pending(in db: Database) throws -> [PendingSyncTransportRecord] {
        let rows = try Row.fetchAll(db, sql: "SELECT record_type, record_name, generation FROM sync_outbox ORDER BY enqueued_at, coalesce_key")
        return try rows.compactMap { row in
            let recordType: String = row["record_type"]
            let recordName: String = row["record_name"]
            guard let record = try record(type: recordType, name: recordName, in: db) else { return nil }
            return PendingSyncTransportRecord(
                record: record,
                outboxItem: .init(recordType: recordType, recordName: recordName, generation: row["generation"])
            )
        }
    }

    static func snapshot(in db: Database) throws -> [SyncTransportRecord] {
        var result: [SyncTransportRecord] = []
        for id in try String.fetchAll(db, sql: "SELECT track_sync_id FROM logical_tracks WHERE is_promoted = 1") {
            if let value = try record(type: "SyncedTrack", name: "track_\(id)", in: db) { result.append(value) }
        }
        for id in try String.fetchAll(db, sql: "SELECT playlist_sync_id FROM playlists WHERE playlist_sync_id != ''") {
            if let value = try record(type: "Playlist", name: "playlist_\(id)", in: db) { result.append(value) }
        }
        for id in try String.fetchAll(db, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE playlist_entry_id != ''") {
            if let value = try record(type: "PlaylistEntry", name: "entry_\(id)", in: db) { result.append(value) }
        }
        for row in try Row.fetchAll(db, sql: "SELECT track_sync_id, device_id FROM play_counters") {
            let trackID: String = row["track_sync_id"]
            let deviceID: String = row["device_id"]
            if let value = try record(type: "PlayCounter", name: "count_\(trackID)_\(deviceID)", in: db) { result.append(value) }
        }
        return result
    }

    static func acknowledge(_ records: [PendingSyncTransportRecord], in db: Database) throws {
        for record in records {
            try SyncOutbox.acknowledge(record.outboxItem, in: db)
        }
    }

    static func apply(_ records: [PendingSyncTransportRecord], to db: Database, receivedAt: Date = Date()) throws {
        try SyncRecordApplier.apply(records.map(\.record), to: db, receivedAt: receivedAt)
    }

    static func apply(_ records: [SyncTransportRecord], to db: Database, receivedAt: Date = Date()) throws {
        try SyncRecordApplier.apply(records, to: db, receivedAt: receivedAt)
    }

    private static func record(type: String, name: String, in db: Database) throws -> SyncTransportRecord? {
        guard try SyncEligibility.allows(recordType: type, recordName: name, in: db) else { return nil }
        switch type {
        case "SyncedTrack":
            let id = String(name.dropFirst("track_".count))
            guard let row = try Row.fetchOne(db, sql: "SELECT lt.*, ta.rating, ta.rating_rev, ta.favorite, ta.favorite_rev FROM logical_tracks lt LEFT JOIN track_annotations ta USING(track_sync_id) WHERE lt.track_sync_id = ?", arguments: [id]) else { return nil }
            let payload = SyncTransportRecord.TrackPayload(
                id: id,
                rating: row["rating"] as Int?, ratingRev: row["rating_rev"] as String?,
                favorite: row["favorite"] as Bool?, favoriteRev: row["favorite_rev"] as String?,
                mergedInto: row["merged_into"] as String?
            )
            return .track(payload)
        case "Playlist":
            let id = String(name.dropFirst("playlist_".count))
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM playlists WHERE playlist_sync_id = ?", arguments: [id]) else { return nil }
            let payload = SyncTransportRecord.PlaylistPayload(
                id: id, name: row["name"] as String,
                nameRev: row["name_rev"] as String? ?? "", kind: row["kind"] as String? ?? "manual",
                sortMode: row["sort_mode"] as String? ?? "manual", sortModeRev: row["sort_mode_rev"] as String? ?? "",
                rule: row["rule"] as String?, ruleRev: row["rule_rev"] as String?,
                createdAt: row["date_created"] as Date, deletedAt: row["deleted_at"] as Date?
            )
            return .playlist(payload)
        case "PlaylistEntry":
            let id = String(name.dropFirst("entry_".count))
            guard let row = try Row.fetchOne(db, sql: "SELECT pt.*, p.playlist_sync_id, COALESCE(se.track_sync_id,t.track_sync_id) AS track_sync_id FROM playlist_tracks pt JOIN playlists p ON p.id = pt.playlist_id JOIN tracks t ON t.id = pt.track_id LEFT JOIN synced_playlist_entries se ON se.playlist_entry_id=pt.playlist_entry_id WHERE pt.playlist_entry_id = ?", arguments: [id]) else { return nil }
            let payload = SyncTransportRecord.EntryPayload(
                id: id, playlistID: row["playlist_sync_id"] as String, trackID: row["track_sync_id"] as String,
                orderingKey: row["ordering_key"] as String? ?? "U", orderingKeyRev: row["ordering_key_rev"] as String? ?? "",
                createdAt: row["created_at"] as Date? ?? Date(), deletedAt: row["deleted_at"] as Date?
            )
            return .entry(payload)
        case "PlayCounter":
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM play_counters WHERE 'count_' || track_sync_id || '_' || device_id = ?", arguments: [name]) else { return nil }
            return .counter(.init(trackID: row["track_sync_id"], deviceID: row["device_id"], count: row["count"], lastPlayedAt: row["last_played_at"]))
        default: return nil
        }
    }

}
