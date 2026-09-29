// SongsTableColumnValueFormatter.swift
//
// Turns a song's details into the text shown in each column of the songs table, such as title,
// year, bitrate, rating or date added. Blank values are shown as empty cells, and ratings and
// file details are written in readable form.

import Foundation

enum SongsTableColumnValueFormatter {
    static func string(for track: Track, columnID: SongsTableColumnID) -> String {
        switch columnID {
        case .artwork:
            return ""
        case .title:
            return track.displayTitle
        case .artist:
            return track.displayArtist
        case .album:
            return track.displayAlbum
        case .albumArtist:
            return track.displayAlbumArtist
        case .composer:
            return track.composer ?? ""
        case .genre:
            return track.genre ?? ""
        case .year:
            return track.year.map(String.init) ?? ""
        case .trackNumber:
            return track.trackNumber.map(String.init) ?? ""
        case .discNumber:
            return track.discNumber.map(String.init) ?? ""
        case .duration:
            return track.durationFormatted
        case .format:
            return track.format?.uppercased() ?? ""
        case .bitRate:
            return track.bitRate.map { "\($0 / 1000) kbps" } ?? ""
        case .sampleRate:
            return track.sampleRate.map { String(format: "%.1f kHz", Double($0) / 1000) } ?? ""
        case .channelCount:
            return track.channelCount.map(String.init) ?? ""
        case .favorite:
            return track.isFavorite ? "Favorite" : ""
        case .rating:
            return track.rating.map { "\($0) of 5 stars" } ?? "Unrated"
        case .playCount:
            return String(track.playCount)
        case .lastPlayed:
            return track.lastPlayedAt.map(dateFormatter.string(from:)) ?? ""
        case .dateAdded:
            return dateFormatter.string(from: track.dateAdded)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
