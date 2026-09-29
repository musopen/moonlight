// MetadataArchive.swift
//
// Backs up and restores the user's personal music data (ratings, favorites, play counts and
// playlists) to a standalone file, without touching the audio files themselves. It also makes
// automatic daily backups and safety copies before risky changes, and deletes old ones on a
// schedule.

import Darwin
import Foundation
import GRDB

enum MetadataArchiveError: LocalizedError {
    case invalidDestination
    case validationFailed
    case unsupportedSchema(Int)
    case missingReference(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination: "The metadata export destination is invalid."
        case .validationFailed: "The completed metadata archive could not be validated."
        case .unsupportedSchema(let version): "Metadata archive schema \(version) is not supported."
        case .missingReference(let value): "The metadata archive contains an unresolved reference: \(value)."
        }
    }
}

struct MetadataArchiveSummary: Identifiable, Sendable {
    let url: URL
    let createdAt: Date
    let recordCount: Int
    var id: URL { url }
}

enum MetadataArchiveWorker {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .utility, operation: operation).value
    }
}

enum MetadataArchive {
    typealias ArchiveInstaller = (_ temporary: URL, _ destination: URL, _ fileManager: FileManager) throws -> Void

    static func export(
        to destination: URL,
        from manager: DatabaseManager,
        createdAt: Date = Date(),
        fileManager: FileManager = .default,
        install: ArchiveInstaller = installArchive
    ) throws {
        guard destination.isFileURL else { throw MetadataArchiveError.invalidDestination }
        let records = try manager.read { db -> [[String: Any]] in
            var output: [[String: Any]] = [[
                "type": "moonlight-metadata",
                "schemaVersion": 1,
                "createdAt": ISO8601DateFormatter().string(from: createdAt)
            ]]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM logical_tracks ORDER BY track_sync_id") {
                output.append(["type": "logicalTrack", "value": jsonObject(row)])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM track_annotations ORDER BY track_sync_id") {
                output.append(["type": "annotation", "value": jsonObject(row)])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM playlists ORDER BY playlist_sync_id") {
                output.append(["type": "playlist", "value": jsonObject(row)])
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT pt.playlist_entry_id, p.playlist_sync_id, COALESCE(se.track_sync_id,t.track_sync_id) AS track_sync_id,
                       pt.ordering_key, pt.ordering_key_rev, pt.created_at, pt.deleted_at
                FROM playlist_tracks pt
                JOIN playlists p ON p.id = pt.playlist_id
                JOIN tracks t ON t.id = pt.track_id
                LEFT JOIN synced_playlist_entries se ON se.playlist_entry_id=pt.playlist_entry_id
                ORDER BY pt.playlist_id, pt.ordering_key, pt.playlist_entry_id
            """) {
                output.append(["type": "playlistEntry", "value": jsonObject(row)])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM play_counters ORDER BY track_sync_id, device_id") {
                output.append(["type": "playCounter", "value": jsonObject(row)])
            }
            var header = output[0]
            header["recordCount"] = output.count - 1
            output[0] = header
            return output
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try validate(temporary)
        try install(temporary, destination, fileManager)
    }

    private static func installArchive(_ temporary: URL, _ destination: URL, _ fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    static func validate(_ url: URL) throws {
        _ = try read(url)
    }

    static func summary(of url: URL) throws -> MetadataArchiveSummary {
        let document = try read(url)
        return MetadataArchiveSummary(url: url, createdAt: document.createdAt, recordCount: document.records.count)
    }

    /// Restores synchronized metadata atomically. Audio catalog rows and physical
    /// availability remain local; unavailable tracks referenced by the archive are
    /// materialized as intentional stubs. A recovery point is written first.
    static func restore(from source: URL, to manager: DatabaseManager, createSafetySnapshot: Bool = true) throws {
        let document = try read(source)
        if createSafetySnapshot {
            _ = try MetadataSnapshotStore.createRecoveryPoint(from: manager, label: "before-restore")
        }
        try manager.write { db in
                try db.execute(sql: "DELETE FROM track_annotations")
                try db.execute(sql: "DELETE FROM playlist_tracks")
                try db.execute(sql: "DELETE FROM synced_playlist_entries")
                try db.execute(sql: "DELETE FROM playlists")
                try db.execute(sql: "DELETE FROM play_counters")
                try db.execute(sql: "UPDATE logical_tracks SET is_promoted = 0, merged_into = NULL")
                try db.execute(sql: "UPDATE tracks SET rating = NULL, rating_rev = NULL, is_favorite = 0, favorite_rev = NULL, play_count = 0, last_played_at = NULL, is_promoted = 0")

                // Seed identities before installing any legacy forward edges;
                // SQLite checks this self-reference immediately, not at commit.
                for record in document.records where record.type == "logicalTrack" {
                    guard let id = string(record.value, "track_sync_id") else { throw MetadataArchiveError.validationFailed }
                    try ensureLogicalTrack(id: id, in: db, createdAt: document.createdAt)
                    if let target = string(record.value, "merged_into") {
                        try ensureLogicalTrack(id: target, in: db, createdAt: document.createdAt)
                    }
                }
                for record in document.records where record.type == "logicalTrack" {
                    let value = record.value
                    guard let id = string(value, "track_sync_id") else { throw MetadataArchiveError.validationFailed }
                    try db.execute(sql: """
                        INSERT INTO logical_tracks
                            (track_sync_id, title, artist, album, album_artist, genre, track_number,
                             disc_number, year, duration_ms, is_promoted, metadata_rev, created_at, merged_into)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(track_sync_id) DO UPDATE SET
                            title=excluded.title, artist=excluded.artist, album=excluded.album,
                            album_artist=excluded.album_artist, genre=excluded.genre,
                            track_number=excluded.track_number, disc_number=excluded.disc_number,
                            year=excluded.year, duration_ms=excluded.duration_ms,
                            is_promoted=excluded.is_promoted, metadata_rev=excluded.metadata_rev,
                            merged_into=excluded.merged_into
                    """, arguments: [
                        id, string(value, "title"), string(value, "artist"), string(value, "album"),
                        string(value, "album_artist"), string(value, "genre"), integer(value, "track_number"),
                        integer(value, "disc_number"), integer(value, "year"), integer(value, "duration_ms"),
                        boolean(value, "is_promoted") ?? false, string(value, "metadata_rev"),
                        date(value, "created_at") ?? document.createdAt, string(value, "merged_into")
                    ])
                    try ensureCompatibilityTrack(id: id, value: value, in: db)
                }

                for record in document.records where record.type == "annotation" {
                    let value = record.value
                    guard let id = string(value, "track_sync_id") else { throw MetadataArchiveError.validationFailed }
                    try ensureLogicalTrack(id: id, in: db, createdAt: document.createdAt)
                    try ensureCompatibilityTrack(id: id, value: value, in: db)
                    try db.execute(sql: """
                        INSERT INTO track_annotations (track_sync_id, rating, rating_rev, favorite, favorite_rev)
                        VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, integer(value, "rating"), string(value, "rating_rev"), boolean(value, "favorite"), string(value, "favorite_rev")])
                }

                for record in document.records where record.type == "playlist" {
                    let value = record.value
                    guard let id = string(value, "playlist_sync_id") else { throw MetadataArchiveError.validationFailed }
                    try db.execute(sql: """
                        INSERT INTO playlists
                            (name, date_created, date_modified, playlist_sync_id, kind, name_rev,
                             sort_mode, sort_mode_rev, rule, rule_rev, deleted_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        string(value, "name") ?? "Untitled Playlist",
                        date(value, "date_created") ?? document.createdAt,
                        date(value, "date_modified") ?? document.createdAt,
                        id, string(value, "kind") ?? "manual", string(value, "name_rev") ?? "",
                        string(value, "sort_mode") ?? "manual", string(value, "sort_mode_rev") ?? "",
                        string(value, "rule"), string(value, "rule_rev"), date(value, "deleted_at")
                    ])
                }

                for record in document.records where record.type == "playlistEntry" {
                    let value = record.value
                    guard let entryID = string(value, "playlist_entry_id"),
                          let playlistID = string(value, "playlist_sync_id"),
                          let trackID = string(value, "track_sync_id"),
                          let localPlaylistID = try Int64.fetchOne(db, sql: "SELECT id FROM playlists WHERE playlist_sync_id = ?", arguments: [playlistID])
                    else { throw MetadataArchiveError.missingReference("playlist entry") }
                    try ensureLogicalTrack(id: trackID, in: db, createdAt: document.createdAt)
                    try ensureCompatibilityTrack(id: trackID, value: value, in: db)
                    guard let localTrackID = try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE track_sync_id = ? ORDER BY availability_status = 'available' DESC LIMIT 1", arguments: [trackID]) else {
                        throw MetadataArchiveError.missingReference(trackID)
                    }
                    let fallbackPosition = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?",
                        arguments: [localPlaylistID]
                    ) ?? 0
                    let orderingKey = string(value, "ordering_key") ?? FractionalOrderingKey.initial(at: fallbackPosition)
                    try db.execute(sql: "INSERT INTO synced_playlist_entries (playlist_entry_id,playlist_sync_id,track_sync_id,ordering_key,ordering_key_rev,created_at,deleted_at) VALUES (?,?,?,?,?,?,?)", arguments: [entryID,playlistID,trackID,orderingKey,string(value,"ordering_key_rev") ?? "",date(value,"created_at") ?? document.createdAt,date(value,"deleted_at")])
                    try db.execute(sql: """
                        INSERT INTO playlist_tracks
                            (playlist_id, track_id, position, playlist_entry_id, ordering_key,
                             ordering_key_rev, created_at, deleted_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        localPlaylistID, localTrackID, 0, entryID, orderingKey,
                        string(value, "ordering_key_rev") ?? "",
                        date(value, "created_at") ?? document.createdAt,
                        date(value, "deleted_at")
                    ])
                }

                try SyncRecordApplier.recomputePositions(in: db)

                for record in document.records where record.type == "playCounter" {
                    let value = record.value
                    guard let trackID = string(value, "track_sync_id"), let deviceID = string(value, "device_id") else {
                        throw MetadataArchiveError.validationFailed
                    }
                    try ensureLogicalTrack(id: trackID, in: db, createdAt: document.createdAt)
                    try ensureCompatibilityTrack(id: trackID, value: value, in: db)
                    try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, ?, ?, ?)", arguments: [trackID, deviceID, integer(value, "count") ?? 0, date(value, "last_played_at")])
                }

                try db.execute(sql: """
                    UPDATE tracks SET
                        rating = (SELECT rating FROM track_annotations WHERE track_sync_id = tracks.track_sync_id),
                        rating_rev = (SELECT rating_rev FROM track_annotations WHERE track_sync_id = tracks.track_sync_id),
                        is_favorite = COALESCE((SELECT favorite FROM track_annotations WHERE track_sync_id = tracks.track_sync_id), 0),
                        favorite_rev = (SELECT favorite_rev FROM track_annotations WHERE track_sync_id = tracks.track_sync_id),
                        play_count = COALESCE((SELECT SUM(count) FROM play_counters WHERE track_sync_id = tracks.track_sync_id), 0),
                        last_played_at = (SELECT MAX(last_played_at) FROM play_counters WHERE track_sync_id = tracks.track_sync_id),
                        is_promoted = COALESCE((SELECT is_promoted FROM logical_tracks WHERE track_sync_id = tracks.track_sync_id), 0)
                """)
                try IdentityRepository.refreshRedirectedComponents(in: db)
                try db.execute(sql: "DELETE FROM sync_outbox")
                try SyncOutbox.enqueueCompleteState(in: db)
                try SyncEligibility.quarantineIneligibleOutbox(in: db)
        }
    }

    private static func jsonObject(_ row: Row) -> [String: Any] {
        var object: [String: Any] = [:]
        for (column, databaseValue) in row {
            if databaseValue.isNull { object[column] = NSNull(); continue }
            if let value = String.fromDatabaseValue(databaseValue) { object[column] = value; continue }
            if let value = Int64.fromDatabaseValue(databaseValue) { object[column] = value; continue }
            if let value = Double.fromDatabaseValue(databaseValue) { object[column] = value; continue }
            if let value = Data.fromDatabaseValue(databaseValue) { object[column] = value.base64EncodedString() }
        }
        return object
    }

    private struct ArchiveRecord {
        let type: String
        let value: [String: Any]
    }

    private struct ArchiveDocument {
        let createdAt: Date
        let records: [ArchiveRecord]
    }

    private static func read(_ url: URL) throws -> ArchiveDocument {
        guard url.isFileURL else { throw MetadataArchiveError.invalidDestination }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        guard let first = lines.first,
              let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              header["type"] as? String == "moonlight-metadata",
              let schemaVersion = header["schemaVersion"] as? Int else {
            throw MetadataArchiveError.validationFailed
        }
        guard schemaVersion == 1 else { throw MetadataArchiveError.unsupportedSchema(schemaVersion) }
        let formatter = ISO8601DateFormatter()
        guard let createdString = header["createdAt"] as? String,
              let createdAt = formatter.date(from: createdString) else { throw MetadataArchiveError.validationFailed }
        guard let expectedRecordCount = header["recordCount"] as? Int else {
            throw MetadataArchiveError.validationFailed
        }
        let allowed = Set(["logicalTrack", "annotation", "playlist", "playlistEntry", "playCounter"])
        let records = try lines.dropFirst().map { line -> ArchiveRecord in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String,
                  allowed.contains(type),
                  let value = object["value"] as? [String: Any] else {
                throw MetadataArchiveError.validationFailed
            }
            return ArchiveRecord(type: type, value: value)
        }
        guard records.count == expectedRecordCount else { throw MetadataArchiveError.validationFailed }
        return ArchiveDocument(createdAt: createdAt, records: records)
    }

    private static func string(_ value: [String: Any], _ key: String) -> String? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        return raw as? String
    }

    private static func integer(_ value: [String: Any], _ key: String) -> Int? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private static func boolean(_ value: [String: Any], _ key: String) -> Bool? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        if let boolean = raw as? Bool { return boolean }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return string == "1" || string.lowercased() == "true" }
        return nil
    }

    private static func date(_ value: [String: Any], _ key: String) -> Date? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        if let number = raw as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = raw as? String else { return nil }
        if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
        if let iso = ISO8601DateFormatter().date(from: string) { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: string)
    }

    private static func ensureLogicalTrack(id: String, in db: Database, createdAt: Date) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO logical_tracks (track_sync_id, created_at) VALUES (?, ?)", arguments: [id, createdAt])
    }

    private static func ensureCompatibilityTrack(id: String, value: [String: Any], in db: Database) throws {
        guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE track_sync_id = ?", arguments: [id]) ?? 0) == 0 else { return }
        try db.execute(sql: """
            INSERT INTO tracks
                (file_url, availability_status, title, artist, album, duration, date_added,
                 track_sync_id, physical_file_id, id_state, is_promoted)
            VALUES (?, 'unavailable', ?, ?, ?, ?, ?, ?, ?, 'unsupported', ?)
        """, arguments: [
            "moonlight-unavailable://\(id)", string(value, "title"), string(value, "artist"),
            string(value, "album"), Double(integer(value, "duration_ms") ?? 0) / 1_000,
            Date(), id, "STUB-\(id)", boolean(value, "is_promoted") ?? true
        ])
    }
}

