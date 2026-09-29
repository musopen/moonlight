import XCTest
import GRDB
@testable import Moonlight

final class MissingFileResolverTests: XCTestCase {
    private var root: URL!
    private var db: DatabaseManager!
    private var folderId: Int64!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightMissingFileResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try DatabaseManager(path: root.appendingPathComponent("library.sqlite").path)
        folderId = try db.write { database in
            try database.execute(sql: """
                INSERT INTO folders (url, bookmark_data, date_added)
                VALUES (?, ?, ?)
            """, arguments: [root.absoluteString, Data(), Date()])
            return database.lastInsertedRowID
        }
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        folderId = nil
    }

    func testMatcherSuggestsNumberPrefixRenameFromMetadata() throws {
        let missing = try insertTrack(
            url: root.appendingPathComponent("Radiohead/01 Airbag.flac"),
            status: "missing",
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 287
        )
        let candidate = try insertTrack(
            url: root.appendingPathComponent("Radiohead/Airbag.flac"),
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 287
        )

        let suggestions = MissingFileMatcher.suggestions(missing: [missing], available: [candidate])
        let suggestion = try XCTUnwrap(suggestions[try XCTUnwrap(missing.dbId)])

        XCTAssertEqual(suggestion.candidate.dbId, candidate.dbId)
        XCTAssertEqual(suggestion.confidence, .high)
        XCTAssertTrue(suggestion.reasons.contains("matching filename"))
        XCTAssertTrue(suggestion.reasons.contains("same title"))
    }

    func testMatcherDoesNotChooseBetweenAmbiguousCandidates() throws {
        let missing = try insertTrack(
            url: root.appendingPathComponent("Old/Something.flac"),
            status: "missing",
            title: "Something",
            artist: "The Beatles",
            album: "Abbey Road",
            duration: 182
        )
        let first = try insertTrack(
            url: root.appendingPathComponent("New A/Something.flac"),
            title: "Something",
            artist: "The Beatles",
            album: "Abbey Road",
            duration: 182
        )
        let second = try insertTrack(
            url: root.appendingPathComponent("New B/Something.flac"),
            title: "Something",
            artist: "The Beatles",
            album: "Abbey Road",
            duration: 182
        )

        let suggestions = MissingFileMatcher.suggestions(missing: [missing], available: [first, second])

        XCTAssertNil(suggestions[try XCTUnwrap(missing.dbId)])
    }

    func testRecoveryRowsShowMissingTrackAndExistingSuggestion() throws {
        let missing = try insertTrack(
            url: root.appendingPathComponent("Old/01 Airbag.wav"),
            status: "missing",
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 287
        )
        let candidateURL = root.appendingPathComponent("New/Airbag.wav")
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: candidateURL)
        let candidate = try insertTrack(
            url: candidateURL,
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 287
        )

        let rows = try MissingFileResolver(db: db).recoveryRows()

        XCTAssertEqual(rows.map(\.id), [try XCTUnwrap(missing.dbId)])
        XCTAssertEqual(rows.first?.suggestion?.candidate.dbId, candidate.dbId)
        XCTAssertEqual(rows.first?.suggestion?.confidence, .high)
    }

    func testResolveMergesImportedCandidateAndPreservesDurableIdentity() throws {
        let oldDateAdded = Date(timeIntervalSince1970: 100)
        let oldLastPlayed = Date(timeIntervalSince1970: 200)
        var missing = Track(
            fileURL: root.appendingPathComponent("Old/01 Airbag.wav").absoluteString,
            folderId: folderId,
            availabilityStatus: "missing",
            missingSince: Date(),
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 287,
            isFavorite: true,
            rating: 2,
            playCount: 7,
            lastPlayedAt: oldLastPlayed,
            dateAdded: oldDateAdded
        )
        try db.write { try missing.insert($0) }
        let missingId = try XCTUnwrap(missing.dbId)

        let candidateURL = root.appendingPathComponent("New/Airbag.wav")
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2]).write(to: candidateURL)
        let candidateLastPlayed = Date(timeIntervalSince1970: 300)
        var candidate = Track(
            fileURL: candidateURL.absoluteString,
            folderId: folderId,
            title: "Airbag (Remastered)",
            artist: "Radiohead",
            album: "OK Computer",
            duration: 288,
            format: "WAV",
            rating: 5,
            playCount: 2,
            lastPlayedAt: candidateLastPlayed,
            dateAdded: Date(timeIntervalSince1970: 400)
        )
        try db.write { try candidate.insert($0) }
        let candidateId = try XCTUnwrap(candidate.dbId)

        let playlistIds = try makePlaylistsAndMemberships(missingId: missingId, candidateId: candidateId)

        try MissingFileResolver(db: db).resolve(
            missingTrackId: missingId,
            to: candidateURL,
            folderId: folderId
        )

        let tracks = try db.read { try Track.fetchAll($0) }
        let resolved = try XCTUnwrap(tracks.first)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(resolved.dbId, missingId)
        XCTAssertEqual(resolved.fileURL, candidateURL.standardizedFileURL.absoluteString)
        XCTAssertTrue(resolved.isAvailable)
        XCTAssertNil(resolved.missingSince)
        XCTAssertEqual(resolved.dateAdded, oldDateAdded)
        XCTAssertEqual(resolved.title, "Airbag (Remastered)")
        XCTAssertTrue(resolved.isFavorite)
        XCTAssertEqual(resolved.rating, 2)
        XCTAssertEqual(resolved.playCount, 9)
        XCTAssertEqual(resolved.lastPlayedAt, candidateLastPlayed)
        XCTAssertEqual(resolved.fileSize, 3)
        XCTAssertEqual(resolved.format, "WAV")

        let memberships = try db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT playlist_id, track_id FROM playlist_tracks
                ORDER BY playlist_id
            """)
        }
        XCTAssertEqual(memberships.count, 2)
        XCTAssertEqual(memberships.map { $0["playlist_id"] as Int64 }, playlistIds)
        XCTAssertTrue(memberships.allSatisfy { ($0["track_id"] as Int64) == missingId })
    }

    func testResolveInheritsCandidateRatingOnlyWhenDurableTrackIsUnrated() throws {
        var durable = Track(
            fileURL: root.appendingPathComponent("Old/Unrated.wav").absoluteString,
            folderId: folderId,
            availabilityStatus: "missing",
            missingSince: Date(),
            title: "Unrated",
            dateAdded: Date()
        )
        try db.write { try durable.insert($0) }
        let durableID = try XCTUnwrap(durable.dbId)

        let candidateURL = root.appendingPathComponent("New/Unrated.wav")
        try FileManager.default.createDirectory(at: candidateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1]).write(to: candidateURL)
        var candidate = Track(
            fileURL: candidateURL.absoluteString,
            folderId: folderId,
            title: "Unrated",
            format: "WAV",
            rating: 4,
            dateAdded: Date()
        )
        try db.write { try candidate.insert($0) }

        try MissingFileResolver(db: db).resolve(
            missingTrackId: durableID,
            to: candidateURL,
            folderId: folderId
        )

        let resolved = try XCTUnwrap(db.read { try Track.fetchOne($0, key: durableID) })
        XCTAssertEqual(resolved.rating, 4)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }, 1)
    }

    func testResolveRejectsFileOutsideKnownLibraryFolder() throws {
        let missing = try insertTrack(
            url: root.appendingPathComponent("Old/Missing.wav"),
            status: "missing",
            title: "Missing"
        )
        let file = root.appendingPathComponent("Replacement.wav")
        try Data([0]).write(to: file)

        XCTAssertThrowsError(
            try MissingFileResolver(db: db).resolve(
                missingTrackId: try XCTUnwrap(missing.dbId),
                to: file,
                folderId: nil
            )
        ) { error in
            XCTAssertEqual(error as? MissingFileResolutionError, .fileOutsideLibrary)
        }
    }

    func testManualResolveToUnimportedRenamedFileKeepsMetadata() throws {
        let oldDateAdded = Date(timeIntervalSince1970: 100)
        var missing = Track(
            fileURL: root.appendingPathComponent("Album/01 Airbag.wav").absoluteString,
            folderId: folderId,
            availabilityStatus: "missing",
            missingSince: Date(),
            title: "Airbag",
            artist: "Radiohead",
            album: "OK Computer",
            isFavorite: true,
            playCount: 12,
            dateAdded: oldDateAdded
        )
        try db.write { try missing.insert($0) }
        let missingId = try XCTUnwrap(missing.dbId)

        let renamedURL = root.appendingPathComponent("Album/Airbag.wav")
        try FileManager.default.createDirectory(
            at: renamedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(to: renamedURL)

        try MissingFileResolver(db: db).resolve(
            missingTrackId: missingId,
            to: renamedURL,
            folderId: folderId
        )

        let resolved = try XCTUnwrap(db.read { try Track.fetchOne($0, key: missingId) })
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }, 1)
        XCTAssertEqual(resolved.dbId, missingId)
        XCTAssertEqual(resolved.fileURL, renamedURL.standardizedFileURL.absoluteString)
        XCTAssertTrue(resolved.isAvailable)
        XCTAssertNil(resolved.missingSince)
        XCTAssertEqual(resolved.title, "Airbag")
        XCTAssertEqual(resolved.artist, "Radiohead")
        XCTAssertEqual(resolved.album, "OK Computer")
        XCTAssertTrue(resolved.isFavorite)
        XCTAssertEqual(resolved.playCount, 12)
        XCTAssertEqual(resolved.dateAdded, oldDateAdded)
        XCTAssertEqual(resolved.fileSize, 4)
    }

    func testConfirmedLibraryRootMovePreservesDurableIdsAcrossCopiedFiles() throws {
        let oldRoot = root.appendingPathComponent("Old Library", isDirectory: true)
        let newRoot = root.appendingPathComponent("New Library", isDirectory: true)
        let relativePath = "Tangled/01 When Will My Life Begin.wav"
        let oldURL = oldRoot.appendingPathComponent(relativePath)
        let newURL = newRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: newURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(to: newURL)

        var durable = Track(
            fileURL: oldURL.absoluteString,
            folderId: folderId,
            title: "When Will My Life Begin?",
            artist: "Mandy Moore",
            album: "Tangled",
            isFavorite: true,
            rating: 3,
            playCount: 11,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        try db.write { try durable.insert($0) }
        let durableId = try XCTUnwrap(durable.dbId)

        // Simulate the destination having already been discovered. Reconnection
        // must merge this duplicate into the older durable identity.
        var importedCopy = Track(
            fileURL: newURL.absoluteString,
            folderId: folderId,
            title: durable.title,
            artist: durable.artist,
            album: durable.album,
            format: "WAV",
            dateAdded: Date(timeIntervalSince1970: 200)
        )
        try db.write { try importedCopy.insert($0) }
        let importedId = try XCTUnwrap(importedCopy.dbId)
        _ = try makePlaylistsAndMemberships(missingId: durableId, candidateId: importedId)

        let count = try MissingFileResolver(db: db).reconnectLibraryRoot(
            folderId: folderId,
            from: oldRoot,
            to: newRoot
        )

        XCTAssertEqual(count, 1)
        let tracks = try db.read { try Track.fetchAll($0) }
        let reconnected = try XCTUnwrap(tracks.first)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(reconnected.dbId, durableId)
        XCTAssertEqual(reconnected.fileURL, newURL.standardizedFileURL.absoluteString)
        XCTAssertTrue(reconnected.isAvailable)
        XCTAssertTrue(reconnected.isFavorite)
        XCTAssertEqual(reconnected.rating, 3)
        XCTAssertEqual(reconnected.playCount, 11)
        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM playlist_tracks WHERE track_id = ?",
                arguments: [durableId]
            )
        }, 2)
    }

    @discardableResult
    private func insertTrack(
        url: URL,
        status: String = "available",
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil
    ) throws -> Track {
        var track = Track(
            fileURL: url.absoluteString,
            folderId: folderId,
            availabilityStatus: status,
            missingSince: status == "missing" ? Date() : nil,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            format: url.pathExtension.uppercased(),
            dateAdded: Date()
        )
        try db.write { try track.insert($0) }
        return track
    }

    private func makePlaylistsAndMemberships(missingId: Int64, candidateId: Int64) throws -> [Int64] {
        try db.write { database in
            var ids: [Int64] = []
            for name in ["Old Playlist", "Candidate Playlist"] {
                try database.execute(sql: """
                    INSERT INTO playlists (name, date_created, date_modified)
                    VALUES (?, ?, ?)
                """, arguments: [name, Date(), Date()])
                ids.append(database.lastInsertedRowID)
            }
            try database.execute(
                sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, 0)",
                arguments: [ids[0], missingId]
            )
            try database.execute(
                sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, 1)",
                arguments: [ids[0], candidateId]
            )
            try database.execute(
                sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, 0)",
                arguments: [ids[1], candidateId]
            )
            return ids
        }
    }
}
