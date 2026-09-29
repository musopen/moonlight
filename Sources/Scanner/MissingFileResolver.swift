// MissingFileResolver.swift
//
// Helps the user reconnect library tracks whose music files have moved or been renamed. It
// suggests likely matches by comparing file name, title, artist, album, length and size, and on
// confirmation relinks the track so its play counts, ratings and playlist places are kept. It can
// also relink a whole music folder that has moved.

import Foundation
import GRDB

enum MissingFileMatchConfidence: Int, Comparable {
    case medium = 1
    case high = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct MissingFileSuggestion: Identifiable {
    let missingTrackId: Int64
    let candidate: Track
    let confidence: MissingFileMatchConfidence
    let reasons: [String]
    let score: Int

    var id: Int64 { missingTrackId }
}

struct MissingFileRecoveryRow: Identifiable {
    let track: Track
    let suggestion: MissingFileSuggestion?

    var id: Int64 { track.dbId! }
}

enum MissingFileResolutionError: LocalizedError, Equatable {
    case trackNotFound
    case trackIsNotMissing
    case fileDoesNotExist
    case unsupportedFileType
    case fileOutsideLibrary

    var errorDescription: String? {
        switch self {
        case .trackNotFound:
            "Moonlight could not find the missing track in its library."
        case .trackIsNotMissing:
            "This track is no longer marked as missing. Refresh the list and try again."
        case .fileDoesNotExist:
            "The selected file is no longer available."
        case .unsupportedFileType:
            "The selected file is not a supported audio format."
        case .fileOutsideLibrary:
            "Choose a file inside one of Moonlight’s music folders so it remains accessible after the app restarts."
        }
    }
}

/// Finds conservative recovery candidates and reconnects them while retaining the
/// missing row's durable database identity and Moonlight-specific relationships.
final class MissingFileResolver {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func recoveryRows() throws -> [MissingFileRecoveryRow] {
        let tracks = try db.read { db in
            try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE,
                         track_number, title COLLATE NOCASE
            """)
        }

        let missing = tracks.filter { !$0.isAvailable && $0.dbId != nil }
        // Availability is maintained by scans. Avoid stat-ing every track here:
        // this screen must remain cheap for libraries with tens of thousands of files.
        let available = tracks.filter(\.isAvailable)
        let suggestions = MissingFileMatcher.suggestions(missing: missing, available: available)

        return missing.map { track in
            MissingFileRecoveryRow(
                track: track,
                suggestion: track.dbId.flatMap { suggestions[$0] }
            )
        }
    }

    /// Reconnects a missing row to an on-disk file. If the scanner already imported
    /// that file as a separate row, its file-derived data and relationships are
    /// merged into the durable missing row before the duplicate is removed.
    func resolve(missingTrackId: Int64, to selectedURL: URL, folderId: Int64?) throws {
        try reconnectTrack(
            trackId: missingTrackId,
            to: selectedURL,
            folderId: folderId,
            requireMissingStatus: true
        )
    }

    /// Applies a user-confirmed library-root move by relative path. This is the
    /// cross-volume counterpart to filesystem-ID relinking: selecting the new root
    /// is the user's authoritative identity decision, so matching descendants keep
    /// their existing track IDs even when a copy received new filesystem IDs.
    @discardableResult
    func reconnectLibraryRoot(
        folderId: Int64,
        from oldRoot: URL,
        to newRoot: URL
    ) throws -> Int {
        let tracks = try db.read { db in
            try Track.filter(Column("folder_id") == folderId).fetchAll(db)
        }
        let oldRootPath = normalizedDirectoryPath(oldRoot)
        let newRootURL = newRoot.standardizedFileURL
        var reconnected = 0

        for track in tracks {
            guard let trackId = track.dbId,
                  let currentURL = URL(string: track.fileURL) else { continue }
            let currentPath = currentURL.standardizedFileURL.path
            let relativePath: String
            if currentPath == oldRootPath {
                relativePath = currentURL.lastPathComponent
            } else {
                let prefix = oldRootPath == "/" ? "/" : oldRootPath + "/"
                guard currentPath.hasPrefix(prefix) else { continue }
                relativePath = String(currentPath.dropFirst(prefix.count))
            }

            let candidateURL = newRootURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: candidateURL.path),
                  MetadataExtractor.supportedExtensions.contains(candidateURL.pathExtension.lowercased()) else {
                continue
            }
            try reconnectTrack(
                trackId: trackId,
                to: candidateURL,
                folderId: folderId,
                requireMissingStatus: false
            )
            reconnected += 1
        }
        return reconnected
    }

    private func reconnectTrack(
        trackId: Int64,
        to selectedURL: URL,
        folderId: Int64?,
        requireMissingStatus: Bool
    ) throws {
        let url = selectedURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFileResolutionError.fileDoesNotExist
        }
        guard MetadataExtractor.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw MissingFileResolutionError.unsupportedFileType
        }
        guard folderId != nil else {
            throw MissingFileResolutionError.fileOutsideLibrary
        }

        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .documentIdentifierKey,
            .volumeUUIDStringKey
        ])
        guard values?.isRegularFile != false else {
            throw MissingFileResolutionError.fileDoesNotExist
        }

        try db.write { db in
            guard var durableTrack = try Track.fetchOne(db, key: trackId) else {
                throw MissingFileResolutionError.trackNotFound
            }
            guard !requireMissingStatus || !durableTrack.isAvailable else {
                throw MissingFileResolutionError.trackIsNotMissing
            }

            let selectedPath = url.path
            let candidate = try Track
                .filter(Column("availability_status") == "available")
                .fetchAll(db)
                .first { track in
                    guard track.dbId != trackId,
                          let candidateURL = URL(string: track.fileURL) else { return false }
                    return candidateURL.standardizedFileURL.path == selectedPath
                }

            if let candidate, let candidateId = candidate.dbId {
                try mergePlaylistMemberships(from: candidateId, into: trackId, db: db)
                mergeFileDerivedData(from: candidate, into: &durableTrack)
                durableTrack.isFavorite = durableTrack.isFavorite || candidate.isFavorite
                if durableTrack.rating == nil {
                    durableTrack.rating = candidate.rating
                }
                durableTrack.playCount += candidate.playCount
                durableTrack.lastPlayedAt = [durableTrack.lastPlayedAt, candidate.lastPlayedAt]
                    .compactMap { $0 }
                    .max()
                try candidate.delete(db)
            }

            durableTrack.fileURL = url.absoluteString
            durableTrack.folderId = folderId
            durableTrack.availabilityStatus = "available"
            durableTrack.fileResourceIdentifier = values?.fileResourceIdentifier as? Data
            durableTrack.documentIdentifier = values?.documentIdentifier.flatMap(Int64.init(exactly:))
            durableTrack.volumeUUID = values?.volumeUUIDString
            durableTrack.lastSeenAt = Date()
            durableTrack.lastSeenScanId = nil
            durableTrack.missingSince = nil
            durableTrack.fileSize = values?.fileSize.flatMap(Int64.init(exactly:))
            durableTrack.fileModifiedAt = values?.contentModificationDate
            durableTrack.albumId = nil
            durableTrack.artistId = nil
            try durableTrack.update(db)
        }
    }

    private func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func mergePlaylistMemberships(from candidateId: Int64, into durableId: Int64, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO playlist_tracks (playlist_id, track_id, position)
            SELECT candidate.playlist_id, ?, candidate.position
            FROM playlist_tracks AS candidate
            WHERE candidate.track_id = ?
              AND NOT EXISTS (
                  SELECT 1 FROM playlist_tracks AS existing
                  WHERE existing.playlist_id = candidate.playlist_id
                    AND existing.track_id = ?
              )
        """, arguments: [durableId, candidateId, durableId])
    }

