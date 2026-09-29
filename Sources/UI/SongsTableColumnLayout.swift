// SongsTableColumnLayout.swift
//
// Defines every column the songs table can show (title, artist, album, genre, bitrate, rating
// and so on), with default widths and which ones are visible at first. It also remembers the
// user's own changes, such as hidden, resized or reordered columns, and saves them so they come
// back next time.

import Foundation

enum SongsTableColumnID: String, Codable, CaseIterable, Identifiable {
    case artwork
    case title
    case artist
    case album
    case albumArtist
    case composer
    case genre
    case year
    case trackNumber
    case discNumber
    case duration
    case format
    case bitRate
    case sampleRate
    case channelCount
    case favorite
    case rating
    case playCount
    case lastPlayed
    case dateAdded

    var id: String { rawValue }
}

enum SongsTableColumnAlignment {
    case leading
    case center
    case trailing
}

enum SongsTableColumnDropPlacement {
    case before
    case after
}

struct SongsTableColumnDefinition: Identifiable {
    let id: SongsTableColumnID
    let title: String
    let defaultWidth: Double
    let minimumWidth: Double
    let defaultVisible: Bool
    let isRequired: Bool
    let alignment: SongsTableColumnAlignment
}

struct SongsTableColumn: Identifiable, Equatable {
    let id: SongsTableColumnID
    var width: Double
    var isVisible: Bool

    var definition: SongsTableColumnDefinition {
        SongsTableColumnLayout.definition(for: id)
    }
}

struct SongsTableColumnLayout: Equatable {
    static let storageKey = "songs_table_columns_v1"
    static let favoriteDefaultMigrationKey = "songs_table_columns_favorite_visible_v1"
    static let horizontalPadding: Double = 16

    static let definitions: [SongsTableColumnDefinition] = [
        .init(id: .artwork, title: "", defaultWidth: 48, minimumWidth: 42, defaultVisible: true, isRequired: false, alignment: .center),
        .init(id: .title, title: "Title", defaultWidth: 300, minimumWidth: 150, defaultVisible: true, isRequired: true, alignment: .leading),
        .init(id: .artist, title: "Artist", defaultWidth: 180, minimumWidth: 100, defaultVisible: true, isRequired: false, alignment: .leading),
        .init(id: .album, title: "Album", defaultWidth: 220, minimumWidth: 120, defaultVisible: true, isRequired: false, alignment: .leading),
        .init(id: .albumArtist, title: "Album Artist", defaultWidth: 180, minimumWidth: 120, defaultVisible: true, isRequired: false, alignment: .leading),
        .init(id: .composer, title: "Composer", defaultWidth: 200, minimumWidth: 120, defaultVisible: false, isRequired: false, alignment: .leading),
        .init(id: .genre, title: "Genre", defaultWidth: 140, minimumWidth: 90, defaultVisible: false, isRequired: false, alignment: .leading),
        .init(id: .year, title: "Year", defaultWidth: 72, minimumWidth: 58, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .trackNumber, title: "Track", defaultWidth: 72, minimumWidth: 58, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .discNumber, title: "Disc", defaultWidth: 64, minimumWidth: 54, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .duration, title: "Time", defaultWidth: 72, minimumWidth: 58, defaultVisible: true, isRequired: false, alignment: .trailing),
        .init(id: .format, title: "Format", defaultWidth: 90, minimumWidth: 70, defaultVisible: false, isRequired: false, alignment: .leading),
        .init(id: .bitRate, title: "Bitrate", defaultWidth: 92, minimumWidth: 76, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .sampleRate, title: "Sample Rate", defaultWidth: 110, minimumWidth: 88, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .channelCount, title: "Channels", defaultWidth: 86, minimumWidth: 70, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .favorite, title: "Favorite", defaultWidth: 78, minimumWidth: 64, defaultVisible: true, isRequired: false, alignment: .center),
        .init(id: .rating, title: "Rating", defaultWidth: 112, minimumWidth: 96, defaultVisible: false, isRequired: false, alignment: .center),
        .init(id: .playCount, title: "Plays", defaultWidth: 74, minimumWidth: 60, defaultVisible: false, isRequired: false, alignment: .trailing),
        .init(id: .lastPlayed, title: "Last Played", defaultWidth: 132, minimumWidth: 104, defaultVisible: false, isRequired: false, alignment: .leading),
        .init(id: .dateAdded, title: "Date Added", defaultWidth: 132, minimumWidth: 104, defaultVisible: false, isRequired: false, alignment: .leading)
    ]

    var columns: [SongsTableColumn]

