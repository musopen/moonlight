// RadioUserState.swift
//
// Stores the user's own radio data, mainly favorite stations, in a small writable database kept
// separate from the built-in station list. On first run it also moves favorites over from the
// older radio database, and keeps any it cannot match so the user can find them again by hand.

import Foundation
import GRDB

struct UnresolvedRadioFavorite: Identifiable, Sendable {
    let stationUUID: String
    let name: String?
    let addedAt: Date
    var id: String { stationUUID }
}

/// Only user state is writable. The reviewed catalog stays in the bundle.
final class RadioUserState: @unchecked Sendable {
    private let queue: DatabaseQueue
    private let directory: URL
    private let legacyURL: URL
    private let legacyBackupURL: URL
    private let catalog: ReviewedRadioCatalog
    private let beforeLegacyCleanup: (() throws -> Void)?
    private let beforeMigrationCommit: (() throws -> Void)?

    init(
        catalog: ReviewedRadioCatalog,
        directory: URL? = nil,
        beforeLegacyCleanup: (() throws -> Void)? = nil,
        beforeMigrationCommit: (() throws -> Void)? = nil
    ) throws {
        guard let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Moonlight", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.catalog = catalog
        self.directory = directory
        self.legacyURL = directory.appendingPathComponent("radio.sqlite")
        self.legacyBackupURL = directory.appendingPathComponent("radio.sqlite.migration-backup")
        self.beforeLegacyCleanup = beforeLegacyCleanup
        self.beforeMigrationCommit = beforeMigrationCommit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "org.musopen.moonlight.radio-user-state"
        queue = try DatabaseQueue(path: directory.appendingPathComponent("radio-user-state.sqlite").path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS favorites(channel_id TEXT PRIMARY KEY, stationuuid TEXT NOT NULL, added_at DATETIME NOT NULL) WITHOUT ROWID")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS unresolved_favorites(stationuuid TEXT PRIMARY KEY, name TEXT, added_at DATETIME NOT NULL) WITHOUT ROWID")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS state_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        }
        try migrateLegacyIfNeeded()
    }

    func favoriteChannelIDs() throws -> Set<String> {
        try queue.read { Set(try String.fetchAll($0, sql: "SELECT channel_id FROM favorites")) }
    }

    func unresolvedFavorites() throws -> [UnresolvedRadioFavorite] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT stationuuid,name,added_at FROM unresolved_favorites ORDER BY added_at DESC").map { row in
                UnresolvedRadioFavorite(stationUUID: row["stationuuid"], name: row["name"], addedAt: row["added_at"])
            }
        }
    }

    func favoriteStations() throws -> [RadioStation] {
        let ids = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT channel_id FROM favorites ORDER BY added_at DESC")
        }
        return try ids.compactMap { try catalog.fetchStation(channelID: $0) }
    }

    func addFavorite(_ station: RadioStation, at date: Date = Date()) throws {
        guard let channelID = station.channelID else { return }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(channel_id,stationuuid,added_at) VALUES (?,?,?) ON CONFLICT(channel_id) DO NOTHING", arguments: [channelID, station.stationUUID, date])
        }
    }

    func removeFavorite(channelID: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM favorites WHERE channel_id=?", arguments: [channelID]) }
    }

    func removeUnresolvedFavorite(stationUUID: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM unresolved_favorites WHERE stationuuid=?", arguments: [stationUUID]) }
    }

    private func migrateLegacyIfNeeded() throws {
        try catalog.validate()
        let completed = try queue.read {
            try String.fetchOne($0, sql: "SELECT value FROM state_metadata WHERE key='legacy_migration_version'") == "1"
        }
        if completed {
            // A crash after the final state commit may leave only cleanup work.
            try? FileManager.default.removeItem(at: legacyBackupURL)
            return
        }
        if FileManager.default.fileExists(atPath: legacyBackupURL.path) {
            // A crash after moving the checkpointed database, but before the
            // final state commit, must leave the original available to retry.
            if !FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.moveItem(at: legacyBackupURL, to: legacyURL)
            } else {
                try FileManager.default.removeItem(at: legacyBackupURL)
            }
        }
        let copied = try queue.read {
            try String.fetchOne($0, sql: "SELECT value FROM state_metadata WHERE key='legacy_copy_version'") == "1"
        }
        if !copied {
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try migrateLegacyFavorites()
            } else {
                return
            }
        }
        try beforeLegacyCleanup?()
        do {
            try stageMigratedLegacyDatabase()
            try removeObsoleteFiles()
            try beforeMigrationCommit?()
            try queue.write { db in
                try db.execute(sql: "INSERT INTO state_metadata(key,value) VALUES ('legacy_migration_version','1') ON CONFLICT(key) DO UPDATE SET value='1'")
            }
        } catch {
            if FileManager.default.fileExists(atPath: legacyBackupURL.path),
               !FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.moveItem(at: legacyBackupURL, to: legacyURL)
            }
            throw error
        }
        // The only remaining file is a checkpointed backup. If deleting it is
        // interrupted, the next launch removes it after seeing the marker.
        try? FileManager.default.removeItem(at: legacyBackupURL)
    }

    private func migrateLegacyFavorites() throws {
        var readonly = Configuration()
        readonly.readonly = true

        let oldFavorites: [(String, Date, String?)] = try {
            let old = try DatabaseQueue(path: legacyURL.path, configuration: readonly)
            return try old.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT f.stationuuid, f.added_at, s.name
                    FROM favorites f LEFT JOIN stations s ON s.stationuuid=f.stationuuid
                """).map { ($0["stationuuid"], $0["added_at"], $0["name"]) }
            }
        }()

        // The slim catalog carries one station UUID per retained stream.
        // It can reconnect those favorites without a separate 65,917-row
        // migration resource. Other UUIDs remain saved for manual re-favoriting.
        let directMappings: [String: String] = try catalog.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT stationuuid, MIN(channel_id) AS channel_id
                FROM streams WHERE stationuuid IS NOT NULL AND stationuuid <> ''
                GROUP BY stationuuid HAVING COUNT(DISTINCT channel_id) = 1
            """)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["stationuuid"] as String, $0["channel_id"] as String)
            })
        }

        var mapped: [(String, String, Date)] = []
        var unresolved: [UnresolvedRadioFavorite] = []
        for (uuid, addedAt, name) in oldFavorites {
            if let channelID = directMappings[uuid] {
                mapped.append((channelID, uuid, addedAt))
            } else {
                unresolved.append(UnresolvedRadioFavorite(stationUUID: uuid, name: name, addedAt: addedAt))
            }
        }

        // The version marker and every favorite commit together. A failed write
        // leaves the legacy database untouched for the next launch.
        try queue.write { db in
            for (channelID, uuid, addedAt) in mapped {
                try db.execute(sql: """
                    INSERT INTO favorites(channel_id,stationuuid,added_at) VALUES (?,?,?)
                    ON CONFLICT(channel_id) DO UPDATE SET
                        stationuuid=excluded.stationuuid, added_at=excluded.added_at
                    WHERE excluded.added_at < favorites.added_at
                """, arguments: [channelID, uuid, addedAt])
            }
            for favorite in unresolved {
                try db.execute(sql: """
                    INSERT INTO unresolved_favorites(stationuuid,name,added_at) VALUES (?,?,?)
                    ON CONFLICT(stationuuid) DO UPDATE SET
                        name=COALESCE(unresolved_favorites.name, excluded.name),
                        added_at=MIN(unresolved_favorites.added_at, excluded.added_at)
                """, arguments: [favorite.stationUUID, favorite.name, favorite.addedAt])
            }
            let mappedCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM favorites") ?? 0
            let unresolvedCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM unresolved_favorites") ?? 0
            guard mappedCount >= Set(mapped.map { $0.0 }).count,
                  unresolvedCount >= unresolved.count else { throw RadioCatalogError.invalidCatalog }
            try db.execute(sql: "INSERT INTO state_metadata(key,value) VALUES ('legacy_copy_version','1')")
            guard try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_copy_version'") == "1" else {
                throw RadioCatalogError.invalidCatalog
            }
        }
        _ = try favoriteChannelIDs()
        _ = try unresolvedFavorites()
    }

    private func stageMigratedLegacyDatabase() throws {
        // The original is kept as a backup until the final marker commits.
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try {
                let old = try DatabaseQueue(path: legacyURL.path)
                try old.writeWithoutTransaction { db in
                    guard try Int.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") == 0 else {
                        throw RadioCatalogError.legacyCheckpointBusy
                    }
                }
            }()
            try FileManager.default.moveItem(at: legacyURL, to: legacyBackupURL)
        }
    }

    private func removeObsoleteFiles() throws {
        let paths = [legacyURL.path + "-wal", legacyURL.path + "-shm"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        for name in ["radio-directory.json", "radio-stations.json", "radio-countrycodes.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

}
