// SmartPlaylist.swift
//
// Powers smart playlists, which fill themselves automatically based on rules like "rated 4 stars
// or more", "favorite", "genre is Jazz" or "not played since a date". It saves those rules and
// finds the library songs that currently match them.

import Foundation
import GRDB

enum SmartPlaylistRuleError: Error, Equatable {
    case tooComplex
}

indirect enum SmartPlaylistRule: Codable, Equatable, Sendable {
    case all([SmartPlaylistRule])
    case any([SmartPlaylistRule])
    case ratingAtLeast(Int)
    case favorite(Bool)
    case playCountAtLeast(Int)
    case lastPlayedBefore(Date)
    case lastPlayedAfter(Date)
    case genre(String)
    case artist(String)
    case composer(String)
    case yearBefore(Int)
    case yearAfter(Int)
    case durationAtLeast(Double)
    case durationAtMost(Double)

    var usesCatalogAttributes: Bool {
        switch self {
        case .genre, .artist, .composer, .yearBefore, .yearAfter, .durationAtLeast, .durationAtMost: true
        case .all(let rules), .any(let rules): rules.contains(where: \.usesCatalogAttributes)
        default: false
        }
    }

    /// Smart playlists are simple lists of conditions. The editor builds rules two levels deep
    /// (one all/any group of conditions); loading allows one extra level for synced rules.
    static let maxConditions = 10
    static let maxDepth = 3

    var depth: Int {
        switch self {
        case .all(let rules), .any(let rules): 1 + (rules.map(\.depth).max() ?? 0)
        default: 1
        }
    }

    var conditionCount: Int {
        switch self {
        case .all(let rules), .any(let rules): rules.reduce(0) { $0 + $1.conditionCount }
        default: 1
        }
    }

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    static func decoded(_ value: String) throws -> SmartPlaylistRule {
        let rule = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard rule.depth <= maxDepth, rule.conditionCount <= maxConditions else {
            throw SmartPlaylistRuleError.tooComplex
        }
        return rule
    }

    fileprivate func predicate() -> (sql: String, arguments: [DatabaseValueConvertible?]) {
        switch self {
        case .all(let rules): return joined(rules, separator: " AND ", empty: "1")
        case .any(let rules): return joined(rules, separator: " OR ", empty: "0")
        case .ratingAtLeast(let value): return ("COALESCE(rating, 0) >= ?", [value])
        case .favorite(let value): return ("is_favorite = ?", [value])
        case .playCountAtLeast(let value): return ("play_count >= ?", [value])
        case .lastPlayedBefore(let date): return ("last_played_at IS NOT NULL AND last_played_at < ?", [date])
        case .lastPlayedAfter(let date): return ("last_played_at IS NOT NULL AND last_played_at > ?", [date])
        case .genre(let value): return ("genre = ? COLLATE NOCASE", [value])
        case .artist(let value): return ("COALESCE(artist, album_artist) = ? COLLATE NOCASE", [value])
        case .composer(let value): return ("composer = ? COLLATE NOCASE", [value])
        case .yearBefore(let value): return ("year IS NOT NULL AND year < ?", [value])
        case .yearAfter(let value): return ("year IS NOT NULL AND year > ?", [value])
        case .durationAtLeast(let value): return ("duration IS NOT NULL AND duration >= ?", [value])
        case .durationAtMost(let value): return ("duration IS NOT NULL AND duration <= ?", [value])
        }
    }

    private func joined(_ rules: [SmartPlaylistRule], separator: String, empty: String) -> (String, [DatabaseValueConvertible?]) {
        guard !rules.isEmpty else { return (empty, []) }
        let predicates = rules.map { $0.predicate() }
        return (predicates.map { "(\($0.sql))" }.joined(separator: separator), predicates.flatMap(\.arguments))
    }
}

enum SmartPlaylistEvaluator {
    static func tracks(matching rule: SmartPlaylistRule, in db: Database) throws -> [Track] {
        let predicate = rule.predicate()
        return try Track.fetchAll(
            db,
            sql: "SELECT * FROM tracks WHERE merged_into IS NULL AND \(LibraryTrackQuery.catalogPredicate()) AND (\(predicate.sql)) ORDER BY COALESCE(album_artist, artist), album, disc_number, track_number, title",
            arguments: StatementArguments(predicate.arguments)
        )
    }
}
