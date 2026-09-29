import AppKit
import GRDB
import XCTest
@testable import Moonlight

final class ScannerTests: XCTestCase {

    func testSupportedExtensions() {
        XCTAssertTrue(MetadataExtractor.supportedExtensions.contains("mp3"))
        XCTAssertTrue(MetadataExtractor.supportedExtensions.contains("flac"))
        XCTAssertTrue(MetadataExtractor.supportedExtensions.contains("aiff"))
        XCTAssertTrue(MetadataExtractor.supportedExtensions.contains("m4a"))
        XCTAssertFalse(MetadataExtractor.supportedExtensions.contains("pdf"))
        XCTAssertFalse(MetadataExtractor.supportedExtensions.contains("mp4"))
    }

    func testArtworkThumbnail() {
        // A 1x1 white JPEG as test input
        let imageData = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
            0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0xFF, 0xD9
        ])
        // Thumbnail generation shouldn't crash on malformed data
        let result = ArtworkExtractor.thumbnail(from: imageData, size: 64)
        // Result may be nil for invalid data — that's acceptable
        _ = result
    }

    func testArtworkImageDownsamplesToMaxPixelSize() throws {
        let data = try makeJPEGData(width: 800, height: 600)
        let image = try XCTUnwrap(Artwork.image(from: data, maxPixelSize: 400))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        XCTAssertLessThanOrEqual(cgImage.width, 400)
        XCTAssertLessThanOrEqual(cgImage.height, 400)
        XCTAssertEqual(cgImage.width, 400)
        XCTAssertEqual(cgImage.height, 300)
    }

    func testArtworkImageDownsampleRejectsInvalidData() {
        XCTAssertNil(Artwork.image(from: Data("not an image".utf8), maxPixelSize: 400))
    }

    func testArtworkStoreDeduplicatesAndBoundsRenditions() throws {
        let db = makeTemporaryDatabase()
        let source = try makeJPEGData(width: 1_200, height: 900)

        let firstID = try XCTUnwrap(ArtworkStore.store(sourceData: source, sourceURL: nil, db: db))
        let secondID = try XCTUnwrap(ArtworkStore.store(sourceData: source, sourceURL: nil, db: db))

        XCTAssertEqual(firstID, secondID)

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT data_small, data_large FROM artwork WHERE id = ?", arguments: [firstID])
        }
        let smallData: Data = try XCTUnwrap(row?["data_small"])
        let largeData: Data = try XCTUnwrap(row?["data_large"])
        let small = try XCTUnwrap(Artwork.image(from: smallData, maxPixelSize: 1_000))
        let large = try XCTUnwrap(Artwork.image(from: largeData, maxPixelSize: 1_000))
        let smallCGImage = try XCTUnwrap(small.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let largeCGImage = try XCTUnwrap(large.cgImage(forProposedRect: nil, context: nil, hints: nil))

        XCTAssertEqual(smallCGImage.width, 160)
        XCTAssertEqual(smallCGImage.height, 120)
        XCTAssertEqual(largeCGImage.width, 600)
        XCTAssertEqual(largeCGImage.height, 450)
        XCTAssertEqual(try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artwork") }, 1)
    }

    func testArtworkStoreGeneratesThumbnailDirectlyFromOriginalArtwork() throws {
        let source = try makeJPEGData(width: 1_200, height: 900)
        let prepared = try XCTUnwrap(ArtworkStore.prepare(from: source))

        let expectedThumbnail = try XCTUnwrap(ArtworkExtractor.thumbnail(
            from: source,
            size: ArtworkStore.thumbnailSize,
            compressionQuality: ArtworkStore.thumbnailCompressionQuality
        ))

        XCTAssertEqual(prepared.thumbnailData, expectedThumbnail)
    }

    func testMetadataNormalization() {
        XCTAssertNil(MetadataExtractor.normalizedTagValue(nil))
        XCTAssertNil(MetadataExtractor.normalizedTagValue(""))
        XCTAssertNil(MetadataExtractor.normalizedTagValue("   \n"))
        XCTAssertEqual(MetadataExtractor.normalizedTagValue("  Bach  "), "Bach")
        XCTAssertEqual(
            MetadataExtractor.normalizedTagValue("Dvor\u{030C}a\u{0301}k"),
            "Dvo\u{0159}\u{00E1}k"
        )
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
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
    }

    func testMetadataNumberParsing() {
        XCTAssertEqual(MetadataExtractor.parseLeadingInteger("03/7"), 3)
        XCTAssertEqual(MetadataExtractor.parseLeadingInteger("1/1"), 1)
        XCTAssertEqual(MetadataExtractor.parseLeadingInteger("  12  "), 12)
        XCTAssertNil(MetadataExtractor.parseLeadingInteger(""))
        XCTAssertNil(MetadataExtractor.parseLeadingInteger("abc"))
        XCTAssertEqual(MetadataExtractor.parseYear("2022-05-01"), 2022)
    }

    func testSparseTagUpdatePreservesUneditedProperties() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("tagged.wav")
        try makeMinimalWAVData().write(to: url)

        try MetadataTagFileWriter.apply(
            TagEditPatch(setting: [.title: "Original Title", .artist: "Original Artist", .comment: "Keep Me"]),
            to: url
        )

        let before = try MetadataTagFileWriter.rawProperties(in: url)
        XCTAssertEqual(before["TITLE"], "Original Title")
        XCTAssertEqual(before["ARTIST"], "Original Artist")
        XCTAssertEqual(before["COMMENT"], "Keep Me")

        try MetadataTagFileWriter.apply(
            TagEditPatch(setting: [.title: "Edited Title"]),
            to: url
        )

        let after = try MetadataTagFileWriter.rawProperties(in: url)
        XCTAssertEqual(after["TITLE"], "Edited Title")
        XCTAssertEqual(after["ARTIST"], "Original Artist")
        XCTAssertEqual(after["COMMENT"], "Keep Me")
    }

    func testMetadataEditingDoesNotOverwriteLocalRating() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rated.wav")
        try makeMinimalWAVData().write(to: url)
        let db = try DatabaseManager(path: root.appendingPathComponent("library.sqlite").path)
        var track = Track(fileURL: url.absoluteString, title: "Before", rating: 5, dateAdded: Date())
        try db.write { try track.insert($0) }

        let service = MetadataEditingService(db: db, bookmarkStore: FolderBookmarkStore(db: db))
        let results = await service.apply(TagEditPatch(setting: [.title: "After"]), to: [track])

        guard case .saved? = results.first?.status else {
            return XCTFail("Expected the tag edit to be saved")
        }
        let refreshed = try XCTUnwrap(db.read { try Track.fetchOne($0, key: track.dbId) })
        XCTAssertEqual(refreshed.title, "After")
        XCTAssertEqual(refreshed.rating, 5)
    }

    func testDerivedDataMaterializesSyncedAnnotationsForNewlyAvailableTrack() async throws {
        let db = makeTemporaryDatabase()
        let syncID = UUID().uuidString.uppercased()
        let trackID = try db.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO logical_tracks (track_sync_id, title, created_at) VALUES (?, 'Downloaded First', ?)",
                arguments: [syncID, Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO tracks
                        (file_url, availability_status, title, date_added, track_sync_id,
                         physical_file_id, id_state)
                    VALUES (?, 'available', 'Downloaded First', ?, ?, ?, 'embedded')
                """,
                arguments: ["file:///tmp/\(syncID).mp3", Date(), syncID, UUID().uuidString.uppercased()]
            )
            try db.execute(
                sql: """
                    INSERT INTO track_annotations
                        (track_sync_id, rating, rating_rev, favorite, favorite_rev)
                    VALUES (?, 4, 'rating-revision', 1, 'favorite-revision')
                """,
                arguments: [syncID]
            )
            return db.lastInsertedRowID
        }

        await LibraryScanner(db: db).rebuildDerivedData()

        let row = try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT rating, rating_rev, is_favorite, favorite_rev FROM tracks WHERE id = ?",
                arguments: [trackID]
            )
        }
        XCTAssertEqual(row?["rating"] as Int?, 4)
        XCTAssertEqual(row?["rating_rev"] as String?, "rating-revision")
        XCTAssertEqual(row?["is_favorite"] as Bool?, true)
        XCTAssertEqual(row?["favorite_rev"] as String?, "favorite-revision")
    }

    func testDerivedDataMaterializesSyncedPlaylistEntryForNewlyAvailableTrack() async throws {
        let db = makeTemporaryDatabase()
        let playlistID = UUID().uuidString.uppercased()
        let trackSyncID = UUID().uuidString.uppercased()
        let entryID = UUID().uuidString.uppercased()
        let localPlaylistID = try db.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO logical_tracks (track_sync_id, title, created_at) VALUES (?, 'Available After Sync', ?)",
                arguments: [trackSyncID, Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO tracks
                        (file_url, availability_status, title, date_added, track_sync_id,
                         physical_file_id, id_state)
                    VALUES (?, 'available', 'Available After Sync', ?, ?, ?, 'embedded')
                """,
                arguments: ["file:///tmp/\(trackSyncID).mp3", Date(), trackSyncID, UUID().uuidString.uppercased()]
            )
            try db.execute(
                sql: """
                    INSERT INTO playlists
                        (name, date_created, date_modified, playlist_sync_id, kind,
                         name_rev, sort_mode, sort_mode_rev)
                    VALUES ('Downloaded Playlist', ?, ?, ?, 'manual', '', 'manual', '')
                """,
                arguments: [Date(), Date(), playlistID]
            )
            let playlist = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO synced_playlist_entries
                        (playlist_entry_id, playlist_sync_id, track_sync_id, ordering_key,
                         ordering_key_rev, created_at)
                    VALUES (?, ?, ?, 'U', '', ?)
                """,
                arguments: [entryID, playlistID, trackSyncID, Date()]
            )
            return playlist
        }

        await LibraryScanner(db: db).rebuildDerivedData()

        let entry = try db.read { db in
            try PlaylistEntry.fetchVisible(in: localPlaylistID, from: db).first
        }
        XCTAssertEqual(entry?.track.title, "Available After Sync")
        XCTAssertEqual(try db.read {
            try String.fetchOne($0, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE playlist_id = ?", arguments: [localPlaylistID])
        }, entryID)
    }

    func testSparseTagUpdatePreservesUTF8Properties() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("unicode-tagged.wav")
        try makeMinimalWAVData().write(to: url)

        let title = "Jakub Hrůša – Symphony in B-flat “Pastorale”"
        let artist = "Klaus Mäkelä, Oslo Philharmonic Orchestra"
        let composer = "Antonín Dvořák"

        try MetadataTagFileWriter.apply(
            TagEditPatch(setting: [
                .title: title,
                .artist: artist,
                .composer: composer
            ]),
            to: url
        )

        let raw = try MetadataTagFileWriter.rawProperties(in: url)
        XCTAssertEqual(raw["TITLE"], title)
        XCTAssertEqual(raw["ARTIST"], artist)
        XCTAssertEqual(raw["COMPOSER"], composer)

        let values = try MetadataTagFileWriter.values(in: url, fields: [.title, .artist, .composer])
        XCTAssertEqual(values[.title], title)
        XCTAssertEqual(values[.artist], artist)
        XCTAssertEqual(values[.composer], composer)
    }

    func testSparseTagUpdateClearsOnlyRequestedProperty() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("cleared.wav")
        try makeMinimalWAVData().write(to: url)

        try MetadataTagFileWriter.apply(
            TagEditPatch(setting: [.title: "Original Title", .artist: "Original Artist"]),
            to: url
        )
        try MetadataTagFileWriter.apply(
            TagEditPatch(removing: [.title]),
            to: url
        )

        let after = try MetadataTagFileWriter.rawProperties(in: url)
        XCTAssertNil(after["TITLE"])
        XCTAssertEqual(after["ARTIST"], "Original Artist")
    }

    func testArtworkRemovalClearsEmbeddedPicture() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("artwork.wav")
        let imageURL = root.appendingPathComponent("cover.jpg")
        try makeMinimalWAVData().write(to: url)
        try makeJPEGData(width: 120, height: 120).write(to: imageURL)

        try MetadataTagFileWriter.apply(TagEditPatch(artwork: .replace(imageURL)), to: url)
        XCTAssertNotNil(MetadataTagFileWriter.artworkImage(in: url))

        try MetadataTagFileWriter.apply(TagEditPatch(artwork: .remove), to: url)
        XCTAssertNil(MetadataTagFileWriter.artworkImage(in: url))
    }

    func testFolderArtworkFindsCaseInsensitiveTrackFolderImage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let track = root.appendingPathComponent("track.flac")
        let artwork = root.appendingPathComponent("Cover.JPG")
        let data = Data("art".utf8)

        try Data().write(to: track)
        try data.write(to: artwork)

        XCTAssertEqual(ArtworkExtractor.folderImage(for: track), data)
    }

    func testFolderArtworkFindsParentImageForDiscFolder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let disc = root.appendingPathComponent("CD2", isDirectory: true)
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)

        let track = disc.appendingPathComponent("track.flac")
        let artwork = root.appendingPathComponent("cover.jpg")
        let data = Data("parent-art".utf8)

        try Data().write(to: track)
        try data.write(to: artwork)

        XCTAssertEqual(ArtworkExtractor.folderImage(for: track), data)
    }

    func testFolderArtworkFindsCommonSubfolderImage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)

        let track = root.appendingPathComponent("track.flac")
        let artwork = covers.appendingPathComponent("front.png")
        let data = Data("subfolder-art".utf8)

        try Data().write(to: track)
        try data.write(to: artwork)

        XCTAssertEqual(ArtworkExtractor.folderImage(for: track), data)
    }

    func testIncrementalScanSkipsUnchangedFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()

        let track = root.appendingPathComponent("unchanged.wav")
        try makeMinimalWAVData().write(to: track)
        _ = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }
        let scannedSummary = await LibraryScanner(db: db).scan(folderURL: root, mode: .incremental, trigger: .manual) { _ in }
        let summary = try XCTUnwrap(scannedSummary)

        XCTAssertEqual(summary.totalFiles, 1)
        XCTAssertEqual(summary.skippedFiles, 1)
        XCTAssertEqual(summary.changedFiles, 0)

        let row = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT mode, trigger, total_files, skipped_files, changed_files, error_count
                FROM scan_jobs
                WHERE id = ?
            """, arguments: [summary.jobId!])
        })
        XCTAssertEqual(row["mode"] as String, ScanMode.incremental.rawValue)
        XCTAssertEqual(row["trigger"] as String, ScanTrigger.manual.rawValue)
        XCTAssertEqual(row["total_files"] as Int, 1)
        XCTAssertEqual(row["skipped_files"] as Int, 1)
        XCTAssertEqual(row["changed_files"] as Int, 0)
        XCTAssertEqual(row["error_count"] as Int, 0)
    }

    func testIncrementalScanRefreshesChangedFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()

        let track = root.appendingPathComponent("changed.wav")
        try makeMinimalWAVData().write(to: track)
        _ = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: track.path)
        let scannedSummary = await LibraryScanner(db: db).scan(folderURL: root, mode: .incremental, trigger: .manual) { _ in }
        let summary = try XCTUnwrap(scannedSummary)

        XCTAssertEqual(summary.skippedFiles, 0)
        XCTAssertEqual(summary.changedFiles, 1)
    }

    func testFullRebuildIgnoresIncrementalSkipCheck() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()

        let track = root.appendingPathComponent("rebuilt.wav")
        try makeMinimalWAVData().write(to: track)
        _ = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }
        let scannedSummary = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }
        let summary = try XCTUnwrap(scannedSummary)

        XCTAssertEqual(summary.skippedFiles, 0)
        XCTAssertEqual(summary.changedFiles, 1)
    }

    func testEmbeddedIdentityChangeInvalidatesIncrementalSkip() {
        let stored = UUID().uuidString.uppercased()
        let copied = UUID().uuidString.uppercased()

        XCTAssertFalse(LibraryScanner.requiresIdentityRefresh(
            embeddedTrackSyncID: stored,
            storedTrackSyncID: stored,
            storedIdentityState: PortableIdentityState.embedded.rawValue
        ))
        XCTAssertTrue(LibraryScanner.requiresIdentityRefresh(
            embeddedTrackSyncID: copied,
            storedTrackSyncID: stored,
            storedIdentityState: PortableIdentityState.embedded.rawValue
        ))
        XCTAssertTrue(LibraryScanner.requiresIdentityRefresh(
            embeddedTrackSyncID: nil,
            storedTrackSyncID: stored,
            storedIdentityState: PortableIdentityState.embedded.rawValue
        ))
        XCTAssertFalse(LibraryScanner.requiresIdentityRefresh(
            embeddedTrackSyncID: nil,
            storedTrackSyncID: stored,
            storedIdentityState: PortableIdentityState.absent.rawValue
        ))
    }

    func testMissingTrackIsPreservedAndRestoredAtItsOriginalPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()
        let folderId = try insertFolder(url: root, db: db)
        let trackURL = root.appendingPathComponent("recover-me.wav")
        try makeMinimalWAVData().write(to: trackURL)

        _ = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .fullRebuild,
            trigger: .manual
        ) { _ in }
        let originalId = try XCTUnwrap(db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks")
        })
        try db.write { db in
            try db.execute(
                sql: "UPDATE tracks SET is_favorite = 1, rating = 4, play_count = 9 WHERE id = ?",
                arguments: [originalId]
            )
        }

        _ = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .fullRebuild,
            trigger: .manual
        ) { _ in }
        XCTAssertEqual(try db.read { database in
            try Int.fetchOne(database, sql: "SELECT rating FROM tracks WHERE id = ?", arguments: [originalId])
        }, 4)

        try FileManager.default.removeItem(at: trackURL)
        let missingScanResult = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { _ in }
        let missingScan = try XCTUnwrap(missingScanResult)

        XCTAssertEqual(missingScan.missingFiles, 1)
        XCTAssertEqual(missingScan.removedFiles, 0)
        let missingRow = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, availability_status, missing_since, is_favorite, rating, play_count
                FROM tracks WHERE id = ?
            """, arguments: [originalId])
        })
        XCTAssertEqual(missingRow["availability_status"] as String, "missing")
        XCTAssertNotNil(missingRow["missing_since"] as Date?)
        XCTAssertEqual(missingRow["is_favorite"] as Bool, true)
        XCTAssertEqual(missingRow["rating"] as Int?, 4)
        XCTAssertEqual(missingRow["play_count"] as Int, 9)

        try makeMinimalWAVData().write(to: trackURL)
        let restoredScanResult = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { _ in }
        let restoredScan = try XCTUnwrap(restoredScanResult)

        XCTAssertEqual(restoredScan.relinkedFiles, 1)
        let restoredRow = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, availability_status, missing_since, is_favorite, rating, play_count
                FROM tracks
            """)
        })
        XCTAssertEqual(restoredRow["id"] as Int64, originalId)
        XCTAssertEqual(restoredRow["availability_status"] as String, "available")
        XCTAssertNil(restoredRow["missing_since"] as Date?)
        XCTAssertEqual(restoredRow["is_favorite"] as Bool, true)
        XCTAssertEqual(restoredRow["rating"] as Int?, 4)
        XCTAssertEqual(restoredRow["play_count"] as Int, 9)
        XCTAssertEqual(try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") }, 1)
    }

    func testRenameAndMoveRelinksSameTrackAndPreservesMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()
        let folderId = try insertFolder(url: root, db: db)
        let originalURL = root.appendingPathComponent("01 Airbag.wav")
        try makeMinimalWAVData().write(to: originalURL)

        _ = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .fullRebuild,
            trigger: .manual
        ) { _ in }

        let originalRow = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, file_resource_identifier, document_identifier, volume_uuid, date_added
                FROM tracks
            """)
        })
        let originalId: Int64 = originalRow["id"]
        let fileResourceIdentifier: Data? = originalRow["file_resource_identifier"]
        let documentIdentifier: Int64? = originalRow["document_identifier"]
        let volumeUUID: String? = originalRow["volume_uuid"]
        guard fileResourceIdentifier != nil, volumeUUID != nil else {
            throw XCTSkip("The test volume does not expose a file resource identifier")
        }
        let originalDateAdded: Date = originalRow["date_added"]

        let playlistId = try db.write { db -> Int64 in
            try db.execute(sql: """
                UPDATE tracks
                SET is_favorite = 1, rating = 5, play_count = 7, last_played_at = ?
                WHERE id = ?
            """, arguments: [Date(), originalId])
            try db.execute(sql: """
                INSERT INTO playlists (name, date_created, date_modified)
                VALUES ('Recovery Test', ?, ?)
            """, arguments: [Date(), Date()])
            let playlistId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position)
                VALUES (?, ?, 0)
            """, arguments: [playlistId, originalId])
            return playlistId
        }

        let albumFolder = root.appendingPathComponent("Radiohead/OK Computer", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        let movedURL = albumFolder.appendingPathComponent("Airbag.wav")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let scanResult = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { _ in }
        let summary = try XCTUnwrap(scanResult)

        XCTAssertEqual(summary.relinkedFiles, 1)
        XCTAssertEqual(summary.missingFiles, 0)
        XCTAssertEqual(summary.removedFiles, 0)
        XCTAssertEqual(try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") }, 1)

        let movedRow = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, file_url, availability_status, missing_since,
                       file_resource_identifier, document_identifier, volume_uuid,
                       date_added, is_favorite, rating, play_count
                FROM tracks
            """)
        })
        XCTAssertEqual(movedRow["id"] as Int64, originalId)
        let canonicalMovedPath = movedURL.path.hasPrefix("/var/") ? "/private\(movedURL.path)" : movedURL.path
        XCTAssertEqual(movedRow["file_url"] as String, URL(fileURLWithPath: canonicalMovedPath).absoluteString)
        XCTAssertEqual(movedRow["availability_status"] as String, "available")
        XCTAssertNil(movedRow["missing_since"] as Date?)
        XCTAssertEqual(movedRow["file_resource_identifier"] as Data?, fileResourceIdentifier)
        XCTAssertEqual(movedRow["document_identifier"] as Int64?, documentIdentifier)
        XCTAssertEqual(movedRow["volume_uuid"] as String?, volumeUUID)
        XCTAssertEqual(movedRow["date_added"] as Date, originalDateAdded)
        XCTAssertEqual(movedRow["is_favorite"] as Bool, true)
        XCTAssertEqual(movedRow["rating"] as Int?, 5)
        XCTAssertEqual(movedRow["play_count"] as Int, 7)
        XCTAssertEqual(try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?",
                arguments: [playlistId, originalId]
            )
        }, 1)
    }

    func testFailedScanDoesNotMarkPreviouslyAvailableTracksMissing() async throws {
        let root = try makeTemporaryDirectory()
        let movedRoot = root.deletingLastPathComponent()
            .appendingPathComponent("MoonlightScannerMoved-(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let db = makeTemporaryDatabase()
        let folderId = try insertFolder(url: root, db: db)
        let trackURL = root.appendingPathComponent("still-owned.wav")
        try makeMinimalWAVData().write(to: trackURL)

        _ = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .fullRebuild,
            trigger: .manual
        ) { _ in }
        let trackId = try XCTUnwrap(db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks")
        })
        try FileManager.default.moveItem(at: root, to: movedRoot)

        let failedScanResult = await LibraryScanner(db: db).scan(
            folderURL: root,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { _ in }
        let failedSummary = try XCTUnwrap(failedScanResult)

        XCTAssertEqual(failedSummary.missingFiles, 0)
        XCTAssertTrue(failedSummary.failed)
        XCTAssertEqual(failedSummary.failureMessage, "Could not completely enumerate library folder")
        let row = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: "SELECT availability_status FROM tracks WHERE id = ?", arguments: [trackId])
        })
        XCTAssertEqual(row["availability_status"] as String, "available")
        let jobStatus = try XCTUnwrap(db.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM scan_jobs WHERE id = ?", arguments: [failedSummary.jobId])
        })
        XCTAssertEqual(jobStatus, "failed")

        let reconnectResult = await LibraryScanner(db: db).scan(
            folderURL: movedRoot,
            folderId: folderId,
            mode: .incremental,
            trigger: .manual
        ) { _ in }
        let reconnectSummary = try XCTUnwrap(reconnectResult)
        XCTAssertEqual(reconnectSummary.relinkedFiles, 1)
        XCTAssertEqual(reconnectSummary.missingFiles, 0)
        let reconnectedRow = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: "SELECT id, file_url, availability_status FROM tracks")
        })
        XCTAssertEqual(reconnectedRow["id"] as Int64, trackId)
        XCTAssertEqual(reconnectedRow["availability_status"] as String, "available")
        XCTAssertTrue((reconnectedRow["file_url"] as String).contains(movedRoot.lastPathComponent))
    }

    func testScanErrorPersistsStageAndCategory() async throws {
        let db = makeTemporaryDatabase()
        let jobId = try db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO scan_jobs (started_at, status, mode, trigger)
                VALUES (?, 'running', 'incremental', 'manual')
            """, arguments: [Date()])
            return db.lastInsertedRowID
        }

        LibraryScanner.recordScanError(
            db: db,
            jobId: jobId,
            fileURL: "file:///tmp/broken.mp3",
            stage: "metadata",
            category: "timeout",
            reason: "Timed out"
        )

        let row = try XCTUnwrap(db.read { db in
            try Row.fetchOne(db, sql: "SELECT stage, category, stable_file_url FROM scan_errors WHERE scan_job_id = ?", arguments: [jobId])
        })
        XCTAssertEqual(row["stage"] as String, "metadata")
        XCTAssertEqual(row["category"] as String, "timeout")
        XCTAssertTrue((row["stable_file_url"] as String).hasSuffix("broken.mp3"))
    }

    func testRemovingFolderClearsScanJobReference() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()
        let store = FolderBookmarkStore(db: db)

        try await store.addFolder(url: root)
        let folders = await store.resolvedFolders()
        let folder = try XCTUnwrap(folders.first)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO scan_jobs (folder_id, started_at, status, mode, trigger)
                VALUES (?, ?, 'completed', 'incremental', 'manual')
            """, arguments: [folder.id, Date()])
        }

        try await store.removeFolder(id: folder.id)

        let folderCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders")
        }
        let scanJobFolderId = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT folder_id FROM scan_jobs LIMIT 1")
        }
        XCTAssertEqual(folderCount, 0)
        XCTAssertNil(scanJobFolderId)
    }

    func testReaddingCanonicalFolderIsRecognizedAsDuplicate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()
        let store = FolderBookmarkStore(db: db)

        let firstRegistration = try await store.addFolder(url: root)
        let originalFolders = await store.resolvedFolders()
        let original = try XCTUnwrap(originalFolders.first)

        let duplicateRegistration = try await store.addFolder(url: root.appendingPathComponent("."))
        let refreshedFolders = await store.resolvedFolders()
        let refreshed = try XCTUnwrap(refreshedFolders.first)

        XCTAssertEqual(firstRegistration, .added(id: original.id, url: root.standardizedFileURL.resolvingSymlinksInPath()))
        XCTAssertEqual(duplicateRegistration, .duplicate(id: original.id, url: root.standardizedFileURL.resolvingSymlinksInPath()))
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshedFolders.count, 1)
    }

    func testFullRebuildClearsStaleArtworkWhenFileHasNoArtwork() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = makeTemporaryDatabase()

        let track = root.appendingPathComponent("no-art.wav")
        try makeMinimalWAVData().write(to: track)
        _ = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }

        try db.write { db in
            try db.execute(sql: "INSERT INTO artwork (data_small, data_large) VALUES (?, ?)", arguments: [Data("a".utf8), Data("b".utf8)])
            try db.execute(sql: "UPDATE tracks SET artwork_id = ? WHERE file_url = ?", arguments: [db.lastInsertedRowID, track.absoluteString])
        }

        _ = await LibraryScanner(db: db).scan(folderURL: root, mode: .fullRebuild, trigger: .manual) { _ in }
        let artworkId = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT artwork_id FROM tracks WHERE file_url = ?", arguments: [track.absoluteString])
        }
        XCTAssertNil(artworkId)
    }

    func testOrderedSelectionSupportsSingleToggleRangeAndRetain() {
        var selection = OrderedSelection<String>()
        let ids = ["a", "b", "c", "d"]

        selection.select("b", in: ids, modifiers: [])
        XCTAssertEqual(selection.ids, Set(["b"]))

        selection.select("d", in: ids, modifiers: [.shift])
        XCTAssertEqual(selection.ids, Set(["b", "c", "d"]))

        selection.select("c", in: ids, modifiers: [.command])
        XCTAssertEqual(selection.ids, Set(["b", "d"]))

        selection.select("a", in: ids, modifiers: [])
        XCTAssertEqual(selection.ids, Set(["a"]))

        selection.retain(validIds: ["d"])
        XCTAssertEqual(selection.ids, Set())

        selection.select("d", in: ids, modifiers: [])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }

    func testTrackRowBackgroundPrecedence() {
        XCTAssertEqual(
            TrackRowBackgroundKind.resolve(isSelected: true, isCurrent: true, isHovered: true),
            .selected
        )
        XCTAssertEqual(
            TrackRowBackgroundKind.resolve(isSelected: true, isCurrent: false, isHovered: true),
            .selected
        )
        XCTAssertEqual(
            TrackRowBackgroundKind.resolve(isSelected: false, isCurrent: true, isHovered: true),
            .hover
        )
        XCTAssertEqual(
            TrackRowBackgroundKind.resolve(isSelected: false, isCurrent: true, isHovered: false),
            .clear
        )
        XCTAssertEqual(
            TrackRowBackgroundKind.resolve(isSelected: false, isCurrent: false, isHovered: false),
            .clear
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemporaryDatabase() -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightScannerDB-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try! DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    private func insertTrack(fileURL: String, db: DatabaseManager) throws {
        var track = Track(
            fileURL: fileURL,
            fileSize: 1,
            fileModifiedAt: Date(),
            title: "Missing",
            artist: "Artist",
            albumArtist: nil,
            album: "Album",
            composer: nil,
            genre: nil,
            year: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: nil,
            bitRate: nil,
            sampleRate: nil,
            channelCount: nil,
            format: "wav",
            dateAdded: Date()
        )
        try db.write { db in try track.insert(db) }
    }

    private func insertFolder(url: URL, db: DatabaseManager) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO folders (url, bookmark_data, date_added)
                VALUES (?, ?, ?)
            """, arguments: [url.absoluteString, Data(), Date()])
            return db.lastInsertedRowID
        }
    }

    private func makeMinimalWAVData() -> Data {
        var data = Data()
        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleData = Data([0, 0, 0, 0])
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        appendASCII("RIFF", to: &data)
        appendUInt32LE(UInt32(36 + sampleData.count), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(channels, to: &data)
        appendUInt32LE(sampleRate, to: &data)
        appendUInt32LE(byteRate, to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(UInt32(sampleData.count), to: &data)
        data.append(sampleData)

        return data
    }

    private func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
