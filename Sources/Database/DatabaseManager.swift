// DatabaseManager.swift
//
// Opens the music library database, a single file on disk that stores the catalog, playlists,
// ratings and settings. It creates the file on first launch, brings older versions up to date, and
// gives the rest of the app a safe way to read from and write to it.

import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    init(path: String? = nil) throws {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let appDir = appSupport.appendingPathComponent("Moonlight", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            dbPath = appDir.appendingPathComponent("library.sqlite").path
        }

        var config = Configuration()
        config.label = "org.musopen.moonlight"
        config.prepareDatabase { db in
            // journal_mode cannot be changed inside a transaction — set it below
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        configureWALMode()
        try Migrator.migrate(dbQueue)
        runRequestedStorageMaintenance()
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    private func configureWALMode() {
        let journalMode = (try? dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        })?.lowercased()

        guard journalMode != "wal" else { return }

        do {
            try dbQueue.writeWithoutTransaction { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            }
        } catch {
            NSLog("Moonlight: unable to switch database to WAL mode: \(error)")
        }
    }

    /// Reclaims space only after a migration explicitly requests it. Running VACUUM
    /// after every scan would block readers and create unnecessary write amplification.
    private func runRequestedStorageMaintenance() {
        let isNeeded = (try? read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = 'artwork_storage_maintenance_needed'"
            )
        }) == "1"
        guard isNeeded else { return }

        do {
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
                try db.execute(sql: "PRAGMA optimize")
            }
            try write { db in
                try db.execute(sql: "DELETE FROM settings WHERE key = 'artwork_storage_maintenance_needed'")
            }
        } catch {
            NSLog("Moonlight: unable to reclaim database storage: \(error)")
        }
    }
}
