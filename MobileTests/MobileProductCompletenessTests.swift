import GRDB
import MediaPlayer
import UIKit
import XCTest
@testable import Moonlight

@MainActor
final class MobileProductCompletenessTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var containerFiles: [URL] = []

    func testSharedCatalogPredicateExcludesSyncStubsFromMobilePageAndSearch() throws {
        _ = try insertTrack(relativePath: "available.m4a", size: 1, title: "Audit Available")
        try database.write { db in
            var stub = Track(fileURL: "moonlight-unavailable://44444444-4444-4444-8444-444444444444", title: "Audit Remote", dateAdded: Date())
            XCTAssertTrue(stub.isSyncOnlyPlaceholder)
            try stub.insert(db)
            try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')")
            XCTAssertEqual(try MobileLibraryQuery.fetchPage(limit: 20, in: db).map(\.displayTitle), ["Audit Available"])
            XCTAssertEqual(try MobileLibraryQuery.search("Audit", limit: 20, in: db).map(\.displayTitle), ["Audit Available"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks"), 2, "The stub remains available for synced playlist references")
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightMobileProductTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        for url in containerFiles { try? FileManager.default.removeItem(at: url) }
        database = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testIndependentUntaggedImportsDoNotInferIdentityFromAudioHash() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "duplicate-source", withExtension: "m4a"))
        let service = MobileImportService(database: database, writerID: { _ in "TEST-WRITER" })

        let failures = await service.importFiles([source, source]) { _ in }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT file_url, audio_hash, artwork_id, id_state FROM tracks WHERE availability_status='available'")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT track_sync_id) FROM tracks") }, 2)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotNil(row["audio_hash"] as String?)
        let artworkID: Int64? = row["artwork_id"]
        XCTAssertNotNil(artworkID, "The real imported fixture's embedded cover should be stored")
        XCTAssertNotNil(try database.read { try Data.fetchOne($0, sql: "SELECT data_large FROM artwork WHERE id=?", arguments: [artworkID]) })
        XCTAssertEqual(
            row["id_state"] as String?,
            "embedded",
            "Container imports must pass the APFS filesystem gate"
        )
        let stored: String = row["file_url"]
        let imported = try XCTUnwrap(ContainerPathResolver.existingURL(forStoredFileURL: stored))
        for value in rows {
            let stored: String = value["file_url"]
            containerFiles.append(try XCTUnwrap(ContainerPathResolver.existingURL(forStoredFileURL: stored)))
        }
        let matchingCopies = try FileManager.default.contentsOfDirectory(
            at: imported.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("duplicate-source") }
        XCTAssertEqual(matchingCopies.count, 2)
    }

    func testActiveSceneRevalidationMarksOnlyMissingContainerFilesUnavailable() throws {
        let existing = try makeContainerFile(named: "existing-\(UUID().uuidString).m4a", bytes: 4)
        let missingName = "missing-\(UUID().uuidString).m4a"
        let existingID = try insertTrack(file: existing)
        let missingID = try insertTrack(relativePath: missingName, size: 8)

        let changed = try MobileLibraryMaintenance.revalidateAvailableFiles(in: database)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try availability(of: existingID), "available")
        XCTAssertEqual(try availability(of: missingID), "unavailable")
    }

    func testDeleteTrackRemovesAudioReportsStorageAndTombstonesMembership() throws {
        let file = try makeContainerFile(named: "delete-\(UUID().uuidString).m4a", bytes: 128)
        let trackID = try insertTrack(file: file)
        let track = try XCTUnwrap(database.read { try Track.fetchOne($0, key: trackID) })
        var playlist = Playlist(name: "Delete", dateCreated: Date(), dateModified: Date())
        try database.write { db in
            try playlist.insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at) VALUES (?, ?, 0, 'DELETE-ENTRY', 'U', '', ?)", arguments: [playlist.id, trackID, Date()])
        }

        XCTAssertEqual(try MobileLibraryMaintenance.storageUsage(in: database), 128)
        try MobileLibraryMaintenance.delete(track: track, in: database)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try availability(of: trackID), "deleted")
        XCTAssertEqual(try MobileLibraryMaintenance.storageUsage(in: database), 0)
        XCTAssertNotNil(try database.read { try Date.fetchOne($0, sql: "SELECT deleted_at FROM playlist_tracks WHERE playlist_entry_id='DELETE-ENTRY'") })
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_name='entry_DELETE-ENTRY'") }, 0)
    }

    func testLibraryPageAndFTSSearchAreBoundedAndDatabaseBacked() throws {
        for index in 0..<6 {
            _ = try insertTrack(relativePath: "page-\(index).m4a", size: 1, title: index == 5 ? "Needle Symphony" : "Other \(index)")
        }
        try database.write { try $0.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')") }

        let page = try database.read { try MobileLibraryQuery.fetchPage(limit: 3, in: $0) }
        let results = try database.read { try MobileLibraryQuery.search("Needle", limit: 20, in: $0) }

        XCTAssertEqual(page.count, 3)
        XCTAssertEqual(results.map(\.displayTitle), ["Needle Symphony"])
    }

    func testRecordingAPlayDoesNotRewriteTheObservedTracksTable() throws {
        let trackID = try insertTrack(relativePath: "play.m4a", size: 1)

        try MobilePlaybackPersistence.recordPlay(localTrackID: trackID, in: database, writerID: { _ in "TEST-WRITER" })

        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT play_count FROM tracks WHERE id=?", arguments: [trackID]) }, 0)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT SUM(count) FROM play_counters") }, 1)
    }

    func testNowPlayingInfoIncludesArtworkAndResolvedDuration() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let artworkData = renderer.pngData { context in UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let track = Track(fileURL: "moonlight-manual:///now-playing.m4a", title: "Artwork", duration: 1, dateAdded: Date())

        let info = MobilePlaybackController.nowPlayingInfo(
            for: track,
            duration: 42,
            currentTime: 3,
            isPlaying: true,
            artworkData: artworkData
        )

        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 42)
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    }

    func testLayoutUsesSidebarOnlyForIPad() {
        XCTAssertFalse(MobileLayoutPolicy.usesSidebar(for: .phone))
        XCTAssertTrue(MobileLayoutPolicy.usesSidebar(for: .pad))
    }

    func testLocalOnlyPlaylistEntryRemovalDoesNotQueueCloudDelete() throws {
        let trackID = try insertTrack(relativePath: "playlist.m4a", size: 1)
        var playlist = Playlist(name: "Remove", dateCreated: Date(), dateModified: Date())
        try database.write { db in
            try playlist.insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, playlist_entry_id, ordering_key, ordering_key_rev, created_at) VALUES (?, ?, 0, 'REMOVE-ENTRY', 'U', '', ?)", arguments: [playlist.id, trackID, Date()])
            try PlaylistEntry.softDelete(entryIDs: [try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM playlist_tracks WHERE playlist_entry_id='REMOVE-ENTRY'"))], inPlaylist: try XCTUnwrap(playlist.id), in: db)
        }

        XCTAssertNotNil(try database.read { try Date.fetchOne($0, sql: "SELECT deleted_at FROM playlist_tracks WHERE playlist_entry_id='REMOVE-ENTRY'") })
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_name='entry_REMOVE-ENTRY'") }, 0)
    }

    private func makeContainerFile(named name: String, bytes: Int) throws -> URL {
        let root = try ContainerPathResolver.directory(for: .manual)
        let file = root.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: file)
        containerFiles.append(file)
        return file
    }

    @discardableResult
    private func insertTrack(file: URL, title: String = "Mobile") throws -> Int64 {
        try insertTrack(relativePath: file.lastPathComponent, size: Int((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0), title: title)
    }

    @discardableResult
    private func insertTrack(relativePath: String, size: Int, title: String = "Mobile") throws -> Int64 {
        let syncID = UUID().uuidString.uppercased()
        let physicalID = UUID().uuidString.uppercased()
        let reference = try XCTUnwrap(ContainerFileReference(root: .manual, relativePath: relativePath))
        var track = Track(fileURL: reference.rawValue, fileSize: Int64(size), title: title, duration: 1, dateAdded: Date(), trackSyncId: syncID, physicalFileId: physicalID)
        try database.write { db in
            try db.execute(sql: "INSERT INTO logical_tracks (track_sync_id, title, created_at) VALUES (?, ?, ?)", arguments: [syncID, title, Date()])
            try track.insert(db)
            try db.execute(sql: "INSERT INTO physical_files (physical_file_id, track_sync_id, library_root_id, relative_path, file_size, id_state) VALUES (?, ?, ?, ?, ?, 'embedded')", arguments: [physicalID, syncID, ContainerFileRoot.manual.rawValue, relativePath, size])
        }
        return try XCTUnwrap(track.dbId)
    }

    private func availability(of trackID: Int64) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT availability_status FROM tracks WHERE id=?", arguments: [trackID]) }
    }
}
