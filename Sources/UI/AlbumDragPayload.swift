// AlbumDragPayload.swift
//
// Describes what gets carried along when you drag one or more albums from the album grid onto a
// playlist. Only the album identifiers travel with the drag; the playlist then looks up the
// songs itself so they are added in proper disc and track order.

import SwiftUI
import UniformTypeIdentifiers

/// Carries one or more selected albums to a playlist drop target. The target
/// resolves tracks from the database so album/disc/track order is preserved.
struct AlbumDragPayload: Codable, Hashable, Transferable {
    let albumIDs: [Int64]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .moonlightAlbumDragPayload)
    }
}

extension UTType {
    static let moonlightAlbumDragPayload = UTType(exportedAs: "org.musopen.moonlight.album-drag-payload")
}
