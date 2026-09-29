// LastFMModels.swift
//
// The shared pieces of data used by the Last.fm feature: the saved sign-in, the song details sent
// to Last.fm, a queued listen waiting to be sent, and the error messages shown when something goes
// wrong.

import Foundation
import GRDB

struct LastFMSession: Codable, Equatable {
    let username: String
    let key: String
}

struct LastFMTrackMetadata: Equatable {
    let artist: String
    let track: String
    let album: String?
    let albumArtist: String?
    let duration: Int?
    let trackNumber: Int?

    init?(track source: Track) {
        guard let artist = source.artist?.trimmedNonEmpty,
              let title = source.title?.trimmedNonEmpty
        else { return nil }

        self.artist = artist
        self.track = title
        self.album = source.album?.trimmedNonEmpty
        self.albumArtist = source.albumArtist?.trimmedNonEmpty
        if let duration = source.duration, duration.isFinite, duration > 0 {
            self.duration = Int(duration.rounded())
        } else {
            self.duration = nil
        }
        self.trackNumber = source.trackNumber.flatMap { $0 > 0 ? $0 : nil }
    }

    init(
        artist: String,
        track: String,
        album: String? = nil,
        albumArtist: String? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil
    ) {
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
    }

    var parameters: [String: String] {
        var parameters = [
            "artist": artist,
            "track": track
        ]
        if let album { parameters["album"] = album }
        if let albumArtist { parameters["albumArtist"] = albumArtist }
        if let duration { parameters["duration"] = String(duration) }
        if let trackNumber { parameters["trackNumber"] = String(trackNumber) }
        return parameters
    }
}

struct LastFMScrobble: Equatable {
    let id: String
    let metadata: LastFMTrackMetadata
    let startedAt: Int

    init(id: String = UUID().uuidString, metadata: LastFMTrackMetadata, startedAt: Int) {
        self.id = id
        self.metadata = metadata
        self.startedAt = startedAt
    }
}

struct LastFMSubmissionResult: Equatable {
    let accepted: Int
    let ignored: Int
}

struct LastFMOutboxEntry: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "lastfm_scrobble_outbox"

    let id: String
    let artist: String
    let track: String
    let album: String?
    let albumArtist: String?
    let duration: Int?
    let trackNumber: Int?
    let startedAt: Int
    let createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date

    enum CodingKeys: String, CodingKey {
        case id, artist, track, album
        case albumArtist = "album_artist"
        case duration
        case trackNumber = "track_number"
        case startedAt = "started_at"
        case createdAt = "created_at"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
    }

    init(scrobble: LastFMScrobble, now: Date) {
        id = scrobble.id
        artist = scrobble.metadata.artist
        track = scrobble.metadata.track
        album = scrobble.metadata.album
        albumArtist = scrobble.metadata.albumArtist
        duration = scrobble.metadata.duration
        trackNumber = scrobble.metadata.trackNumber
        startedAt = scrobble.startedAt
        createdAt = now
        attemptCount = 0
        nextAttemptAt = now
    }

    var scrobble: LastFMScrobble {
        LastFMScrobble(
            id: id,
            metadata: LastFMTrackMetadata(
                artist: artist,
                track: track,
                album: album,
                albumArtist: albumArtist,
                duration: duration,
                trackNumber: trackNumber
            ),
            startedAt: startedAt
        )
    }
}

enum LastFMAPIError: Error, Equatable, LocalizedError {
    case missingConfiguration
    case api(code: Int, message: String)
    case httpStatus(Int)
    case invalidResponse
    case transport(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Last.fm credentials are not configured in this build."
        case let .api(_, message):
            message
        case let .httpStatus(status):
            "Last.fm returned HTTP status \(status)."
        case .invalidResponse:
            "Last.fm returned an unreadable response."
        case let .transport(message):
            message
        case let .keychain(status):
            "The Last.fm session could not be stored in Keychain (\(status))."
        }
    }

    var requiresReauthentication: Bool {
        if case .api(code: 9, message: _) = self { return true }
        return false
    }

    var isRetryableScrobbleFailure: Bool {
        switch self {
        case .transport:
            true
        case let .httpStatus(status):
            status == 408 || status == 429 || (500...599).contains(status)
        case let .api(code, _):
            code == 11 || code == 16
        default:
            false
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
