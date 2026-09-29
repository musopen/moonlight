// MobileImportService.swift
//
// Brings music files the user picks on iPhone or iPad into Moonlight. Each file is copied into the
// app's Music folder, given a permanent ID tag, has its song details (title, artist, album,
// artwork) read, and is added to the library database. It runs in the background so large imports
// do not freeze the screen, and skips songs that are already on the device.

import AVFoundation
import Foundation
import GRDB
import SPFKMetadataC

enum MobileImportError: LocalizedError {
    case unsupportedFormat(String)
    case inaccessibleFile
    case duplicateIdentity

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value): "Moonlight cannot yet import .\(value) files on this device."
        case .inaccessibleFile: "The selected file provider did not make this file available."
        case .duplicateIdentity: "This track is already stored on this device."
        }
    }
}

/// Copies user-selected audio into the app container and indexes it.
///
/// This is an actor rather than a method on the `@MainActor` library model on
/// purpose. Importing one file performs a full-size copy, a possible iCloud
/// materialization, one tag read, a TagLib property read and a database write.
/// Running that chain on the main actor froze the UI and got the app killed with
/// `0x8badf00d` on a realistic multi-file import.
actor MobileImportService {
    struct Progress: Sendable {
        let completed: Int
        let total: Int
        let filename: String
    }

    private let database: DatabaseManager
    private let tagger: PortableIdentityTagger
    private let writerID: @Sendable (Database) throws -> String

    init(
        database: DatabaseManager,
        writerID: @escaping @Sendable (Database) throws -> String = { database in
            try SyncDeviceIdentity.id(in: database)
        }
    ) {
        self.database = database
        self.tagger = PortableIdentityTagger(db: database)
        self.writerID = writerID
    }

    /// Imports each URL in turn, reporting progress as it goes. Returns one
    /// message per failed file; an empty array means everything landed.
    ///
    /// Failures are collected rather than thrown so one bad file in a selection of
    /// sixty does not abandon the other fifty-nine.
    func importFiles(_ urls: [URL], progress: @Sendable @escaping (Progress) -> Void) async -> [String] {
        var failures: [String] = []
        var imported = 0

        for (index, url) in urls.enumerated() {
            progress(Progress(completed: index, total: urls.count, filename: url.lastPathComponent))
            do {
                try await importFile(url)
                imported += 1
            } catch MobileImportError.duplicateIdentity {
                continue
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // One rebuild for the batch. Rebuilding per file made import cost grow
        // with the square of the library size.
        if MobileImportBatchPolicy.requiresSearchIndexRebuild(successfulImportCount: imported) {
            do { try rebuildSearchIndex() }
            catch { failures.append("Search index rebuild failed: \(error.localizedDescription)") }
        }
        return failures
    }

    private func importFile(_ source: URL) async throws {
        let ext = source.pathExtension.lowercased()
        guard PortableIdentityTag.supportedExtensions.contains(ext) else { throw MobileImportError.unsupportedFormat(ext) }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let musicDirectory = try ContainerPathResolver.directory(for: .manual)
        let destination = uniqueDestination(for: source.lastPathComponent, in: musicDirectory)
        var staged = musicDirectory.appendingPathComponent(".import-\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            try coordinatedCopy(from: source, to: staged)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            try staged.setResourceValues(excluded)

            let existingIdentity = PortableIdentityTag.read(from: staged)
            let audioHash = try AudioEssenceHasher.hash(url: staged)
            let duplicateCount = try database.read { db in
                if let existingIdentity {
                    return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE track_sync_id=? AND availability_status='available'", arguments: [existingIdentity]) ?? 0
                }
                // Untagged imports intentionally remain independent local identities.
                // Audio hashes verify rewrite integrity, never identity.
                return 0
            }
            guard duplicateCount == 0 else { throw MobileImportError.duplicateIdentity }

            let identity = existingIdentity ?? UUID().uuidString.uppercased()
            if existingIdentity == nil {
                let values = try staged.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                try await tagger.tag(url: staged, identity: identity, expectedSize: Int64(values.fileSize ?? 0), expectedMtime: values.contentModificationDate)
            }

            try FileManager.default.moveItem(at: staged, to: destination)
            let properties = normalizedProperties(TagLibBridge.getProperties(destination.path) as? [String: String] ?? [:])
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            let artworkData = await embeddedArtwork(in: asset)
            let resources = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let preparedArtwork = artworkData.flatMap(ArtworkStore.prepare)
            let physicalID = UUID().uuidString.uppercased()
            let relativePath = destination.lastPathComponent
            guard let reference = ContainerFileReference(root: .manual, relativePath: relativePath) else {
                throw MobileImportError.inaccessibleFile
            }

            try database.write { db in
                let writer = try writerID(db)
                let revision = SyncRevision.make(writerID: writer).rawValue
                let title = properties["TITLE"] ?? destination.deletingPathExtension().lastPathComponent
                let artist = properties["ARTIST"]
                let albumArtist = properties["ALBUMARTIST"] ?? properties["ALBUM ARTIST"]
                let album = properties["ALBUM"]
                let artworkID = try preparedArtwork.map { try ArtworkStore.artworkID(for: $0, sourceURL: reference.rawValue, db: db) }
                try db.execute(sql: "INSERT INTO logical_tracks (track_sync_id, title, artist, album, album_artist, genre, track_number, disc_number, year, duration_ms, metadata_rev, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(track_sync_id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album, album_artist=excluded.album_artist, genre=excluded.genre, track_number=excluded.track_number, disc_number=excluded.disc_number, year=excluded.year, duration_ms=excluded.duration_ms, metadata_rev=excluded.metadata_rev", arguments: [identity, title, artist, album, albumArtist, properties["GENRE"], integer(properties["TRACKNUMBER"]), integer(properties["DISCNUMBER"]), integer(properties["DATE"] ?? properties["YEAR"]), Int(duration * 1_000), revision, Date()])
                var track = Track(fileURL: reference.rawValue, fileSize: Int64(resources.fileSize ?? 0), fileModifiedAt: resources.contentModificationDate, title: title, artist: artist, albumArtist: albumArtist, album: album, composer: properties["COMPOSER"], genre: properties["GENRE"], year: integer(properties["DATE"] ?? properties["YEAR"]), trackNumber: integer(properties["TRACKNUMBER"]), discNumber: integer(properties["DISCNUMBER"]), duration: duration, format: ext, dateAdded: Date(), artworkId: artworkID, trackSyncId: identity, physicalFileId: physicalID, metadataRev: revision, audioHash: audioHash, idState: "embedded")
                try track.insert(db)
                try db.execute(sql: "INSERT INTO physical_files (physical_file_id, track_sync_id, library_root_id, relative_path, file_size, mtime, format, audio_hash, id_state, is_preferred, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'embedded', 1, ?)", arguments: [physicalID, identity, ContainerFileRoot.manual.rawValue, relativePath, resources.fileSize, resources.contentModificationDate, ext, audioHash, Date()])
                try db.execute(sql: "INSERT OR IGNORE INTO track_annotations (track_sync_id) VALUES (?)", arguments: [identity])
                try SyncEligibility.verifyFile(destination, physicalFileID: physicalID, in: db)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func rebuildSearchIndex() throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')")
        }
    }

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let proposed = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let url = URL(fileURLWithPath: filename)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(MobileImportError.inaccessibleFile)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            result = Result { try FileManager.default.copyItem(at: readableURL, to: destination) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    private func embeddedArtwork(in asset: AVURLAsset) async -> Data? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    private func normalizedProperties(_ properties: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: properties.map { ($0.key.uppercased(), $0.value) })
    }

    private func integer(_ value: String?) -> Int? {
        value.flatMap { Int($0.split(separator: "/").first ?? "") }
    }

}
