// ReviewedRadioCatalog.swift
//
// Opens the built-in list of radio stations that ships inside the app, reviewed in advance and
// never changed on the user's machine. It checks the list is complete and undamaged, then answers
// searches by name, country, audio quality and popularity, and lists countries by how many
// stations they have.

import Foundation
import GRDB

/// The reviewed snapshot is opened directly in the app bundle. No writable copy is made.
final class ReviewedRadioCatalog: @unchecked Sendable {
    static let catalogName = "radio-catalog"

    let path: String
    private let queue: DatabaseQueue

    init(path: String? = nil, bundle: Bundle = .main) throws {
        guard let path = path ?? bundle.url(forResource: Self.catalogName, withExtension: "sqlite")?.path else {
            throw RadioCatalogError.missingResource(Self.catalogName)
        }
        self.path = path
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "org.musopen.moonlight.reviewed-radio"
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try validate()
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T { try queue.read(block) }

    func validate() throws {
        try read { db in
            let version = try String.fetchOne(db, sql: "SELECT value FROM catalog_metadata WHERE key='schema_version'")
            let status = try String.fetchOne(db, sql: "SELECT value FROM catalog_metadata WHERE key='status'")
            guard version == "1", status == "reviewed-healthy-snapshot",
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM channels") == 42_630,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM streams") == 44_726,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM channel_search") == 42_630,
                  try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                throw RadioCatalogError.invalidCatalog
            }
        }
    }

    func stationCount() throws -> Int {
        try read { try Int.fetchOne($0, sql: "SELECT count(*) FROM channels") ?? 0 }
    }

    func fetchStations(
        search: String? = nil, countryCode: String? = nil,
        minimumBitrate: Int = 0, popularOnly: Bool = false, limit: Int = 200
    ) throws -> [RadioStation] {
        var filters = ["1=1"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            if search.count >= 3 {
                filters.append("c.id IN (SELECT channel_id FROM channel_search WHERE channel_search MATCH ?)")
                arguments.append("\"\(search.replacingOccurrences(of: "\"", with: "\"\""))\"")
            } else {
                filters.append("c.id IN (SELECT channel_id FROM channel_search WHERE search_text LIKE ? ESCAPE '\\')")
                let escaped = search
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                arguments.append("%\(escaped)%")
            }
        }
        if let countryCode, !countryCode.isEmpty {
            filters.append("c.country_code = ?")
            arguments.append(countryCode.uppercased())
        }
        if minimumBitrate > 0 {
            filters.append("EXISTS (SELECT 1 FROM streams quality WHERE quality.channel_id=c.id AND quality.bitrate_kbps>=?)")
            arguments.append(minimumBitrate)
        }
        if popularOnly { filters.append("c.is_popular=1") }
        arguments.append(max(1, min(limit, 500)))
        return try read { db in
            try Self.fetchRows(db, whereSQL: filters.joined(separator: " AND "), arguments: StatementArguments(arguments))
        }
    }

    func fetchStation(channelID: String) throws -> RadioStation? {
        try read { db in
            try Self.fetchRows(db, whereSQL: "c.id=?", arguments: [channelID, 1]).first
        }
    }

    func fetchCountries(limit: Int = 60) throws -> [RadioCountry] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT country_code, count(*) AS station_count FROM channels
                WHERE country_code IS NOT NULL AND country_code<>''
                GROUP BY country_code ORDER BY station_count DESC LIMIT ?
            """, arguments: [max(1, min(limit, 250))]).map { row in
                let code: String = row["country_code"]
                return RadioCountry(countryCode: code, name: Locale.current.localizedString(forRegionCode: code) ?? code, stationCount: row["station_count"])
            }
        }
    }

    private static func fetchRows(_ db: Database, whereSQL: String, arguments: StatementArguments) throws -> [RadioStation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.*, s.stream_url, s.codec, s.bitrate_kbps, s.stationuuid,
                   (SELECT group_concat(alt.stream_url, char(31)) FROM streams alt
                    WHERE alt.channel_id=c.id AND alt.id<>s.id) AS alternate_urls
            FROM channels c JOIN streams s ON s.channel_id=c.id AND s.is_default=1
            WHERE \(whereSQL)
            ORDER BY c.is_popular DESC, c.display_name COLLATE NOCASE LIMIT ?
        """, arguments: arguments)
        return rows.map { row in
            let channelID: String = row["id"]
            let countryCode: String? = row["country_code"]
            let alternatives: String? = row["alternate_urls"]
            return RadioStation(
                id: Int64(bitPattern: Self.stableID(channelID)),
                stationUUID: row["stationuuid"] ?? "",
                changeUUID: "",
                name: row["display_name"],
                streamURL: row["stream_url"],
                tags: [], countryCode: countryCode,
                country: countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) },
                codec: row["codec"], bitrate: row["bitrate_kbps"] ?? 0,
                votes: 0, clickCount: 0, isPopular: row["is_popular"],
                lastCheckOK: true, latitude: nil, longitude: nil,
                channelID: channelID, callSign: row["call_sign"],
                frequency: row["frequency"], city: row["city"], region: row["region"],
                organizationName: row["organization_name"], homepageURL: row["homepage_url"],
                logoURL: row["logo_url"],
                alternateStreamURLs: alternatives?.split(separator: Character(UnicodeScalar(31))).map(String.init) ?? []
            )
        }
    }

    private static func stableID(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

enum RadioCatalogError: LocalizedError {
    case missingResource(String)
    case invalidCatalog
    case legacyCheckpointBusy

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): "The \(name) resource is missing from Moonlight."
        case .invalidCatalog: "The bundled radio catalog failed validation."
        case .legacyCheckpointBusy: "The old radio database is busy and will be migrated on a later launch."
        }
    }
}
