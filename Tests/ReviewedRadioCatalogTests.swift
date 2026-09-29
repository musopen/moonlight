import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class ReviewedRadioCatalogTests: XCTestCase {
    private var directory: URL!
    private var catalog: ReviewedRadioCatalog!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewedRadio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalog = try ReviewedRadioCatalog()
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRadioWebURLOnlyAcceptsHTTPLinks() {
        XCTAssertEqual(RadioWebURL.validated("https://example.com/stream")?.absoluteString, "https://example.com/stream")
        XCTAssertNotNil(RadioWebURL.validated(" HTTP://example.com/live.mp3 "))
        XCTAssertNil(RadioWebURL.validated("file:///etc/passwd"))
        XCTAssertNil(RadioWebURL.validated("javascript:alert(1)"))
        XCTAssertNil(RadioWebURL.validated("ftp://example.com/stream"))
        XCTAssertNil(RadioWebURL.validated("https:///no-host"))
        XCTAssertNil(RadioWebURL.validated(nil))
    }

    func testBundledCatalogIsCompleteReadableAndImmutable() throws {
        XCTAssertTrue(catalog.path.contains(".app/Contents/Resources/"))
        XCTAssertEqual(try catalog.stationCount(), 42_630)
        try catalog.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM streams"), 44_726)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM channels WHERE is_popular=1"), 3_195)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM catalog_metadata WHERE key='schema_version'"), "1")
            XCTAssertThrowsError(try db.execute(sql: "DELETE FROM channels"))
        }
        let search = try catalog.fetchStations(search: "KUSC")
        XCTAssertFalse(search.isEmpty)
        XCTAssertTrue(try catalog.fetchStations(search: "Exitosa Noticias Chiclayo")
            .contains { $0.channelID == "00708bd9-bb2b-4e13-9628-a359c875ed43" })
        XCTAssertTrue(try catalog.fetchStations(search: "Voice of Korea")
            .contains { $0.name == "Pyongyang Radio FM" })
        try catalog.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM streams WHERE is_default=1"), 42_630)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM streams WHERE stationuuid IS NULL OR stationuuid=''"), 0)
        }
    }

    @MainActor
    func testCleanInstallBrowsesWithoutDirectoryRequestOrFullCatalogCopy() async throws {
        let state = try RadioUserState(catalog: catalog, directory: directory)
        let model = RadioViewModel(catalog: catalog, userState: state)
        await model.prepareDirectory()
        await model.openResults(tag: nil, label: "All Stations")
        XCTAssertFalse(model.stations.isEmpty)
        XCTAssertNil(model.directoryError)
        XCTAssertTrue(try state.favoriteChannelIDs().isEmpty)
        XCTAssertFalse(try catalog.fetchStations(limit: 5).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
        let stateSize = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("radio-user-state.sqlite").path)[.size] as? Int64 ?? 0
        XCTAssertLessThan(stateSize, 100_000)
    }

    func testBundledStreamLinksDoNotCarryDirectoryReferralTags() throws {
        let tagged = try catalog.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM streams
                WHERE lower(stream_url) LIKE '%radiobrowser%' OR lower(stream_url) LIKE '%radio-browser%'
                """) ?? 0
        }
        // 83 stations only play (or could not be checked) with the label in their own address.
        XCTAssertLessThanOrEqual(tagged, 83)
    }

    func testMigrationCoalescesUUIDsAndPreservesUnmappedAndOffCatalogFavorites() throws {
        let samples = try mappingSamples()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = Date(timeIntervalSince1970: 1_600_000_000)
        let missingUUID = "99999999-9999-4999-8999-999999999999"
        try makeLegacy([
            (samples.mapped[0], first, "First name"),
            (samples.mapped[1], earlier, "Second name"),
            (samples.omitted, first, "Off catalog"),
            (missingUUID, first, "Unmapped name"),
        ])
        let obsoleteCache = directory.appendingPathComponent("radio-stations.json")
        try Data("obsolete".utf8).write(to: obsoleteCache)
        let state = try RadioUserState(catalog: catalog, directory: directory)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([samples.channelID]))
        let unresolved = try state.unresolvedFavorites()
        XCTAssertEqual(Set(unresolved.map(\.stationUUID)), Set([samples.omitted, missingUUID]))
        XCTAssertEqual(unresolved.first { $0.stationUUID == missingUUID }?.name, "Unmapped name")
        XCTAssertEqual(try state.favoriteStations().count, 1)
        let userDB = try DatabaseQueue(path: directory.appendingPathComponent("radio-user-state.sqlite").path)
        try userDB.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT stationuuid,added_at FROM favorites WHERE channel_id=?", arguments: [samples.channelID]))
            XCTAssertEqual(row["stationuuid"] as String, samples.mapped[1])
            XCTAssertEqual(row["added_at"] as Date, earlier)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_migration_version'"), "1")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite-shm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteCache.path))
    }

    @MainActor
    func testUnresolvedFavoriteCanBeRemovedWithoutChangingCurrentFavorites() async throws {
        let sample = try mappingSamples()
        let missingUUID = "99999999-9999-4999-8999-999999999999"
        try makeLegacy([
            (sample.mapped[0], Date(timeIntervalSince1970: 100), "Current station"),
            (missingUUID, Date(timeIntervalSince1970: 200), "Old station"),
        ])
        let state = try RadioUserState(catalog: catalog, directory: directory)
        let model = RadioViewModel(catalog: catalog, userState: state)
        await model.prepareDirectory()
        XCTAssertEqual(model.unresolvedFavorites.map(\.stationUUID), [missingUUID])
        XCTAssertEqual(model.favorites.count, 1)

        await model.removeUnresolvedFavorite(missingUUID)

        XCTAssertTrue(model.unresolvedFavorites.isEmpty)
        XCTAssertTrue(try state.unresolvedFavorites().isEmpty)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([sample.channelID]))
        XCTAssertEqual(model.favorites.count, 1)
    }

    func testFailedLegacyReadKeepsDatabaseAndRetriesLater() throws {
        let sample = try mappingSamples()
        let legacyPath = directory.appendingPathComponent("radio.sqlite").path
        let old = try DatabaseQueue(path: legacyPath)
        try old.write { db in
            try db.execute(sql: "CREATE TABLE stations(stationuuid TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE favorites(stationuuid TEXT PRIMARY KEY)")
        }
        XCTAssertThrowsError(try RadioUserState(catalog: catalog, directory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
        let userDB = try DatabaseQueue(path: directory.appendingPathComponent("radio-user-state.sqlite").path)
        try userDB.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM favorites"), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_migration_version'"))
        }
        try old.write { db in
            try db.execute(sql: "ALTER TABLE favorites ADD COLUMN added_at DATETIME")
            try db.execute(sql: "INSERT INTO stations VALUES (?,?)", arguments: [sample.mapped[0], "Saved"])
            try db.execute(sql: "INSERT INTO favorites VALUES (?,?)", arguments: [sample.mapped[0], Date(timeIntervalSince1970: 100)])
        }
        let state = try RadioUserState(catalog: catalog, directory: directory)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([sample.channelID]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
    }

    func testCrashAfterCopyRetriesCleanupWithoutDuplicatingFavorites() throws {
        let sample = try mappingSamples()
        try makeLegacy([(sample.mapped[0], Date(timeIntervalSince1970: 100), "Saved")])
        enum SimulatedCrash: Error { case interrupted }
        XCTAssertThrowsError(try RadioUserState(
            catalog: catalog, directory: directory,
            beforeLegacyCleanup: { throw SimulatedCrash.interrupted }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
        let userDB = try DatabaseQueue(path: directory.appendingPathComponent("radio-user-state.sqlite").path)
        try userDB.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM favorites"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_copy_version'"), "1")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_migration_version'"))
        }
        let state = try RadioUserState(catalog: catalog, directory: directory)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([sample.channelID]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("radio.sqlite").path))
    }

    func testFailureAfterCheckpointRestoresLegacyDatabaseAndRetries() throws {
        let sample = try mappingSamples()
        let savedAt = Date(timeIntervalSince1970: 123)
        try makeLegacy([(sample.mapped[0], savedAt, "Saved")])
        enum SimulatedFailure: Error { case interrupted }
        XCTAssertThrowsError(try RadioUserState(
            catalog: catalog, directory: directory,
            beforeMigrationCommit: { throw SimulatedFailure.interrupted }
        ))
        let legacyPath = directory.appendingPathComponent("radio.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath + ".migration-backup"))
        let old = try DatabaseQueue(path: legacyPath)
        try old.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT stationuuid FROM favorites"), sample.mapped[0])
            XCTAssertEqual(try Date.fetchOne(db, sql: "SELECT added_at FROM favorites"), savedAt)
        }
        let userDB = try DatabaseQueue(path: directory.appendingPathComponent("radio-user-state.sqlite").path)
        try userDB.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM state_metadata WHERE key='legacy_migration_version'"))
        }
        let state = try RadioUserState(catalog: catalog, directory: directory)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([sample.channelID]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
    }

    func testRetryAfterCrashWithLegacyDatabaseInBackupLocation() throws {
        let sample = try mappingSamples()
        try makeLegacy([(sample.mapped[0], Date(timeIntervalSince1970: 321), "Saved")])
        enum SimulatedCrash: Error { case interrupted }
        XCTAssertThrowsError(try RadioUserState(
            catalog: catalog, directory: directory,
            beforeLegacyCleanup: { throw SimulatedCrash.interrupted }
        ))
        let legacy = directory.appendingPathComponent("radio.sqlite")
        let backup = directory.appendingPathComponent("radio.sqlite.migration-backup")
        try FileManager.default.moveItem(at: legacy, to: backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        let state = try RadioUserState(catalog: catalog, directory: directory)
        XCTAssertEqual(try state.favoriteChannelIDs(), Set([sample.channelID]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    private func makeLegacy(_ favorites: [(String, Date, String)]) throws {
        let db = try DatabaseQueue(path: directory.appendingPathComponent("radio.sqlite").path)
        try db.write { database in
            try database.execute(sql: "CREATE TABLE stations(stationuuid TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE favorites(stationuuid TEXT PRIMARY KEY, added_at DATETIME NOT NULL)")
            for (uuid, date, name) in favorites {
                try database.execute(sql: "INSERT INTO stations VALUES (?,?)", arguments: [uuid, name])
                try database.execute(sql: "INSERT INTO favorites VALUES (?,?)", arguments: [uuid, date])
            }
        }
    }

    private func mappingSamples() throws -> (channelID: String, mapped: [String], omitted: String) {
        try catalog.read { db in
            let channelID = try XCTUnwrap(String.fetchOne(db, sql: """
                SELECT channel_id FROM streams
                GROUP BY channel_id HAVING count(DISTINCT stationuuid)>=2 LIMIT 1
            """))
            let mapped = try String.fetchAll(db, sql: """
                SELECT DISTINCT stationuuid FROM streams WHERE channel_id=?
                ORDER BY stationuuid LIMIT 2
            """, arguments: [channelID])
            return (channelID, mapped, "88888888-8888-4888-8888-888888888888")
        }
    }
}