    var visibleColumns: [SongsTableColumn] {
        columns.filter(\.isVisible)
    }

    var contentWidth: Double {
        visibleColumns.reduce(Self.horizontalPadding * 2) { $0 + $1.width }
    }

    static var defaultLayout: SongsTableColumnLayout {
        SongsTableColumnLayout(columns: definitions.map {
            SongsTableColumn(id: $0.id, width: $0.defaultWidth, isVisible: $0.defaultVisible || $0.isRequired)
        }).sanitized()
    }

    static func definition(for id: SongsTableColumnID) -> SongsTableColumnDefinition {
        definitions.first { $0.id == id }!
    }

    static func load(userDefaults: UserDefaults = .standard) -> SongsTableColumnLayout {
        let layout: SongsTableColumnLayout
        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) {
            layout = stored.layout.sanitized()
        } else {
            layout = defaultLayout
        }

        var migratedLayout = layout
        if !userDefaults.bool(forKey: favoriteDefaultMigrationKey) {
            migratedLayout.setVisibility(true, for: .favorite)
            userDefaults.set(true, forKey: favoriteDefaultMigrationKey)
        }
        return migratedLayout
    }

    func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(StoredLayout(layout: sanitized())) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    func sanitized() -> SongsTableColumnLayout {
        var seen = Set<SongsTableColumnID>()
        var sanitizedColumns: [SongsTableColumn] = []

        for column in columns where !seen.contains(column.id) {
            let definition = Self.definition(for: column.id)
            sanitizedColumns.append(SongsTableColumn(
                id: column.id,
                width: max(column.width, definition.minimumWidth),
                isVisible: definition.isRequired || column.isVisible
            ))
            seen.insert(column.id)
        }

        for definition in Self.definitions where !seen.contains(definition.id) {
            sanitizedColumns.append(SongsTableColumn(
                id: definition.id,
                width: definition.defaultWidth,
                isVisible: definition.defaultVisible || definition.isRequired
            ))
        }

        if !sanitizedColumns.contains(where: { $0.id == .title && $0.isVisible }) {
            if let index = sanitizedColumns.firstIndex(where: { $0.id == .title }) {
                sanitizedColumns[index].isVisible = true
            }
        }

        return SongsTableColumnLayout(columns: sanitizedColumns)
    }

    mutating func setVisibility(_ isVisible: Bool, for id: SongsTableColumnID) {
        let definition = Self.definition(for: id)
        guard !definition.isRequired else { return }
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].isVisible = isVisible
    }

    mutating func setWidth(_ width: Double, for id: SongsTableColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].width = max(width, columns[index].definition.minimumWidth)
    }

    mutating func moveColumn(_ id: SongsTableColumnID, to placement: SongsTableColumnDropPlacement, relativeTo targetID: SongsTableColumnID) {
        guard id != targetID,
              let sourceIndex = columns.firstIndex(where: { $0.id == id }),
              let targetIndex = columns.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let visibleIDs = visibleColumns.map(\.id)
        guard visibleIDs.contains(id), visibleIDs.contains(targetID) else {
            return
        }

        let movedColumn = columns.remove(at: sourceIndex)
        let adjustedTargetIndex = columns.firstIndex(where: { $0.id == targetID }) ?? targetIndex
        let insertionIndex = placement == .before ? adjustedTargetIndex : adjustedTargetIndex + 1
        columns.insert(movedColumn, at: min(insertionIndex, columns.count))
    }

    mutating func moveColumn(_ id: SongsTableColumnID, toVisiblePositionOf targetID: SongsTableColumnID) {
        guard id != targetID else { return }
        let visibleIDs = visibleColumns.map(\.id)
        guard let sourceVisibleIndex = visibleIDs.firstIndex(of: id),
              let targetVisibleIndex = visibleIDs.firstIndex(of: targetID) else {
            return
        }
        moveColumn(id, to: sourceVisibleIndex < targetVisibleIndex ? .after : .before, relativeTo: targetID)
    }

    mutating func resetToDefaults() {
        self = Self.defaultLayout
    }
}

private struct StoredLayout: Codable {
    let columns: [StoredColumn]

    init(layout: SongsTableColumnLayout) {
        columns = layout.columns.map {
            StoredColumn(id: $0.id, width: $0.width, isVisible: $0.isVisible)
        }
    }

    var layout: SongsTableColumnLayout {
        SongsTableColumnLayout(columns: columns.map {
            SongsTableColumn(id: $0.id, width: $0.width, isVisible: $0.isVisible)
        })
    }
}

private struct StoredColumn: Codable {
    let id: SongsTableColumnID
    let width: Double
    let isVisible: Bool
}
