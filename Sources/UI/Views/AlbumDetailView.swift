// AlbumDetailView.swift
//
// The page for a single album, opened from the album grid, an artist or a genre. It shows the
// artwork and album details, play, shuffle and edit-tags buttons, and the track list grouped by
// disc. Songs can be selected by clicking or by dragging a rectangle, rated, added to playlists
// and played from a right-click menu. The reusable song row and star-rating menu also live here.

import AppKit
import SwiftUI
import GRDB
import CoreImage

struct AlbumDetailView: View {
    let album: Album
    var revealTrackID: Int64? = nil
    var backLabel: String = "Albums"
    var onBack: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @State private var tracks: [Track] = []
    @State private var accentColor: Color = Color.dAccent
    @State private var selection = OrderedSelection<Int64>()
    @State private var displayedAlbum: Album?
    @State private var orderedTrackIds: [Int64] = []
    @State private var trackFrames: [Int64: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var hasRevealedTrack = false

    private let trackListCoordinateSpace = "albumDetailTrackList"

    private var isMarqueeSelecting: Bool {
        marqueeStart != nil
    }

    private var currentAlbum: Album {
        displayedAlbum ?? album
    }

    private var totalDurationFormatted: String {
        let total = tracks.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }

    private var hasMultipleDiscs: Bool {
        Set(tracks.compactMap { $0.discNumber }).count > 1
    }

    private var trackGroups: [(disc: Int?, tracks: [Track])] {
        guard hasMultipleDiscs else { return [(nil, tracks)] }
        var result: [(Int?, [Track])] = []
        var currentDisc: Int? = tracks.first?.discNumber
        var currentGroup: [Track] = []
        for track in tracks {
            if track.discNumber != currentDisc {
                result.append((currentDisc, currentGroup))
                currentDisc = track.discNumber
                currentGroup = []
            }
            currentGroup.append(track)
        }
        if !currentGroup.isEmpty { result.append((currentDisc, currentGroup)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Back nav bar
            if onBack != nil {
                backBar
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        Color.clear.frame(minHeight: 720)
                        // Corner glow from album accent — fades on both right and bottom
                        RadialGradient(
                            stops: [
                                .init(color: accentColor.opacity(0.50), location: 0),
                                .init(color: accentColor.opacity(0.20), location: 0.35),
                                .init(color: .clear, location: 0.65)
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 600
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                        VStack(alignment: .leading, spacing: 0) {
                            heroHeader
                            trackList
                        }
                    }
                }
                .onChange(of: orderedTrackIds) { _, ids in
                    guard !hasRevealedTrack,
                          let revealTrackID,
                          ids.contains(revealTrackID) else { return }
                    hasRevealedTrack = true
                    selection.replace(with: Set([revealTrackID]))
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(Optional(revealTrackID), anchor: .center)
                    }
                }
            }
            .background(Color.bgContent)
        }
        .task { await loadTracks() }
        .task { await loadAccentColor() }
        .onChange(of: appState.libraryVersion) { _, _ in
            Task {
                await loadTracks()
                await loadAccentColor()
            }
        }
    }

    // MARK: - Back bar

    private var backBar: some View {
        ZStack(alignment: .bottom) {
            Color.bgChrome.opacity(0.72)
                .background(.ultraThinMaterial)

            HStack {
                Button {
                    onBack?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(backLabel)
                            .font(.system(size: 12.5))
                    }
                    .foregroundStyle(Color.textSecondary)
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color.borderSoft)
                .frame(height: 0.5)
        }
        .frame(height: 40)
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        HStack(alignment: .bottom, spacing: 32) {
            ArtworkView(
                albumId: currentAlbum.id,
                artworkId: currentAlbum.artworkId,
                large: true,
                decodeMaxPixelSize: 600,
                cornerRadius: 6,
                iconFont: .largeTitle
            )
                .frame(width: 232, height: 232)
                .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                .flexibleFrame()

            VStack(alignment: .leading, spacing: 0) {
                // Genre · Year tag
                let genreTag: String? = currentAlbum.genre.flatMap {
                    let v = $0.trimmingCharacters(in: .whitespaces)
                    return (v.isEmpty || v.lowercased() == "unknown genre") ? nil : v
                }
                let tag = [genreTag, currentAlbum.year.map(String.init)].compactMap { $0 }.joined(separator: " · ").uppercased()
                if !tag.isEmpty {
                    Text(tag)
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1.4)
                        .foregroundStyle(accentColor)
                }

                // Album title — serif
                Text(currentAlbum.title)
                    .font(.system(size: 34, weight: .medium, design: .serif))
                    .tracking(-0.6)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                // Composer / artist
                Text(currentAlbum.displayArtist)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 12)

                // Meta line
                if !tracks.isEmpty {
                    HStack(spacing: 6) {
                        Text("\(tracks.count.formatted()) tracks")
                        Text("·")
                        Text(totalDurationFormatted)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 12)
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Play/Pause — accent fill
                    let albumIsPlaying = controller.isPlaying && tracks.contains(where: { track in
                        controller.currentTrack?.hasSameIdentity(as: track) == true
                    })
                    Button {
                        if albumIsPlaying {
                            controller.togglePlayPause()
                        } else if let first = tracks.first(where: \.isAvailable) {
                            controller.play(track: first, in: tracks)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: albumIsPlaying ? "pause.fill" : "play.fill").font(.system(size: 11))
                            Text(albumIsPlaying ? "Pause" : "Play").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: "#0a0a0e"))
                        .frame(height: 30)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 6).fill(accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(!tracks.contains(where: \.isAvailable))

                    // Shuffle — ghost
                    Button {
                        let shuffled = tracks.filter(\.isAvailable).shuffled()
                        if let first = shuffled.first { controller.play(track: first, in: shuffled) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle").font(.system(size: 11))
                            Text("Shuffle").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.textPrimary)
                        .frame(height: 30)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.borderMedium, lineWidth: 0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!tracks.contains(where: \.isAvailable))

                    Button {
                        appState.editAlbumTags(title: "Edit Album Tags", tracks: tracks.filter(\.isAvailable))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "tag").font(.system(size: 11))
                            Text("Edit Tags").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.textPrimary)
                        .frame(height: 30)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.borderMedium, lineWidth: 0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!tracks.contains(where: \.isAvailable))
                }
                .padding(.top, 18)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackList: some View {
        let selectedTrackIds = selection.ids

        VStack(spacing: 0) {
            // Column header
            HStack(spacing: 0) {
                Text("#")
                    .frame(width: 36, alignment: .leading)
                Text("Movement / Track")
                Spacer()
                Text("Time")
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Color.textTertiary)
            .frame(height: 28)
            .padding(.horizontal, 24)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.borderSoft).frame(height: 0.5)
            }

            // Tracks (grouped by disc when multi-disc)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }

                LazyVStack(spacing: 0) {
                    ForEach(Array(trackGroups.enumerated()), id: \.offset) { _, group in
                        if hasMultipleDiscs {
                            HStack {
                                Text("Disc \(group.disc.map(String.init) ?? "?")")
                                    .font(.system(size: 11, weight: .semibold))
                                    .kerning(0.8)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Color.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.03))
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.borderSoft).frame(height: 0.5)
                            }
                        }
                        ForEach(group.tracks, id: \.dbId) { track in
                            TrackRow(
                                track: track,
                                showArtist: false,
                                isCurrent: controller.currentTrack?.hasSameIdentity(as: track) == true,
                                isPlaying: controller.currentTrack?.hasSameIdentity(as: track) == true && controller.isPlaying,
                                isSelected: track.dbId.map(selection.contains) == true,
                                selectedTrackIds: selectedTrackIds,
                                selectedTracksProvider: { selectedTracks },
                                accentColor: accentColor,
                                horizontalPadding: 24,
                                onPlay: { controller.playOrToggle(track: track, in: tracks) },
                                onPlayNow: { controller.play(track: track, in: tracks) },
                                onSelect: { select(track) }
                            )
                            .trackSelectionFrame(
                                id: track.dbId,
                                coordinateSpace: trackListCoordinateSpace,
                                isEnabled: isMarqueeSelecting
                            )
                            .id(track.dbId)
                        }
                    }
                }
                .padding(.bottom, 32)

                if let trackMarqueeRect {
                    Rectangle()
                        .fill(Color.dAccent.opacity(0.14))
                        .overlay(
                            Rectangle()
                                .stroke(Color.dAccent.opacity(0.7), lineWidth: 1)
                        )
                        .frame(width: trackMarqueeRect.width, height: trackMarqueeRect.height)
                        .offset(x: trackMarqueeRect.minX, y: trackMarqueeRect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: trackListCoordinateSpace)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(trackMarqueeGesture)
            .onPreferenceChange(TrackFramePreferenceKey.self) { trackFrames = $0 }
        }
        .padding(.top, 8)
    }

    // MARK: - Data loading

    private func loadTracks() async {
        let knownTrackIds = tracks.compactMap(\.dbId)
        let loadedTracks: [Track] = (try? appState.db.read { db in
            try LibraryAlbumQuery.tracks(for: album, knownTrackIDs: knownTrackIds, in: db)
        }) ?? []

        tracks = loadedTracks
        orderedTrackIds = loadedTracks.compactMap(\.dbId)
        selection.retain(validIds: Set(orderedTrackIds))

        displayedAlbum = (try? appState.db.read { db in
            guard let albumId = loadedTracks.first?.albumId else { return nil }
            return try Album.fetchOne(db, key: albumId)
        }) ?? displayedAlbum
    }

    private var selectedTracks: [Track] {
        tracks.filter { $0.dbId.map(selection.contains) == true }
    }

    private func select(_ track: Track) {
        guard let trackId = track.dbId else { return }
        selection.select(trackId, in: orderedTrackIds, modifiers: currentSelectionModifiers())
    }

    private func clearSelection() {
        selection.clear()
    }

    private var trackMarqueeRect: CGRect? {
        guard let marqueeStart, let marqueeCurrent else { return nil }
        return CGRect(
            x: min(marqueeStart.x, marqueeCurrent.x),
            y: min(marqueeStart.y, marqueeCurrent.y),
            width: abs(marqueeStart.x - marqueeCurrent.x),
            height: abs(marqueeStart.y - marqueeCurrent.y)
        )
    }

    private var trackMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(trackListCoordinateSpace))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    trackFrames = [:]
                }
                marqueeCurrent = value.location
                updateTrackMarqueeSelection()
            }
            .onEnded { value in
                if marqueeStart != nil, marqueeCurrent != nil {
                    updateTrackMarqueeSelection()
                    self.marqueeStart = nil
                    self.marqueeCurrent = nil
                    trackFrames = [:]
                    return
                }
            }
    }

    private func updateTrackMarqueeSelection() {
        guard let trackMarqueeRect else { return }
        let ids = orderedTrackIds.filter { id in
            guard let frame = trackFrames[id] else { return false }
            return frame.intersects(trackMarqueeRect)
        }
        selection.replace(with: Set(ids))
    }

    private func currentSelectionModifiers() -> SelectionModifiers {
        var modifiers: SelectionModifiers = []
        if NSEvent.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if NSEvent.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func loadAccentColor() async {
        guard let albumId = currentAlbum.id,
              let cgImage = (try? appState.db.read { db -> CGImage? in
                  guard let alb = try Album.fetchOne(db, key: albumId),
                        let artId = alb.artworkId,
                        let art = try Artwork.fetchOne(db, key: artId)
                  else { return nil }
                  return art.imageLarge?.cgImage(forProposedRect: nil, context: nil, hints: nil)
              }) ?? nil else { return }

        let color = await Task.detached(priority: .utility) {
            Self.extractDominantColor(from: cgImage)
        }.value

        guard let color else { return }
        await MainActor.run { accentColor = color }
    }

    private static func extractDominantColor(from cgImage: CGImage) -> Color? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4,
                          bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255

        // RGB → HSB without NSColor (safe in Task.detached)
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        let saturation = maxC > 0 ? delta / maxC : 0
        let brightness = maxC

        // Too desaturated (B&W photo, gray cover): fall back to dAccent
        guard saturation > 0.12 else { return nil }

        var hue = 0.0
        if delta > 0 {
            if maxC == r      { hue = (g - b) / delta + (g < b ? 6 : 0) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else              { hue = (r - b) / delta + 4 }
            hue /= 6
        }

        // Use the hue direction from the artwork but always vivid enough for
        // button fills and gradient overlays to read clearly on a dark background.
        return Color(hue: hue, saturation: 0.68, brightness: 0.80)
    }
}

