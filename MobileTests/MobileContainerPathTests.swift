import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class MobileContainerPathTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var resolvedFileURL: URL?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightMobileContainerPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let resolvedFileURL {
            try? FileManager.default.removeItem(at: resolvedFileURL)
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        resolvedFileURL = nil
        temporaryDirectory = nil
    }

    func testMigratedLegacyPathResolvesInsideCurrentContainerToExistingFile() throws {
        let filename = "A1-Migration-\(UUID().uuidString).m4a"
        let legacyURL = URL(
            fileURLWithPath: "/var/mobile/Containers/Data/Application/PRE-V14/Documents/Music/\(filename)"
        )
        let currentRoot = try ContainerPathResolver.directory(for: .manual)
        let currentFile = currentRoot.appendingPathComponent(filename)
        resolvedFileURL = currentFile
        try Data("playable fixture".utf8).write(to: currentFile, options: .atomic)

        XCTAssertNotEqual(
            legacyURL.deletingLastPathComponent().standardizedFileURL,
            currentRoot.standardizedFileURL,
            "The repro must use a stored container root different from the current simulator container."
        )

        let databaseURL = temporaryDirectory.appendingPathComponent("legacy.sqlite")
        var legacyDatabase: DatabaseManager? = try DatabaseManager(path: databaseURL.path)
        try legacyDatabase?.write { db in
            let trackSyncID = "A1-TRACK-\(UUID().uuidString)"
            let physicalFileID = "A1-PHYSICAL-\(UUID().uuidString)"
            try db.execute(
                sql: "INSERT INTO logical_tracks (track_sync_id, title, is_promoted, created_at) VALUES (?, 'A1 migration', 0, ?)",
                arguments: [trackSyncID, Date()]
            )
            var track = Track(
                fileURL: legacyURL.absoluteString,
                title: "A1 migration",
                dateAdded: Date(),
                trackSyncId: trackSyncID,
                physicalFileId: physicalFileID
            )
            try track.insert(db)
            try db.execute(
                sql: "INSERT INTO physical_files (physical_file_id, track_sync_id, library_root_id, relative_path, id_state, is_preferred) VALUES (?, ?, 'mobile-container', ?, 'embedded', 1)",
                arguments: [physicalFileID, trackSyncID, filename]
            )
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14_container_relative_paths'")
        }
        legacyDatabase = nil

        let migratedDatabase = try DatabaseManager(path: databaseURL.path)
        let migratedValue = try XCTUnwrap(migratedDatabase.read { db in
            try String.fetchOne(db, sql: "SELECT file_url FROM tracks LIMIT 1")
        })
        let resolvedURL = try XCTUnwrap(ContainerPathResolver.existingURL(forStoredFileURL: migratedValue))

        XCTAssertNotEqual(resolvedURL.standardizedFileURL, legacyURL.standardizedFileURL)
        XCTAssertEqual(resolvedURL.standardizedFileURL, currentFile.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.path))
    }
}
