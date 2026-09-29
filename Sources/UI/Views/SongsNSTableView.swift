// SongsNSTableView.swift
//
// The spreadsheet-style songs table used on the Songs, Favorites and playlist pages. It shows
// songs in columns that can be resized, reordered, hidden or sorted, and supports selecting,
// double-click to play, dragging, star ratings, favorites and a right-click menu. It is built
// with the Mac's native table for speed with large libraries.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SongsNSTableView: NSViewRepresentable {
    let tracks: [Track]
    let currentTrackID: Int64?
    let isPlaying: Bool
    @Binding var selection: OrderedSelection<Int64>
    @Binding var columnLayout: SongsTableColumnLayout
    @Binding var sortOrder: SongsSortOrder
    let appState: AppState
    let controller: PlaybackController
    /// Optional row identities for collection views whose rows are associations
    /// rather than library tracks (for example, playlist memberships).
    let rowIDs: [Int64]?
    let allowsSorting: Bool
    let onReorder: (([Int64], Int) -> Void)?
    let onInsert: (([Int64], Int) -> Void)?
    /// Called by playlist tables to request removal of the selected membership
    /// rows without removing the underlying library tracks.
    let onRequestRemove: (([Int64]) -> Void)?
    /// Called by library-backed tables to remove selected tracks from the local
    /// library while leaving their source audio files untouched.
    let onRequestLibraryRemoval: (([Int64]) -> Void)?
    let dragSourcePlaylistID: Int64?

    init(
        tracks: [Track],
        currentTrackID: Int64?,
        isPlaying: Bool,
        selection: Binding<OrderedSelection<Int64>>,
        columnLayout: Binding<SongsTableColumnLayout>,
        sortOrder: Binding<SongsSortOrder>,
        appState: AppState,
        controller: PlaybackController,
        rowIDs: [Int64]? = nil,
        allowsSorting: Bool = true,
        onReorder: (([Int64], Int) -> Void)? = nil,
        onInsert: (([Int64], Int) -> Void)? = nil,
        onRequestRemove: (([Int64]) -> Void)? = nil,
        onRequestLibraryRemoval: (([Int64]) -> Void)? = nil,
        dragSourcePlaylistID: Int64? = nil
    ) {
        self.tracks = tracks
        self.currentTrackID = currentTrackID
        self.isPlaying = isPlaying
        _selection = selection
        _columnLayout = columnLayout
        _sortOrder = sortOrder
        self.appState = appState
        self.controller = controller
        self.rowIDs = rowIDs
        self.allowsSorting = allowsSorting
        self.onReorder = onReorder
        self.onInsert = onInsert
        self.onRequestRemove = onRequestRemove
        self.onRequestLibraryRemoval = onRequestLibraryRemoval
        self.dragSourcePlaylistID = dragSourcePlaylistID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SongsAppKitTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.menuProvider = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClickedRow(_:))
        tableView.rowHeight = 36
        tableView.headerView = SongsTableHeaderView()
        (tableView.headerView as? SongsTableHeaderView)?.menuProvider = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.backgroundColor = AppTheme.current.palette.nsBgContent
        tableView.registerForDraggedTypes([.fileURL, .moonlightTrackDragPayload])
        tableView.setDraggingSourceOperationMask(onReorder == nil ? .copy : [.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        context.coordinator.syncSortDescriptors(on: tableView)

        context.coordinator.configureColumns(on: tableView, force: true)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.current.palette.nsBgContent
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let tableView = scrollView.documentView as? SongsAppKitTableView else { return }
        let palette = AppTheme.current.palette
        scrollView.backgroundColor = palette.nsBgContent
        tableView.backgroundColor = palette.nsBgContent

        context.coordinator.configureColumns(on: tableView)
        context.coordinator.reloadIfNeeded(on: tableView)
        context.coordinator.syncSelectionFromBinding(on: tableView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, SongsTableMenuProviding {
        var parent: SongsNSTableView
        weak var tableView: SongsAppKitTableView?
        private var lastTracks: [Track] = []
        private var lastRowIDs: [Int64]?
        private var lastCurrentTrackID: Int64?
        private var lastIsPlaying = false
        private var lastLayout: SongsTableColumnLayout?
        private var hoveredRow: Int?
        private var isSyncingColumns = false
        private var isSyncingSelection = false

        init(_ parent: SongsNSTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.tracks.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = SongsTableRowView()
            rowView.onHoverChange = { [weak self, weak tableView] isHovered in
                guard let self, let tableView else { return }
                if isHovered {
                    self.hoveredRow = row
                } else if self.hoveredRow == row {
                    self.hoveredRow = nil
                }
                guard row >= 0, row < tableView.numberOfRows else { return }
                let interactiveColumns = IndexSet(tableView.tableColumns.enumerated().compactMap { index, column in
                    let identifier = column.identifier.rawValue
                    return identifier == SongsTableColumnID.rating.rawValue
                        || identifier == SongsTableColumnID.favorite.rawValue ? index : nil
                })
                guard !interactiveColumns.isEmpty else { return }
                tableView.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: interactiveColumns
                )
            }
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.tracks.count,
                  let tableColumn,
                  let columnID = SongsTableColumnID(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }

            let track = parent.tracks[row]
            let isCurrent = track.dbId == parent.currentTrackID
            let isSelected = tableView.selectedRowIndexes.contains(row)

            if columnID == .artwork {
                let identifier = NSUserInterfaceItemIdentifier("artworkCell")
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsArtworkCellView
                    ?? SongsArtworkCellView(identifier: identifier)
                cell.configure(
                    track: track,
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && parent.isPlaying,
                    isSelected: isSelected,
                    appState: parent.appState
                )
                return cell
            }

            if columnID == .rating {
                let identifier = NSUserInterfaceItemIdentifier("ratingCell")
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsRatingCellView
                    ?? SongsRatingCellView(identifier: identifier)
                cell.configure(
                    rating: track.rating,
                    isSelected: isSelected,
                    isRowHovered: row == hoveredRow
                ) { [weak self] rating in
                    guard let self, let trackID = track.dbId else { return }
                    let trackIDs = self.trackIDsForInlineAction(clickedRow: row, fallback: trackID)
                    try? self.parent.appState.setRating(rating, forTrackIDs: trackIDs)
                }
                return cell
            }

            if columnID == .favorite {
                let identifier = NSUserInterfaceItemIdentifier("favoriteCell")
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsFavoriteCellView
                    ?? SongsFavoriteCellView(identifier: identifier)
                cell.configure(
                    isFavorite: track.isFavorite,
                    isSelected: isSelected,
                    isRowHovered: row == hoveredRow
                ) { [weak self] isFavorite in
                    guard let self, let trackID = track.dbId else { return }
                    let trackIDs = self.trackIDsForInlineAction(clickedRow: row, fallback: trackID)
                    try? self.parent.appState.setFavorite(isFavorite, forTrackIDs: trackIDs)
                }
                return cell
            }

            let identifier = NSUserInterfaceItemIdentifier("textCell-\(columnID.rawValue)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsTextCellView
                ?? SongsTextCellView(identifier: identifier)
            cell.configure(
                text: displayText(for: track, columnID: columnID),
                columnID: columnID,
                isCurrent: isCurrent,
                isSelected: isSelected,
                alignment: SongsTableColumnLayout.definition(for: columnID).alignment
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView = notification.object as? NSTableView else { return }

            let selectedRows = tableView.selectedRowIndexes
            let selectedIDs = selectedRows.compactMap(rowID(at:))
            parent.selection.replace(with: Set(selectedIDs))
            reloadVisibleRows(on: tableView)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !isSyncingColumns,
                  let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let columnID = SongsTableColumnID(rawValue: tableColumn.identifier.rawValue) else {
                return
            }
            parent.columnLayout.setWidth(Double(tableColumn.width), for: columnID)
            parent.columnLayout.save()
            lastLayout = parent.columnLayout
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !isSyncingColumns,
                  let tableView = notification.object as? NSTableView else {
                return
            }

            var layout = parent.columnLayout
            let orderedIDs = tableView.tableColumns.compactMap { SongsTableColumnID(rawValue: $0.identifier.rawValue) }
            for (index, columnID) in orderedIDs.enumerated() {
                let visibleIDs = layout.visibleColumns.map(\.id)
                guard index < visibleIDs.count, visibleIDs[index] != columnID else { continue }
                layout.moveColumn(columnID, to: .before, relativeTo: visibleIDs[index])
            }
            parent.columnLayout = layout
            parent.columnLayout.save()
            lastLayout = parent.columnLayout
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard parent.allowsSorting,
                  let descriptor = tableView.sortDescriptors.first,
                  descriptor.key == SongsTableColumnID.rating.rawValue else { return }
            parent.sortOrder = descriptor.ascending ? .ratingAscending : .ratingDescending
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < parent.tracks.count,
                  let trackID = parent.tracks[row].dbId else {
                return nil
            }

            let item = NSPasteboardItem()
            let payload = TrackDragPayload(trackId: trackID, sourcePlaylistId: parent.dragSourcePlaylistID)
            if let data = try? JSONEncoder().encode(payload) {
                item.setData(data, forType: .moonlightTrackDragPayload)
            }
            if parent.tracks[row].isAvailable, let url = URL(string: parent.tracks[row].fileURL) {
                item.setString(url.absoluteString, forType: .fileURL)
            }
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            if parent.onReorder != nil, info.draggingSource as? NSTableView === tableView {
                return .move
            }
            return parent.onInsert == nil ? [] : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard dropOperation == .above else { return false }
            if let onReorder = parent.onReorder, info.draggingSource as? NSTableView === tableView {
                let entryIDs = tableView.selectedRowIndexes.compactMap(rowID(at:))
                guard !entryIDs.isEmpty else { return false }
                onReorder(entryIDs, row)
                return true
            }
            guard let onInsert = parent.onInsert else { return false }
            let trackIDs = info.draggingPasteboard.pasteboardItems?
                .compactMap { $0.data(forType: .moonlightTrackDragPayload) }
                .compactMap { try? JSONDecoder().decode(TrackDragPayload.self, from: $0) }
                .flatMap(\.trackIds) ?? []
            guard !trackIDs.isEmpty else { return false }
            onInsert(trackIDs, row)
            return true
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            parent.onReorder != nil && context == .withinApplication ? [.copy, .move] : .copy
        }

        @objc func doubleClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < parent.tracks.count, parent.tracks[row].isAvailable else { return }
            parent.controller.play(track: parent.tracks[row], in: parent.tracks)
        }

        func headerMenu() -> NSMenu {
            let menu = NSMenu()
            for definition in SongsTableColumnLayout.definitions {
                let item = NSMenuItem(
                    title: definition.title.isEmpty ? "Artwork" : definition.title,
                    action: #selector(toggleColumnVisibility(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = definition.id.rawValue
                item.state = parent.columnLayout.columns.first(where: { $0.id == definition.id })?.isVisible == true ? .on : .off
                item.isEnabled = !definition.isRequired
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let resetItem = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns(_:)), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
            return menu
        }

        func rowMenu(for event: NSEvent, in tableView: SongsAppKitTableView) -> NSMenu? {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard row >= 0, row < parent.tracks.count else { return nil }

            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            let track = parent.tracks[row]
            let selectedTracks = selectedTracksForAction(fallback: track)
            let menu = NSMenu()

            let playNow = NSMenuItem(title: "Play Now", action: #selector(playContextTrack(_:)), keyEquivalent: "")
            playNow.target = self
            playNow.representedObject = row
            playNow.isEnabled = track.isAvailable
            menu.addItem(playNow)

            if !selectedTracks.isEmpty {
                let playSelected = NSMenuItem(title: "Play Selected", action: #selector(playSelectedTracks(_:)), keyEquivalent: "")
                playSelected.target = self
                playSelected.isEnabled = selectedTracks.contains(where: \.isAvailable)
                menu.addItem(playSelected)

                let playlistMenu = NSMenu()
                if parent.appState.playlists.isEmpty {
                    let emptyItem = NSMenuItem(title: "No playlists yet", action: nil, keyEquivalent: "")
                    emptyItem.isEnabled = false
                    playlistMenu.addItem(emptyItem)
                } else {
                    for playlist in parent.appState.playlists {
                        let item = NSMenuItem(title: playlist.name, action: #selector(addSelectedTracksToPlaylist(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = playlist.id
                        playlistMenu.addItem(item)
                    }
                }
                let playlistItem = NSMenuItem(title: "Add Selected to Playlist", action: nil, keyEquivalent: "")
                playlistItem.submenu = playlistMenu
                menu.addItem(playlistItem)

                let newPlaylist = NSMenuItem(title: "New Playlist from Selected…", action: #selector(createPlaylistFromSelected(_:)), keyEquivalent: "")
                newPlaylist.target = self
                menu.addItem(newPlaylist)

                if parent.onRequestRemove != nil {
                    menu.addItem(.separator())
                    let count = selectedEntryIDsForAction().count
                    let title = count == 1 ? "Remove from Playlist" : "Remove \(count) from Playlist"
                    let remove = NSMenuItem(title: title, action: #selector(requestRemoveSelectedPlaylistEntries(_:)), keyEquivalent: "")
                    remove.target = self
                    remove.isEnabled = count > 0
                    menu.addItem(remove)
                }

                let editSelected = NSMenuItem(title: "Edit Selected Tags...", action: #selector(editSelectedTags(_:)), keyEquivalent: "")
                editSelected.target = self
                editSelected.isEnabled = selectedTracks.contains(where: \.isAvailable)
                menu.addItem(editSelected)
                menu.addItem(.separator())
            }

            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = ratingMenu()
            menu.addItem(rateItem)

            menu.addItem(.separator())
            let editTrack = NSMenuItem(title: "Edit Tags...", action: #selector(editContextTrack(_:)), keyEquivalent: "")
            editTrack.target = self
            editTrack.representedObject = row
            editTrack.isEnabled = track.isAvailable
            menu.addItem(editTrack)
            menu.addItem(.separator())
            let reveal = NSMenuItem(title: track.isAvailable ? "Reveal in Finder" : "File Unavailable", action: #selector(revealContextTrack(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = row
            reveal.isEnabled = track.isAvailable
            menu.addItem(reveal)

            if parent.onRequestLibraryRemoval != nil {
                menu.addItem(.separator())
                let count = selectedTracks.count
                let title = count == 1 ? "Remove from Library" : "Remove \(count) from Library"
                let remove = NSMenuItem(title: title, action: #selector(requestLibraryRemoval(_:)), keyEquivalent: "")
                remove.target = self
                remove.isEnabled = count > 0
                menu.addItem(remove)
            }

            return menu
        }

        func deleteSelectedRows() -> Bool {
            if let remove = parent.onRequestRemove {
                let entryIDs = selectedEntryIDsForAction()
                guard !entryIDs.isEmpty else { return false }
                remove(entryIDs)
                return true
            }

            let trackIDs = selectedTracksForAction().compactMap(\.dbId)
            guard !trackIDs.isEmpty, let remove = parent.onRequestLibraryRemoval else { return false }
            remove(trackIDs)
            return true
        }

        func selectAllRows() -> Bool {
            guard let tableView else { return false }
            tableView.selectRowIndexes(IndexSet(integersIn: 0..<parent.tracks.count), byExtendingSelection: false)
            return true
        }

        @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let columnID = SongsTableColumnID(rawValue: rawValue) else {
                return
            }
            let isVisible = parent.columnLayout.columns.first(where: { $0.id == columnID })?.isVisible == true
            parent.columnLayout.setVisibility(!isVisible, for: columnID)
            parent.columnLayout.save()
            if let tableView {
                configureColumns(on: tableView, force: true)
            }
        }

        @objc private func resetColumns(_ sender: NSMenuItem) {
            parent.columnLayout.resetToDefaults()
            parent.columnLayout.save()
            if let tableView {
                configureColumns(on: tableView, force: true)
            }
        }

        @objc private func playContextTrack(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int,
                  row >= 0, row < parent.tracks.count else {
                return
            }
            parent.controller.play(track: parent.tracks[row], in: parent.tracks)
        }

        @objc private func playSelectedTracks(_ sender: NSMenuItem) {
            let tracks = selectedTracksForAction().filter(\.isAvailable)
            guard let first = tracks.first else { return }
            parent.controller.play(track: first, in: tracks)
        }

        @objc private func addSelectedTracksToPlaylist(_ sender: NSMenuItem) {
            guard let playlistID = sender.representedObject as? Int64 else { return }
            parent.appState.addTracks(selectedTracksForAction(), toPlaylist: playlistID)
        }

        @objc private func createPlaylistFromSelected(_ sender: NSMenuItem) {
            let tracks = selectedTracksForAction()
            guard !tracks.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "New Playlist"
            alert.informativeText = "Create a playlist containing the selected tracks."
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            let nameField = NSTextField(string: "New Playlist")
            nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = nameField
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let playlist = parent.appState.createPlaylist(name: name), let playlistID = playlist.id else { return }
            parent.appState.addTracks(tracks, toPlaylist: playlistID)
            parent.appState.selectedSidebarItem = .playlist(playlistID)
        }

        @objc private func requestRemoveSelectedPlaylistEntries(_ sender: NSMenuItem) {
            let entryIDs = selectedEntryIDsForAction()
            guard !entryIDs.isEmpty else { return }
            parent.onRequestRemove?(entryIDs)
        }

        @objc private func requestLibraryRemoval(_ sender: NSMenuItem) {
            let trackIDs = selectedTracksForAction().compactMap(\.dbId)
            guard !trackIDs.isEmpty else { return }
            parent.onRequestLibraryRemoval?(trackIDs)
        }

        @objc private func editSelectedTags(_ sender: NSMenuItem) {
            parent.appState.editAlbumTags(title: "Edit Selected Tags", tracks: selectedTracksForAction().filter(\.isAvailable))
        }

        @objc private func rateSelectedTracks(_ sender: NSMenuItem) {
            guard let rating = sender.representedObject as? Int else { return }
            let trackIDs = selectedTracksForAction().compactMap(\.dbId)
            try? parent.appState.setRating(rating, forTrackIDs: trackIDs)
        }

        @objc private func clearSelectedTrackRatings(_ sender: NSMenuItem) {
            let trackIDs = selectedTracksForAction().compactMap(\.dbId)
            try? parent.appState.setRating(nil, forTrackIDs: trackIDs)
        }

        @objc private func editContextTrack(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int,
                  row >= 0, row < parent.tracks.count else {
                return
            }
            parent.appState.editTags(for: parent.tracks[row])
        }

        @objc private func revealContextTrack(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int,
                  row >= 0, row < parent.tracks.count else {
                return
            }
            parent.appState.revealInFinder(track: parent.tracks[row])
        }

        func configureColumns(on tableView: NSTableView, force: Bool = false) {
            let visibleColumns = parent.columnLayout.visibleColumns
            let visibleIDs = visibleColumns.map(\.id)
            let currentIDs = tableView.tableColumns.compactMap { SongsTableColumnID(rawValue: $0.identifier.rawValue) }
            let shouldRebuild = force || currentIDs != visibleIDs

            isSyncingColumns = true
            defer {
                isSyncingColumns = false
                lastLayout = parent.columnLayout
            }

            if shouldRebuild {
                for column in tableView.tableColumns {
                    tableView.removeTableColumn(column)
                }
                for column in visibleColumns {
                    tableView.addTableColumn(makeTableColumn(for: column))
                }
                syncSortDescriptors(on: tableView)
                return
            }

            for column in visibleColumns {
                guard let tableColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.id.rawValue)) else {
                    continue
                }
                tableColumn.minWidth = CGFloat(column.definition.minimumWidth)
                if abs(tableColumn.width - CGFloat(column.width)) > 0.5 {
                    tableColumn.width = CGFloat(column.width)
                }
            }
        }

        func reloadIfNeeded(on tableView: NSTableView) {
            let shouldReload = parent.tracks != lastTracks
                || parent.rowIDs != lastRowIDs
                || parent.currentTrackID != lastCurrentTrackID
                || parent.isPlaying != lastIsPlaying
                || parent.columnLayout != lastLayout

            guard shouldReload else { return }

            // A rating (or favorite) edit reloads the playlist's read model via
            // `libraryVersion`. The membership order is unchanged in that case,
            // so reloading the entire NSTableView unnecessarily tears down every
            // visible row and produces a distracting flash. Preserve full reloads
            // for inserts, removals, reorders, and column changes, but redraw only
            // the affected stable rows for in-place track updates.
            if hasSameRowStructure(), parent.columnLayout == lastLayout {
                var rowsToReload = IndexSet(parent.tracks.indices.filter {
                    parent.tracks[$0] != lastTracks[$0]
                })
                var columnsToReload = columnsForTrackChanges(in: rowsToReload, on: tableView)

                if parent.currentTrackID != lastCurrentTrackID || parent.isPlaying != lastIsPlaying {
                    let playbackTrackIDs = Set([parent.currentTrackID, lastCurrentTrackID].compactMap { $0 })
                    rowsToReload.formUnion(IndexSet(parent.tracks.indices.filter {
                        guard let trackID = parent.tracks[$0].dbId else { return false }
                        return playbackTrackIDs.contains(trackID)
                    }))
                    rowsToReload.formUnion(IndexSet(lastTracks.indices.filter {
                        guard let trackID = lastTracks[$0].dbId else { return false }
                        return playbackTrackIDs.contains(trackID)
                    }))
                    columnsToReload.formUnion(columnIndexes(for: [.artwork], on: tableView))
                }

                if !rowsToReload.isEmpty, !columnsToReload.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: rowsToReload,
                        columnIndexes: columnsToReload
                    )
                }
            } else {
                tableView.reloadData()
            }
            lastTracks = parent.tracks
            lastRowIDs = parent.rowIDs
            lastCurrentTrackID = parent.currentTrackID
            lastIsPlaying = parent.isPlaying
            lastLayout = parent.columnLayout
        }

        private func hasSameRowStructure() -> Bool {
            guard parent.tracks.count == lastTracks.count, parent.rowIDs == lastRowIDs else {
                return false
            }
            return zip(parent.tracks, lastTracks).allSatisfy { current, previous in
                current.hasSameIdentity(as: previous)
            }
        }

        private func columnsForTrackChanges(in rows: IndexSet, on tableView: NSTableView) -> IndexSet {
            guard !rows.isEmpty else { return [] }
            let onlyRatingsChanged = rows.allSatisfy {
                parent.tracks[$0].differsOnlyInRating(from: lastTracks[$0])
            }
            if onlyRatingsChanged {
                return columnIndexes(for: [.rating], on: tableView)
            }

            let onlyFavoritesChanged = rows.allSatisfy {
                parent.tracks[$0].differsOnlyInFavorite(from: lastTracks[$0])
            }
            if onlyFavoritesChanged {
                return columnIndexes(for: [.favorite], on: tableView)
            }

            return IndexSet(integersIn: 0..<tableView.numberOfColumns)
        }

        private func columnIndexes(for columnIDs: Set<SongsTableColumnID>, on tableView: NSTableView) -> IndexSet {
            IndexSet(tableView.tableColumns.enumerated().compactMap { index, column in
                guard let columnID = SongsTableColumnID(rawValue: column.identifier.rawValue),
                      columnIDs.contains(columnID) else {
                    return nil
                }
                return index
            })
        }

        func syncSelectionFromBinding(on tableView: NSTableView) {
            let selectedIDs = parent.selection.ids
            let indexes = IndexSet(parent.tracks.indices.compactMap { index in
                rowID(at: index).map(selectedIDs.contains) == true ? index : nil
            })

            guard indexes != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
            reloadVisibleRows(on: tableView)
        }

        private func makeTableColumn(for column: SongsTableColumn) -> NSTableColumn {
            let definition = column.definition
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id.rawValue))
            tableColumn.title = definition.title
            tableColumn.headerCell = SongsTableHeaderCell(textCell: definition.title.isEmpty ? " " : definition.title.uppercased())
            tableColumn.headerCell.alignment = definition.alignment.textAlignment
            tableColumn.width = CGFloat(column.width)
            tableColumn.minWidth = CGFloat(definition.minimumWidth)
            tableColumn.resizingMask = .userResizingMask
            if parent.allowsSorting, column.id == .rating {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: SongsTableColumnID.rating.rawValue,
                    ascending: true
                )
            }
            return tableColumn
        }

        func syncSortDescriptors(on tableView: NSTableView) {
            guard parent.allowsSorting else {
                tableView.sortDescriptors = []
                return
            }
            switch parent.sortOrder {
            case .title:
                tableView.sortDescriptors = []
            case .ratingAscending:
                tableView.sortDescriptors = [NSSortDescriptor(key: SongsTableColumnID.rating.rawValue, ascending: true)]
            case .ratingDescending:
                tableView.sortDescriptors = [NSSortDescriptor(key: SongsTableColumnID.rating.rawValue, ascending: false)]
            }
        }

        private func ratingMenu() -> NSMenu {
            let menu = NSMenu()
            for rating in 1...5 {
                let title = rating == 1 ? "1 Star" : "\(rating) Stars"
                let item = NSMenuItem(title: title, action: #selector(rateSelectedTracks(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = rating
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(clearSelectedTrackRatings(_:)), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
            return menu
        }

        private func displayText(for track: Track, columnID: SongsTableColumnID) -> String {
            if columnID == .favorite {
                return track.isFavorite ? "♥" : ""
            }
            let text = SongsTableColumnValueFormatter.string(for: track, columnID: columnID)
            if columnID == .title, !track.isAvailable {
                return AppTheme.current.displayText(text) + " — Unavailable"
            }
            switch columnID {
            case .title, .artist, .album, .albumArtist, .composer, .genre:
                return AppTheme.current.displayText(text)
            default:
                return text
            }
        }

        private func selectedTracksForAction(fallback: Track? = nil) -> [Track] {
            let selectedIDs = parent.selection.ids
            let tracks = parent.tracks.enumerated().compactMap { index, track in
                rowID(at: index).map(selectedIDs.contains) == true ? track : nil
            }
            if tracks.isEmpty, let fallback {
                return [fallback]
            }
            return tracks
        }

        private func selectedEntryIDsForAction() -> [Int64] {
            parent.tracks.indices.compactMap { index in
                guard let rowID = rowID(at: index), parent.selection.ids.contains(rowID) else { return nil }
                return rowID
            }
        }

        private func trackIDsForInlineAction(clickedRow: Int, fallback trackID: Int64) -> [Int64] {
            guard let clickedRowID = rowID(at: clickedRow), parent.selection.ids.contains(clickedRowID) else {
                return [trackID]
            }
            return selectedTracksForAction().compactMap(\.dbId)
        }

        private func rowID(at row: Int) -> Int64? {
            guard row >= 0, row < parent.tracks.count else { return nil }
            if let rowIDs = parent.rowIDs, rowIDs.count == parent.tracks.count {
                return rowIDs[row]
            }
            return parent.tracks[row].dbId
        }

        private func reloadVisibleRows(on tableView: NSTableView) {
            let rows = tableView.rows(in: tableView.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0 else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }
}

private extension Track {
    /// Rating writes also update the sync revision and promotion flag, neither of
    /// which affects a table cell. Treat that three-field mutation as a rating-only
    /// visual change so artwork and text cells remain intact.
    func differsOnlyInRating(from previous: Track) -> Bool {
        var normalized = self
        normalized.rating = previous.rating
        normalized.ratingRev = previous.ratingRev
        normalized.isPromoted = previous.isPromoted
        return normalized == previous
    }

    func differsOnlyInFavorite(from previous: Track) -> Bool {
        var normalized = self
        normalized.isFavorite = previous.isFavorite
        normalized.favoriteRev = previous.favoriteRev
        normalized.isPromoted = previous.isPromoted
        return normalized == previous
    }
}

@MainActor
protocol SongsTableMenuProviding: AnyObject {
    func headerMenu() -> NSMenu
    func rowMenu(for event: NSEvent, in tableView: SongsAppKitTableView) -> NSMenu?
    func deleteSelectedRows() -> Bool
    func selectAllRows() -> Bool
}

final class SongsAppKitTableView: NSTableView {
    weak var menuProvider: SongsTableMenuProviding?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?.rowMenu(for: event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (modifiers.isEmpty || modifiers == .command),
           (event.keyCode == 51 || event.keyCode == 117),
           menuProvider?.deleteSelectedRows() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.keyCode == 0,
           menuProvider?.selectAllRows() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SongsTableHeaderView: NSTableHeaderView {
    weak var menuProvider: SongsTableMenuProviding?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?.headerMenu()
    }
}

private final class SongsTableRowView: NSTableRowView {
    private var isHovered = false
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(false)
        needsDisplay = true
    }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let palette = AppTheme.current.palette
        let color: NSColor
        if isSelected {
            color = AppTheme.current.isRetroMoonPod ? palette.nsAccent : palette.nsBgSelectedActive
        } else if isHovered {
            color = palette.nsBgHover
        } else {
            color = palette.nsBgContent
        }
        color.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
    }
}

enum SongsTableInteraction {
    /// An inline action on an already-selected row applies to the selection. Clicking
    /// a control on another row affects only that row and never rewrites selection.
    static func targetTrackIDs(clickedTrackID: Int64, selectedTrackIDs: Set<Int64>) -> [Int64] {
        selectedTrackIDs.contains(clickedTrackID) ? selectedTrackIDs.sorted() : [clickedTrackID]
    }
}

enum SongsRatingAppearance {
    static func displayedRating(currentRating: Int?, hoveredRating: Int?) -> Int {
        hoveredRating ?? currentRating ?? 0
    }
}

private final class SongsHoverButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class SongsRatingCellView: NSTableCellView {
    private let stackView = NSStackView()
    private var buttons: [NSButton] = []
    private var rating: Int?
    private var isRowSelected = false
    private var isRowHovered = false
    private var isHovered = false
    private var hoveredRating: Int?
    private var onRate: ((Int?) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(
        rating: Int?,
        isSelected: Bool,
        isRowHovered: Bool = false,
        onRate: @escaping (Int?) -> Void
    ) {
        self.rating = rating
        isRowSelected = isSelected
        self.isRowHovered = isRowHovered
        self.onRate = onRate
        setAccessibilityLabel("Track rating")
        setAccessibilityValue(rating.map { "\($0) of 5 stars" } ?? "Unrated")
        updateButtons()
    }

    func performRatingAction(_ rating: Int) {
        guard (1...5).contains(rating) else { return }
        // Clicking the selected rating is the direct way to return a track to
        // Unrated. The context menu retains its explicit "Clear Rating" command.
        onRate?(self.rating == rating ? nil : rating)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateButtons()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateButtons()
    }

    @objc private func starPressed(_ sender: NSButton) {
        performRatingAction(sender.tag)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        for value in 1...5 {
            let button = SongsHoverButton()
            button.tag = value
            button.target = self
            button.action = #selector(starPressed(_:))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel(value == 1 ? "Rate 1 star" : "Rate \(value) stars")
            button.toolTip = value == 1 ? "Rate 1 star" : "Rate \(value) stars"
            button.onHoverChange = { [weak self] isHovered in
                guard let self else { return }
                self.hoveredRating = isHovered ? value : nil
                self.updateButtons()
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 16),
                button.heightAnchor.constraint(equalToConstant: 20)
            ])
            stackView.addArrangedSubview(button)
            buttons.append(button)
        }

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func updateButtons() {
        let displayedRating = SongsRatingAppearance.displayedRating(
            currentRating: rating,
            hoveredRating: hoveredRating
        )
        let revealsAllStars = isHovered || isRowHovered || isRowSelected
        for button in buttons {
            let isFilled = button.tag <= displayedRating
            button.image = NSImage(
                systemSymbolName: isFilled ? "star.fill" : "star",
                accessibilityDescription: button.toolTip
            )
            button.contentTintColor = isFilled
                ? AppTheme.current.palette.nsAccent
                : AppTheme.current.palette.nsTextTertiary
            button.alphaValue = isFilled || revealsAllStars || hoveredRating != nil ? 1 : 0
            if button.tag == rating {
                button.setAccessibilityLabel("Clear rating")
                button.toolTip = "Clear rating"
            } else {
                button.setAccessibilityLabel(button.tag == 1 ? "Rate 1 star" : "Rate \(button.tag) stars")
                button.toolTip = button.tag == 1 ? "Rate 1 star" : "Rate \(button.tag) stars"
            }
        }
    }
}

final class SongsFavoriteCellView: NSTableCellView {
    private let button = SongsHoverButton()
    private var isFavorite = false
    private var isRowSelected = false
    private var isRowHovered = false
    private var isHovered = false
    private var onToggle: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(
        isFavorite: Bool,
        isSelected: Bool,
        isRowHovered: Bool = false,
        onToggle: @escaping (Bool) -> Void
    ) {
        self.isFavorite = isFavorite
        isRowSelected = isSelected
        self.isRowHovered = isRowHovered
        self.onToggle = onToggle
        setAccessibilityLabel("Favorite")
        setAccessibilityValue(isFavorite ? "Favorite" : "Not favorite")
        updateButton()
    }

    func performToggleAction() {
        onToggle?(!isFavorite)
    }

    @objc private func favoritePressed(_ sender: NSButton) {
        performToggleAction()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        button.target = self
        button.action = #selector(favoritePressed(_:))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.onHoverChange = { [weak self] isHovered in
            self?.isHovered = isHovered
            self?.updateButton()
        }
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func updateButton() {
        let appearsFavorite = isFavorite || isHovered
        let actionLabel = isFavorite ? "Remove from Favorites" : "Add to Favorites"
        button.image = NSImage(
            systemSymbolName: appearsFavorite ? "heart.fill" : "heart",
            accessibilityDescription: actionLabel
        )
        button.setAccessibilityLabel(actionLabel)
        button.toolTip = actionLabel
        button.contentTintColor = appearsFavorite
            ? AppTheme.current.palette.nsAccent
            : AppTheme.current.palette.nsTextTertiary
        button.alphaValue = isFavorite || isHovered || isRowHovered || isRowSelected ? 1 : 0
    }
}

private final class SongsTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(
        text: String,
        columnID: SongsTableColumnID,
        isCurrent: Bool,
        isSelected: Bool,
        alignment: SongsTableColumnAlignment
    ) {
        label.stringValue = text
        label.alignment = alignment.textAlignment
        label.font = font(for: columnID, isCurrent: isCurrent)
        label.textColor = textColor(for: columnID, isCurrent: isCurrent, isSelected: isSelected)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func font(for columnID: SongsTableColumnID, isCurrent: Bool) -> NSFont {
        switch columnID {
        case .duration, .year, .trackNumber, .discNumber, .bitRate, .sampleRate, .channelCount, .playCount:
            return AppTheme.current.nsFont(.numeric, size: 11.5, monospacedDigit: true)
        case .title:
            return AppTheme.current.nsFont(.table, size: 12.5, weight: isCurrent ? .medium : .regular)
        case .favorite, .rating:
            return AppTheme.current.nsFont(.icon, size: 12)
        default:
            return AppTheme.current.nsFont(.metadata, size: 12.5)
        }
    }

    private func textColor(for columnID: SongsTableColumnID, isCurrent: Bool, isSelected: Bool) -> NSColor {
        let palette = AppTheme.current.palette
        if isSelected, AppTheme.current.isRetroMoonPod {
            return palette.nsBgContent
        }
        if columnID == .favorite || columnID == .rating {
            return label.stringValue.isEmpty ? palette.nsTextTertiary : palette.nsAccent
        }
        if columnID == .title, isCurrent, !isSelected {
            return palette.nsAccent
        }
        switch columnID {
        case .title:
            return palette.nsTextPrimary
        case .duration, .year, .trackNumber, .discNumber, .bitRate, .sampleRate, .channelCount, .playCount:
            return palette.nsTextTertiary
        default:
            return palette.nsTextSecondary
        }
    }
}

private final class SongsArtworkCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(track: Track, isCurrent: Bool, isPlaying: Bool, isSelected: Bool, appState: AppState) {
        let rootView = AnyView(
            SongsArtworkCell(
                track: track,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                isSelected: isSelected
            )
            .environmentObject(appState)
        )

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
                hostingView.widthAnchor.constraint(equalToConstant: 30),
                hostingView.heightAnchor.constraint(equalToConstant: 30)
            ])
            self.hostingView = hostingView
        }
    }
}

private struct SongsArtworkCell: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelected: Bool

    var body: some View {
        ZStack {
            ArtworkView(albumId: track.albumId, artworkId: track.artworkId, cornerRadius: 3, iconFont: .caption2)
                .frame(width: 30, height: 30)

            if isCurrent && isPlaying {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.35))
                    .frame(width: 30, height: 30)
                VUMeterInline(color: isSelected && AppTheme.current.isRetroMoonPod ? Color.bgContent : Color.dAccent)
            }
        }
        .frame(width: 30, height: 30)
    }
}

private final class SongsTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let palette = AppTheme.current.palette
        palette.nsBgChrome.setFill()
        cellFrame.fill()

        palette.nsBorderSoft.setFill()
        NSRect(x: cellFrame.maxX - 0.5, y: cellFrame.minY + 4, width: 0.5, height: cellFrame.height - 8).fill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 0.5).fill()

        drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 0), in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppTheme.current.nsFont(.table, size: 11, weight: .medium),
            .foregroundColor: AppTheme.current.palette.nsTextTertiary,
            .paragraphStyle: paragraphStyle,
            .kern: 0.5
        ]

        let attributedString = NSAttributedString(string: stringValue, attributes: attributes)
        let textRect = NSRect(
            x: cellFrame.minX,
            y: cellFrame.midY - attributedString.size().height / 2,
            width: cellFrame.width,
            height: attributedString.size().height
        )
        attributedString.draw(in: textRect)
    }
}

private extension SongsTableColumnAlignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let moonlightTrackDragPayload = NSPasteboard.PasteboardType(UTType.moonlightTrackDragPayload.identifier)
}