// MARK: - View extension helper

private extension View {
    func flexibleFrame() -> some View {
        self.fixedSize()
    }
}

// MARK: - TrackRow

struct TrackRow: View {
    let track: Track
    var sourcePlaylistId: Int64? = nil
    var showArtist: Bool = true
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var isSelected: Bool = false
    var selectedTrackIds: Set<Int64> = []
    var selectedTracksProvider: () -> [Track] = { [] }
    var accentColor: Color = Color.dAccent
    var horizontalPadding: CGFloat = 0
    var onPlay: (() -> Void)? = nil
    var onPlayNow: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @State private var isFavorite: Bool
    @State private var isHovered = false
    @State private var optimisticIsPlaying: Bool?
    @State private var isPlayButtonPressed = false

    init(track: Track, sourcePlaylistId: Int64? = nil, showArtist: Bool = true,
         isCurrent: Bool = false, isPlaying: Bool = false,
         isSelected: Bool = false, selectedTrackIds: Set<Int64> = [],
         selectedTracksProvider: @escaping () -> [Track] = { [] }, accentColor: Color = Color.dAccent,
         horizontalPadding: CGFloat = 0, onPlay: (() -> Void)? = nil,
         onPlayNow: (() -> Void)? = nil, onSelect: (() -> Void)? = nil) {
        self.track = track
        self.sourcePlaylistId = sourcePlaylistId
        self.showArtist = showArtist
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        self.selectedTrackIds = selectedTrackIds
        self.selectedTracksProvider = selectedTracksProvider
        self.accentColor = accentColor
        self.horizontalPadding = horizontalPadding
        self.onPlay = onPlay
        self.onPlayNow = onPlayNow
        self.onSelect = onSelect
        self._isFavorite = State(initialValue: track.isFavorite)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Track number / hover play / VU meter
            ZStack {
                if !track.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(selectedTertiaryForeground)
                } else if isHovered {
                    Image(systemName: pressedDisplayIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(selectedPrimaryForeground)
                        .frame(width: 36, height: 34, alignment: .center)
                        .contentShape(Rectangle())
                        .gesture(playButtonPressGesture)
                } else if isCurrent && isPlaying {
                    VUMeterInline(color: isSelected && AppTheme.current.isRetroMoonPod ? Color.bgContent : accentColor)
                } else {
                    Text(track.trackNumber.map(String.init) ?? "–")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(selectedTertiaryForeground)
                }
            }
            .frame(width: 36, height: 34, alignment: .center)

            // Title (+ artist if showArtist)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.isAvailable ? track.displayTitle : "\(track.displayTitle) — Unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedPrimaryForeground)
                    .lineLimit(1)
                if showArtist {
                    Text(track.displayArtist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(selectedSecondaryForeground)
                        .lineLimit(1)
                }
            }
            .padding(.leading, showArtist ? 10 : 0)

            Spacer()

            // Duration
            Text(track.durationFormatted)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(selectedTertiaryForeground)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 34)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            guard track.isAvailable else { return }
            showPlayNowFeedback()
        }
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { onSelect?() }
        )
        .animation(.easeOut(duration: 0.12), value: optimisticIsPlaying)
        .contextMenu {
            Menu("Add to Playlist") {
                if appState.playlists.isEmpty {
                    Text("No playlists yet")
                } else {
                    ForEach(appState.playlists) { playlist in
                        Button(playlist.name) {
                            if let id = playlist.id {
                                appState.addTracks(tracksForContextAction(), toPlaylist: id)
                            }
                        }
                    }
                }
            }
            Divider()
            if onPlay != nil || onPlayNow != nil {
                Button("Play Now") { showPlayNowFeedback() }
                    .disabled(!track.isAvailable)
                if !selectedTrackIds.isEmpty {
                    Button("Play Selected") {
                        let tracks = selectedTracksForAction().filter(\.isAvailable)
                        guard let first = tracks.first else { return }
                        appState.playbackController.play(track: first, in: tracks)
                    }
                    Button("Edit Selected Tags…") {
                        appState.editAlbumTags(title: "Edit Selected Tags", tracks: selectedTracksForAction().filter(\.isAvailable))
                    }
                }
                Divider()
            }
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                isFavorite.toggle()
                appState.toggleFavorite(track: track)
            }
            TrackRatingMenu(tracks: tracksForContextAction())
            Divider()
            Button("Edit Tags…") { appState.editTags(for: track) }
                .disabled(!track.isAvailable)
            Divider()
            Button(track.isAvailable ? "Reveal in Finder" : "File Unavailable") {
                appState.revealInFinder(track: track)
            }
            .disabled(!track.isAvailable)
        }
        .trackDragSource(
            for: track,
            sourcePlaylistId: sourcePlaylistId,
            selectedTrackIds: selectedTrackIds
        )
    }

    private var rowBackground: Color {
        TrackRowBackgroundKind
            .resolve(isSelected: isSelected, isCurrent: isCurrent, isHovered: isHovered)
            .color()
    }

    private var selectedPrimaryForeground: Color {
        isSelected && AppTheme.current.isRetroMoonPod ? Color.bgContent : Color.textPrimary
    }

    private var selectedSecondaryForeground: Color {
        isSelected && AppTheme.current.isRetroMoonPod ? Color.bgContent.opacity(0.86) : Color.textSecondary
    }

    private var selectedTertiaryForeground: Color {
        isSelected && AppTheme.current.isRetroMoonPod ? Color.bgContent.opacity(0.76) : Color.textTertiary
    }

    private func selectedTracksForAction() -> [Track] {
        selectedTracksProvider()
    }

    private func tracksForContextAction() -> [Track] {
        if let trackId = track.dbId, selectedTrackIds.contains(trackId) {
            return selectedTracksForAction()
        }
        return [track]
    }

    private var displayedIsPlaying: Bool {
        optimisticIsPlaying ?? isPlaying
    }

    private var pressedDisplayIsPlaying: Bool {
        isPlayButtonPressed ? (isCurrent ? !displayedIsPlaying : true) : displayedIsPlaying
    }

    private var playButtonPressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPlayButtonPressed else { return }
                isPlayButtonPressed = true
            }
            .onEnded { _ in
                isPlayButtonPressed = false
                showPlayFeedback()
            }
    }

    private func showPlayFeedback() {
        guard track.isAvailable else { return }
        optimisticIsPlaying = isCurrent ? !displayedIsPlaying : true
        onPlay?()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            optimisticIsPlaying = nil
        }
    }

    private func showPlayNowFeedback() {
        guard track.isAvailable else { return }
        optimisticIsPlaying = true
        (onPlayNow ?? onPlay)?()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            optimisticIsPlaying = nil
        }
    }
}

struct TrackRatingMenu: View {
    let tracks: [Track]
    @EnvironmentObject private var appState: AppState

    private var trackIDs: [Int64] {
        Array(Set(tracks.compactMap(\.dbId)))
    }

    var body: some View {
        Menu("Rate") {
            ForEach(1...5, id: \.self) { rating in
                Button(rating == 1 ? "1 Star" : "\(rating) Stars") {
                    try? appState.setRating(rating, forTrackIDs: trackIDs)
                }
            }
            Divider()
            Button("Clear Rating") {
                try? appState.setRating(nil, forTrackIDs: trackIDs)
            }
        }
        .disabled(trackIDs.isEmpty)
    }
}