    private func mergeFileDerivedData(from candidate: Track, into durable: inout Track) {
        durable.fileSize = candidate.fileSize
        durable.fileModifiedAt = candidate.fileModifiedAt
        durable.title = candidate.title
        durable.artist = candidate.artist
        durable.albumArtist = candidate.albumArtist
        durable.album = candidate.album
        durable.composer = candidate.composer
        durable.genre = candidate.genre
        durable.year = candidate.year
        durable.trackNumber = candidate.trackNumber
        durable.discNumber = candidate.discNumber
        durable.duration = candidate.duration
        durable.bitRate = candidate.bitRate
        durable.sampleRate = candidate.sampleRate
        durable.channelCount = candidate.channelCount
        durable.format = candidate.format
        durable.artworkId = candidate.artworkId ?? durable.artworkId
    }
}

enum MissingFileMatcher {
    private struct ScoredCandidate {
        let track: Track
        let score: Int
        let reasons: [String]
    }

    static func suggestions(missing: [Track], available: [Track]) -> [Int64: MissingFileSuggestion] {
        var result: [Int64: MissingFileSuggestion] = [:]
        var byFileName: [String: [Track]] = [:]
        var byFileStem: [String: [Track]] = [:]
        var byTitle: [String: [Track]] = [:]

        for track in available {
            let name = fileName(track.fileURL)
            if !name.isEmpty { byFileName[name, default: []].append(track) }
            let stem = normalizedFileStem(track.fileURL)
            if !stem.isEmpty { byFileStem[stem, default: []].append(track) }
            if let title = track.title.map(normalize), !title.isEmpty {
                byTitle[title, default: []].append(track)
            }
        }

        for missingTrack in missing {
            guard let missingId = missingTrack.dbId else { continue }
            var candidatePool: [String: Track] = [:]
            func include(_ tracks: [Track]?) {
                for track in tracks ?? [] {
                    candidatePool[track.fileURL] = track
                }
            }
            include(byFileName[fileName(missingTrack.fileURL)])
            include(byFileStem[normalizedFileStem(missingTrack.fileURL)])
            if let title = missingTrack.title.map(normalize), !title.isEmpty {
                include(byTitle[title])
            }

            let ranked = candidatePool.values
                .compactMap { score(missing: missingTrack, candidate: $0) }
                .sorted {
                    if $0.score == $1.score {
                        return $0.track.fileURL.localizedStandardCompare($1.track.fileURL) == .orderedAscending
                    }
                    return $0.score > $1.score
                }

            guard let best = ranked.first else { continue }
            // Equal or near-equal candidates are ambiguous, so do not recommend one.
            if let runnerUp = ranked.dropFirst().first, best.score - runnerUp.score < 10 {
                continue
            }

            let confidence: MissingFileMatchConfidence
            if best.score >= 80 {
                confidence = .high
            } else if best.score >= 55 {
                confidence = .medium
            } else {
                continue
            }

            result[missingId] = MissingFileSuggestion(
                missingTrackId: missingId,
                candidate: best.track,
                confidence: confidence,
                reasons: best.reasons,
                score: best.score
            )
        }

        return result
    }

