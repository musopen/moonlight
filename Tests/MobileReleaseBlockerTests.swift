import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class MobileReleaseBlockerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightMobileReleaseBlockerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testMobileContainerReferenceSurvivesContainerPathChanges() throws {
        let oldDocuments = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Documents", isDirectory: true)
        let reference = try XCTUnwrap(ContainerFileReference(
            root: .manual,
            relativePath: "Classical/100% #1 – Bach Cello Suite.flac"
        ))

        XCTAssertFalse(reference.rawValue.contains(oldDocuments.path))
        XCTAssertEqual(ContainerFileReference(rawValue: reference.rawValue), reference)
    }

    func testMobileContainerMigrationRewritesExistingAbsoluteTrackURL() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("mobile-legacy.sqlite")
        var legacy: DatabaseManager? = try DatabaseManager(path: databaseURL.path)
        try legacy?.write { db in
            let trackSyncID = "MOBILE-LEGACY-TRACK"
            let physicalFileID = "MOBILE-LEGACY-PHYSICAL"
            try db.execute(
                sql: "INSERT INTO logical_tracks (track_sync_id, title, is_promoted, created_at) VALUES (?, 'Legacy', 0, ?)",
                arguments: [trackSyncID, Date()]
            )
            var track = Track(
                fileURL: "file:///var/mobile/Containers/Data/Application/OLD/Documents/Music/Legacy Song.flac",
                title: "Legacy",
                dateAdded: Date(),
                trackSyncId: trackSyncID,
                physicalFileId: physicalFileID
            )
            try track.insert(db)
            try db.execute(
                sql: "INSERT INTO physical_files (physical_file_id, track_sync_id, library_root_id, relative_path, id_state, is_preferred) VALUES (?, ?, 'mobile-container', 'Legacy Song.flac', 'embedded', 1)",
                arguments: [physicalFileID, trackSyncID]
            )
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14_container_relative_paths'")
        }
        legacy = nil

        let migrated = try DatabaseManager(path: databaseURL.path)
        let storedURL = try migrated.read {
            try String.fetchOne($0, sql: "SELECT file_url FROM tracks WHERE track_sync_id = 'MOBILE-LEGACY-TRACK'")
        }
        XCTAssertEqual(storedURL, ContainerFileReference(root: .manual, relativePath: "Legacy Song.flac")?.rawValue)
    }

    func testCloudPushTriggersFetchOnlyWhenEngineCanHandleIt() {
        XCTAssertTrue(CloudRemoteNotificationPolicy.shouldFetch(isCloudKitNotification: true, engineIsAvailable: true))
        XCTAssertFalse(CloudRemoteNotificationPolicy.shouldFetch(isCloudKitNotification: false, engineIsAvailable: true))
        XCTAssertFalse(CloudRemoteNotificationPolicy.shouldFetch(isCloudKitNotification: true, engineIsAvailable: false))
    }

    @MainActor
    func testMobileImportWorkRunsOffMainActor() async throws {
        let ranOnMainThread = await MobileBackgroundWork.run { Thread.isMainThread }
        XCTAssertFalse(ranOnMainThread)
    }

    func testMobileImportRebuildsFTSOnlyAfterAProductiveBatch() {
        XCTAssertFalse(MobileImportBatchPolicy.requiresSearchIndexRebuild(successfulImportCount: 0))
        XCTAssertTrue(MobileImportBatchPolicy.requiresSearchIndexRebuild(successfulImportCount: 1))
        XCTAssertTrue(MobileImportBatchPolicy.requiresSearchIndexRebuild(successfulImportCount: 60))
    }

    func testDatabaseOpenFailureIsThrownInsteadOfTrapping() throws {
        let blockingFile = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)

        XCTAssertThrowsError(try DatabaseManager(path: blockingFile.appendingPathComponent("library.sqlite").path))
    }

    func testAudioSessionDoesNotActivateAtLaunch() {
        XCTAssertFalse(MobileAudioSessionPolicy.requiresActivation(for: .launch))
    }

    func testAudioSessionReactivatesAfterResumableInterruption() {
        XCTAssertTrue(MobileAudioSessionPolicy.requiresActivation(for: .interruptionEndedShouldResume))
    }

    func testFailedPlayerItemStopsPlaybackAndSurfacesError() {
        XCTAssertEqual(
            MobilePlaybackItemPolicy.action(for: .failed("The audio file could not be opened.")),
            .stopAndPresentError("The audio file could not be opened.")
        )
        XCTAssertEqual(MobilePlaybackItemPolicy.action(for: .readyToPlay), .none)
    }
}
