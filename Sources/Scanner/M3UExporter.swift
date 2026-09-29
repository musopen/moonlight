// M3UExporter.swift
//
// Saves a list of tracks as an M3U playlist file, a common plain-text playlist format that other
// music players can open. Each available track is written with its length, artist and title, with
// any line breaks in them turned into spaces so they can't add extra lines to the file. Tracks whose
// files are missing, or whose file paths contain a line break, are skipped and counted.

import Foundation

struct M3UExportReport: Equatable {
    let exportedTrackCount: Int
    let unavailableTrackCount: Int
}

enum M3UExportError: LocalizedError {
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let url, let error): "Moonlight could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

enum M3UExporter {
    @discardableResult
    static func export(tracks: [Track], to url: URL) throws -> M3UExportReport {
        var lines = ["#EXTM3U"]
        var exported = 0
        var unavailable = 0
        for track in tracks {
            guard track.isAvailable,
                  let fileURL = URL(string: track.fileURL),
                  fileURL.isFileURL,
                  !fileURL.path.contains(where: \.isNewline) else {
                unavailable += 1
                continue
            }
            if let duration = track.duration {
                let artist = track.artist ?? track.albumArtist ?? ""
                let title = track.title ?? ""
                let label = artist.isEmpty ? title : "\(artist) - \(title)"
                lines.append("#EXTINF:\(Int(duration)),\(label.singleLineText)")
            }
            lines.append(fileURL.path)
            exported += 1
        }
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw M3UExportError.writeFailed(url, error)
        }
        return M3UExportReport(exportedTrackCount: exported, unavailableTrackCount: unavailable)
    }
}
