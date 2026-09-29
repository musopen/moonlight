import CloudKit
import Foundation
import GRDB
import SPFKMetadataC
import XCTest
@testable import Moonlight

final class SyncIdentityTests: XCTestCase {
    private var directory: URL!
    private var manager: DatabaseManager!

    func testRedirectChainsAndCompetingEdgesConvergeInEveryDeliveryOrder() throws {
        let ids = ["11111111-1111-4111-8111-111111111111", "88888888-8888-4888-8888-888888888888", "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"]
        let edges: [SyncTransportRecord] = [
            .track(.init(id: ids[2], mergedInto: ids[1])),
            .track(.init(id: ids[1], mergedInto: ids[0])),
            .track(.init(id: ids[2], mergedInto: ids[0]))
        ]
        for order in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
            let store = try DatabaseManager(path: directory.appendingPathComponent("order-\(order.map(String.init).joined()).sqlite").path)
            try store.write { db in
                try SyncRecordApplier.apply(order.map { edges[$0] }, to: db)
                // An old client proposes the opposite direction; canonicalizing
                // terminals must not persist a cycle or a self-edge.
                try SyncRecordApplier.apply([.track(.init(id: ids[0], mergedInto: ids[2])), .track(.init(id: ids[0], mergedInto: ids[0]))] + edges, to: db)
                for id in ids { XCTAssertEqual(try IdentityRepository.resolveTerminal(id, in: db), ids[0]) }
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT merged_into FROM logical_tracks WHERE track_sync_id=?", arguments: [ids[0]]))
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox"), 0, "Receiving a redirect is not local proof of embedding")
            }
        }
    }

    func testCorruptExistingRedirectCycleRejectsBatchAtomically() throws {
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "88888888-8888-4888-8888-888888888888"
        _ = try insertTrack(syncID: a, title: "A")
        _ = try insertTrack(syncID: b, title: "B")
        try manager.write { db in
            try db.execute(sql: "UPDATE logical_tracks SET merged_into=? WHERE track_sync_id=?", arguments: [b,a])
            try db.execute(sql: "UPDATE logical_tracks SET merged_into=? WHERE track_sync_id=?", arguments: [a,b])
        }
        XCTAssertThrowsError(try manager.write { db in
            try SyncRecordApplier.apply([.counter(.init(trackID: a, deviceID: "A", count: 7))], to: db)
        })
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM play_counters") }, 0)
    }

    func testRemoteRedirectPreservesOriginCountersFilesAndLateUpdatesUnderReplay() throws {
        let survivor = "11111111-1111-4111-8111-111111111111"
        let loser = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        let local = try insertTrack(syncID: loser, title: "Local alias audio")
        let rev = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "A").rawValue
        let later = SyncRevision.make(at: Date(timeIntervalSince1970: 101), writerID: "B").rawValue
        try manager.write { db in
            try db.execute(sql: "INSERT INTO physical_files (physical_file_id, track_sync_id, library_root_id, relative_path, id_state) SELECT physical_file_id,track_sync_id,'REDIRECT','alias.mp3','embedded' FROM tracks WHERE id=?", arguments: [local])
            // The survivor deliberately does not exist yet. Both counters
            // precede/follow the redirect in different delivery orders below.
            let redirect = SyncTransportRecord.track(.init(id: loser, rating: 4, ratingRev: rev, favorite: true, favoriteRev: rev, mergedInto: survivor))
            let a = SyncTransportRecord.counter(.init(trackID: loser, deviceID: "A", count: 3, lastPlayedAt: Date(timeIntervalSince1970: 10)))
            let b = SyncTransportRecord.counter(.init(trackID: survivor, deviceID: "B", count: 4, lastPlayedAt: Date(timeIntervalSince1970: 20)))
            let playlistID = "77777777-7777-4777-8777-777777777777"
            let playlist = SyncTransportRecord.playlist(.init(id: playlistID, name: "Redirect", nameRev: rev, kind: "manual", sortMode: "manual", sortModeRev: rev, createdAt: Date(timeIntervalSince1970: 1)))
            let entry = SyncTransportRecord.entry(.init(id: "REDIRECT-ENTRY", playlistID: playlistID, trackID: loser, orderingKey: "U", orderingKeyRev: rev, createdAt: Date(timeIntervalSince1970: 1)))
            try SyncRecordApplier.apply([a, playlist, entry, redirect, b], to: db)
            for _ in 0..<3 { try SyncRecordApplier.apply([b, redirect, entry, a], to: db) }
            XCTAssertEqual(try IdentityRepository.resolveTerminal(loser, in: db), survivor)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM track_annotations WHERE track_sync_id=?", arguments: [survivor]), 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE id=?", arguments: [local]), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(count) FROM play_counters"), 7)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM physical_files"), loser, "Physical identity must still match its embedded tag; a redirect is not an audio rewrite")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT track_id FROM playlist_tracks"), local)
            let late = SyncTransportRecord.track(.init(id: loser, rating: 5, ratingRev: later))
            let fifth = SyncTransportRecord.counter(.init(trackID: loser, deviceID: "A", count: 5, lastPlayedAt: Date(timeIntervalSince1970: 30)))
            try SyncRecordApplier.apply([late, fifth, redirect, a, b, fifth], to: db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks WHERE id=?", arguments: [local]), 5)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_favorite FROM tracks WHERE id=?", arguments: [local]), true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE id=?", arguments: [local]), 9)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(count) FROM play_counters"), 9)
        }
    }

    func testRebuildingAfterRedirectRetainsComponentAnnotationsAndCounters() async throws {
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        let local = try insertTrack(syncID: b, title: "Local alias")
        let rev = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "A").rawValue
        try manager.write { db in
            try SyncRecordApplier.apply([
                .track(.init(id: b, mergedInto: a)),
                .track(.init(id: a, rating: 5, ratingRev: rev)),
                .counter(.init(trackID: a, deviceID: "A", count: 3)),
                .counter(.init(trackID: b, deviceID: "B", count: 4))
            ], to: db)
        }
        await LibraryScanner(db: manager).rebuildDerivedData()
        try manager.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks WHERE id=?", arguments: [local]), 5)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE id=?", arguments: [local]), 7)
        }
    }

    func testFailedHardLinkedEmbeddingCannotReleaseAnyTrackDependentRecord() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let folder = directory.appendingPathComponent("failed-embedding", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("hardlinked.mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try FileManager.default.linkItem(at: copy, to: directory.appendingPathComponent("hardlink-outside-scan.mp3"))
        let folderID = try manager.write { db in
            try db.execute(sql: "INSERT INTO folders (url,bookmark_data,date_added,library_root_id) VALUES (?,?,?,'FAILED-EMBEDDING')", arguments: [folder.absoluteString,Data(),Date()])
            return db.lastInsertedRowID
        }
        _ = await LibraryScanner(db: manager).scan(folderURL: folder, folderId: folderID, mode: .fullRebuild, trigger: .manual) { _ in }
        let track = try XCTUnwrap(manager.read { try Track.fetchOne($0) })
        let playlist = try insertPlaylist()
        try manager.write { db in
            try AppState.setRating(4, forTrackIDs: [try XCTUnwrap(track.dbId)], in: db)
            try AppState.setFavorite(true, forTrackIDs: [try XCTUnwrap(track.dbId)], in: db)
            try AppState.appendTrackIds([try XCTUnwrap(track.dbId)], toPlaylist: playlist, in: db)
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id,device_id,count) VALUES (?,'A',3)", arguments: [track.trackSyncId])
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(track.trackSyncId)_A", in: db)
        }
        await PortableIdentityTagger(db: manager).processPending()
        XCTAssertNil(PortableIdentityTag.read(from: copy))
        let coordinator = CloudKitSyncCoordinator(manager: manager)
        try manager.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM tagging_jobs"), "skipped_unwritable")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM verified_track_identities"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM tracks"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_type != 'Playlist'"), 0)
            XCTAssertTrue(try SQLiteSyncTransport.snapshot(in: db).allSatisfy { $0.key.hasPrefix("Playlist:") })
        }
        let entry = try XCTUnwrap(manager.read { try String.fetchOne($0, sql: "SELECT playlist_entry_id FROM playlist_tracks") })
        for name in ["track_\(track.trackSyncId)", "entry_\(entry)", "count_\(track.trackSyncId)_A"] {
            XCTAssertNil(coordinator.record(for: .init(recordName: name)))
        }
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT rating FROM track_annotations") }, 4)
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT SUM(count) FROM play_counters") }, 3)
    }

    func testEligibilityMigrationDoesNotTrustLegacyEmbeddedStateOrPromotion() throws {
        let id = "55555555-5555-4555-8555-555555555555"
        let local = try insertTrack(syncID: id, title: "Legacy")
        try manager.write { db in
            try db.execute(sql: "DROP TABLE verified_track_identities")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v17_verified_sync_identity'")
            try db.execute(sql: "UPDATE tracks SET id_state='embedded',is_promoted=1 WHERE id=?", arguments: [local])
            try db.execute(sql: "UPDATE logical_tracks SET is_promoted=1")
            try db.execute(sql: "INSERT OR REPLACE INTO track_annotations (track_sync_id,rating,favorite) VALUES (?,5,1)", arguments: [id])
            try db.execute(sql: "INSERT INTO sync_outbox (coalesce_key,record_type,record_name,enqueued_at) VALUES (?,'SyncedTrack',?,?)", arguments: ["SyncedTrack:track_\(id)","track_\(id)",Date()])
        }
        try Migrator.migrate(manager.dbQueue)
        try manager.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM verified_track_identities"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM tracks"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM track_annotations"), 5)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT favorite FROM track_annotations"), true)
        }
    }

    func testUnverifiedIdentityCannotPromoteOrEnterAnyTrackDependentOutbox() throws {
        for state in ["absent", "unsupported", "unwritable", "unknown"] {
            let id = UUID().uuidString
            let localID = try insertTrack(syncID: id, title: "Local only")
            try manager.write { db in
                try db.execute(sql: "UPDATE tracks SET id_state=? WHERE id=?", arguments: [state, localID])
                try AppState.setRating(4, forTrackIDs: [localID], in: db)
                try AppState.setFavorite(true, forTrackIDs: [localID], in: db)
                try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count) VALUES (?, 'LOCAL', 3)", arguments: [id])
                try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(id)_LOCAL", in: db)
                var playlist = Playlist(name: "Mixed local playlist", dateCreated: Date(), dateModified: Date())
                try playlist.insert(db)
                try PlaylistMutation.append([localID], to: try XCTUnwrap(playlist.id), in: db)
                try SyncOutbox.enqueueCompleteState(in: db)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM tracks WHERE id=?", arguments: [localID]), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM logical_tracks WHERE track_sync_id=?", arguments: [id]), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_type != 'Playlist'"), 0)
                XCTAssertTrue(try SQLiteSyncTransport.pending(in: db).allSatisfy { if case .playlist = $0.record { return true }; return false })
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks WHERE id=?", arguments: [localID]), 4)
                XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_favorite FROM tracks WHERE id=?", arguments: [localID]), true)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count FROM play_counters WHERE track_sync_id=?", arguments: [id]), 3)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE track_id=?", arguments: [localID]), 1)
            }
        }
    }

    func testEmbeddingReleasesRetainedLocalStateAndProviderRejectsLegacyLeak() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let folder = directory.appendingPathComponent("eligibility", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("eligible.mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let folderID = try manager.write { db in
            try db.execute(sql: "INSERT INTO folders (url, bookmark_data, date_added, library_root_id) VALUES (?, ?, ?, 'ELIGIBILITY')", arguments: [folder.absoluteString, Data(), Date()])
            return db.lastInsertedRowID
        }
        _ = await LibraryScanner(db: manager).scan(folderURL: folder, folderId: folderID, mode: .fullRebuild, trigger: .manual) { _ in }
        let track = try XCTUnwrap(manager.read { try Track.fetchOne($0) })
        try manager.write { db in
            try AppState.setRating(5, forTrackIDs: [try XCTUnwrap(track.dbId)], in: db)
            try AppState.setFavorite(true, forTrackIDs: [try XCTUnwrap(track.dbId)], in: db)
            var playlist = Playlist(name: "Eligibility", dateCreated: Date(), dateModified: Date())
            try playlist.insert(db)
            try PlaylistMutation.append([try XCTUnwrap(track.dbId)], to: try XCTUnwrap(playlist.id), in: db)
            let writer = try SyncDeviceIdentity.id(in: db)
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count) VALUES (?, ?, 3)", arguments: [track.trackSyncId, writer])
            // Simulate a pending generation left by a legacy client, bypassing
            // enqueue. Both actual CKRecord provider and neutral transport gate it.
            try db.execute(sql: "INSERT INTO sync_outbox (coalesce_key, record_type, record_name, enqueued_at) VALUES (?, 'SyncedTrack', ?, ?)", arguments: ["SyncedTrack:track_\(track.trackSyncId)", "track_\(track.trackSyncId)", Date()])
            XCTAssertTrue(try SQLiteSyncTransport.pending(in: db).isEmpty)
        }
        let coordinator = CloudKitSyncCoordinator(manager: manager)
        let recordID = CKRecord.ID(recordName: "track_\(track.trackSyncId)")
        XCTAssertNil(coordinator.record(for: recordID))
        await PortableIdentityTagger(db: manager).processPending()
        XCTAssertEqual(PortableIdentityTag.read(from: copy), track.trackSyncId)
        try manager.read { db in
            XCTAssertTrue(try SyncEligibility.isVerified(track.trackSyncId, in: db))
            let records = try SQLiteSyncTransport.pending(in: db)
            XCTAssertEqual(records.count, 3)
            XCTAssertEqual(Set(records.map(\.outboxItem.recordType)), ["SyncedTrack", "PlaylistEntry", "PlayCounter"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM tracks"), 1)
        }
        let legacy = CKRecord(recordType: "SyncedTrack", recordID: recordID)
        legacy["trackSyncID"] = track.trackSyncId
        legacy["title"] = "Legacy cloud title"
        legacy["albumArtist"] = "Legacy cloud album artist"
        legacy["unrecognizedFileMetadata"] = "Must not echo"
        try await coordinator.applyFetchedRecords([legacy])
        let outgoing = try XCTUnwrap(coordinator.record(for: recordID))
        XCTAssertEqual(outgoing["rating"] as? Int, 5)
        XCTAssertEqual(outgoing["favorite"] as? Bool, true)
        XCTAssertNil(outgoing["unrecognizedFileMetadata"])
        for field in ["title", "artist", "album", "albumArtist", "composer", "genre", "trackNumber", "discNumber", "year", "durationMs", "metadataRev", "artwork"] {
            XCTAssertNil(outgoing[field], "File metadata is local-only: \(field)")
        }
    }

    func testLegacyCloudDescriptionsNeverApplyToCatalogOrPlaceholder() async throws {
        let id = "55555555-5555-4555-8555-555555555555"
        _ = try insertTrack(syncID: id, title: "Local file title")
        let coordinator = CloudKitSyncCoordinator(manager: manager)
        for target in [id, "66666666-6666-4666-8666-666666666666"] {
            let record = CKRecord(recordType: "SyncedTrack", recordID: .init(recordName: "track_\(target)"))
            record["trackSyncID"] = target
            record["title"] = "Remote title"
            record["artist"] = "Remote artist"
            record["album"] = "Remote album"
            record["genre"] = "Remote genre"
            for key in ["albumArtist", "composer", "artwork"] { record[key] = "Remote file value" }
            for key in ["trackNumber", "discNumber", "year", "durationMs"] { record[key] = 999 }
            try manager.write { try SyncRecordApplier.apply([.track(.init(id: target))], to: $0) }
            let columns = "title,artist,album,album_artist,composer,genre,track_number,disc_number,year,duration,artwork_id,metadata_rev"
            let before = try manager.read { try Row.fetchOne($0, sql: "SELECT \(columns) FROM tracks WHERE track_sync_id=?", arguments: [target]) }
            record["metadataRev"] = SyncRevision.make(writerID: "REMOTE").rawValue
            record["rating"] = 4
            record["ratingRev"] = SyncRevision.make(writerID: "REMOTE").rawValue
            try await coordinator.applyFetchedRecords([record])
            XCTAssertEqual(before, try manager.read { try Row.fetchOne($0, sql: "SELECT \(columns) FROM tracks WHERE track_sync_id=?", arguments: [target]) })
            try manager.read { db in
                let logical = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM logical_tracks WHERE track_sync_id=?", arguments: [target]))
                XCTAssertNotEqual(logical["title"] as String?, "Remote title")
                XCTAssertNotEqual(logical["artist"] as String?, "Remote artist")
                XCTAssertNil(logical["genre"] as String?)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks WHERE track_sync_id=?", arguments: [target]), 4)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM tracks WHERE track_sync_id=?", arguments: [target]), target == id ? "Local file title" : nil)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_promoted FROM tracks WHERE track_sync_id=?", arguments: [target]), 0)
            }
        }
    }

    func testQueuedIdentityWriteReadsReplacementPermissionAndCompletes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let folder = directory.appendingPathComponent("queued", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("queued.mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let folderID = try manager.write { db in
            try db.execute(sql: "INSERT INTO folders (url, bookmark_data, date_added, library_root_id) VALUES (?, ?, ?, 'AUDIT-ROOT')", arguments: [folder.absoluteString, Data(), Date()])
            return db.lastInsertedRowID
        }
        let summary = await LibraryScanner(db: manager).scan(folderURL: folder, folderId: folderID, mode: .fullRebuild, trigger: .manual) { _ in }
        XCTAssertEqual(summary?.errorCount, 0)
        let identity = try XCTUnwrap(manager.read { try String.fetchOne($0, sql: "SELECT track_sync_id FROM tracks") })
        let tagger = PortableIdentityTagger(db: manager)
        await tagger.processPending()
        XCTAssertEqual(PortableIdentityTag.read(from: copy), identity)
        XCTAssertEqual(try manager.read { try String.fetchOne($0, sql: "SELECT state FROM tagging_jobs") }, "done")
        // A deliberate relink may replace a tag; verify that the queued flag,
        // not a hard-coded default, reaches the guarded writer.
        let replacement = "33333333-3333-4333-8333-333333333333"
        try manager.write { db in
            try db.execute(sql: "INSERT INTO logical_tracks (track_sync_id, created_at) VALUES (?, ?)", arguments: [replacement, Date()])
            let physicalID = try XCTUnwrap(String.fetchOne(db, sql: "SELECT physical_file_id FROM physical_files"))
            try IdentityRepository.relink(physicalFileID: physicalID, to: replacement, in: db)
        }
        await tagger.processPending()
        XCTAssertEqual(PortableIdentityTag.read(from: copy), replacement)
        XCTAssertEqual(try manager.read { try String.fetchOne($0, sql: "SELECT state FROM tagging_jobs") }, "done")
    }

    /// Independent untagged copies intentionally have distinct local identities;
    /// shared sync requires distributing verified tagged bytes.
    func testIndependentUntaggedScansCreateDistinctStableIdentities() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        XCTAssertNil(PortableIdentityTag.read(from: fixture))
        var identities: [String] = []
        for device in ["A", "B"] {
            let folder = directory.appendingPathComponent(device, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("same.mp3")
            try FileManager.default.copyItem(at: fixture, to: copy)
            XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: copy))
            let store = try DatabaseManager(path: directory.appendingPathComponent("\(device).sqlite").path)
            let scanner = LibraryScanner(db: store)
            let summary = await scanner.scan(folderURL: folder, mode: .fullRebuild, trigger: .manual) { _ in }
            XCTAssertEqual(summary?.errorCount, 0)
            let id = try XCTUnwrap(store.read { try String.fetchOne($0, sql: "SELECT track_sync_id FROM tracks") })
            XCTAssertNotNil(UUID(uuidString: id))
            identities.append(id)
            _ = await scanner.scan(folderURL: folder, mode: .fullRebuild, trigger: .manual) { _ in }
            try store.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM tracks"), id)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM physical_files"), id)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logical_tracks"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tagging_jobs WHERE state='pending'"), 1)
            }
        }
        XCTAssertNotEqual(identities[0], identities[1], "Untagged independent imports currently split; release blocker")
    }

    func testRemoteBeforeLocalTaggedImportAllocatesDistinctPhysicalUUIDsAndRepairsLegacyStubs() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let id = "22222222-2222-4222-8222-222222222222"
        let tagged = directory.appendingPathComponent("remote-first-tagged.mp3")
        try FileManager.default.copyItem(at: fixture, to: tagged)
        try PortableIdentityTag.write(id, to: tagged)
        let bytes = try Data(contentsOf: tagged)
        let rev = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "A").rawValue
        var physicalIDs: [String] = []
        for device in ["REMOTE-A", "REMOTE-B"] {
            let store = try DatabaseManager(path: directory.appendingPathComponent("\(device).sqlite").path)
            try store.write { db in
                try SyncRecordApplier.apply([
                    .track(.init(id: id, rating: 4, ratingRev: rev, favorite: true, favoriteRev: rev)),
                    .playlist(.init(id: "P", name: "Remote first", nameRev: rev, kind: "manual", sortMode: "manual", sortModeRev: rev, createdAt: Date())),
                    .entry(.init(id: "E", playlistID: "P", trackID: id, orderingKey: "U", orderingKeyRev: rev, createdAt: Date()))
                ], to: db)
            }
            let originalRow = try XCTUnwrap(store.read { try Int64.fetchOne($0, sql: "SELECT id FROM tracks") })
            let folder = directory.appendingPathComponent(device, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("same.mp3")
            try FileManager.default.copyItem(at: tagged, to: copy)
            let scanner = LibraryScanner(db: store)
            let summary = await scanner.scan(folderURL: folder, mode: .fullRebuild, trigger: .manual) { _ in }
            XCTAssertEqual(summary?.errorCount, 0)
            let physical = try XCTUnwrap(store.read { try String.fetchOne($0, sql: "SELECT physical_file_id FROM physical_files") })
            XCTAssertNotNil(UUID(uuidString: physical))
            XCTAssertFalse(physical.hasPrefix("STUB-"))
            physicalIDs.append(physical)
            try store.read { db in
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM tracks"), originalRow)
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT track_id FROM playlist_tracks"), originalRow)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT physical_file_id FROM tracks"), physical)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT availability_status FROM tracks"), "available")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks"), 4)
                XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_favorite FROM tracks"), true)
                XCTAssertTrue(try SyncEligibility.isVerified(id, in: db))
            }
            // Reproduce the already-materialized state observed on physical MAC B,
            // including local job/conflict references which must survive repair.
            let stub = "STUB-\(id)"
            try store.write { db in
                try db.execute(sql: "UPDATE physical_files SET physical_file_id=?", arguments: [stub])
                try db.execute(sql: "UPDATE tracks SET physical_file_id=?", arguments: [stub])
                try db.execute(sql: "INSERT INTO tagging_jobs (physical_file_id,state,attempts,may_replace_existing_identity) VALUES (?,'done',2,1)", arguments: [stub])
                try db.execute(sql: "INSERT INTO identity_conflicts (id,track_sync_id,physical_file_id,reason,created_at) VALUES ('CONFLICT',?,?,'fixture',?)", arguments: [id,stub,Date()])
            }
            let repaired = await scanner.scan(folderURL: folder, mode: .incremental, trigger: .manual) { _ in }
            XCTAssertEqual(repaired?.errorCount, 0)
            let newPhysical = try XCTUnwrap(store.read { try String.fetchOne($0, sql: "SELECT physical_file_id FROM physical_files") })
            XCTAssertNotNil(UUID(uuidString: newPhysical))
            try store.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT physical_file_id FROM tracks"), newPhysical)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT physical_file_id FROM tagging_jobs"), newPhysical)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT physical_file_id FROM identity_conflicts"), newPhysical)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tagging_jobs"), 2)
                XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT may_replace_existing_identity FROM tagging_jobs"), true)
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT track_id FROM playlist_tracks"), originalRow)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM physical_files"), 1)
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            _ = await scanner.scan(folderURL: folder, mode: .fullRebuild, trigger: .manual) { _ in }
            XCTAssertEqual(try store.read { try String.fetchOne($0, sql: "SELECT physical_file_id FROM physical_files") }, newPhysical)
            XCTAssertEqual(try Data(contentsOf: copy), bytes)
        }
        XCTAssertNotEqual(physicalIDs[0], physicalIDs[1])
    }

    func testIndependentPretaggedScansShareIdentityAndMaterializeAnnotations() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let id = "22222222-2222-4222-8222-222222222222"
        let tagged = directory.appendingPathComponent("tagged.mp3")
        try FileManager.default.copyItem(at: fixture, to: tagged)
        try PortableIdentityTag.write(id, to: tagged)
        let revision = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "A").rawValue
        var physicalIDs: [String] = []
        for device in ["A", "B"] {
            let folder = directory.appendingPathComponent(device, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("same.mp3")
            try FileManager.default.copyItem(at: tagged, to: copy)
            let store = try DatabaseManager(path: directory.appendingPathComponent("\(device).sqlite").path)
            let summary = await LibraryScanner(db: store).scan(folderURL: folder, mode: .fullRebuild, trigger: .manual) { _ in }
            XCTAssertEqual(summary?.errorCount, 0)
            try store.write { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM tracks"), id)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM physical_files"), id)
                physicalIDs.append(try XCTUnwrap(String.fetchOne(db, sql: "SELECT physical_file_id FROM tracks")))
                let record = SyncTransportRecord.track(.init(id: id, rating: 4, ratingRev: revision, favorite: true, favoriteRev: revision))
                try SyncRecordApplier.apply([record, record], to: db)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM tracks WHERE track_sync_id=?", arguments: [id]), 4)
                XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_favorite FROM tracks WHERE track_sync_id=?", arguments: [id]), true)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logical_tracks"), 1)
                XCTAssertEqual(record.recordName, "track_\(id)")
            }
        }
        XCTAssertNotEqual(physicalIDs[0], physicalIDs[1])
    }

    func testInvalidIdentityWriteLeavesFixtureBytesUnchanged() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3"))
        let copy = directory.appendingPathComponent("malformed.mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let before = try Data(contentsOf: copy)
        XCTAssertThrowsError(try PortableIdentityTag.write("not-a-uuid", to: copy))
        XCTAssertEqual(try Data(contentsOf: copy), before)
    }

    func testFractionalPrependRemainsBelowLeadingZeroAndOneBoundaries() {
        for upper in ["1", "01", "001", "01U", FractionalOrderingKey.initial(at: 0)] {
            var current = upper
            for _ in 0..<100 {
                let next = FractionalOrderingKey.between(nil, current)
                XCTAssertLessThan(next, current, "Prepending before \(current)")
                XCTAssertFalse(next.hasSuffix("0"))
                current = next
            }
        }
    }

    func testOutboxSurvivesReopenAndTransactionRollback() throws {
        let path = directory.appendingPathComponent("restart.sqlite").path
        let instant = Date(timeIntervalSince1970: 1_000)
        do {
            let store = try DatabaseManager(path: path)
            try store.write { db in
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_RESTART", in: db, at: instant)
            }
            enum Aborted: Error { case transaction }
            XCTAssertThrowsError(try store.write { db in
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_RESTART", in: db, at: instant)
                throw Aborted.transaction
            })
        }
        let reopened = try DatabaseManager(path: path)
        try reopened.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try SyncOutbox.pending(recordName: "playlist_RESTART", in: db)?.generation, 1)
            XCTAssertEqual(try Date.fetchOne(db, sql: "SELECT deliver_after FROM sync_outbox"), instant)
        }
    }

    func testRepeatedAndStaleCountersPreserveSumAndLatestPlayback() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let records: [SyncTransportRecord] = [
            .counter(.init(trackID: id, deviceID: "A", count: 4, lastPlayedAt: Date(timeIntervalSince1970: 20))),
            .counter(.init(trackID: id, deviceID: "B", count: 3, lastPlayedAt: Date(timeIntervalSince1970: 30))),
            .counter(.init(trackID: id, deviceID: "A", count: 1, lastPlayedAt: Date(timeIntervalSince1970: 10)))
        ]
        try manager.write { db in
            for _ in 0..<3 { try SyncRecordApplier.apply(records, to: db) }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE track_sync_id=?", arguments: [id]), 7)
            XCTAssertEqual(try Date.fetchOne(db, sql: "SELECT last_played_at FROM tracks WHERE track_sync_id=?", arguments: [id]), Date(timeIntervalSince1970: 30))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_counters"), 2)
        }
    }

    func testDisabledCloudSyncStatusIsNeverReportedAsUpToDate() {
        let status = CloudSyncStatus()
        status.isEnabled = false
        status.pendingChangeCount = 61

        XCTAssertEqual(status.headline, "iCloud Sync is Off")
        XCTAssertTrue(status.explanation.contains("until you choose"))
    }

    func testEnabledCloudSyncStatusExplainsPendingChanges() {
        let status = CloudSyncStatus()
        status.isEnabled = true
        status.pendingChangeCount = 2

        XCTAssertEqual(status.headline, "Changes ready to sync")
        XCTAssertTrue(status.explanation.contains("2 local changes"))
    }

    func testMissingCloudKitRecordIsRetriedAsNewSave() {
        XCTAssertTrue(CloudKitSyncCoordinator.shouldRecreateMissingRecord(after: CKError(.unknownItem)))
        XCTAssertFalse(CloudKitSyncCoordinator.shouldRecreateMissingRecord(after: CKError(.networkUnavailable)))
    }

    @MainActor
    func testFetchedCloudKitChangesRefreshMacPlaylistReadModels() async throws {
        let appState = AppState(db: manager)
        let playlistID = UUID().uuidString.uppercased()
        let trackID = UUID().uuidString.uppercased()
        let entryID = UUID().uuidString.uppercased()
        let revision = SyncRevision.make(writerID: "REMOTE").rawValue
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)

        let playlist = CKRecord(recordType: "Playlist", recordID: .init(recordName: "playlist_\(playlistID)", zoneID: zone))
        playlist["playlistID"] = playlistID as NSString
        playlist["name"] = "Fresh from iCloud" as NSString
        playlist["nameRev"] = revision as NSString
        playlist["sortModeRev"] = revision as NSString
        playlist["createdAt"] = Date() as NSDate

        let track = CKRecord(recordType: "SyncedTrack", recordID: .init(recordName: "track_\(trackID)", zoneID: zone))
        track["trackSyncID"] = trackID as NSString
        track["title"] = "Remote Song" as NSString
        track["metadataRev"] = revision as NSString

        let entry = CKRecord(recordType: "PlaylistEntry", recordID: .init(recordName: "entry_\(entryID)", zoneID: zone))
        entry["playlistEntryID"] = entryID as NSString
        entry["playlistID"] = playlistID as NSString
        entry["trackSyncID"] = trackID as NSString
        entry["orderingKey"] = "U" as NSString
        entry["orderingKeyRev"] = revision as NSString
        entry["createdAt"] = Date() as NSDate

        try await appState.cloudSync.applyFetchedRecords([playlist, track, entry])

        XCTAssertEqual(appState.playlists.map(\.name), ["Fresh from iCloud"])
        XCTAssertEqual(appState.libraryVersion, 1)
        let localPlaylistID = try XCTUnwrap(appState.playlists.first?.id)
        XCTAssertEqual(
            try manager.read { try PlaylistEntry.fetchVisible(in: localPlaylistID, from: $0).map { $0.track.title } },
            [nil]
        )
    }

    @MainActor
    func testFetchedFavoriteAndRatingRefreshesReadModelsWithOneInvalidation() async throws {
        let trackID = UUID().uuidString.uppercased()
        let localTrackID = try insertTrack(syncID: trackID, title: "Local Song")
        let appState = AppState(db: manager)
        let revision = SyncRevision.make(writerID: "REMOTE").rawValue
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "SyncedTrack", recordID: .init(recordName: "track_\(trackID)", zoneID: zone))
        record["trackSyncID"] = trackID as NSString
        record["rating"] = 5 as NSNumber
        record["ratingRev"] = revision as NSString
        record["favorite"] = true as NSNumber
        record["favoriteRev"] = revision as NSString

        try await appState.cloudSync.applyFetchedRecords([record])

        XCTAssertEqual(appState.libraryVersion, 1)
        let row = try manager.read { db in
            try Row.fetchOne(db, sql: "SELECT rating, is_favorite FROM tracks WHERE id = ?", arguments: [localTrackID])
        }
        XCTAssertEqual(row?["rating"] as Int?, 5)
        XCTAssertEqual(row?["is_favorite"] as Bool?, true)
    }

    @MainActor
    func testMixedFetchedBatchEmitsOneInvalidation() async throws {
        let trackID = UUID().uuidString.uppercased()
        _ = try insertTrack(syncID: trackID, title: "Local Song")
        let appState = AppState(db: manager)
        let revision = SyncRevision.make(writerID: "REMOTE").rawValue
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)

        let track = CKRecord(recordType: "SyncedTrack", recordID: .init(recordName: "track_\(trackID)", zoneID: zone))
        track["trackSyncID"] = trackID as NSString
        track["title"] = "Renamed remotely" as NSString
        track["metadataRev"] = revision as NSString

        let counter = CKRecord(recordType: "PlayCounter", recordID: .init(recordName: "count_\(trackID)_REMOTE", zoneID: zone))
        counter["trackSyncID"] = trackID as NSString
        counter["deviceID"] = "REMOTE" as NSString
        counter["count"] = 7 as NSNumber
        counter["lastPlayedAt"] = Date() as NSDate

        let playlistID = UUID().uuidString.uppercased()
        let playlist = CKRecord(recordType: "Playlist", recordID: .init(recordName: "playlist_\(playlistID)", zoneID: zone))
        playlist["playlistID"] = playlistID as NSString
        playlist["name"] = "Remote Playlist" as NSString
        playlist["nameRev"] = revision as NSString
        playlist["sortModeRev"] = revision as NSString
        playlist["createdAt"] = Date() as NSDate

        try await appState.cloudSync.applyFetchedRecords([track, counter, playlist])

        XCTAssertEqual(appState.libraryVersion, 1)
        XCTAssertEqual(appState.playlists.map(\.name), ["Remote Playlist"])
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT play_count FROM tracks WHERE track_sync_id = ?", arguments: [trackID]) }, 7)
    }

    @MainActor
    func testEmptyOrUnmaterializedFetchedBatchDoesNotInvalidate() async throws {
        let appState = AppState(db: manager)
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let unsupported = CKRecord(recordType: "FutureRecord", recordID: .init(recordName: "future", zoneID: zone))

        try await appState.cloudSync.applyFetchedRecords([])
        try await appState.cloudSync.applyFetchedRecords([unsupported])

        XCTAssertEqual(appState.libraryVersion, 0)
    }

    @MainActor
    func testMetadataRestoreEmitsOneSynchronizedStateInvalidation() async throws {
        let trackID = UUID().uuidString.uppercased()
        let localTrackID = try insertTrack(syncID: trackID, title: "Restored")
        try manager.write { db in
            try db.execute(sql: "INSERT INTO track_annotations (track_sync_id, rating) VALUES (?, 4)", arguments: [trackID])
            try db.execute(sql: "UPDATE tracks SET rating = 4 WHERE id = ?", arguments: [localTrackID])
        }
        let archive = directory.appendingPathComponent("restore-refresh.ndjson")
        try MetadataArchive.export(to: archive, from: manager)
        let snapshot = try MetadataArchive.summary(of: archive)
        try manager.write { db in
            try db.execute(sql: "UPDATE track_annotations SET rating = 1 WHERE track_sync_id = ?", arguments: [trackID])
            try db.execute(sql: "UPDATE tracks SET rating = 1 WHERE id = ?", arguments: [localTrackID])
        }
        let appState = AppState(db: manager)

        try await appState.restoreMetadataSnapshot(snapshot)

        XCTAssertEqual(appState.libraryVersion, 1)
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT rating FROM tracks WHERE id = ?", arguments: [localTrackID]) }, 4)
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoonlightSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDown() async throws {
        manager = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testCompositeRevisionOrdersTimestampThenWriterAndClampsFuture() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = SyncRevision.make(at: date, writerID: "A")
        let b = SyncRevision.make(at: date, writerID: "B")
        let later = SyncRevision.make(at: date.addingTimeInterval(1), writerID: "A")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, later)

        let received = Date(timeIntervalSince1970: 1_800_000_000)
        let hostile = SyncRevision.make(at: received.addingTimeInterval(86_400), writerID: "DEVICE")
        XCTAssertEqual(hostile.clamped(receivedAt: received).timestamp!.timeIntervalSince1970, received.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFractionalKeysRemainStrictlyOrderedAcrossRepeatedInsertions() {
        var lower = FractionalOrderingKey.between(nil, nil)
        let upper = FractionalOrderingKey.between(lower, nil)
        for _ in 0..<200 {
            let inserted = FractionalOrderingKey.between(lower, upper)
            XCTAssertLessThan(lower, inserted)
            XCTAssertLessThan(inserted, upper)
            lower = inserted
        }
    }

    func testFractionalKeyGenerationIsTotalForEqualAndInvertedBounds() {
        let equal = FractionalOrderingKey.between("U", "U")
        XCTAssertGreaterThan(equal, "U")

        let inverted = FractionalOrderingKey.between("z", "A")
        XCTAssertGreaterThan(inverted, "A")
        XCTAssertLessThan(inverted, "z")
    }

    func testSyncedEntryReorderRecomputesCompatibilityPositions() throws {
        let trackID = "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB"
        let playlistID = "CDCDCDCD-CDCD-4DCD-8DCD-CDCDCDCDCDCD"
        _ = try insertTrack(syncID: trackID, title: "Ordered")
        try manager.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, date_created, date_modified, playlist_sync_id) VALUES ('Remote order', ?, ?, ?)", arguments: [Date(), Date(), playlistID])
            let firstRevision = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "PHONE").rawValue
            try SQLiteSyncTransport.apply([
                .entry(.init(id: "ENTRY-A", playlistID: playlistID, trackID: trackID, orderingKey: "A", orderingKeyRev: firstRevision, createdAt: Date(timeIntervalSince1970: 1), deletedAt: nil)),
                .entry(.init(id: "ENTRY-B", playlistID: playlistID, trackID: trackID, orderingKey: "Z", orderingKeyRev: firstRevision, createdAt: Date(timeIntervalSince1970: 2), deletedAt: nil))
            ], to: db, receivedAt: Date(timeIntervalSince1970: 200))

            let reorderRevision = SyncRevision.make(at: Date(timeIntervalSince1970: 300), writerID: "PHONE").rawValue
            try SQLiteSyncTransport.apply([
                .entry(.init(id: "ENTRY-B", playlistID: playlistID, trackID: trackID, orderingKey: "0A", orderingKeyRev: reorderRevision, createdAt: Date(timeIntervalSince1970: 2), deletedAt: nil))
            ], to: db, receivedAt: Date(timeIntervalSince1970: 400))
        }

        let rows = try manager.read { db in
            try Row.fetchAll(db, sql: "SELECT playlist_entry_id, position FROM playlist_tracks ORDER BY ordering_key, playlist_entry_id")
        }
        XCTAssertEqual(rows.map { $0["playlist_entry_id"] as String }, ["ENTRY-B", "ENTRY-A"])
        XCTAssertEqual(rows.map { $0["position"] as Int }, [0, 1])
    }

    func testOutboxCoalescesRepeatedWrites() throws {
        try manager.write { db in
            for _ in 0..<50 {
                try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_A", in: db)
            }
        }
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, 1)
    }

    func testOutboxAcknowledgementPreservesAnEditMadeWhileRecordIsInFlight() throws {
        let firstEdit = Date(timeIntervalSince1970: 1_000)
        let secondEdit = Date(timeIntervalSince1970: 1_001)
        let inFlight = try manager.write { db -> SyncOutbox.PendingItem in
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_A", in: db, at: firstEdit)
            return try XCTUnwrap(SyncOutbox.pending(recordName: "playlist_A", in: db))
        }

        try manager.write { db in
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_A", in: db, at: secondEdit)
            try SyncOutbox.acknowledge(inFlight, in: db)
        }
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, 1)

        let retry = try manager.read { try XCTUnwrap(SyncOutbox.pending(recordName: "playlist_A", in: $0)) }
        XCTAssertGreaterThan(retry.generation, inFlight.generation)
        try manager.write { try SyncOutbox.acknowledge(retry, in: $0) }
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }, 0)
    }

    func testOutboxDefersPlaybackButPromptEditAdvancesDelivery() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try manager.write { db in
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_A", in: db, at: now, delivery: .playbackBatch)
        }
        let delayed = try XCTUnwrap(manager.read { try Date.fetchOne($0, sql: "SELECT deliver_after FROM sync_outbox WHERE record_name = 'playlist_A'") })
        XCTAssertEqual(delayed.timeIntervalSince(now), 180, accuracy: 0.001)

        let ratingEdit = now.addingTimeInterval(10)
        try manager.write { db in
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_A", in: db, at: ratingEdit)
        }
        let advanced = try XCTUnwrap(manager.read { try Date.fetchOne($0, sql: "SELECT deliver_after FROM sync_outbox WHERE record_name = 'playlist_A'") })
        XCTAssertEqual(advanced.timeIntervalSince1970, ratingEdit.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMergeUsesLexicalSurvivorPreservesDuplicateEntriesAndSumsCounters() throws {
        let firstLocal = try insertTrack(syncID: "11111111-1111-4111-8111-111111111111", title: "First")
        let secondLocal = try insertTrack(syncID: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", title: "Second")
        let playlist = try insertPlaylist()
        try manager.write { db in
            try AppState.appendTrackIds([firstLocal, secondLocal, secondLocal], toPlaylist: playlist, in: db)
            try db.execute(sql: "INSERT OR REPLACE INTO track_annotations (track_sync_id, rating, rating_rev) VALUES (?, 3, ?)", arguments: ["11111111-1111-4111-8111-111111111111", SyncRevision.make(writerID: "A").rawValue])
            try db.execute(sql: "INSERT OR REPLACE INTO track_annotations (track_sync_id, rating, rating_rev) VALUES (?, 5, ?)", arguments: ["FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", SyncRevision.make(at: Date().addingTimeInterval(1), writerID: "B").rawValue])
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, 'MAC', 4, ?), (?, 'MAC', 7, ?), (?, 'PHONE', 2, ?)", arguments: ["11111111-1111-4111-8111-111111111111", Date(timeIntervalSince1970: 10), "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", Date(timeIntervalSince1970: 20), "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", Date(timeIntervalSince1970: 30)])

            let survivor = try IdentityRepository.merge("FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", "11111111-1111-4111-8111-111111111111", in: db)
            XCTAssertEqual(survivor, "11111111-1111-4111-8111-111111111111")
        }

        let result = try manager.read { db -> (Int, Int?, [Int]) in
            let entryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlist]) ?? 0
            let rating = try Int.fetchOne(db, sql: "SELECT rating FROM track_annotations WHERE track_sync_id = '11111111-1111-4111-8111-111111111111'")
            let counts = try Int.fetchAll(db, sql: "SELECT SUM(count) FROM play_counters GROUP BY device_id ORDER BY device_id")
            return (entryCount, rating, counts)
        }
        XCTAssertEqual(result.0, 3)
        XCTAssertEqual(result.1, 5)
        XCTAssertEqual(result.2, [11, 2])
    }

    func testConcurrentFieldEditsConvergeIndependentFields() {
        let base = SyncedTrackState(trackSyncID: "T", rating: 1, ratingRev: .make(at: Date(timeIntervalSince1970: 1), writerID: "A"), favorite: false, favoriteRev: .make(at: Date(timeIntervalSince1970: 1), writerID: "A"), title: nil, artist: nil, album: nil, metadataRev: nil, mergedInto: nil)
        var mac = base
        mac.rating = 5
        mac.ratingRev = .make(at: Date(timeIntervalSince1970: 2), writerID: "MAC")
        var phone = base
        phone.favorite = true
        phone.favoriteRev = .make(at: Date(timeIntervalSince1970: 3), writerID: "PHONE")

        var storeA = mac; storeA.merge(phone, receivedAt: Date(timeIntervalSince1970: 4))
        var storeB = phone; storeB.merge(mac, receivedAt: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(storeA, storeB)
        XCTAssertEqual(storeA.rating, 5)
        XCTAssertEqual(storeA.favorite, true)
    }

    func testFutureRevisionIsRejectedWithoutDeviceSpecificClamping() {
        let received = Date(timeIntervalSince1970: 2_000)
        var local = SyncedTrackState(trackSyncID: "T", rating: 2, ratingRev: .make(at: Date(timeIntervalSince1970: 1_000), writerID: "LOCAL"), favorite: nil, favoriteRev: nil, title: nil, artist: nil, album: nil, metadataRev: nil, mergedInto: nil)
        let hostile = SyncedTrackState(trackSyncID: "T", rating: 5, ratingRev: .make(at: received.addingTimeInterval(3_600), writerID: "REMOTE"), favorite: nil, favoriteRev: nil, title: nil, artist: nil, album: nil, metadataRev: nil, mergedInto: nil)
        local.merge(hostile, receivedAt: received)
        XCTAssertEqual(local.rating, 2)
    }

    func testSmartPlaylistRuleDecodingRejectsRulesBeyondTheLimits() throws {
        let tenConditions = SmartPlaylistRule.all(Array(repeating: .favorite(true), count: SmartPlaylistRule.maxConditions))
        XCTAssertEqual(try SmartPlaylistRule.decoded(tenConditions.encoded()), tenConditions)

        let elevenConditions = SmartPlaylistRule.all(Array(repeating: .favorite(true), count: SmartPlaylistRule.maxConditions + 1))
        XCTAssertThrowsError(try SmartPlaylistRule.decoded(elevenConditions.encoded())) { error in
            XCTAssertEqual(error as? SmartPlaylistRuleError, .tooComplex)
        }

        let threeLevels = SmartPlaylistRule.all([.any([.genre("Baroque"), .composer("Bach")]), .favorite(true)])
        XCTAssertEqual(try SmartPlaylistRule.decoded(threeLevels.encoded()), threeLevels)

        let fourLevels = SmartPlaylistRule.all([.any([.all([.favorite(true)])])])
        XCTAssertThrowsError(try SmartPlaylistRule.decoded(fourLevels.encoded())) { error in
            XCTAssertEqual(error as? SmartPlaylistRuleError, .tooComplex)
        }
    }

    func testSmartPlaylistRulesRoundTripAndFlagCatalogLimitedRules() throws {
        let stateOnly = SmartPlaylistRule.all([.favorite(true), .playCountAtLeast(10)])
        XCTAssertFalse(stateOnly.usesCatalogAttributes)
        XCTAssertEqual(try SmartPlaylistRule.decoded(stateOnly.encoded()), stateOnly)
        XCTAssertTrue(SmartPlaylistRule.any([stateOnly, .composer("Bach")]).usesCatalogAttributes)
        XCTAssertTrue(SmartPlaylistRule.durationAtLeast(300).usesCatalogAttributes)
    }

    func testPerDeviceCountersSumWithoutClobbering() throws {
        _ = try insertTrack(syncID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", title: "Counter")
        try manager.write { db in
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count) VALUES (?, 'MAC', 3), (?, 'PHONE', 4)", arguments: ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
        }
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT SUM(count) FROM play_counters") }, 7)
    }

    func testMetadataArchiveIsAtomicAndValidNDJSON() throws {
        _ = try insertTrack(syncID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", title: "Archived")
        let destination = directory.appendingPathComponent("metadata.ndjson")
        try MetadataArchive.export(to: destination, from: manager)
        XCTAssertNoThrow(try MetadataArchive.validate(destination))
        let text = try String(contentsOf: destination)
        XCTAssertTrue(text.contains("moonlight-metadata"))
        XCTAssertTrue(text.contains("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
    }

    func testSnapshotPruningPreservesSafetyPointsAndIgnoresUnrelatedFiles() throws {
        let snapshotDirectory = directory.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var dailyURLs: [URL] = []
        var safetyURLs: [URL] = []

        for index in 0..<7 {
            let url = snapshotDirectory.appendingPathComponent("moonlight-metadata-\(index).ndjson")
            try Data("daily".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(Double(-index) * 86_400)], ofItemAtPath: url.path)
            dailyURLs.append(url)
        }
        for index in 0..<8 {
            let url = snapshotDirectory.appendingPathComponent("moonlight-before-restore-\(index).ndjson")
            try Data("safety".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(Double(index + 1) * 60)], ofItemAtPath: url.path)
            safetyURLs.append(url)
        }
        let unrelated = snapshotDirectory.appendingPathComponent("notes.txt")
        try Data("not a snapshot".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-400 * 86_400)], ofItemAtPath: unrelated.path)

        try MetadataSnapshotStore.prune(directory: snapshotDirectory, now: now, fileManager: .default)

        XCTAssertTrue(dailyURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(safetyURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testMetadataArchiveRejectsLineBoundaryTruncation() throws {
        _ = try insertTrack(syncID: "C3C3C3C3-C3C3-43C3-83C3-C3C3C3C3C3C3", title: "Must not disappear")
        let complete = directory.appendingPathComponent("complete.ndjson")
        let truncated = directory.appendingPathComponent("truncated.ndjson")
        try MetadataArchive.export(to: complete, from: manager)
        var lines = try String(contentsOf: complete, encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        lines.removeLast()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: truncated)

        XCTAssertThrowsError(try MetadataArchive.validate(truncated))
    }

    func testMetadataArchiveRemovesTemporaryFileWhenReplacementFails() throws {
        let parent = directory.appendingPathComponent("archive-failure", isDirectory: true)
        let occupiedDestination = parent.appendingPathComponent("occupied.ndjson")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("existing archive".utf8).write(to: occupiedDestination)

        XCTAssertThrowsError(try MetadataArchive.export(
            to: occupiedDestination,
            from: manager,
            install: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".occupied.ndjson.") && $0.pathExtension == "tmp" }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStartupSweepRemovesOnlyOldMoonlightRewriteTemps() throws {
        let root = directory.appendingPathComponent("sweep", isDirectory: true)
        let nested = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let old = nested.appendingPathComponent(".moonlight-11111111-1111-4111-8111-111111111111-song.flac")
        let recent = nested.appendingPathComponent(".moonlight-22222222-2222-4222-8222-222222222222-song.flac")
        let userFile = nested.appendingPathComponent(".moonlight-not-a-rewrite.flac")
        for url in [old, recent, userFile] { try Data("temp".utf8).write(to: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: userFile.path)

        let removed = try PortableIdentityTagger.sweepOrphanedTemporaryFiles(in: root, olderThan: 86_400, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func testMalformedMP3TagBoundariesThrowInsteadOfUnderflowing() throws {
        let malformed = directory.appendingPathComponent("malformed.mp3")
        var bytes = Data(repeating: 0, count: 64)
        bytes.replaceSubrange(0..<10, with: [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        bytes.replaceSubrange(32..<40, with: Data("APETAGEX".utf8))
        bytes.replaceSubrange(44..<48, with: withUnsafeBytes(of: UInt32(32).littleEndian) { Data($0) })
        try bytes.write(to: malformed)

        XCTAssertThrowsError(try AudioEssenceHasher.hash(url: malformed))
    }

    func testArchivePreservesRedirectOriginsAndCannotGrantCloudEligibility() throws {
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        _ = try insertTrack(syncID: a, title: "Survivor")
        let localB = try insertTrack(syncID: b, title: "Origin")
        let playlist = try insertPlaylist()
        let rev = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "A").rawValue
        try manager.write { db in
            try AppState.appendTrackIds([localB], toPlaylist: playlist, in: db)
            try SyncRecordApplier.apply([
                .track(.init(id: b, rating: 5, ratingRev: rev, mergedInto: a)),
                .counter(.init(trackID: a, deviceID: "A", count: 3)),
                .counter(.init(trackID: b, deviceID: "B", count: 4))
            ], to: db)
            // Simulate a legacy archive which claimed promotion without proof.
            try db.execute(sql: "UPDATE logical_tracks SET is_promoted=1")
        }
        let archive = directory.appendingPathComponent("redirect-restore.ndjson")
        try MetadataArchive.export(to: archive, from: manager)
        let restored = try DatabaseManager(path: directory.appendingPathComponent("restored.sqlite").path)
        try MetadataArchive.restore(from: archive, to: restored, createSafetySnapshot: false)
        try restored.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT track_sync_id FROM synced_playlist_entries"), b)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MIN(play_count) FROM tracks"), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(count) FROM play_counters"), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MIN(rating) FROM tracks"), 5)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(is_promoted) FROM tracks"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM verified_track_identities"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_type != 'Playlist'"), 0)
        }
    }

    func testArchiveRedirectToLaterTargetRestoresAndCycleRollsBack() throws {
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        _ = try insertTrack(syncID: a, title: "Legacy forward edge")
        _ = try insertTrack(syncID: b, title: "Later target")
        try manager.write { try $0.execute(sql: "UPDATE logical_tracks SET merged_into=? WHERE track_sync_id=?", arguments: [b,a]) }
        let archive = directory.appendingPathComponent("forward.ndjson")
        try MetadataArchive.export(to: archive, from: manager)
        let restored = try DatabaseManager(path: directory.appendingPathComponent("forward.sqlite").path)
        try MetadataArchive.restore(from: archive, to: restored, createSafetySnapshot: false)
        XCTAssertEqual(try restored.read { try IdentityRepository.resolveTerminal(a, in: $0) }, b)
        try manager.write { try $0.execute(sql: "UPDATE logical_tracks SET merged_into=? WHERE track_sync_id=?", arguments: [a,b]) }
        try MetadataArchive.export(to: archive, from: manager)
        XCTAssertThrowsError(try MetadataArchive.restore(from: archive, to: restored, createSafetySnapshot: false))
        XCTAssertEqual(try restored.read { try IdentityRepository.resolveTerminal(a, in: $0) }, b)
    }

    func testMetadataArchiveRestoreIsTransactionalAndRequeuesState() throws {
        let syncID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let localTrack = try insertTrack(syncID: syncID, title: "Restorable")
        let playlist = try insertPlaylist()
        try manager.write { db in
            let rev = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "MAC").rawValue
            try db.execute(sql: "INSERT OR REPLACE INTO track_annotations (track_sync_id, rating, rating_rev, favorite, favorite_rev) VALUES (?, 5, ?, 1, ?)", arguments: [syncID, rev, rev])
            try db.execute(sql: "UPDATE logical_tracks SET is_promoted = 1 WHERE track_sync_id = ?", arguments: [syncID])
            try AppState.appendTrackIds([localTrack], toPlaylist: playlist, in: db)
            try db.execute(sql: "INSERT INTO play_counters (track_sync_id, device_id, count, last_played_at) VALUES (?, ?, 9, ?)", arguments: [syncID, try SyncDeviceIdentity.id(in: db), Date(timeIntervalSince1970: 200)])
        }
        let archive = directory.appendingPathComponent("restore.ndjson")
        try MetadataArchive.export(to: archive, from: manager, createdAt: Date(timeIntervalSince1970: 300))

        try manager.write { db in
            try db.execute(sql: "DELETE FROM track_annotations")
            try db.execute(sql: "DELETE FROM playlist_tracks")
            try db.execute(sql: "DELETE FROM playlists")
            try db.execute(sql: "DELETE FROM play_counters")
        }
        try MetadataArchive.restore(from: archive, to: manager, createSafetySnapshot: false)

        try manager.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM track_annotations WHERE track_sync_id = ?", arguments: [syncID]), 5)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT favorite FROM track_annotations WHERE track_sync_id = ?", arguments: [syncID]), true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(count) FROM play_counters WHERE track_sync_id = ?", arguments: [syncID]), 9)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks"), 1)
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0, 0)
        }
    }

    func testMetadataArchiveRestoreDerivesPositionFromOrderingKey() throws {
        let trackID = "EFEFEFEF-EFEF-4FEF-8FEF-EFEFEFEFEFEF"
        let localTrackID = try insertTrack(syncID: trackID, title: "Archive order")
        let playlistID = try insertPlaylist()
        try manager.write { db in
            let playlistSyncID = "12121212-1212-4212-8212-121212121212"
            try db.execute(sql: "UPDATE playlists SET playlist_sync_id = ? WHERE id = ?", arguments: [playlistSyncID, playlistID])
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at) VALUES (?, ?, 0, 'ZZZ-ENTRY', 'A', '', ?), (?, ?, 1, 'AAA-ENTRY', 'Z', '', ?)", arguments: [playlistID, localTrackID, Date(), playlistID, localTrackID, Date()])
        }
        let archive = directory.appendingPathComponent("ordered-restore.ndjson")
        try MetadataArchive.export(to: archive, from: manager)
        try MetadataArchive.restore(from: archive, to: manager, createSafetySnapshot: false)

        let rows = try manager.read { db in
            try Row.fetchAll(db, sql: "SELECT playlist_entry_id, position FROM playlist_tracks ORDER BY position")
        }
        XCTAssertEqual(rows.map { $0["playlist_entry_id"] as String }, ["ZZZ-ENTRY", "AAA-ENTRY"])
        XCTAssertEqual(rows.map { $0["position"] as Int }, [0, 1])
    }

    func testCloudKitFetchBatchMaterializesResolvableEntriesOnce() async throws {
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let trackID = "34343434-3434-4434-8434-343434343434"
        let playlistID = "56565656-5656-4656-8656-565656565656"
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let revision = SyncRevision.make(at: Date(timeIntervalSince1970: 100), writerID: "PHONE").rawValue

        func record(_ type: String, _ name: String) -> CKRecord {
            let value = CKRecord(recordType: type, recordID: .init(recordName: name, zoneID: zone))
            value["schemaVersion"] = NSNumber(value: 1)
            return value
        }
        let first = record("PlaylistEntry", "entry_FIRST")
        first["playlistEntryID"] = "FIRST" as NSString
        first["playlistID"] = playlistID as NSString
        first["trackSyncID"] = trackID as NSString
        first["orderingKey"] = "Z" as NSString
        first["orderingKeyRev"] = revision as NSString
        first["createdAt"] = Date(timeIntervalSince1970: 2) as NSDate
        let second = record("PlaylistEntry", "entry_SECOND")
        second["playlistEntryID"] = "SECOND" as NSString
        second["playlistID"] = playlistID as NSString
        second["trackSyncID"] = trackID as NSString
        second["orderingKey"] = "A" as NSString
        second["orderingKeyRev"] = revision as NSString
        second["createdAt"] = Date(timeIntervalSince1970: 1) as NSDate
        let playlist = record("Playlist", "playlist_\(playlistID)")
        playlist["playlistID"] = playlistID as NSString
        playlist["name"] = "Batch" as NSString
        playlist["nameRev"] = revision as NSString
        playlist["sortModeRev"] = revision as NSString
        playlist["createdAt"] = Date(timeIntervalSince1970: 1) as NSDate
        let track = record("SyncedTrack", "track_\(trackID)")
        track["trackSyncID"] = trackID as NSString
        track["title"] = "Batch track" as NSString
        track["metadataRev"] = revision as NSString

        var stagedEntryReads = 0
        try manager.write { db in
            db.trace { event in
                if event.description.contains("FROM synced_playlist_entries se") {
                    stagedEntryReads += 1
                }
            }
        }
        defer { try? manager.write { $0.trace(options: []) } }
        try await CloudKitSyncCoordinator(manager: manager).applyFetchedRecords(
            [first, second, playlist, track],
            receivedAt: receivedAt
        )

        XCTAssertEqual(stagedEntryReads, 1)
        let positions = try manager.read { db in
            try Int.fetchAll(db, sql: "SELECT position FROM playlist_tracks ORDER BY ordering_key, playlist_entry_id")
        }
        XCTAssertEqual(positions, [0, 1])
    }

    func testMacPlaylistQueryExcludesSyncedEntryTombstone() throws {
        let trackSyncID = "B1-TRACK-\(UUID().uuidString)"
        let trackLocalID = try insertTrack(syncID: trackSyncID, title: "Removed remotely")
        let playlistLocalID = try insertPlaylist()
        let playlistSyncID = try manager.read { db in
            try XCTUnwrap(String.fetchOne(db, sql: "SELECT playlist_sync_id FROM playlists WHERE id = ?", arguments: [playlistLocalID]))
        }
        let revision = SyncRevision.make(
            at: Date(timeIntervalSince1970: 100),
            writerID: "PHONE"
        ).rawValue

        try manager.write { db in
            try SQLiteSyncTransport.apply([
                .entry(.init(
                    id: "B1-ENTRY",
                    playlistID: playlistSyncID,
                    trackID: trackSyncID,
                    orderingKey: "U",
                    orderingKeyRev: revision,
                    createdAt: Date(timeIntervalSince1970: 10),
                    deletedAt: nil
                ))
            ], to: db, receivedAt: Date(timeIntervalSince1970: 200))
        }
        XCTAssertEqual(try manager.read { try PlaylistEntry.fetchVisible(in: playlistLocalID, from: $0).map(\.track.dbId) }, [trackLocalID])

        try manager.write { db in
            try SQLiteSyncTransport.apply([
                .entry(.init(
                    id: "B1-ENTRY",
                    playlistID: playlistSyncID,
                    trackID: trackSyncID,
                    orderingKey: "U",
                    orderingKeyRev: revision,
                    createdAt: Date(timeIntervalSince1970: 10),
                    deletedAt: Date(timeIntervalSince1970: 300)
                ))
            ], to: db, receivedAt: Date(timeIntervalSince1970: 400))
        }

        XCTAssertTrue(try manager.read { try PlaylistEntry.fetchVisible(in: playlistLocalID, from: $0).isEmpty })
    }

    @MainActor
    func testThrowingCloudKitBatchRequiresExplicitFullResyncRecovery() async throws {
        let first = "B2-A-\(UUID().uuidString)"
        let second = "B2-B-\(UUID().uuidString)"
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO logical_tracks (track_sync_id, title, merged_into, created_at, is_promoted) VALUES (?, 'A', ?, ?, 1), (?, 'B', ?, ?, 1)",
                arguments: [first, second, Date(), second, first, Date()]
            )
        }

        let zone = CKRecordZone.ID(
            zoneName: CloudKitSyncCoordinator.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let validPlaylistID = "B2-PLAYLIST-\(UUID().uuidString)"
        let valid = CKRecord(
            recordType: "Playlist",
            recordID: .init(recordName: "playlist_\(validPlaylistID)", zoneID: zone)
        )
        valid["playlistID"] = validPlaylistID as NSString
        valid["name"] = "Rolled back" as NSString
        valid["createdAt"] = Date() as NSDate
        let poison = CKRecord(
            recordType: "SyncedTrack",
            recordID: .init(recordName: "track_\(first)", zoneID: zone)
        )
        poison["trackSyncID"] = first as NSString

        let appState = AppState(db: manager)
        let coordinator = appState.cloudSync
        do {
            try await coordinator.applyFetchedRecords([valid, poison])
            XCTFail("Expected the corrupt identity cycle to reject the batch")
        } catch IdentityRepositoryError.cyclicMerge {
            // The batch remains atomic, but the coordinator must expose recovery.
        }

        let recoveryRequired = await MainActor.run { coordinator.status.requiresFullResync }
        XCTAssertTrue(recoveryRequired)
        let recoveryProblem = await MainActor.run { coordinator.status.problem }
        XCTAssertEqual(recoveryProblem, .fetchedBatchRejected)
        XCTAssertNotNil(try manager.read {
            try Data.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = 'rejected_batch_requires_full_resync'")
        })
        XCTAssertNil(try manager.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM playlists WHERE playlist_sync_id = ?", arguments: [validPlaylistID])
        })
        XCTAssertEqual(appState.libraryVersion, 0, "A rolled-back fetched batch must not invalidate UI read models")
    }

    func testMaterializationQueriesAreStructurallyChunked() throws {
        let records: [SyncTransportRecord] = (0..<2_501).map { index in
            .entry(.init(
                id: "B3-ENTRY-\(index)",
                playlistID: "B3-MISSING-PLAYLIST",
                trackID: "B3-MISSING-TRACK",
                orderingKey: String(format: "%08d", index),
                orderingKeyRev: "",
                createdAt: Date(timeIntervalSince1970: Double(index)),
                deletedAt: nil
            ))
        }
        var materializationReads = 0

        try manager.write { db in
            db.trace { event in
                if event.description.contains("FROM synced_playlist_entries se") {
                    materializationReads += 1
                }
            }
            defer { db.trace(options: []) }
            try SyncRecordApplier.apply(records, to: db)
        }

        XCTAssertEqual(materializationReads, 3, "2,501 IDs must be queried in 1,000-item chunks")
    }

    func testInvalidArchiveDoesNotMutateCurrentMetadata() throws {
        let syncID = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
        _ = try insertTrack(syncID: syncID, title: "Safe")
        try manager.write { db in
            try db.execute(sql: "INSERT INTO track_annotations (track_sync_id, rating) VALUES (?, 4)", arguments: [syncID])
        }
        let invalid = directory.appendingPathComponent("invalid.ndjson")
        try Data("{\"type\":\"not-moonlight\"}\n".utf8).write(to: invalid)
        XCTAssertThrowsError(try MetadataArchive.restore(from: invalid, to: manager, createSafetySnapshot: false))
        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT rating FROM track_annotations WHERE track_sync_id = ?", arguments: [syncID]) }, 4)
    }

    func testHardLinkedFileIsRejectedBeforeAnyWrite() async throws {
        let original = directory.appendingPathComponent("hard-linked.mp3")
        let linked = directory.appendingPathComponent("hard-linked-copy.mp3")
        try Data("not-a-real-mp3".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)
        guard PortableIdentityFilesystemPolicy.permitsAtomicReplace(at: original) else { throw XCTSkip("Test volume is not on the proven allowlist") }
        let values = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let tagger = PortableIdentityTagger(db: manager)
        do {
            try await tagger.tag(url: original, identity: UUID().uuidString, expectedSize: Int64(values.fileSize ?? 0), expectedMtime: values.contentModificationDate)
            XCTFail("Expected hard-link refusal")
        } catch PortableIdentityError.hardLinked {
            XCTAssertEqual(try Data(contentsOf: original), Data("not-a-real-mp3".utf8))
            XCTAssertEqual(try Data(contentsOf: linked), Data("not-a-real-mp3".utf8))
        }
    }

    func testCheckedInFormatFixturesSurviveActualAtomicRewrite() async throws {
        let fixtures = ["mp3", "flac", "m4a", "ogg", "opus"]
        let tagger = PortableIdentityTagger(db: manager)

        for ext in fixtures {
            let bundled = try XCTUnwrap(
                Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: ext),
                "The checked-in \(ext) fixture must be a test resource"
            )
            let working = directory.appendingPathComponent("rewrite-working.\(ext)")
            try FileManager.default.copyItem(at: bundled, to: working)
            XCTAssertTrue(PortableIdentityFilesystemPolicy.permitsAtomicReplace(at: working), "The rewrite fixture must run on the APFS allowlist")

            let beforeTags = try XCTUnwrap(
                normalizedTags(TagLibBridge.getProperties(working.path) as? [String: String]),
                "TagLib must open the real \(ext) fixture"
            )
            XCTAssertEqual(beforeTags["TITLE"], "Moonlight — 東京", ext)
            if ext == "mp3" {
                XCTAssertTrue(beforeTags.values.contains("FOREIGN-MBID-001"), "The MP3 fixture must carry a foreign MusicBrainz tag before Moonlight rewrites it")
            }
            let beforeHash = try AudioEssenceHasher.hash(url: working)
            let beforeBytes = try Data(contentsOf: working)
            let resources = try working.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let identity = UUID().uuidString.uppercased()

            try await tagger.tag(
                url: working,
                identity: identity,
                expectedSize: Int64(resources.fileSize ?? -1),
                expectedMtime: resources.contentModificationDate
            )

            XCTAssertNotEqual(try Data(contentsOf: working), beforeBytes, "\(ext) must actually be rewritten")
            XCTAssertEqual(PortableIdentityTag.read(from: working), identity, ext)
            if ext == "mp3" {
                let frames = TagLibBridge.moonlightTrackIDFrames(working.path)
                XCTAssertEqual(frames["UFID"], identity, "MP3 must carry the Moonlight UFID")
                XCTAssertEqual(frames["TXXX"], identity, "MP3 must carry the Moonlight TXXX fallback")
                let surfacedTags = try XCTUnwrap(TagLibBridge.getProperties(working.path) as? [String: String])
                XCTAssertEqual(surfacedTags["MOONLIGHT_TRACK_ID"], identity, "TagLib must surface the TXXX description as the filtered property key")
            }
            XCTAssertEqual(try AudioEssenceHasher.hash(url: working), beforeHash, ext)
            XCTAssertEqual(
                normalizedTags(TagLibBridge.getProperties(working.path) as? [String: String]),
                beforeTags,
                "\(ext) pre-existing metadata changed"
            )
        }
    }

    func testMP3DualIdentityFramesReadAndSelfHeal() async throws {
        let bundled = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3")
        )
        let expectedHash = try AudioEssenceHasher.hash(url: bundled)
        let identity = UUID().uuidString.uppercased()

        let ufidOnly = directory.appendingPathComponent("ufid-only.mp3")
        try FileManager.default.copyItem(at: bundled, to: ufidOnly)
        try PortableIdentityTag.write(identity, to: ufidOnly)
        XCTAssertTrue(TagLibBridge.updateProperties(
            ufidOnly.path,
            setting: [:],
            removing: ["MOONLIGHT_TRACK_ID"]
        ))
        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(ufidOnly.path), ["UFID": identity])
        XCTAssertEqual(PortableIdentityTag.read(from: ufidOnly), identity, "UFID-only MP3s must remain readable")
        try await tagFile(ufidOnly, identity: identity)
        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(ufidOnly.path), ["UFID": identity, "TXXX": identity])
        XCTAssertEqual(try AudioEssenceHasher.hash(url: ufidOnly), expectedHash)

        let txxxOnly = directory.appendingPathComponent("txxx-only.mp3")
        try FileManager.default.copyItem(at: bundled, to: txxxOnly)
        XCTAssertTrue(TagLibBridge.updateProperties(
            txxxOnly.path,
            setting: ["MOONLIGHT_TRACK_ID": identity],
            removing: []
        ))
        let txxxProperties = try XCTUnwrap(TagLibBridge.getProperties(txxxOnly.path) as? [String: String])
        XCTAssertEqual(txxxProperties["MOONLIGHT_TRACK_ID"], identity)
        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(txxxOnly.path), ["TXXX": identity])
        XCTAssertEqual(PortableIdentityTag.read(from: txxxOnly), identity, "TXXX-only MP3s must remain readable")
        try await tagFile(txxxOnly, identity: identity)
        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(txxxOnly.path), ["UFID": identity, "TXXX": identity])
        XCTAssertEqual(try AudioEssenceHasher.hash(url: txxxOnly), expectedHash)
    }

    func testMP3DisagreementPrefersUFIDAndTaggingReconcilesTXXX() async throws {
        let bundled = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3")
        )
        let working = directory.appendingPathComponent("disagreeing-frames.mp3")
        try FileManager.default.copyItem(at: bundled, to: working)
        let ufidIdentity = UUID().uuidString.uppercased()
        let txxxIdentity = UUID().uuidString.uppercased()
        try PortableIdentityTag.write(ufidIdentity, to: working)
        XCTAssertTrue(TagLibBridge.updateProperties(
            working.path,
            setting: ["MOONLIGHT_TRACK_ID": txxxIdentity],
            removing: []
        ))

        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(working.path), [
            "UFID": ufidIdentity,
            "TXXX": txxxIdentity
        ])
        XCTAssertEqual(PortableIdentityTag.read(from: working), ufidIdentity, "UFID is authoritative when valid frames disagree")

        try await tagFile(working, identity: ufidIdentity)
        XCTAssertEqual(TagLibBridge.moonlightTrackIDFrames(working.path), [
            "UFID": ufidIdentity,
            "TXXX": ufidIdentity
        ])
    }

    func testAutomaticTaggingNeverReplacesAnExistingDifferentIdentity() async throws {
        let bundled = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "rewrite-fixture", withExtension: "mp3")
        )
        let working = directory.appendingPathComponent("already-tagged-copy.mp3")
        try FileManager.default.copyItem(at: bundled, to: working)
        XCTAssertTrue(PortableIdentityFilesystemPolicy.permitsAtomicReplace(at: working))

        let embeddedIdentity = UUID().uuidString.uppercased()
        let pendingIdentity = UUID().uuidString.uppercased()
        try PortableIdentityTag.write(embeddedIdentity, to: working)
        let beforeBytes = try Data(contentsOf: working)
        let resources = try working.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        do {
            try await PortableIdentityTagger(db: manager).tag(
                url: working,
                identity: pendingIdentity,
                expectedSize: Int64(resources.fileSize ?? -1),
                expectedMtime: resources.contentModificationDate
            )
            XCTFail("Automatic tagging must not replace an existing Moonlight identifier")
        } catch PortableIdentityError.existingIdentityMismatch(let expected, let found) {
            XCTAssertEqual(expected, pendingIdentity)
            XCTAssertEqual(found, embeddedIdentity)
        }

        XCTAssertEqual(PortableIdentityTag.read(from: working), embeddedIdentity)
        XCTAssertEqual(try Data(contentsOf: working), beforeBytes)
    }

    func testExternalToolRoundTripPreservesMoonlightMP3Identity() throws {
        guard let path = ProcessInfo.processInfo.environment["MOONLIGHT_VERIFY_FILE"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set MOONLIGHT_VERIFY_FILE to manually verify an externally round-tripped MP3")
        }

        let url = URL(fileURLWithPath: path)
        let frames = TagLibBridge.moonlightTrackIDFrames(url.path)
        let ufid = frames["UFID"] ?? "MISSING"
        let txxx = frames["TXXX"] ?? "MISSING"
        let resolved = PortableIdentityTag.read(from: url)
        print("Moonlight portable ID verification: \(url.path)")
        print("UFID owner https://moonlight.app/track-id: \(ufid)")
        print("TXXX description MOONLIGHT_TRACK_ID: \(txxx)")
        print("Resolved Moonlight track ID (UFID preferred): \(resolved ?? "UNREADABLE")")
        XCTAssertNotNil(resolved, "No valid Moonlight UUID was readable from UFID or TXXX")
    }

    @discardableResult
    private func insertTrack(syncID: String, title: String) throws -> Int64 {
        var track = Track(fileURL: "file:///tmp/\(UUID().uuidString).flac", title: title, dateAdded: Date(), trackSyncId: syncID)
        try manager.write { db in
            try track.insert(db)
            _ = try SyncIdentityBridge.ensureLogicalTrack(forLocalTrackID: track.dbId!, in: db)
        }
        return track.dbId!
    }

    private func insertPlaylist() throws -> Int64 {
        var playlist = Playlist(name: "Duplicates", dateCreated: Date(), dateModified: Date())
        try manager.write { try playlist.insert($0) }
        return playlist.id!
    }

    private func tagFile(_ url: URL, identity: String) async throws {
        XCTAssertTrue(PortableIdentityFilesystemPolicy.permitsAtomicReplace(at: url), "The rewrite fixture must run on the APFS allowlist")
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try await PortableIdentityTagger(db: manager).tag(
            url: url,
            identity: identity,
            expectedSize: Int64(resources.fileSize ?? -1),
            expectedMtime: resources.contentModificationDate
        )
    }

    private func normalizedTags(_ tags: [String: String]?) -> [String: String]? {
        tags?.filter { key, _ in
            let normalized = key.uppercased()
            return normalized != "MOONLIGHT_TRACK_ID"
                && !normalized.contains("MOONLIGHT.APP/TRACK-ID")
                && !normalized.contains("COM.MOONLIGHT.APP")
        }
    }
}
