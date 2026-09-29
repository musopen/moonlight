// Album.swift
//
// Describes an album as stored in the music library database (a structured file on disk that holds
// the catalog): its title, album artist, year, genre, number of discs and cover art. It shows
// "Various Artists" when no album artist is known.

import Foundation
import GRDB

struct Album: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "albums"

    var id: Int64?
    var title: String
    var albumArtist: String?
    var year: Int?
    var genre: String?
    var discCount: Int?
    var artworkId: Int64?

    enum CodingKeys: String, CodingKey {
        case id, title
        case albumArtist = "album_artist"
        case year, genre
        case discCount = "disc_count"
        case artworkId = "artwork_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var displayArtist: String { albumArtist ?? "Various Artists" }
}
