// ArtworkStore.swift
//
// Prepares and saves album cover art. It makes a small thumbnail and a larger display copy from
// the original image, and stores each unique picture only once so that many tracks sharing the
// same cover do not waste space.

import CryptoKit
import Foundation
import GRDB

struct PreparedArtwork {
    let contentHash: Data
    let thumbnailData: Data
    let displayData: Data
}

enum ArtworkStore {
    static let thumbnailSize: CGFloat = 160
    static let displaySize: CGFloat = 600
    static let thumbnailCompressionQuality: CGFloat = 0.75
    static let displayCompressionQuality: CGFloat = 0.80

    static func prepare(from sourceData: Data) -> PreparedArtwork? {
        // Create both renditions from the original artwork. Chaining the thumbnail
        // through the display JPEG adds an unnecessary lossy encode.
        guard let displayData = ArtworkExtractor.thumbnail(
            from: sourceData,
            size: displaySize,
            compressionQuality: displayCompressionQuality
        ),
        let thumbnailData = ArtworkExtractor.thumbnail(
            from: sourceData,
            size: thumbnailSize,
            compressionQuality: thumbnailCompressionQuality
        ) else {
            return nil
        }

        return PreparedArtwork(
            contentHash: Data(SHA256.hash(data: displayData)),
            thumbnailData: thumbnailData,
            displayData: displayData
        )
    }

    static func contentHash(for displayData: Data) -> Data {
        Data(SHA256.hash(data: displayData))
    }

    static func artworkID(for prepared: PreparedArtwork, sourceURL: String?, db: Database) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO artwork (content_hash, source_url, data_small, data_large)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(content_hash) DO NOTHING
        """, arguments: [
            prepared.contentHash,
            sourceURL,
            prepared.thumbnailData,
            prepared.displayData
        ])

        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM artwork WHERE content_hash = ?",
            arguments: [prepared.contentHash]
        ) else {
            throw ArtworkStoreError.missingStoredArtwork
        }
        return id
    }

    static func store(sourceData: Data, sourceURL: String?, db: DatabaseManager) throws -> Int64? {
        guard let prepared = prepare(from: sourceData) else { return nil }
        return try db.write { database in
            try artworkID(for: prepared, sourceURL: sourceURL, db: database)
        }
    }
}

private enum ArtworkStoreError: LocalizedError {
    case missingStoredArtwork

    var errorDescription: String? { "Artwork was not saved" }
}
