import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class TwoStoreSyncHarnessTests: XCTestCase {
    private var root: URL!
    private var mac: DatabaseManager!
    private var phone: DatabaseManager!
    private var server: DatabaseManager!
    private let trackID = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let playlistID = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoonlightTwoStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mac = try DatabaseManager(path: root.appendingPathComponent("mac.sqlite").path)
        phone = try DatabaseManager(path: root.appendingPathComponent("phone.sqlite").path)
        server = try DatabaseManager(path: root.appendingPathComponent("server.sqlite").path)
        try seed(mac, deviceID: "MAC")
        try seed(phone, deviceID: "PHONE")
    }

    override func tearDown() async throws {
        mac = nil; phone = nil; server = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testOfflineIndependentFieldsEntriesAndCountersConverge() throws {
        let ratingRev = SyncRevision.make(at: Date(timeIntervalSince1970: 1_000), writerID: "MAC").rawValue
        let favoriteRev = SyncRevision.make(at: Date(timeIntervalSince1970: 1_001), writerID: "PHONE").rawValue
        try mac.write { db in
            try db.execute(sql: "UPDATE track_annotations SET rating=5, rating_rev=? WHERE track_sync_id=?", arguments: [ratingRev, trackID])
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, 'MAC', 3, ?)", arguments: [trackID, Date(timeIntervalSince1970: 1_010)])
            try addEntry("ENTRY-MAC", key: "G", to: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackID)", in: db)
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(trackID)_MAC", in: db)
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_ENTRY-MAC", in: db)
        }
        try phone.write { db in
            try db.execute(sql: "UPDATE track_annotations SET favorite=1, favorite_rev=? WHERE track_sync_id=?", arguments: [favoriteRev, trackID])
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, 'PHONE', 4, ?)", arguments: [trackID, Date(timeIntervalSince1970: 1_011)])
            try addEntry("ENTRY-PHONE", key: "T", to: db)
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackID)", in: db)
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(trackID)_PHONE", in: db)
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_ENTRY-PHONE", in: db)
        }

        try exchange(mac)
        try exchange(phone)
        try broadcast()

        for store in [mac!, phone!] {
            try store.read { db in
                let annotation = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM track_annotations WHERE track_sync_id=?", arguments: [trackID]))
                XCTAssertEqual(annotation["rating"] as Int?, 5)
                XCTAssertEqual(annotation["favorite"] as Bool?, true)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(count) FROM play_counters WHERE track_sync_id=?", arguments: [trackID]), 7)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE deleted_at IS NULL"), 2)
            }
        }
    }

    func testRemoveWinsOverStaleEntryAndOldClientCannotResurrectIt() throws {
        try mac.write { try addEntry("COMMON", key: "U", to: $0) }
        try exchange(mac)
        try broadcast()

        let deletion = Date(timeIntervalSince1970: 2_000)
        try mac.write { db in
            try db.execute(sql: "UPDATE playlist_tracks SET deleted_at=? WHERE playlist_entry_id='COMMON'", arguments: [deletion])
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_COMMON", in: db)
        }
        // The phone is an old offline client and only changes ordering.
        let reorderRev = SyncRevision.make(at: Date(timeIntervalSince1970: 1_500), writerID: "PHONE").rawValue
        try phone.write { db in
            try db.execute(sql: "UPDATE playlist_tracks SET ordering_key='z', ordering_key_rev=? WHERE playlist_entry_id='COMMON'", arguments: [reorderRev])
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_COMMON", in: db)
        }

        try exchange(phone)
        try exchange(mac)
        try broadcast()
        for store in [mac!, phone!] {
            XCTAssertNotNil(try store.read { try Date.fetchOne($0, sql: "SELECT deleted_at FROM playlist_tracks WHERE playlist_entry_id='COMMON'") })
        }
    }

    func testClockSkewedDeletionRemainsMonotonic() throws {
        try mac.write { try addEntry("CLOCK-SKEW", key: "U", to: $0) }
        try exchange(mac)
        try broadcast()

        // The delete clock is behind created_at=100. It must still be a
        // permanent tombstone, even after an old client sends a live reorder.
        let skewedDeletion = Date(timeIntervalSince1970: 50)
        try mac.write { db in
            try db.execute(sql: "UPDATE playlist_tracks SET deleted_at=? WHERE playlist_entry_id='CLOCK-SKEW'", arguments: [skewedDeletion])
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_CLOCK-SKEW", in: db)
        }
        let staleRevision = SyncRevision.make(at: Date(timeIntervalSince1970: 75), writerID: "PHONE").rawValue
        try phone.write { db in
            try db.execute(sql: "UPDATE playlist_tracks SET ordering_key='z', ordering_key_rev=? WHERE playlist_entry_id='CLOCK-SKEW'", arguments: [staleRevision])
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_CLOCK-SKEW", in: db)
        }

        try exchange(phone)
        try exchange(mac)
        try broadcast()
        for store in [mac!, phone!] {
            XCTAssertEqual(
                try store.read { try Date.fetchOne($0, sql: "SELECT deleted_at FROM playlist_tracks WHERE playlist_entry_id='CLOCK-SKEW'") },
                skewedDeletion
            )
        }
    }

    func testLaterRatingWinsRegardlessOfUploadOrder() throws {
        let older = SyncRevision.make(at: Date(timeIntervalSince1970: 3_000), writerID: "MAC").rawValue
        let newer = SyncRevision.make(at: Date(timeIntervalSince1970: 3_001), writerID: "PHONE").rawValue
        try mac.write { db in
            try db.execute(sql: "UPDATE track_annotations SET rating=2, rating_rev=? WHERE track_sync_id=?", arguments: [older, trackID])
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackID)", in: db)
        }
        try phone.write { db in
            try db.execute(sql: "UPDATE track_annotations SET rating=5, rating_rev=? WHERE track_sync_id=?", arguments: [newer, trackID])
            try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackID)", in: db)
        }
        try exchange(phone)
        try exchange(mac)
        try broadcast()
        XCTAssertEqual(try mac.read { try Int.fetchOne($0, sql: "SELECT rating FROM track_annotations WHERE track_sync_id=?", arguments: [trackID]) }, 5)
        XCTAssertEqual(try phone.read { try Int.fetchOne($0, sql: "SELECT rating FROM track_annotations WHERE track_sync_id=?", arguments: [trackID]) }, 5)
    }

    func testMergeRedirectArrivingBeforeSurvivorPropagatesAcrossStores() throws {
        let duplicate = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFE"
        for store in [mac!, phone!] {
            try store.write { db in
                try db.execute(sql: "INSERT INTO logical_tracks (track_sync_id, title, created_at, is_promoted) VALUES (?, 'Duplicate', ?, 1)", arguments: [duplicate, Date(timeIntervalSince1970: 1)])
                try db.execute(sql: "INSERT INTO verified_track_identities VALUES (?, ?)", arguments: [duplicate, Date(timeIntervalSince1970: 1)])
                try db.execute(sql: "INSERT INTO tracks (file_url, title, date_added, track_sync_id, physical_file_id, id_state, is_promoted) VALUES (?, 'Duplicate', ?, ?, ?, 'embedded', 1)", arguments: ["file:///\(duplicate)-\(UUID().uuidString).flac", Date(timeIntervalSince1970: 1), duplicate, UUID().uuidString])
            }
        }
        try mac.write { db in _ = try IdentityRepository.merge(trackID, duplicate, in: db) }
        try exchange(mac)
        try broadcast()
        XCTAssertEqual(try phone.read { try IdentityRepository.resolveTerminal(duplicate, in: $0) }, trackID)
    }

    func testDelayedEntryReplayPreservesNewerLocalReorder() throws {
        try assertNewerLocalReorderSurvives { database, stale in
            try SyncRecordApplier.apply(stale.filter {
                if case .entry = $0 { return true }; return false
            }, to: database)
        }
    }

    func testParentRefreshPreservesNewerLocalReorder() throws {
        try assertNewerLocalReorderSurvives { database, stale in
            try SyncRecordApplier.apply(stale.filter {
                if case .entry = $0 { return false }; return true
            }, to: database)
        }
    }

    func testScannerRematerializationPreservesNewerLocalReorder() throws {
        try assertNewerLocalReorderSurvives { database, _ in
            try SyncRecordApplier.materializeResolvablePlaylistEntries(in: database)
        }
    }

    private func assertNewerLocalReorderSurvives(
        refresh: (Database, [SyncTransportRecord]) throws -> Void
    ) throws {
        try mac.write { database in
            // Three distinct memberships of one verified track, as in P04.
            try addEntry("REORDER-E1", key: "U", to: database)
            try addEntry("REORDER-E2", key: "UV", to: database)
            try addEntry("REORDER-E3", key: "UVV", to: database)
        }
        let stale = try mac.read { try SQLiteSyncTransport.snapshot(in: $0) }
        try mac.write { database in
            try SyncRecordApplier.apply(stale, to: database)
            let playlist = try XCTUnwrap(Int64.fetchOne(database, sql: "SELECT id FROM playlists WHERE playlist_sync_id=?", arguments: [playlistID]))
            let entry = try XCTUnwrap(Int64.fetchOne(database, sql: "SELECT id FROM playlist_tracks WHERE playlist_entry_id='REORDER-E1'"))
            try AppState.reorderPlaylistEntries([entry], inPlaylist: playlist, toRow: 3, in: database)
            let local = try XCTUnwrap(Row.fetchOne(database, sql: "SELECT ordering_key, ordering_key_rev FROM playlist_tracks WHERE id=?", arguments: [entry]))
            let expectedKey: String = local["ordering_key"]
            let expectedRevision: String = local["ordering_key_rev"]
            XCTAssertGreaterThan(expectedKey, "UVV")

            for _ in 0..<2 {
                try refresh(database, stale)
                let current = try XCTUnwrap(Row.fetchOne(database, sql: "SELECT ordering_key, ordering_key_rev FROM playlist_tracks WHERE id=?", arguments: [entry]))
                XCTAssertEqual(current["ordering_key"] as String, expectedKey)
                XCTAssertEqual(current["ordering_key_rev"] as String, expectedRevision)
                XCTAssertEqual(try String.fetchAll(database, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE playlist_id=? AND deleted_at IS NULL ORDER BY position, id", arguments: [playlist]), ["REORDER-E2", "REORDER-E3", "REORDER-E1"])
            }
            // Protecting a local winner must still allow a newer remote move.
            let nextRevision = SyncRevision.make(at: Date().addingTimeInterval(1), writerID: "PHONE").rawValue
            let next = SyncTransportRecord.entry(.init(id: "REORDER-E1", playlistID: playlistID, trackID: trackID, orderingKey: "G", orderingKeyRev: nextRevision, createdAt: Date(timeIntervalSince1970: 100), deletedAt: nil))
            try SyncRecordApplier.apply([next], to: database)
            XCTAssertEqual(try String.fetchAll(database, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE playlist_id=? AND deleted_at IS NULL ORDER BY position, id", arguments: [playlist]), ["REORDER-E1", "REORDER-E2", "REORDER-E3"])
            XCTAssertEqual(try String.fetchOne(database, sql: "SELECT ordering_key_rev FROM playlist_tracks WHERE id=?", arguments: [entry]), nextRevision)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id=?", arguments: [playlist]), 3)
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    private func exchange(_ client: DatabaseManager) throws {
        let records = try client.read { try SQLiteSyncTransport.pending(in: $0) }
        try server.write { try SQLiteSyncTransport.apply(records, to: $0, receivedAt: Date(timeIntervalSince1970: 10_000)) }
        // This database simulates the cloud, not a client without local audio.
        // All received records came through the client's eligibility gate.
        try server.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO verified_track_identities SELECT track_sync_id, CURRENT_TIMESTAMP FROM logical_tracks")
            try db.execute(sql: "UPDATE logical_tracks SET is_promoted=1")
        }
        try client.write { try SQLiteSyncTransport.acknowledge(records, in: $0) }
    }

    private func broadcast() throws {
        let records = try server.read { try SQLiteSyncTransport.snapshot(in: $0) }
        try mac.write { try SQLiteSyncTransport.apply(records, to: $0, receivedAt: Date(timeIntervalSince1970: 10_000)) }
        try phone.write { try SQLiteSyncTransport.apply(records, to: $0, receivedAt: Date(timeIntervalSince1970: 10_000)) }
    }

    private func seed(_ manager: DatabaseManager, deviceID: String) throws {
        try manager.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('device_id', ?)", arguments: [Data(deviceID.utf8)])
            try db.execute(sql: "INSERT INTO logical_tracks (track_sync_id, title, created_at, is_promoted) VALUES (?, 'Shared Track', ?, 1)", arguments: [trackID, Date(timeIntervalSince1970: 1)])
            try db.execute(sql: "INSERT INTO tracks (file_url, title, date_added, track_sync_id, physical_file_id, id_state, is_promoted) VALUES (?, 'Shared Track', ?, ?, ?, 'embedded', 1)", arguments: ["file:///\(deviceID).flac", Date(timeIntervalSince1970: 1), trackID, "PHYSICAL-\(deviceID)"])
            try db.execute(sql: "INSERT INTO track_annotations (track_sync_id) VALUES (?)", arguments: [trackID])
            // Deterministic transport fixtures model a previously verified file.
            try db.execute(sql: "INSERT INTO verified_track_identities VALUES (?, ?)", arguments: [trackID, Date(timeIntervalSince1970: 1)])
            try db.execute(sql: "INSERT INTO playlists (name, date_created, date_modified, playlist_sync_id, name_rev, sort_mode_rev) VALUES ('Shared', ?, ?, ?, ?, ?)", arguments: [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 1), playlistID, SyncRevision.make(at: Date(timeIntervalSince1970: 1), writerID: deviceID).rawValue, SyncRevision.make(at: Date(timeIntervalSince1970: 1), writerID: deviceID).rawValue])
        }
    }

    private func addEntry(_ id: String, key: String, to db: Database) throws {
        let playlistLocalID = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM playlists WHERE playlist_sync_id=?", arguments: [playlistID]))
        let trackLocalID = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE track_sync_id=?", arguments: [trackID]))
        let position = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id=?", arguments: [playlistLocalID]) ?? 0
        let revision = SyncRevision.make(at: Date(timeIntervalSince1970: 100 + Double(position)), writerID: "ENTRY").rawValue
        try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [playlistLocalID, trackLocalID, position, id, key, revision, Date(timeIntervalSince1970: 100)])
        try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(trackID)", in: db)
        try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(playlistID)", in: db)
        try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(id)", in: db)
    }
}
