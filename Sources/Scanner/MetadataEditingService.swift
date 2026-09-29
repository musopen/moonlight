// MetadataEditingService.swift
//
// Saves changes the user makes to song details, such as title, artist, album or cover art, into
// the music files on the Mac. It backs up each file first, checks afterwards that only the
// intended details changed, and restores the backup if anything went wrong. The library database
// is then updated to match.

import AppKit
import Foundation
import GRDB

enum MetadataEditingError: LocalizedError {
    case unsupportedFormat(String)
    case missingFile(URL)
    case securityScopeDenied(URL)
    case backupFailed(URL)
    case restoreFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "Editing is not supported for .\(ext) files"
        case .missingFile(let url):
            "File does not exist: \(url.path)"
        case .securityScopeDenied(let url):
            "Moonlight does not have write access to \(url.path)"
        case .backupFailed(let url):
            "Could not create a backup before editing \(url.lastPathComponent)"
        case .restoreFailed(let url):
            "Save failed and Moonlight could not restore \(url.lastPathComponent) from backup"
        }
    }
}

actor MetadataEditingService {
    private let db: DatabaseManager
    private let bookmarkStore: FolderBookmarkStore

    init(db: DatabaseManager, bookmarkStore: FolderBookmarkStore) {
        self.db = db
        self.bookmarkStore = bookmarkStore
    }

    func loadValues(for tracks: [Track], fields: [EditableTagField] = EditableTagField.allCases) async -> [EditableTagField: MultiTagValue] {
        var valuesByField: [EditableTagField: [String?]] = [:]

        for track in tracks {
            guard let url = URL(string: track.fileURL) else { continue }
            let values = (try? await withScopedAccess(to: url) {
                try MetadataTagFileWriter.values(in: url, fields: fields)
            }) ?? [:]

            for field in fields {
                valuesByField[field, default: []].append(values[field])
            }
        }

        var result: [EditableTagField: MultiTagValue] = [:]
        for field in fields {
            let values = valuesByField[field, default: []]
            guard let first = values.first else {
                result[field] = .same(nil)
                continue
            }
            result[field] = values.allSatisfy { $0 == first } ? .same(first) : .mixed
        }
        return result
    }

    func loadArtwork(for track: Track?) async -> NSImage? {
        guard let track, let url = URL(string: track.fileURL) else { return nil }
        return try? await withScopedAccess(to: url) {
            MetadataTagFileWriter.artworkImage(in: url)
        }
    }

    func apply(_ patch: TagEditPatch, to tracks: [Track]) async -> [TagEditResult] {
        guard !patch.isEmpty else {
            return tracks.map { TagEditResult(fileURL: $0.fileURL, status: .skipped) }
        }

        var results: [TagEditResult] = []
        for track in tracks {
            guard let url = URL(string: track.fileURL) else {
                results.append(TagEditResult(fileURL: track.fileURL, status: .failed("Invalid file URL")))
                continue
            }

            do {
                try await apply(patch, to: url)
                try await refreshDatabaseTrack(for: url, artworkEdit: patch.artwork)
                results.append(TagEditResult(fileURL: track.fileURL, status: .saved))
            } catch {
                results.append(TagEditResult(fileURL: track.fileURL, status: .failed(error.localizedDescription)))
            }
        }

        return results
    }

    private func apply(_ patch: TagEditPatch, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        guard MetadataExtractor.supportedExtensions.contains(ext) else {
            throw MetadataEditingError.unsupportedFormat(ext)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataEditingError.missingFile(url)
        }

        try await withScopedAccess(to: url) {
            let backupURL = try makeBackup(for: url)
            do {
                let before = try MetadataTagFileWriter.rawProperties(in: url)
                try MetadataTagFileWriter.apply(patch, to: url)
                let after = try MetadataTagFileWriter.rawProperties(in: url)
                try MetadataTagFileWriter.verify(patch, url: url, before: before, after: after)
                try? FileManager.default.removeItem(at: backupURL)
            } catch {
                do {
                    try restoreBackup(backupURL, to: url)
                } catch {
                    throw MetadataEditingError.restoreFailed(url)
                }
                throw error
            }
        }
    }

    private func refreshDatabaseTrack(for url: URL, artworkEdit: ArtworkEdit) async throws {
        let meta = try await MetadataExtractor.extract(from: url)
        let attrs = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .documentIdentifierKey,
            .volumeUUIDStringKey
        ])
        let documentIdentifier = attrs?.documentIdentifier.flatMap { Int64(exactly: $0) }
        let artworkId: Int64?

        switch artworkEdit {
        case .unchanged:
            artworkId = nil
        case .remove:
            artworkId = -1
        case .replace:
            if let artworkData = meta.artworkData {
                artworkId = try ArtworkStore.store(sourceData: artworkData, sourceURL: nil, db: db) ?? -1
            } else {
                artworkId = -1
            }
        }

        try db.write { db in
            try db.execute(sql: """
                UPDATE tracks SET
                  file_size = ?,
                  file_modified_at = ?,
                  file_resource_identifier = ?,
                  document_identifier = ?,
                  volume_uuid = ?,
                  availability_status = 'available',
                  last_seen_at = ?,
                  missing_since = NULL,
                  title = ?,
                  artist = ?,
                  album_artist = ?,
                  album = ?,
                  composer = ?,
                  genre = ?,
                  year = ?,
                  track_number = ?,
                  disc_number = ?,
                  duration = ?,
                  bit_rate = ?,
                  sample_rate = ?,
                  channel_count = ?,
                  format = ?
                WHERE file_url = ?
            """, arguments: [
                attrs?.fileSize,
                attrs?.contentModificationDate,
                attrs?.fileResourceIdentifier as? Data,
                documentIdentifier,
                attrs?.volumeUUIDString,
                Date(),
                meta.title,
                meta.artist,
                meta.albumArtist,
                meta.album,
                meta.composer,
                meta.genre,
                meta.year,
                meta.trackNumber,
                meta.discNumber,
                meta.duration,
                meta.bitRate,
                meta.sampleRate,
                meta.channelCount,
                meta.format,
                url.absoluteString
            ])

            if let artworkId {
                if artworkId > 0 {
                    try db.execute(sql: """
                        UPDATE tracks
                        SET artwork_id = ?, artwork_source_url = NULL,
                            artwork_source_file_size = NULL, artwork_source_modified_at = NULL
                        WHERE file_url = ?
                    """,
                                   arguments: [artworkId, url.absoluteString])
                } else {
                    try db.execute(sql: """
                        UPDATE tracks
                        SET artwork_id = NULL, artwork_source_url = NULL,
                            artwork_source_file_size = NULL, artwork_source_modified_at = NULL
                        WHERE file_url = ?
                    """,
                                   arguments: [url.absoluteString])
                }
            }
        }
    }

    private func withScopedAccess<T>(to fileURL: URL, _ body: () throws -> T) async throws -> T {
        let scopedURL = await scopedFolderURL(for: fileURL) ?? fileURL
        let didStartAccess = scopedURL.startAccessingSecurityScopedResource()
        guard didStartAccess || FileManager.default.isWritableFile(atPath: fileURL.path) else {
            throw MetadataEditingError.securityScopeDenied(fileURL)
        }
        defer {
            if didStartAccess {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    private func scopedFolderURL(for fileURL: URL) async -> URL? {
        let folders = await bookmarkStore.resolvedFolders()
        return folders
            .map(\.url)
            .filter { fileURL.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private func makeBackup(for url: URL) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Moonlight", isDirectory: true)
            .appendingPathComponent("TagBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let backupURL = base.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            return backupURL
        } catch {
            throw MetadataEditingError.backupFailed(url)
        }
    }

    private func restoreBackup(_ backupURL: URL, to originalURL: URL) throws {
        if FileManager.default.fileExists(atPath: originalURL.path) {
            try FileManager.default.removeItem(at: originalURL)
        }
        try FileManager.default.copyItem(at: backupURL, to: originalURL)
        try? FileManager.default.removeItem(at: backupURL)
    }
}
