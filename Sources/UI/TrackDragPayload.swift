// TrackDragPayload.swift
//
// Describes what gets carried along when you drag songs, for example into a playlist or to
// reorder one. It records which songs are being dragged and, if they came from a playlist, which
// one. It also adds a shortcut that makes any song row draggable, carrying the whole selection
// when the dragged song is part of it.

import SwiftUI
import UniformTypeIdentifiers

struct TrackDragPayload: Codable, Hashable, Transferable {
    let trackIds: [Int64]
    let sourcePlaylistId: Int64?

    init(trackId: Int64, sourcePlaylistId: Int64? = nil) {
        self.trackIds = [trackId]
        self.sourcePlaylistId = sourcePlaylistId
    }

    init(trackIds: [Int64], sourcePlaylistId: Int64? = nil) {
        self.trackIds = trackIds
        self.sourcePlaylistId = sourcePlaylistId
    }

    var trackId: Int64 { trackIds.first ?? -1 }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .moonlightTrackDragPayload)
    }
}

extension UTType {
    static let moonlightTrackDragPayload = UTType(exportedAs: "org.musopen.moonlight.track-drag-payload")
}

extension View {
    @ViewBuilder
    func trackDragSource(
        for track: Track,
        sourcePlaylistId: Int64? = nil,
        selectedTrackIds: Set<Int64> = []
    ) -> some View {
        let trackIds = track.dbId.map { trackId in
            selectedTrackIds.contains(trackId) && !selectedTrackIds.isEmpty
                ? Array(selectedTrackIds)
                : [trackId]
        } ?? []

        if !trackIds.isEmpty {
            let payload = TrackDragPayload(trackIds: trackIds, sourcePlaylistId: sourcePlaylistId)
            draggable(payload)
        } else {
            self
        }
    }
}
