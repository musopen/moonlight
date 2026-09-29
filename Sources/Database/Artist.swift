// Artist.swift
//
// Describes an artist as stored in the music library database (a structured file on disk that
// holds the catalog). Each artist is simply a name with an internal ID number.

import Foundation
import GRDB

struct Artist: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "artists"

    var id: Int64?
    var name: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
