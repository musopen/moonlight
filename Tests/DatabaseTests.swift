import AppKit
import XCTest
import GRDB
@testable import Moonlight

final class DatabaseTests: XCTestCase {

    private var db: DatabaseManager!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: temporaryDirectory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDown() async throws {
        db = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSchemaCreates() throws {
        // Verify all expected tables exist
        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
            """)
        }
        XCTAssertTrue(tables.contains("tracks"))
        XCTAssertTrue(tables.contains("albums"))
        XCTAssertTrue(tables.contains("artists"))
        XCTAssertTrue(tables.contains("artwork"))
        XCTAssertTrue(tables.contains("folders"))
        XCTAssertTrue(tables.contains("playlists"))
        XCTAssertTrue(tables.contains("scan_jobs"))
        XCTAssertTrue(tables.contains("lastfm_scrobble_outbox"))
    }

    func testFreshSyncOutboxMatchesMigratedDeliverAfterNullability() throws {
        let column = try XCTUnwrap(db.read { database in
            try database.columns(in: "sync_outbox").first { $0.name == "deliver_after" }
        })
        XCTAssertFalse(column.isNotNull)
    }

    func testMetadataArchiveWorkerLeavesTheMainThread() async throws {
        let executedOnMainThread = try await MetadataArchiveWorker.run { Thread.isMainThread }
        XCTAssertFalse(executedOnMainThread)
    }

    func testWALModeEnabled() throws {
        let mode = try db.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(mode, "wal")
    }

    func testTrackRatingsMigrationUpgradesExistingRowsAsUnrated() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("ratings-legacy.sqlite")
        let legacy = try DatabaseQueue(path: databaseURL.path)
        try legacy.write { database in
            try database.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in [
                "v1_initial", "v2_artwork_on_tracks", "v3_tracks_fts_album_artist",
                "v4_scan_summaries", "v5_lastfm_scrobble_outbox", "v6_deduplicated_artwork",
                "v7_durable_track_identity", "v8_file_resource_identity"
            ] {
                try database.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
            try database.execute(sql: "CREATE TABLE tracks (id INTEGER PRIMARY KEY, file_url TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO tracks (id, file_url) VALUES (1, 'file:///legacy.flac')")
        }

        let migrated = try DatabaseManager(path: databaseURL.path)
        let result = try migrated.read { database -> (Bool, Int?) in
            let hasRating = try database.columns(in: "tracks").contains { $0.name == "rating" }
            let rating = try Int.fetchOne(database, sql: "SELECT rating FROM tracks WHERE id = 1")
            return (hasRating, rating)
        }

        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
    }

    func testRatingDatabaseConstraintRejectsOutOfRangeValues() throws {
        let trackID = try insertTrack(
            fileURL: "file:///tmp/ratings-constraint.flac",
            title: "Constraint",
            artist: nil,
            albumArtist: nil,
            album: "Ratings"
        )

        XCTAssertThrowsError(try db.write { database in
            try database.execute(sql: "UPDATE tracks SET rating = 0 WHERE id = ?", arguments: [trackID])
        })
        XCTAssertThrowsError(try db.write { database in
            try database.execute(sql: "UPDATE tracks SET rating = 6 WHERE id = ?", arguments: [trackID])
        })
    }

    @MainActor
    func testSettingAndClearingSingleRating() throws {
        let trackID = try insertTrack(
            fileURL: "file:///tmp/single-rating.flac",
            title: "Single",
            artist: nil,
            albumArtist: nil,
            album: "Ratings"
        )
        let appState = AppState(db: db)

        try appState.setRating(3, forTrackID: trackID)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT rating FROM tracks WHERE id = ?", arguments: [trackID]) }, 3)

        try appState.setRating(nil, forTrackID: trackID)
        XCTAssertNil(try db.read { try Int.fetchOne($0, sql: "SELECT rating FROM tracks WHERE id = ?", arguments: [trackID]) })
    }

    @MainActor
    func testFavoriteMutationUpdatesSelectionWithOneRefreshAndPopulatesFavorites() throws {
        let firstID = try insertTrack(
            fileURL: "file:///tmp/favorite-first.flac",
            title: "Favorite First",
            artist: nil,
            albumArtist: nil,
            album: "Favorites"
        )
        let secondID = try insertTrack(
            fileURL: "file:///tmp/favorite-second.flac",
            title: "Favorite Second",
            artist: nil,
            albumArtist: nil,
            album: "Favorites"
        )
        let appState = AppState(db: db)

        try appState.setFavorite(true, forTrackIDs: [firstID, secondID, firstID])

        XCTAssertEqual(appState.libraryVersion, 1)
        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM tracks WHERE is_favorite = 1")
        }, 2)

        try appState.setFavorite(false, forTrackID: firstID)

        XCTAssertEqual(appState.libraryVersion, 2)
        XCTAssertEqual(try db.read { database in
            try Int64.fetchAll(database, sql: "SELECT id FROM tracks WHERE is_favorite = 1 ORDER BY id")
        }, [secondID])
    }

    @MainActor
    func testRefreshingPlaylistsPublishesNewManualPlaylist() throws {
        let appState = AppState(db: db)
        XCTAssertTrue(appState.playlists.isEmpty)

        let created = try db.write { database -> Playlist in
            var playlist = Playlist(name: "Sidebar Test", dateCreated: Date(), dateModified: Date())
            try playlist.insert(database)
            return playlist
        }
        appState.refreshPlaylists()

        XCTAssertEqual(appState.playlists.map(\.id), [created.id])
        XCTAssertEqual(appState.playlists.map(\.name), ["Sidebar Test"])
    }

    @MainActor
    func testRemoteParentTombstoneDismissesSelectionAndHidesRetainedMemberships() throws {
        let deletedID = try insertPlaylist(name: "Remote deletion")
        let liveID = try insertPlaylist(name: "Control")
        let trackID = try insertTrack(fileURL: "file:///tmp/deletion-control.flac", title: "Retained audio", artist: nil, albumArtist: nil, album: "Control")
        try db.write { database in
            try PlaylistMutation.append([trackID, trackID], to: deletedID, in: database)
            try PlaylistMutation.append([trackID], to: liveID, in: database)
        }
        let appState = AppState(db: db)
        appState.selectedSidebarItem = .playlist(deletedID)
        let playlist = try db.read { try XCTUnwrap(Playlist.fetchOne($0, key: deletedID)) }
        let deletion = Date(timeIntervalSince1970: 1_788_815_000)
        let tombstone = SyncTransportRecord.playlist(.init(
            id: playlist.playlistSyncId, name: playlist.name, nameRev: playlist.nameRev,
            kind: playlist.kind, sortMode: playlist.sortMode, sortModeRev: playlist.sortModeRev,
            rule: playlist.rule, ruleRev: playlist.ruleRev, createdAt: playlist.dateCreated, deletedAt: deletion
        ))
        for _ in 0..<2 {
            try db.write { try SyncRecordApplier.apply([tombstone], to: $0) }
            appState.refreshPlaylists()
            XCTAssertEqual(appState.selectedSidebarItem, .albums)
            XCTAssertEqual(appState.playlists.map(\.id), [liveID])
            try db.read { database in
                // Parent-only sync does not require separate child tombstones.
                XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id=? AND deleted_at IS NULL", arguments: [deletedID]), 2)
                XCTAssertTrue(try PlaylistEntry.fetchVisible(in: deletedID, from: database).isEmpty)
                XCTAssertEqual(try PlaylistEntry.fetchVisible(in: liveID, from: database).map(\.track.dbId), [trackID])
                XCTAssertNotNil(try Track.fetchOne(database, key: trackID))
                XCTAssertEqual(try Playlist.fetchOne(database, key: deletedID)?.deletedAt, deletion)
            }
        }
        // Refreshes for an unrelated deleted parent must preserve live selection.
        appState.selectedSidebarItem = .playlist(liveID)
        appState.refreshPlaylists()
        XCTAssertEqual(appState.selectedSidebarItem, .playlist(liveID))
        appState.selectedSidebarItem = .favorites
        appState.refreshPlaylists()
        XCTAssertEqual(appState.selectedSidebarItem, .favorites)
    }

    @MainActor
    func testAddingDraggedAlbumsPreservesAlbumAndTrackOrder() throws {
        var firstAlbum = Album(title: "First Album")
        var secondAlbum = Album(title: "Second Album")
        try db.write { database in
            try firstAlbum.insert(database)
            try secondAlbum.insert(database)
        }
        let firstTrack = try insertTrack(fileURL: "file:///tmp/album-first-track-1.flac", title: "First 1", artist: nil, albumArtist: nil, album: "First Album")
        let secondTrack = try insertTrack(fileURL: "file:///tmp/album-first-track-2.flac", title: "First 2", artist: nil, albumArtist: nil, album: "First Album")
        let thirdTrack = try insertTrack(fileURL: "file:///tmp/album-second-track-1.flac", title: "Second 1", artist: nil, albumArtist: nil, album: "Second Album")
        try db.write { database in
            try database.execute(sql: "UPDATE tracks SET album_id = ?, disc_number = 1, track_number = 1 WHERE id = ?", arguments: [firstAlbum.id, firstTrack])
            try database.execute(sql: "UPDATE tracks SET album_id = ?, disc_number = 1, track_number = 2 WHERE id = ?", arguments: [firstAlbum.id, secondTrack])
            try database.execute(sql: "UPDATE tracks SET album_id = ?, disc_number = 1, track_number = 1 WHERE id = ?", arguments: [secondAlbum.id, thirdTrack])
        }
        let appState = AppState(db: db, playlistDuplicateAddResolver: { _ in .skip })
        let playlist = try XCTUnwrap(appState.createPlaylist(name: "Album Drop"))
        let playlistID = try XCTUnwrap(playlist.id)

        appState.addAlbums([try XCTUnwrap(secondAlbum.id), try XCTUnwrap(firstAlbum.id)], toPlaylist: playlistID)
        // Repeating a whole-album add asks the user about its duplicates. This
        // test chooses Skip and confirms that the original order is retained.
        appState.addAlbums([try XCTUnwrap(firstAlbum.id), try XCTUnwrap(secondAlbum.id)], toPlaylist: playlistID)

        XCTAssertEqual(try db.read { database in
            try Int64.fetchAll(database, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlistID])
        }, [thirdTrack, firstTrack, secondTrack])
    }

    @MainActor
    func testPlaylistDuplicateResolutionAddsOrCancelsRepeatedTracks() throws {
        let trackID = try insertTrack(
            fileURL: "file:///tmp/playlist-duplicate-resolution.flac",
            title: "Repeated",
            artist: nil,
            albumArtist: nil,
            album: "Playlist"
        )
        let track = try db.read { database in try XCTUnwrap(Track.fetchOne(database, key: trackID)) }

        var duplicateCounts: [Int] = []
        let addState = AppState(db: db, playlistDuplicateAddResolver: {
            duplicateCounts.append($0)
            return .add
        })
        let addPlaylist = try XCTUnwrap(addState.createPlaylist(name: "Allow Repeats"))
        let addPlaylistID = try XCTUnwrap(addPlaylist.id)
        addState.addTrack(track, toPlaylist: addPlaylistID)
        addState.addTrack(track, toPlaylist: addPlaylistID)

        XCTAssertEqual(duplicateCounts, [1])
        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL", arguments: [addPlaylistID])
        }, 2)

        let cancelState = AppState(db: db, playlistDuplicateAddResolver: { _ in .cancel })
        let cancelPlaylist = try XCTUnwrap(cancelState.createPlaylist(name: "No Repeats"))
        let cancelPlaylistID = try XCTUnwrap(cancelPlaylist.id)
        cancelState.addTrack(track, toPlaylist: cancelPlaylistID)
        cancelState.addTrack(track, toPlaylist: cancelPlaylistID)

        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL", arguments: [cancelPlaylistID])
        }, 1)
    }

    @MainActor
    func testRatingMutationSetsAndClearsAtomicallyWithOneRefresh() throws {
        let firstID = try insertTrack(
            fileURL: "file:///tmp/rating-first.flac",
            title: "First",
            artist: nil,
            albumArtist: nil,
            album: "Ratings"
        )
        let secondID = try insertTrack(
            fileURL: "file:///tmp/rating-second.flac",
            title: "Second",
            artist: nil,
            albumArtist: nil,
            album: "Ratings"
        )
        try db.write { database in
            try database.execute(sql: "UPDATE tracks SET is_favorite = 1 WHERE id = ?", arguments: [firstID])
        }
        let appState = AppState(db: db)

        try appState.setRating(4, forTrackIDs: [firstID, secondID, firstID])

        XCTAssertEqual(appState.libraryVersion, 1)
        XCTAssertEqual(try db.read { database in
            try Int.fetchAll(database, sql: "SELECT rating FROM tracks ORDER BY id")
        }, [4, 4])
        XCTAssertThrowsError(try appState.setRating(8, forTrackIDs: [firstID, secondID])) { error in
            XCTAssertEqual(error as? TrackRatingError, .invalidValue(8))
        }
        XCTAssertEqual(appState.libraryVersion, 1)
        XCTAssertEqual(try db.read { database in
            try Int.fetchAll(database, sql: "SELECT rating FROM tracks ORDER BY id")
        }, [4, 4])

        try appState.setRating(nil, forTrackIDs: [firstID, secondID])

        XCTAssertEqual(appState.libraryVersion, 2)
        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM tracks WHERE rating IS NOT NULL")
        }, 0)
        XCTAssertEqual(try db.read { database in
            try Bool.fetchOne(database, sql: "SELECT is_favorite FROM tracks WHERE id = ?", arguments: [firstID])
        }, true)
    }

    func testSongsRatingSortingAndFilteringSemantics() throws {
        let entries: [(String, Int?)] = [
            ("Zulu Unrated", nil), ("Beta One", 1), ("Alpha Three", 3),
            ("Alpha Three", 3), ("Omega Five", 5)
        ]
        var insertedIDs: [Int64] = []
        for (title, rating) in entries {
            let trackID = try insertTrack(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                title: title,
                artist: nil,
                albumArtist: nil,
                album: "Ratings"
            )
            insertedIDs.append(trackID)
            if let rating {
                try db.write { database in
                    try AppState.setRating(rating, forTrackIDs: [trackID], in: database)
                }
            }
        }

        let ascending = try db.read {
            try SongsTrackQuery.fetch(in: $0, ratingFilter: .all, sortOrder: .ratingAscending)
        }
        XCTAssertEqual(ascending.map(\.rating), [nil, 1, 3, 3, 5])
        XCTAssertEqual(
            ascending.filter { $0.rating == 3 }.compactMap(\.dbId),
            [insertedIDs[2], insertedIDs[3]]
        )

        let descending = try db.read {
            try SongsTrackQuery.fetch(in: $0, ratingFilter: .all, sortOrder: .ratingDescending)
        }
        XCTAssertEqual(descending.map(\.rating), [5, 3, 3, 1, nil])
        XCTAssertEqual(try db.read {
            try SongsTrackQuery.fetch(in: $0, ratingFilter: .unrated, sortOrder: .title)
        }.map(\.rating), [nil])
        XCTAssertEqual(try db.read {
            try SongsTrackQuery.fetch(in: $0, ratingFilter: .exact(3), sortOrder: .title)
        }.map(\.rating), [3, 3])
        XCTAssertEqual(try db.read {
            try SongsTrackQuery.fetch(in: $0, ratingFilter: .atLeast(3), sortOrder: .ratingAscending)
        }.map(\.rating), [3, 3, 5])
    }

    func testSongsQueryExcludesSyncOnlyUnavailablePlaceholders() throws {
        let localTrackID = try insertTrack(
            fileURL: "file:///tmp/local-track.flac",
            title: "Local Track",
            artist: nil,
            albumArtist: nil,
            album: "Library"
        )
        let placeholderID = try db.write { database -> Int64 in
            var placeholder = Track(
                fileURL: "moonlight-unavailable://sync-only-track",
                availabilityStatus: "unavailable",
                title: nil,
                artist: nil,
                album: nil,
                dateAdded: Date()
            )
            try placeholder.insert(database)
            return try XCTUnwrap(placeholder.dbId)
        }
        let missingLocalTrackID = try db.write { database -> Int64 in
            var track = Track(
                fileURL: "file:///Volumes/Offline/Missing%20Locally.flac",
                availabilityStatus: "missing",
                title: "Missing Locally",
                album: "Library",
                dateAdded: Date()
            )
            try track.insert(database)
            return try XCTUnwrap(track.dbId)
        }
        try db.write { database in
            try database.execute(sql: "UPDATE tracks SET rating = 4 WHERE id IN (?, ?)", arguments: [localTrackID, missingLocalTrackID])
            try database.execute(sql: "UPDATE tracks SET availability_status = 'unavailable', is_favorite = 1 WHERE id = ?", arguments: [placeholderID])
        }

        for filter in [SongsRatingFilter.all, .atLeast(3)] {
            let tracks = try db.read {
                try SongsTrackQuery.fetch(in: $0, ratingFilter: filter, sortOrder: .title)
            }
            XCTAssertEqual(tracks.compactMap(\.dbId), [localTrackID, missingLocalTrackID])
        }
    }

    func testSyncStubsStayOutOfLibraryBrowseQueriesButRemainInManualPlaylists() async throws {
        let localAlbum = "Local Album \(UUID().uuidString)"
        let localTrackID = try insertTrack(
            fileURL: "file:///tmp/local-library-track.flac",
            title: "Local Library Track",
            artist: "Local Artist",
            albumArtist: "Local Artist",
            album: localAlbum,
            composer: "Local Composer",
            genre: "Local Genre"
        )
        let stubAlbum = "Sync-only Album \(UUID().uuidString)"
        let stubTrackID = try db.write { database -> Int64 in
            var track = Track(
                fileURL: "moonlight-unavailable://remote-library-track",
                availabilityStatus: "unavailable",
                title: "Remote Library Track",
                artist: "Remote Artist",
                albumArtist: "Remote Artist",
                album: stubAlbum,
                composer: "Remote Composer",
                genre: "Remote Genre",
                dateAdded: Date()
            )
            try track.insert(database)
            return try XCTUnwrap(track.dbId)
        }
        try db.write { database in
            try database.execute(sql: "UPDATE tracks SET is_favorite = 1, rating = 5 WHERE id IN (?, ?)", arguments: [localTrackID, stubTrackID])
        }

        await LibraryScanner(db: db).rebuildDerivedData()

        let query = try XCTUnwrap(MusicSearchQuery("remote library"))
        let results = try db.read { database -> (albums: [Album], albumTracks: [Track], artists: [String], composers: [String], genres: [String], favorites: [Track], search: [Track], smart: [Track]) in
            let localAlbum = try XCTUnwrap(Album.filter(sql: "title = ?", arguments: [localAlbum]).fetchOne(database))
            let playlistAlbums = try LibraryAlbumQuery.fetchVisible(in: database)
            return (
                albums: playlistAlbums,
                albumTracks: try LibraryAlbumQuery.tracks(for: localAlbum, knownTrackIDs: [localTrackID, stubTrackID], in: database),
                artists: try String.fetchAll(database, sql: "SELECT name FROM artists ORDER BY name"),
                composers: try LibraryBrowseQuery.composers(in: database),
                genres: try LibraryBrowseQuery.genres(in: database),
                favorites: try LibraryBrowseQuery.favoriteTracks(sortedBy: .title, in: database),
                search: try SearchResultsQuery.tracks(matching: query, in: database),
                smart: try SmartPlaylistEvaluator.tracks(matching: .ratingAtLeast(1), in: database)
            )
        }

        XCTAssertEqual(results.albums.map(\.title), [localAlbum])
        XCTAssertEqual(results.albumTracks.map(\.dbId), [localTrackID])
        XCTAssertEqual(results.artists, ["Local Artist"])
        XCTAssertEqual(results.composers, ["Local Composer"])
        XCTAssertEqual(results.genres, ["Local Genre"])
        XCTAssertEqual(results.favorites.map(\.dbId), [localTrackID])
        XCTAssertTrue(results.search.isEmpty)
        XCTAssertEqual(results.smart.map(\.dbId), [localTrackID])

        let playlistID = try insertPlaylist(name: "Synced Manual Playlist")
        try db.write { database in
            try PlaylistMutation.append([stubTrackID], to: playlistID, in: database)
        }
        let entries = try db.read { try PlaylistEntry.fetchVisible(in: playlistID, from: $0) }
        XCTAssertEqual(entries.map(\.track.dbId), [stubTrackID])
        XCTAssertFalse(try XCTUnwrap(entries.first?.track).isAvailable)
        XCTAssertTrue(try XCTUnwrap(entries.first?.track).isSyncOnlyPlaceholder)
    }

    func testArtworkMigrationDeduplicatesLegacyRows() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("legacy.sqlite")
        let imageData = try makeJPEGData(width: 800, height: 600)

        do {
            let legacy = try DatabaseQueue(path: databaseURL.path)
            try legacy.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                for identifier in ["v1_initial", "v2_artwork_on_tracks", "v3_tracks_fts_album_artist", "v4_scan_summaries", "v5_lastfm_scrobble_outbox"] {
                    try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
                }
                try db.execute(sql: "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)")
                try db.execute(sql: """
                    CREATE TABLE artwork (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        source_url TEXT,
                        data_small BLOB,
                        data_large BLOB,
                        dominant_color_hex TEXT
                    )
                """)
                try db.execute(sql: "CREATE TABLE albums (id INTEGER PRIMARY KEY, artwork_id INTEGER)")
                try db.execute(sql: "CREATE TABLE tracks (id INTEGER PRIMARY KEY, artwork_id INTEGER)")

                try db.execute(sql: "INSERT INTO artwork (data_small, data_large) VALUES (?, ?)", arguments: [imageData, imageData])
                try db.execute(sql: "INSERT INTO artwork (data_small, data_large) VALUES (?, ?)", arguments: [imageData, imageData])
                try db.execute(sql: "INSERT INTO tracks (id, artwork_id) VALUES (1, 1), (2, 2)")
                try db.execute(sql: "INSERT INTO albums (id, artwork_id) VALUES (1, 2)")
            }
        }

        let migrated = try DatabaseManager(path: databaseURL.path)
        let result = try migrated.read { db -> (Int, [Int64], Int64?) in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artwork") ?? 0
            let trackArtworkIDs = try Int64.fetchAll(db, sql: "SELECT artwork_id FROM tracks ORDER BY id")
            let albumArtworkID = try Int64.fetchOne(db, sql: "SELECT artwork_id FROM albums WHERE id = 1")
            return (count, trackArtworkIDs, albumArtworkID)
        }

        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1, [1, 1])
        XCTAssertEqual(result.2, 1)
    }

    func testTrackInsertAndFetch() throws {
        let track = Track(
            fileURL: "file:///tmp/test.mp3",
            title: "Test Track",
            artist: "Test Artist",
            dateAdded: Date()
        )
        var inserted = track
        try db.write { db in
            try inserted.insert(db)
        }
        XCTAssertNotNil(inserted.dbId)

        let fetched = try db.read { db in
            try Track.filter(sql: "title = ?", arguments: ["Test Track"]).fetchOne(db)
        }
        XCTAssertEqual(fetched?.title, "Test Track")
        XCTAssertEqual(fetched?.artist, "Test Artist")
    }

    func testDerivedAlbumsMergeSameTitleWithDifferentAlbumArtists() async throws {
        let albumTitle = "Merge Test Album \(UUID().uuidString)"
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "First Movement",
                        artist: "Track Artist 1",
                        albumArtist: "Conductor 1",
                        album: albumTitle)
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Second Movement",
                        artist: "Track Artist 2",
                        albumArtist: "Conductor 2",
                        album: albumTitle)

        await LibraryScanner(db: db).rebuildDerivedData()

        let albums = try db.read { db in
            try Album.filter(sql: "title = ?", arguments: [albumTitle]).fetchAll(db)
        }
        XCTAssertEqual(albums.count, 1)
        XCTAssertNil(albums.first?.albumArtist)

        let albumIds = try db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT album_id FROM tracks
                WHERE album = ? AND album_id IS NOT NULL
            """, arguments: [albumTitle])
        }
        XCTAssertEqual(albumIds, [albums.first?.id].compactMap { $0 })
    }

    func testDerivedAlbumsRetainSharedAlbumArtist() async throws {
        let albumTitle = "Shared Artist Album \(UUID().uuidString)"
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "First Track",
                        artist: "Soloist 1",
                        albumArtist: "Shared Ensemble",
                        album: albumTitle)
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Second Track",
                        artist: "Soloist 2",
                        albumArtist: "Shared Ensemble",
                        album: albumTitle)

        await LibraryScanner(db: db).rebuildDerivedData()

        let album = try db.read { db in
            try Album.filter(sql: "title = ?", arguments: [albumTitle]).fetchOne(db)
        }
        XCTAssertEqual(album?.albumArtist, "Shared Ensemble")
    }

    func testTokenizedSearchMatchesAcrossTrackFields() async throws {
        try seedSearchTracks()
        await LibraryScanner(db: db).rebuildDerivedData()

        XCTAssertEqual(try searchTrackTitles("bach goldberg gould"), ["Aria"])
        XCTAssertEqual(try searchTrackTitles("beethoven 5 kleiber"), ["Symphony No. 5 in C Minor, Op. 67: I. Allegro"])
        XCTAssertEqual(try searchTrackTitles("deb la mer"), ["La mer: De l'aube a midi sur la mer"])
        XCTAssertEqual(try searchTrackTitles("yo ma bach cello"), ["Cello Suite No. 1 in G Major: Prelude"])
    }

    func testTokenizedSearchSurfacesAlbumsFromTrackMetadata() async throws {
        try seedSearchTracks()
        await LibraryScanner(db: db).rebuildDerivedData()

        XCTAssertEqual(try searchAlbumTitles("bach goldberg gould"), ["Goldberg Variations"])
    }

    func testSpecificTrackSearchSuppressesTrackDerivedAlbums() async throws {
        try seedSearchTracks()
        await LibraryScanner(db: db).rebuildDerivedData()

        XCTAssertEqual(try searchTrackTitles("mozart piano sonata 12 f major"), ["Piano Sonata No. 12 in F Major, K. 332: I. Allegro"])
        XCTAssertEqual(try searchAlbumTitles("mozart piano sonata 12 f major"), [])
    }

    func testSpecificSearchStillShowsDirectAlbumMatches() async throws {
        try seedSearchTracks()
        await LibraryScanner(db: db).rebuildDerivedData()

        XCTAssertEqual(try searchAlbumTitles("mozart complete piano sonatas"), ["Mozart / The Complete Piano Sonatas - Mao Fujita"])
    }

    func testTokenizedSearchHandlesPunctuationAndQuotes() async throws {
        try seedSearchTracks()
        await LibraryScanner(db: db).rebuildDerivedData()

        XCTAssertEqual(MusicSearchQuery("op. 67 \"kleiber\"")?.ftsExpression, "\"op\"* \"67\"* \"kleiber\"*")
        XCTAssertEqual(try searchTrackTitles("op. 67 \"kleiber\""), ["Symphony No. 5 in C Minor, Op. 67: I. Allegro"])
    }

    func testAppendTrackIdsToPlaylistPreservesDropOrder() throws {
        let playlistId = try insertPlaylist(name: "Drop Order")
        let firstTrackId = try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                                           title: "First Dropped Track",
                                           artist: "Artist",
                                           albumArtist: nil,
                                           album: "Album")
        let secondTrackId = try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                                            title: "Second Dropped Track",
                                            artist: "Artist",
                                            albumArtist: nil,
                                            album: "Album")

        try db.write { db in
            try AppState.appendTrackIds([secondTrackId, firstTrackId], toPlaylist: playlistId, in: db)
        }

        let rows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT track_id, position FROM playlist_tracks
                WHERE playlist_id = ?
                ORDER BY position
            """, arguments: [playlistId])
        }
        let trackIds: [Int64] = rows.map { $0["track_id"] }
        let positions: [Int] = rows.map { $0["position"] }
        XCTAssertEqual(trackIds, [secondTrackId, firstTrackId])
        XCTAssertEqual(positions, [0, 1])
    }

    func testAppendTrackIdsCopiesBetweenPlaylists() throws {
        let sourcePlaylistId = try insertPlaylist(name: "Source")
        let destinationPlaylistId = try insertPlaylist(name: "Destination")
        let trackId = try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                                      title: "Copied Track",
                                      artist: "Artist",
                                      albumArtist: nil,
                                      album: "Album")

        try db.write { db in
            try AppState.appendTrackIds([trackId], toPlaylist: sourcePlaylistId, in: db)
            try AppState.appendTrackIds([trackId], toPlaylist: destinationPlaylistId, in: db)
        }

        let sourceCount = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM playlist_tracks
                WHERE playlist_id = ? AND track_id = ?
            """, arguments: [sourcePlaylistId, trackId])
        }
        let destinationCount = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM playlist_tracks
                WHERE playlist_id = ? AND track_id = ?
            """, arguments: [destinationPlaylistId, trackId])
        }
        XCTAssertEqual(sourceCount, 1)
        XCTAssertEqual(destinationCount, 1)
    }

    @MainActor
    func testRemovingPlaylistEntriesKeepsTracksInLibraryAndSoftDeletesMembership() throws {
        let playlistID = try insertPlaylist(name: "Removal")
        let firstTrackID = try insertTrack(
            fileURL: "file:///tmp/remove-first-\(UUID().uuidString).flac",
            title: "First",
            artist: "Artist",
            albumArtist: nil,
            album: "Album"
        )
        let secondTrackID = try insertTrack(
            fileURL: "file:///tmp/remove-second-\(UUID().uuidString).flac",
            title: "Second",
            artist: "Artist",
            albumArtist: nil,
            album: "Album"
        )
        let entryIDs = try db.write { database in
            try PlaylistMutation.append([firstTrackID, secondTrackID], to: playlistID, in: database)
        }

        let appState = AppState(db: db)
        appState.removePlaylistEntries([entryIDs[0]], fromPlaylist: playlistID)

        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM tracks WHERE id = ?", arguments: [firstTrackID])
        }, 1)
        XCTAssertNotNil(try db.read { database in
            try Date.fetchOne(database, sql: "SELECT deleted_at FROM playlist_tracks WHERE id = ?", arguments: [entryIDs[0]])
        })
        XCTAssertEqual(try db.read { database in
            try PlaylistEntry.fetchVisible(in: playlistID, from: database).map(\.track.dbId)
        }, [secondTrackID])
    }

    func testReorderPlaylistEntriesPersistsCustomOrderByMembershipIdentity() throws {
        let playlistID = try insertPlaylist(name: "Reorder")
        let trackIDs = try (1...3).map { index in
            try insertTrack(
                fileURL: "file:///tmp/reorder-\(index)-\(UUID().uuidString).flac",
                title: "Track \(index)",
                artist: "Artist",
                albumArtist: nil,
                album: "Album"
            )
        }

        let entryIDs = try db.write { database -> [Int64] in
            let membershipTrackIDs = [trackIDs[0], trackIDs[1], trackIDs[0], trackIDs[2]]
            return try membershipTrackIDs.enumerated().map { position, trackID in
                try database.execute(
                    sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                    arguments: [playlistID, trackID, position]
                )
                return database.lastInsertedRowID
            }
        }

        try db.write { database in
            // Move only the second occurrence of Track 1 to the front.
            try AppState.reorderPlaylistEntries([entryIDs[2]], inPlaylist: playlistID, toRow: 0, in: database)
        }

        let rows = try db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT id, position FROM playlist_tracks
                WHERE playlist_id = ?
                ORDER BY position
            """, arguments: [playlistID])
        }
        XCTAssertEqual(rows.map { $0["id"] as Int64 }, [entryIDs[2], entryIDs[0], entryIDs[1], entryIDs[3]])
        XCTAssertEqual(rows.map { $0["position"] as Int }, [0, 1, 2, 3])
    }

    @discardableResult
    private func insertTrack(
        fileURL: String,
        title: String,
        artist: String?,
        albumArtist: String?,
        album: String,
        composer: String? = nil,
        genre: String? = nil
    ) throws -> Int64 {
        var track = Track(
            fileURL: fileURL,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            composer: composer,
            genre: genre,
            dateAdded: Date()
        )
        try db.write { db in
            try track.insert(db)
        }
        return try XCTUnwrap(track.dbId)
    }

    private func insertPlaylist(name: String) throws -> Int64 {
        var playlist = Playlist(name: name, dateCreated: Date(), dateModified: Date())
        try db.write { db in
            try playlist.insert(db)
        }
        return try XCTUnwrap(playlist.id)
    }

    private func seedSearchTracks() throws {
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Aria",
                        artist: "Glenn Gould",
                        albumArtist: "Glenn Gould",
                        album: "Goldberg Variations",
                        composer: "Johann Sebastian Bach")
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Symphony No. 5 in C Minor, Op. 67: I. Allegro",
                        artist: "Carlos Kleiber",
                        albumArtist: "Wiener Philharmoniker / Carlos Kleiber",
                        album: "Beethoven: Symphonies Nos. 5 & 7",
                        composer: "Ludwig van Beethoven")
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "La mer: De l'aube a midi sur la mer",
                        artist: "Orchestre National de France",
                        albumArtist: "Jean Martinon",
                        album: "Debussy: La Mer",
                        composer: "Claude Debussy")
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Cello Suite No. 1 in G Major: Prelude",
                        artist: "Yo-Yo Ma",
                        albumArtist: "Yo-Yo Ma",
                        album: "Bach: Cello Suites",
                        composer: "Johann Sebastian Bach")
        try insertTrack(fileURL: "file:///tmp/\(UUID().uuidString).flac",
                        title: "Piano Sonata No. 12 in F Major, K. 332: I. Allegro",
                        artist: "Mao Fujita",
                        albumArtist: "Mao Fujita",
                        album: "Mozart / The Complete Piano Sonatas - Mao Fujita",
                        composer: "Mozart")
    }

    private func searchTrackTitles(_ text: String) throws -> [String] {
        guard let searchQuery = MusicSearchQuery(text) else { return [] }
        return try db.read { db in
            try SearchResultsQuery.tracks(matching: searchQuery, in: db).compactMap(\.title)
        }
    }

    private func searchAlbumTitles(_ text: String) throws -> [String] {
        guard let searchQuery = MusicSearchQuery(text) else { return [] }
        return try db.read { db in
            try SearchResultsQuery.albums(matching: searchQuery, in: db).map(\.title)
        }
    }

    private func makeJPEGData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
    }
}
