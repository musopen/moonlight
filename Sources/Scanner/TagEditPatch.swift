// TagEditPatch.swift
//
// Defines the song details a user can edit, such as title, artist, album and track number, and how
// a set of edits is described: values to set, values to clear and a cover art change. It also
// covers showing "mixed" when several selected songs differ, and recording whether each file
// saved, was skipped or failed.

import Foundation
import SPFKMetadata

enum EditableTagField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case title
    case artist
    case albumArtist
    case album
    case composer
    case genre
    case date
    case trackNumber
    case discNumber
    case comment
    case compilation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .albumArtist: "Album Artist"
        case .album: "Album"
        case .composer: "Composer"
        case .genre: "Genre"
        case .date: "Date / Year"
        case .trackNumber: "Track Number"
        case .discNumber: "Disc Number"
        case .comment: "Comment"
        case .compilation: "Compilation"
        }
    }

    var tagKey: TagKey {
        switch self {
        case .title: .title
        case .artist: .artist
        case .albumArtist: .albumArtist
        case .album: .album
        case .composer: .composer
        case .genre: .genre
        case .date: .date
        case .trackNumber: .trackNumber
        case .discNumber: .discNumber
        case .comment: .comment
        case .compilation: .compilation
        }
    }

    static let commonFields: [EditableTagField] = [
        .title, .artist, .album, .date, .trackNumber, .genre, .comment, .albumArtist, .composer, .discNumber, .compilation
    ]
}

enum MultiTagValue: Equatable, Sendable {
    case same(String?)
    case mixed

    var displayValue: String {
        switch self {
        case .same(let value): value ?? ""
        case .mixed: ""
        }
    }

    var isMixed: Bool {
        if case .mixed = self { return true }
        return false
    }
}

struct TagEditPatch: Sendable {
    var setting: [EditableTagField: String] = [:]
    var removing: Set<EditableTagField> = []
    var artwork: ArtworkEdit = .unchanged

    var isEmpty: Bool {
        setting.isEmpty && removing.isEmpty && artwork == .unchanged
    }
}

enum ArtworkEdit: Equatable, Sendable {
    case unchanged
    case replace(URL)
    case remove
}

struct TagEditResult: Identifiable, Sendable {
    enum Status: Sendable {
        case saved
        case skipped
        case failed(String)
    }

    let id = UUID()
    let fileURL: String
    let status: Status
}

struct TagEditorContext: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [Track]
}
