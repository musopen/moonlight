import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class PlaylistImportServiceTests: XCTestCase {
    private var directory: URL!
    private var manager: DatabaseManager!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoonlightPlaylistImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDown() async throws {
        manager = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testParserPreservesExtendedInfoAndAbsoluteURL() throws {
        let url = try writePlaylist("\u{FEFF}#EXTM3U\n#EXTINF:245,Artist - Track\nfile:///Music/Track%20One.flac\n", named: "extended.m3u8")

        let entries = try M3UParser.parse(url: url)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].lineNumber, 3)
        XCTAssertEqual(entries[0].extendedInfo, M3UExtendedInfo(duration: 245, title: "Artist - Track"))
        XCTAssertEqual(entries[0].resolvedURL?.path, "/Music/Track One.flac")
    }

    func testPreviewMatchesExactPathAndLeavesAmbiguousFilenameUnresolved() throws {
        _ = try insertTrack(path: "/Music/One.flac")
        _ = try insertTrack(path: "/Music/A/Same.flac")
        _ = try insertTrack(path: "/Music/B/Same.flac")
        let url = try writePlaylist("file:///Music/One.flac\nSame.flac\nMissing.flac\n", named: "matches.m3u")

        let preview = try manager.read { try PlaylistImportService.preview(urls: [url], in: $0) }.single

        XCTAssertNotNil(preview.items[0].matchedTrack)
        XCTAssertNil(preview.items[1].matchedTrack)
        XCTAssertNil(preview.items[2].matchedTrack)
    }

    func testCommitPreservesOrOptionallyRemovesRepeatedLocalOnlyTracks() throws {
        _ = try insertTrack(path: "/Music/Repeated.flac")
        let url = try writePlaylist("file:///Music/Repeated.flac\nfile:///Music/Repeated.flac\n", named: "repeated.m3u8")
        let preview = try manager.read { try PlaylistImportService.preview(urls: [url], in: $0) }

        let preserved = try manager.write { try PlaylistImportService.commit(previews: preview, removeRepeatedTracks: false, in: $0) }
        let deduplicated = try manager.write { try PlaylistImportService.commit(previews: preview, removeRepeatedTracks: true, in: $0) }

        XCTAssertEqual(preserved.importedTrackCount, 2)
        XCTAssertEqual(deduplicated.importedTrackCount, 1)
        XCTAssertEqual(try manager.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL", arguments: [preserved.playlistIDs[0]])
        }, 2)
        XCTAssertEqual(try manager.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND deleted_at IS NULL", arguments: [deduplicated.playlistIDs[0]])
        }, 1)
        XCTAssertEqual(try manager.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE record_type = 'PlaylistEntry'")
        }, 0)
    }

    func testExporterWritesUTF8PlaylistAndReportsUnavailableTracks() throws {
        let output = directory.appendingPathComponent("export.m3u8")
        let available = Track(
            fileURL: URL(fileURLWithPath: "/Music/Exported Track.flac").absoluteString,
            title: "Exported Track",
            artist: "Artist",
            duration: 123.9,
            dateAdded: Date()
        )
        var unavailable = Track(
            fileURL: URL(fileURLWithPath: "/Music/Missing.flac").absoluteString,
            title: "Missing",
            dateAdded: Date()
        )
        unavailable.availabilityStatus = "unavailable"

        let report = try M3UExporter.export(tracks: [available, unavailable], to: output)

        XCTAssertEqual(report, M3UExportReport(exportedTrackCount: 1, unavailableTrackCount: 1))
        let content = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(content.contains("#EXTINF:123,Artist - Exported Track"))
        XCTAssertTrue(content.contains("/Music/Exported Track.flac"))
        XCTAssertFalse(content.contains("Missing.flac"))
    }

    func testExporterKeepsEachTrackOnItsOwnLines() throws {
        let output = directory.appendingPathComponent("export.m3u8")
        let injected = Track(
            fileURL: URL(fileURLWithPath: "/Music/Song.flac").absoluteString,
            title: "Song\n/Users/victim/secret.flac",
            artist: "Artist\r\n#EXTINF:1,Fake",
            duration: 60,
            dateAdded: Date()
        )
        let newlinePath = Track(
            fileURL: URL(fileURLWithPath: "/Music/Bad\nName.flac").absoluteString,
            title: "Bad",
            duration: 60,
            dateAdded: Date()
        )

        let report = try M3UExporter.export(tracks: [injected, newlinePath], to: output)

        XCTAssertEqual(report, M3UExportReport(exportedTrackCount: 1, unavailableTrackCount: 1))
        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines, [
            "#EXTM3U",
            "#EXTINF:60,Artist #EXTINF:1,Fake - Song /Users/victim/secret.flac",
            "/Music/Song.flac",
            ""
        ])
    }

    func testTextCleaningReplacesControlCharactersButKeepsOrdinaryText() {
        XCTAssertEqual("A\r\n\tB\u{0}C".singleLineText, "A B C")
        XCTAssertEqual("Line\u{2028}Two".singleLineText, "Line Two")
        XCTAssertEqual("Dvořák  👩‍👩‍👧 Op. 95".singleLineText, "Dvořák  👩‍👩‍👧 Op. 95")
        XCTAssertEqual("One\r\nTwo\rThree\u{7}".cleanedText(keepingLineBreaks: true), "One\nTwo\nThree ")
    }

    private func insertTrack(path: String) throws -> Int64 {
        var track = Track(fileURL: URL(fileURLWithPath: path).absoluteString, title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, dateAdded: Date())
        try manager.write { try track.insert($0) }
        return try XCTUnwrap(track.dbId)
    }

    private func writePlaylist(_ content: String, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private extension Collection {
    var single: Element {
        precondition(count == 1)
        return first!
    }
}
