// SearchResultsView.swift
//
// The quick search pop-up. As the user types, matching albums and songs appear in one list that
// can be moved through with the arrow keys and opened or played with Return. It also contains
// the search rules that decide which albums and songs match.

import SwiftUI
import AppKit
import GRDB

struct MusicSearchQuery {
    let tokens: [String]
    let ftsExpression: String
    let includesSpecificTrackTerms: Bool

    init?(_ text: String) {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        self.tokens = tokens
        includesSpecificTrackTerms = tokens.count >= 4
        ftsExpression = tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    var likePatterns: [String] {
        tokens.map { "%\(Self.escapeLikePattern($0))%" }
    }

    private static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

enum SearchResultsQuery {
    static func albums(matching searchQuery: MusicSearchQuery, in db: Database) throws -> [Album] {
        let albumFieldPredicate = searchQuery.tokens
            .map { _ in "(albums.title LIKE ? ESCAPE '\\' OR albums.album_artist LIKE ? ESCAPE '\\')" }
            .joined(separator: " AND ")
        let albumTitlePredicate = searchQuery.tokens
            .map { _ in "albums.title LIKE ? ESCAPE '\\'" }
            .joined(separator: " AND ")
        let albumArtistPredicate = searchQuery.tokens
            .map { _ in "albums.album_artist LIKE ? ESCAPE '\\'" }
            .joined(separator: " AND ")
        let trackDerivedAlbumPredicate = searchQuery.includesSpecificTrackTerms
            ? "0"
            : """
              EXISTS (
                  SELECT 1 FROM tracks
                  JOIN tracks_fts ON tracks.rowid = tracks_fts.rowid
                  WHERE tracks.album_id = albums.id
                    AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
                    AND tracks_fts MATCH ?
              )
              """

        var arguments: [String] = []
        for pattern in searchQuery.likePatterns {
            arguments.append(pattern)
            arguments.append(pattern)
        }
        if !searchQuery.includesSpecificTrackTerms {
            arguments.append(searchQuery.ftsExpression)
        }
        arguments.append(contentsOf: searchQuery.likePatterns)
        arguments.append(contentsOf: searchQuery.likePatterns)
        if !searchQuery.includesSpecificTrackTerms {
            arguments.append(searchQuery.ftsExpression)
        }

        return try Album.fetchAll(db, sql: """
            SELECT albums.*
            FROM albums
            WHERE EXISTS (
                SELECT 1 FROM tracks
                WHERE tracks.album_id = albums.id
                  AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "tracks"))
            )
              AND (\(albumFieldPredicate)
                   OR \(trackDerivedAlbumPredicate))
            ORDER BY
                CASE
                    WHEN \(albumTitlePredicate) THEN 0
                    WHEN \(albumArtistPredicate) THEN 1
                    WHEN \(trackDerivedAlbumPredicate) THEN 2
                    ELSE 3
                END,
                albums.title COLLATE NOCASE
            LIMIT 8
        """, arguments: StatementArguments(arguments))
    }

    static func tracks(matching searchQuery: MusicSearchQuery, in db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT t.* FROM tracks t
            JOIN tracks_fts ON t.rowid = tracks_fts.rowid
            WHERE tracks_fts MATCH ?
              AND \(LibraryTrackQuery.catalogPredicate(tableAlias: "t"))
            ORDER BY rank,
                     COALESCE(t.album, '') COLLATE NOCASE,
                     COALESCE(t.disc_number, 0),
                     COALESCE(t.track_number, 0),
                     COALESCE(t.title, '') COLLATE NOCASE
            LIMIT 24
        """, arguments: [searchQuery.ftsExpression])
    }
}

struct SearchResultsView: View {
    let query: String
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var scrollTargetID: String?

    private var trimmedQuery: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SpotlightResult] {
        albums.map(SpotlightResult.album) + tracks.map(SpotlightResult.track)
    }

    var body: some View {
        VStack(spacing: 0) {
            spotlightField

            Divider()
                .overlay(Color.borderSoft)

            if results.isEmpty {
                emptyState
            } else {
                resultList
            }

            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.bgElevated.opacity(0.24))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.borderMedium, lineWidth: 0.5)
        )
        .padding(1)
        .task(id: trimmedQuery) { await search() }
        .onChange(of: appState.libraryVersion) { _, _ in
            Task { await search() }
        }
        .onChange(of: results.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") {
                selectedID = ids.first
            }
        }
    }

    private var spotlightField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.textTertiary)

            SpotlightSearchField(
                placeholder: "Search albums and songs",
                text: $appState.searchText,
                onMoveUp: selectPrevious,
                onMoveDown: selectNext,
                onReturn: chooseSelected,
                onEscape: { onDismiss?() }
            )
            .frame(height: 26)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: trimmedQuery.isEmpty ? "music.note.list" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(Color.textQuaternary)

            Text(trimmedQuery.isEmpty ? "Start typing" : "No results")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textSecondary)

            if !trimmedQuery.isEmpty {
                Text("No albums or songs matched \"\(trimmedQuery)\".")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: 424)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !albums.isEmpty {
                        SpotlightSectionHeader(title: "Albums", count: albums.count)
                            .padding(.top, 2)
                        ForEach(albums) { album in
                            resultRow(.album(album))
                        }
                    }

                    if !tracks.isEmpty {
                        SpotlightSectionHeader(title: "Songs", count: tracks.count)
                            .padding(.top, albums.isEmpty ? 2 : 10)
                        ForEach(tracks, id: \.dbId) { track in
                            resultRow(.track(track))
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 424)
            .onChange(of: scrollTargetID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ result: SpotlightResult) -> some View {
        SpotlightResultRow(
            result: result,
            isHighlighted: result.id == (hoveredID ?? selectedID),
            isCurrent: result.trackID == controller.currentTrack?.dbId,
            isPlaying: result.trackID == controller.currentTrack?.dbId && controller.isPlaying
        )
        .id(result.id)
        .onHover { isHovered in
            hoveredID = isHovered ? result.id : nil
        }
        .onTapGesture {
            selectedID = result.id
            choose(result)
        }
        .contextMenu {
            if let track = result.track {
                TrackRatingMenu(tracks: [track])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(resultSummary)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.textTertiary)

            Spacer()

            FooterKey(label: "↑↓")
            Text("Select")
            FooterKey(label: "Return")
            Text("Choose")
            FooterKey(label: "Esc")
            Text("Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.bgChrome.opacity(0.28))
    }

    private var resultSummary: String {
        guard !results.isEmpty else { return "" }
        let albumText = albums.count == 1 ? "1 album" : "\(albums.count) albums"
        let songText = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        return "\(albumText), \(songText)"
    }

    private func search() async {
        guard !trimmedQuery.isEmpty else {
            albums = []
            tracks = []
            selectedID = nil
            return
        }

        guard let searchQuery = MusicSearchQuery(trimmedQuery) else {
            albums = []
            tracks = []
            selectedID = nil
            return
        }

        albums = (try? appState.db.read { try SearchResultsQuery.albums(matching: searchQuery, in: $0) }) ?? []

        tracks = (try? appState.db.read { try SearchResultsQuery.tracks(matching: searchQuery, in: $0) }) ?? []

        let ids = results.map(\.id)
        if selectedID == nil || !ids.contains(selectedID ?? "") {
            selectedID = ids.first
        }
    }

    private func selectPrevious() {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[max(0, currentIndex - 1)].id
        hoveredID = nil
        scrollTargetID = selectedID
    }

    private func selectNext() {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? -1
        selectedID = results[min(results.count - 1, currentIndex + 1)].id
        hoveredID = nil
        scrollTargetID = selectedID
    }

    private func chooseSelected() {
        guard let selectedID, let result = results.first(where: { $0.id == selectedID }) else { return }
        choose(result)
    }

    private func choose(_ result: SpotlightResult) {
        switch result {
        case .album(let album):
            appState.showAlbum(albumId: album.id)
            onDismiss?()
        case .track(let track):
            controller.play(track: track, in: tracks)
            onDismiss?()
        }
    }
}

private enum SpotlightResult: Identifiable {
    case album(Album)
    case track(Track)

    var id: String {
        switch self {
        case .album(let album):
            return "album-\(album.id ?? -1)-\(album.title)"
        case .track(let track):
            return "track-\(track.dbId ?? -1)"
        }
    }

    var title: String {
        switch self {
        case .album(let album): return album.title
        case .track(let track): return track.displayTitle
        }
    }

    var subtitle: String {
        switch self {
        case .album(let album):
            return [album.displayArtist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case .track(let track):
            return [track.displayArtist, track.displayAlbum].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    var albumID: Int64? {
        switch self {
        case .album(let album): return album.id
        case .track(let track): return track.albumId
        }
    }

    var artworkID: Int64? {
        switch self {
        case .album(let album): return album.artworkId
        case .track(let track): return track.artworkId
        }
    }

    var trackID: Int64? {
        guard case .track(let track) = self else { return nil }
        return track.dbId
    }

    var track: Track? {
        guard case .track(let track) = self else { return nil }
        return track
    }

    var duration: String? {
        guard case .track(let track) = self else { return nil }
        return track.durationFormatted
    }
}

private struct SpotlightSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.textTertiary)

            Text(count.formatted())
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color.textQuaternary)

            Spacer()
        }
        .frame(height: 22)
        .padding(.horizontal, 10)
    }
}

private struct SpotlightResultRow: View {
    let result: SpotlightResult
    let isHighlighted: Bool
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(albumId: result.albumID, artworkId: result.artworkID, cornerRadius: 5, iconFont: .caption)
                    .frame(width: 38, height: 38)

                if isCurrent && isPlaying {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.black.opacity(0.42))
                        .frame(width: 38, height: 38)
                    VUMeterInline(color: Color.dAccent)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isHighlighted ? Color.textPrimary : Color.textPrimary.opacity(0.94))
                    .lineLimit(1)

                Text(result.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isHighlighted ? Color.textSecondary : Color.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let duration = result.duration {
                Text(duration)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textQuaternary)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? Color.bgSelectedActive : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isHighlighted ? Color.borderMedium : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

private struct FooterKey: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.borderSoft, lineWidth: 0.5)
                    )
            )
    }
}

private struct SpotlightSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = KeyHandlingTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 18, weight: .regular)
        textField.textColor = AppTheme.current.palette.nsTextPrimary
        textField.contentType = nil
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: AppTheme.current.palette.nsTextTertiary
            ]
        )
        textField.cell?.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.onMoveUp = onMoveUp
        textField.onMoveDown = onMoveDown
        textField.onReturn = onReturn
        textField.onEscape = onEscape

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            (textField.currentEditor() as? NSTextView)?.configureAsMusicSearchFieldEditor()
            textField.currentEditor()?.selectedRange = NSRange(location: textField.stringValue.count, length: 0)
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.textColor = AppTheme.current.palette.nsTextPrimary
        nsView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: AppTheme.current.palette.nsTextTertiary
            ]
        )
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        guard let textField = nsView as? KeyHandlingTextField else { return }
        textField.onMoveUp = onMoveUp
        textField.onMoveDown = onMoveDown
        textField.onReturn = onReturn
        textField.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            (textField.currentEditor() as? NSTextView)?.configureAsMusicSearchFieldEditor()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let textField = control as? KeyHandlingTextField else { return false }
            textView.configureAsMusicSearchFieldEditor()

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                textField.onMoveUp?()
                return true
            case #selector(NSResponder.moveDown(_:)):
                textField.onMoveDown?()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                textField.onReturn?()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textField.onEscape?()
                return true
            default:
                return false
            }
        }
    }
}

private final class KeyHandlingTextField: NSTextField {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onReturn?()
        case 53:
            onEscape?()
        case 125:
            onMoveDown?()
        case 126:
            onMoveUp?()
        default:
            super.keyDown(with: event)
        }
    }
}