    private static func score(missing: Track, candidate: Track) -> ScoredCandidate? {
        var score = 0
        var reasons: [String] = []
        var hasNamingEvidence = false

        let missingName = fileName(missing.fileURL)
        let candidateName = fileName(candidate.fileURL)
        if !missingName.isEmpty, missingName == candidateName {
            score += 70
            reasons.append("same filename")
            hasNamingEvidence = true
        } else {
            let missingStem = normalizedFileStem(missing.fileURL)
            let candidateStem = normalizedFileStem(candidate.fileURL)
            if !missingStem.isEmpty, missingStem == candidateStem {
                score += 45
                reasons.append("matching filename")
                hasNamingEvidence = true
            }
        }

        if equalNonempty(missing.title, candidate.title) {
            score += 40
            reasons.append("same title")
            hasNamingEvidence = true
        }
        if equalNonempty(missing.artist ?? missing.albumArtist, candidate.artist ?? candidate.albumArtist) {
            score += 20
            reasons.append("same artist")
        }
        if equalNonempty(missing.album, candidate.album) {
            score += 15
            reasons.append("same album")
        }
        if let lhs = missing.duration, let rhs = candidate.duration,
           lhs.isFinite, rhs.isFinite, abs(lhs - rhs) <= 2 {
            score += 15
            reasons.append("same duration")
        }
        if let lhs = missing.fileSize, let rhs = candidate.fileSize, lhs == rhs {
            score += 10
            reasons.append("same file size")
        }
        if equalNonempty(missing.format, candidate.format) {
            score += 5
            reasons.append("same format")
        }

        guard hasNamingEvidence else { return nil }
        return ScoredCandidate(track: candidate, score: score, reasons: reasons)
    }

    private static func fileName(_ value: String) -> String {
        guard let url = URL(string: value) else { return "" }
        return normalize(url.lastPathComponent)
    }

    private static func normalizedFileStem(_ value: String) -> String {
        guard let url = URL(string: value) else { return "" }
        let stem = url.deletingPathExtension().lastPathComponent
        let withoutTrackNumber = stem.replacingOccurrences(
            of: #"^\s*\d{1,3}(?:\s*[-._]\s*|\s+)"#,
            with: "",
            options: .regularExpression
        )
        return normalize(withoutTrackNumber)
    }

    private static func equalNonempty(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = normalize(lhs)
        return !left.isEmpty && left == normalize(rhs)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