enum MetadataSnapshotStore {
    static func directory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Moonlight/MetadataSnapshots", isDirectory: true)
    }

    static func createIfDue(from manager: DatabaseManager, now: Date = Date(), fileManager: FileManager = .default) throws -> URL? {
        let directory = directory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "ndjson" }
        let newestDate = existing.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.compactMap { $0 }.max()
        guard newestDate == nil || now.timeIntervalSince(newestDate!) >= 24 * 60 * 60 else { return nil }

        let destination = directory.appendingPathComponent("moonlight-metadata-\(Int(now.timeIntervalSince1970)).ndjson")
        try MetadataArchive.export(to: destination, from: manager, createdAt: now)
        try prune(directory: directory, now: now, fileManager: fileManager)
        return destination
    }

    static func createRecoveryPoint(from manager: DatabaseManager, label: String, now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let directory = directory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let destination = directory.appendingPathComponent("moonlight-\(safeLabel)-\(Int(now.timeIntervalSince1970)).ndjson")
        try MetadataArchive.export(to: destination, from: manager, createdAt: now)
        return destination
    }

    static func snapshots(fileManager: FileManager = .default) throws -> [MetadataArchiveSummary] {
        let directory = directory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "ndjson" }
            .compactMap { try? MetadataArchive.summary(of: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Prunes automatic daily snapshots only. Manual and before-* recovery points
    /// never compete with the daily/weekly/monthly retention budget.
    static func prune(directory: URL, now: Date, fileManager: FileManager) throws {
        let calendar = Calendar(identifier: .gregorian)
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "ndjson" && $0.lastPathComponent.hasPrefix("moonlight-metadata-") }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        var keep = Set(dated.prefix(7).map { $0.0 })
        var weeks = Set<String>()
        var months = Set<String>()
        for (url, date) in dated.dropFirst(7) {
            let age = now.timeIntervalSince(date)
            if age <= 8 * 7 * 86_400 {
                let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                let key = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
                if weeks.insert(key).inserted { keep.insert(url) }
            } else if age <= 366 * 86_400 {
                let components = calendar.dateComponents([.year, .month], from: date)
                let key = "\(components.year ?? 0)-\(components.month ?? 0)"
                if months.insert(key).inserted { keep.insert(url) }
            }
        }
        for (url, _) in dated where !keep.contains(url) { try fileManager.removeItem(at: url) }
    }
}
