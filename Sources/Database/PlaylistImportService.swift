// PlaylistImportService.swift
//
// Imports playlists from standard .m3u playlist files made by other music apps. It matches each
// listed file to a song in the Moonlight library, shows the user which entries could not be found,
// and then creates the new playlists.

import Foundation
import GRDB

struct PlaylistImportItem: Identifiable, Hashable {
    let entry: M3UEntry
    let matchedTrack: Track?

    var id: String { entry.id }
    var isResolved: Bool { matchedTrack != nil }
}

struct PlaylistImportPreview: Identifiable, Hashable {
    let sourceURL: URL
    let suggestedName: String
    let items: [PlaylistImportItem]

    var id: URL { sourceURL }
    var resolvedCount: Int { items.lazy.filter(\.isResolved).count }
    var unresolvedItems: [PlaylistImportItem] { items.filter { !$0.isResolved } }
}

struct PlaylistImportReview: Identifiable {
    let id = UUID()
    let previews: [PlaylistImportPreview]
}

struct PlaylistImportCommitSummary: Equatable {
    let playlistIDs: [Int64]
    let importedTrackCount: Int
    let unresolvedEntryCount: Int
}

enum PlaylistImportService {
    static func preview(urls: [URL], in db: Database) throws -> [PlaylistImportPreview] {
        let tracks = try Track.fetchAll(db, sql: """
            SELECT * FROM tracks
            WHERE availability_status = 'available' AND merged_into IS NULL
        """)
        let roots = try String.fetchAll(db, sql: "SELECT url FROM folders")
            .compactMap { URL(string: $0)?.standardizedFileURL }
        let byPath = Dictionary(grouping: tracks.compactMap { track in
            filePath(for: track).map { ($0, track) }
        }, by: \.0).compactMapValues { candidates in
            candidates.count == 1 ? candidates[0].1 : nil
        }
        let byName = Dictionary(grouping: tracks, by: { normalizedFileName(fileName(for: $0.fileURL)) })

        return try urls.map { sourceURL in
            let items = try M3UParser.parse(url: sourceURL).map { entry in
                PlaylistImportItem(entry: entry, matchedTrack: match(entry, byPath: byPath, byName: byName, roots: roots))
            }
            return PlaylistImportPreview(
                sourceURL: sourceURL,
                suggestedName: sourceURL.deletingPathExtension().lastPathComponent,
                items: items
            )
        }
    }

    static func commit(
        previews: [PlaylistImportPreview],
        removeRepeatedTracks: Bool,
        in db: Database
    ) throws -> PlaylistImportCommitSummary {
        var playlistIDs: [Int64] = []
        var imported = 0
        var unresolved = 0

        for preview in previews {
            let now = Date()
            let revision = SyncRevision.make(at: now, writerID: try SyncDeviceIdentity.id(in: db)).rawValue
            var playlist = Playlist(
                name: preview.suggestedName.isEmpty ? "Imported Playlist" : preview.suggestedName,
                dateCreated: now,
                dateModified: now,
                nameRev: revision,
                sortModeRev: revision
            )
            try playlist.insert(db)
            try SyncOutbox.enqueue(recordType: "Playlist", recordName: "playlist_\(playlist.playlistSyncId)", in: db)

            var seenTrackIDs = Set<Int64>()
            var trackIDs: [Int64] = []
            for item in preview.items {
                guard let trackID = item.matchedTrack?.dbId else {
                    unresolved += 1
                    continue
                }
                if removeRepeatedTracks, !seenTrackIDs.insert(trackID).inserted { continue }
                trackIDs.append(trackID)
            }
            guard let playlistID = playlist.id else { throw PlaylistImportError.noPlaylistID }
            try PlaylistMutation.append(trackIDs, to: playlistID, in: db)
            imported += trackIDs.count
            playlistIDs.append(playlistID)
        }
        return PlaylistImportCommitSummary(
            playlistIDs: playlistIDs,
            importedTrackCount: imported,
            unresolvedEntryCount: unresolved
        )
    }

    private static func match(
        _ entry: M3UEntry,
        byPath: [String: Track],
        byName: [String: [Track]],
        roots: [URL]
    ) -> Track? {
        let rawPath = entry.rawPath.trimmingCharacters(in: .newlines)
        var candidates: [URL] = []
        if let absolute = entry.resolvedURL { candidates.append(absolute) }
        if !rawPath.hasPrefix("/") && URL(string: rawPath)?.isFileURL != true {
            candidates.append(entry.sourceURL.deletingLastPathComponent().appendingPathComponent(rawPath).standardizedFileURL)
            candidates.append(contentsOf: roots.map { $0.appendingPathComponent(rawPath).standardizedFileURL })
        }
        for candidate in candidates {
            if let track = byPath[candidate.path] { return track }
        }
        let name = normalizedFileName(URL(fileURLWithPath: rawPath).lastPathComponent)
        guard let sameNamed = byName[name], sameNamed.count == 1 else { return nil }
        return sameNamed[0]
    }

    private static func filePath(for track: Track) -> String? {
        guard let url = URL(string: track.fileURL), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    private static func fileName(for value: String) -> String {
        guard let url = URL(string: value) else { return "" }
        return url.lastPathComponent
    }

    private static func normalizedFileName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum PlaylistImportError: LocalizedError {
    case noPlaylistID

    var errorDescription: String? { "Moonlight could not create the imported playlist." }
}
