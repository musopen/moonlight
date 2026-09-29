// Track.swift
//
// Describes a song as stored in the library database: its file location, tags such as title,
// artist and album, audio details, favorite status, rating and play count. It also holds the
// shared lookups the library screens use to list albums, composers, genres and favorites, while
// hiding placeholder songs that exist only on another device.

import Foundation
import GRDB

/// SQL predicates shared by library-browsing queries.
///
/// Synced annotations can create a local placeholder for audio that is only
/// present on another device. That row is deliberately retained for playlist
/// membership and sync, but it is not part of this device's library catalog.
enum LibraryTrackQuery {
    static let syncStubURLPrefix = "moonlight-unavailable://"

    static func isSyncStubURL(_ fileURL: String) -> Bool {
        fileURL.hasPrefix(syncStubURLPrefix)
    }

    /// A predicate for catalog surfaces. `tableAlias` may be a table name or
    /// SQL alias such as `tracks` or `t`.
    static func catalogPredicate(tableAlias: String? = nil) -> String {
        let column = tableAlias.map { "\($0).file_url" } ?? "file_url"
        return "\(column) NOT LIKE '\(syncStubURLPrefix)%'"
    }
}

#if os(macOS)
enum LibraryAlbumQuery {
    static func fetchVisible(in db: Database) throws -> [Album] {
        try Album.fetchAll(db, sql: """
            SELECT albums.*
            FROM albums
            WHERE EXISTS (
                SELECT 1 FROM tracks
                WHERE tracks.album_id = albums.id
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
            )
            ORDER BY title
        """)
    }

    /// Fetches tracks for both the album grid and detail view. Cached detail IDs
    /// are rechecked so a sync placeholder can never survive a UI refresh.
    static func tracks(
        for album: Album,
        knownTrackIDs: [Int64] = [],
        in db: Database
    ) throws -> [Track] {
        if !knownTrackIDs.isEmpty {
            let placeholders = knownTrackIDs.map { _ in "?" }.joined(separator: ",")
            return try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                WHERE id IN (\(placeholders))
                  AND \(LibraryTrackQuery.catalogPredicate())
                ORDER BY disc_number, track_number, title
            """, arguments: StatementArguments(knownTrackIDs))
        }

        if let albumID = album.id {
            let tracks = try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                WHERE album_id = ?
                  AND \(LibraryTrackQuery.catalogPredicate())
                ORDER BY disc_number, track_number, title
            """, arguments: [albumID])
            if !tracks.isEmpty { return tracks }
        }

        return try Track.fetchAll(db, sql: """
            SELECT * FROM tracks
            WHERE album = ?
              AND \(LibraryTrackQuery.catalogPredicate())
            ORDER BY disc_number, track_number, title
        """, arguments: [album.title])
    }
}
#endif

enum LibraryBrowseQuery {
    static func composers(in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT composer FROM tracks
            WHERE composer IS NOT NULL AND composer != ''
              AND \(LibraryTrackQuery.catalogPredicate())
            ORDER BY composer COLLATE NOCASE
        """)
    }

    static func tracks(composedBy composer: String, in db: Database) throws -> [Track] {
        try Track.filter(sql: "composer = ? AND \(LibraryTrackQuery.catalogPredicate())", arguments: [composer])
            .order(Column("album"), Column("disc_number"), Column("track_number"))
            .fetchAll(db)
    }

    static func genres(in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT genre FROM tracks
            WHERE genre IS NOT NULL AND genre != ''
              AND LOWER(genre) != 'unknown genre'
              AND \(LibraryTrackQuery.catalogPredicate())
            ORDER BY genre COLLATE NOCASE
        """)
    }

#if os(macOS)
    static func favoriteTracks(sortedBy sortOrder: SongsSortOrder, in db: Database) throws -> [Track] {
        try Track.fetchAll(
            db,
            sql: "SELECT * FROM tracks WHERE is_favorite = 1 AND \(LibraryTrackQuery.catalogPredicate()) ORDER BY \(SongsTrackQuery.orderSQL(for: sortOrder))"
        )
    }
#endif
}

struct Track: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "tracks"

    // GRDB primary key — optional before insert, non-nil after
    var dbId: Int64?
    var fileURL: String
    var folderId: Int64?
    var availabilityStatus: String = "available"
    var fileResourceIdentifier: Data?
    var documentIdentifier: Int64?
    var volumeUUID: String?
    var lastSeenAt: Date?
    var lastSeenScanId: Int64?
    var missingSince: Date?
    var fileSize: Int64?
    var fileModifiedAt: Date?
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double?
    var bitRate: Int?
    var sampleRate: Int?
    var channelCount: Int?
    var format: String?
    var isFavorite: Bool = false
    var rating: Int?
    var playCount: Int = 0
    var lastPlayedAt: Date?
    var dateAdded: Date
    var artworkId: Int64?
    var albumId: Int64?
    var artistId: Int64?
    var trackSyncId: String = UUID().uuidString.uppercased()
    var physicalFileId: String = UUID().uuidString.uppercased()
    var metadataRev: String?
    var ratingRev: String?
    var favoriteRev: String?
    var mergedInto: String?
    var isPromoted: Bool = false
    var audioHash: String?
    var idState: String = "unknown"

    enum CodingKeys: String, CodingKey {
        case dbId = "id"
        case fileURL = "file_url"
        case folderId = "folder_id"
        case availabilityStatus = "availability_status"
        case fileResourceIdentifier = "file_resource_identifier"
        case documentIdentifier = "document_identifier"
        case volumeUUID = "volume_uuid"
        case lastSeenAt = "last_seen_at"
        case lastSeenScanId = "last_seen_scan_id"
        case missingSince = "missing_since"
        case fileSize = "file_size"
        case fileModifiedAt = "file_modified_at"
        case title, artist
        case albumArtist = "album_artist"
        case album, composer, genre, year
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case duration
        case bitRate = "bit_rate"
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case format
        case isFavorite = "is_favorite"
        case rating
        case playCount = "play_count"
        case lastPlayedAt = "last_played_at"
        case dateAdded = "date_added"
        case artworkId = "artwork_id"
        case albumId = "album_id"
        case artistId = "artist_id"
        case trackSyncId = "track_sync_id"
        case physicalFileId = "physical_file_id"
        case metadataRev = "metadata_rev"
        case ratingRev = "rating_rev"
        case favoriteRev = "favorite_rev"
        case mergedInto = "merged_into"
        case isPromoted = "is_promoted"
        case audioHash = "audio_hash"
        case idState = "id_state"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        dbId = inserted.rowID
    }

    // Persisted tracks use the database primary key as their durable identity.
    var id: Int64? { dbId }

    var isAvailable: Bool { availabilityStatus == "available" }
    var isSyncOnlyPlaceholder: Bool { LibraryTrackQuery.isSyncStubURL(fileURL) }

    func hasSameIdentity(as other: Track) -> Bool {
        if let dbId, let otherId = other.dbId {
            return dbId == otherId
        }
        return fileURL == other.fileURL
    }

    var displayTitle: String { title ?? URL(string: fileURL)?.deletingPathExtension().lastPathComponent ?? fileURL }
    var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    var displayAlbum: String { album ?? "Unknown Album" }
    var displayAlbumArtist: String { albumArtist ?? "" }

    var durationFormatted: String {
        guard let d = duration, d.isFinite, d > 0 else { return "--:--" }
        let total = Int(d)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
