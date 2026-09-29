// NowPlayingView.swift
//
// The full-window Now Playing screen. It shows large artwork, the song or radio station details,
// playback controls, a time bar and an expandable "Up Next" queue, with a background that can
// tint to match the artwork or play a looping video scene. Controls fade away when the mouse is
// idle, and each retro theme gets its own styled version.

import SwiftUI
import AppKit
import Combine
import GRDB

struct NowPlayingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: PlaybackController

    @State private var accentColor = Color.dAccent
    @State private var isQueueExpanded = false
    @State private var isInteractionVisible = true
    @State private var hideInteractionTask: Task<Void, Never>?

    private var currentTrack: Track? { controller.currentTrack }
    private var currentRadioStation: RadioStation? { controller.currentRadioStation }
    private var isSceneActive: Bool { appState.sceneEnabled && appState.sceneURL != nil }
    private var interactionOpacity: Double { isInteractionVisible || isQueueExpanded ? 1 : 0 }
    private var allowsInteractionHitTesting: Bool { isInteractionVisible || isQueueExpanded }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                sceneBackground(size: proxy.size)
                    .ignoresSafeArea()

                if let track = currentTrack {
                    ScrollView {
                        nowPlayingContent(for: track, size: proxy.size)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)

                    queueDisclosure
                        .padding(.trailing, 22)
                        .padding(.top, isSceneActive && controller.isPlaying ? 18 : 0)
                        .padding(.bottom, isSceneActive && controller.isPlaying ? 0 : 18)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: isSceneActive && controller.isPlaying ? .topTrailing : .bottomTrailing
                        )
                        .opacity(interactionOpacity)
                        .allowsHitTesting(allowsInteractionHitTesting)
                } else if let station = currentRadioStation {
                    ScrollView {
                        radioNowPlayingContent(for: station, size: proxy.size)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                nowPlayingChromeControls
                    .padding(.top, 14)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(interactionOpacity)
                    .allowsHitTesting(allowsInteractionHitTesting)
            }
            .contentShape(Rectangle())
            .background(
                NowPlayingPointerActivityReader(
                    onPointerActivity: {
                        guard NSApp.isActive else { return }
                        showInteractions()
                        scheduleInteractionHide()
                    },
                    onPointerExit: {
                        scheduleInteractionHide()
                    },
                    onWindowInactive: {
                        hideInteractions()
                    }
                )
            )
            .onChange(of: isQueueExpanded) { _, expanded in
                if expanded {
                    showInteractions()
                } else {
                    scheduleInteractionHide()
                }
            }
        }
        .background(Color.bgContent)
        .animation(.easeInOut(duration: 0.18), value: interactionOpacity)
        .onAppear {
            showInteractions()
            scheduleInteractionHide()
        }
        .onDisappear {
            hideInteractionTask?.cancel()
            hideInteractionTask = nil
        }
        .task(id: accentColorTaskKey) {
            await loadAccentColor()
        }
        .onExitCommand {
            appState.exitNowPlaying()
        }
    }

    private var accentColorTaskKey: String {
        if let station = currentRadioStation {
            return "radio-\(station.stationUUID)"
        }

        guard let track = currentTrack else {
            return "nil-\(appState.libraryVersion)"
        }

        let artworkKey = track.artworkId.map(String.init) ?? "nil"
        let albumKey = track.albumId.map(String.init) ?? "nil"
        return "\(artworkKey)-\(albumKey)-\(appState.libraryVersion)"
    }

    private var nowPlayingChromeControls: some View {
        HStack(spacing: 0) {
            NowPlayingChromeButton(icon: "xmark", help: "Collapse Now Playing") {
                appState.exitNowPlaying()
            }

            if currentRadioStation == nil {
                NowPlayingChromeButton(icon: "rectangle.on.rectangle", help: "Open Mini Player") {
                    appState.enterMiniPlayer()
                }
            }

            NowPlayingSceneMenu()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            Group {
                if AppTheme.current.transportChromeStyle == .terminal {
                    Rectangle()
                        .fill(Color.bgChrome)
                        .overlay(Rectangle().stroke(Color.dAccent.opacity(0.84), lineWidth: 1))
                } else if AppTheme.current.transportChromeStyle == .retroMoonPod {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.bgChrome)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(0.11))
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                }
            }
        )
        .shadow(color: .black.opacity((AppTheme.current.transportChromeStyle == .retroMoonPod || AppTheme.current.transportChromeStyle == .terminal) ? 0 : 0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private func sceneBackground(size: CGSize) -> some View {
        backgroundGradient(size: size)

        if appState.sceneEnabled, let sceneURL = appState.sceneURL {
            ScenePlayerView(url: sceneURL, isEnabled: appState.sceneEnabled)
                .allowsHitTesting(false)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.42), location: 0),
                    .init(color: Color.black.opacity(0.30), location: 0.45),
                    .init(color: Color.black.opacity(0.58), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if AppTheme.current.transportChromeStyle == .terminal {
                ScanlineOverlay()
                TerminalVignetteOverlay()
            }
        }
    }

    private func backgroundGradient(size: CGSize) -> some View {
        let longestSide = max(size.width, size.height)

        return ZStack {
            if AppTheme.current.transportChromeStyle == .terminal {
                Color.bgContent

                // Phosphor ambient — faint green glow bleeding across the whole screen face
                RadialGradient(
                    gradient: Gradient(colors: [Color.dAccent.opacity(0.06), Color.clear]),
                    center: .center,
                    startRadius: 60,
                    endRadius: 480
                )

                RadialGradient(
                    stops: [
                        .init(color: Color.dAccent.opacity(0.18), location: 0),
                        .init(color: Color(hex: "#20c8ff").opacity(0.08), location: 0.42),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 120,
                    endRadius: max(760, longestSide * 0.86)
                )

                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.035), location: 0),
                        .init(color: Color.clear, location: 0.30),
                        .init(color: Color.black.opacity(0.62), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                ScanlineOverlay()
                TerminalVignetteOverlay()
            } else if AppTheme.current.transportChromeStyle == .moonamp {
                LinearGradient(
                    colors: [
                        Color(hex: "#2f334f"),
                        Color(hex: "#1f223a"),
                        Color(hex: "#121427")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    stops: [
                        .init(color: Color(hex: "#4b506f").opacity(0.28), location: 0),
                        .init(color: Color(hex: "#252944").opacity(0.20), location: 0.46),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 120,
                    endRadius: max(700, longestSide * 0.82)
                )

                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.06), location: 0),
                        .init(color: Color.clear, location: 0.28),
                        .init(color: Color.black.opacity(0.34), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if AppTheme.current.transportChromeStyle == .moonPod {
                LinearGradient(
                    colors: [
                        Color(hex: "#fbfaf6"),
                        Color(hex: "#eff3f4")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if AppTheme.current.transportChromeStyle == .retroMoonPod {
                Color.bgContent
            } else {
                Color.bgContent

                RadialGradient(
                    stops: [
                        .init(color: accentColor.opacity(0.58), location: 0),
                        .init(color: accentColor.opacity(0.28), location: 0.34),
                        .init(color: accentColor.opacity(0.10), location: 0.64),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 80,
                    endRadius: max(720, longestSide * 0.92)
                )

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.10), location: 0),
                        .init(color: Color.bgContent.opacity(0.10), location: 0.48),
                        .init(color: Color.black.opacity(0.28), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func nowPlayingContent(for track: Track, size: CGSize) -> some View {
        if isSceneActive && controller.isPlaying {
            return AnyView(sceneNowPlayingContent(for: track, size: size))
        }

        if AppTheme.current.transportChromeStyle == .terminal {
            return AnyView(terminalNowPlayingContent(for: track, size: size))
        }

        if AppTheme.current.transportChromeStyle == .moonamp {
            return AnyView(moonampNowPlayingContent(for: track, size: size))
        }

        if AppTheme.current.transportChromeStyle == .retroMoonPod {
            return AnyView(retroMoonPodNowPlayingContent(for: track, size: size))
        }

        return AnyView(standardNowPlayingContent(for: track, size: size))
    }

    private func radioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        if isSceneActive && controller.isPlaying {
            return AnyView(sceneRadioNowPlayingContent(for: station, size: size))
        }

        if AppTheme.current.transportChromeStyle == .terminal {
            return AnyView(terminalRadioNowPlayingContent(for: station, size: size))
        }

        if AppTheme.current.transportChromeStyle == .moonamp {
            return AnyView(moonampRadioNowPlayingContent(for: station, size: size))
        }

        if AppTheme.current.transportChromeStyle == .retroMoonPod {
            return AnyView(retroMoonPodRadioNowPlayingContent(for: station, size: size))
        }

        return AnyView(standardRadioNowPlayingContent(for: station, size: size))
    }

    private func standardRadioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        let side = artworkSize(for: size)

        return VStack(spacing: 0) {
            Spacer(minLength: max(32, size.height * 0.08))

            radioArtworkPlaceholder(side: side, cornerRadius: 10)
                .shadow(
                    color: .black.opacity(AppTheme.current.transportChromeStyle == .moonPod ? 0.10 : 0.34),
                    radius: AppTheme.current.transportChromeStyle == .moonPod ? 8 : 28,
                    y: AppTheme.current.transportChromeStyle == .moonPod ? 3 : 14
                )

            radioMetadata(for: station)
                .frame(width: min(720, max(360, size.width * 0.62)))
                .padding(.top, 28)

            radioLiveStatus
                .frame(width: min(500, max(320, size.width * 0.44)))
                .padding(.top, 34)

            radioControls
                .padding(.top, 24)
                .opacity(interactionOpacity)
                .allowsHitTesting(allowsInteractionHitTesting)

            Spacer(minLength: 64)
        }
        .padding(.horizontal, 40)
    }

    private func sceneRadioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        let contentWidth = min(620, max(340, size.width * 0.54))

        return VStack {
            Spacer(minLength: 0)

            VStack(spacing: 11) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(AppTheme.current.font(.icon, size: 30, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.55), radius: 8, y: 2)

                VStack(spacing: 3) {
                    Text(AppTheme.current.displayText(station.name))
                        .font(AppTheme.current.font(.title, size: 20, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text(AppTheme.current.displayText(radioLocationLine(for: station)))
                        .font(AppTheme.current.font(.body, size: 13.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .lineLimit(1)
                }

                radioLiveStatus
                    .foregroundStyle(Color.white.opacity(0.88))

                radioControls
                    .opacity(interactionOpacity)
                    .allowsHitTesting(allowsInteractionHitTesting)
            }
            .frame(width: contentWidth)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, minHeight: size.height)
    }

    private func retroMoonPodRadioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        let panelWidth = min(980, max(620, size.width * 0.70))
        let compositionTopInset = max(82, min(150, size.height * 0.095))

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: controller.isPlaying ? "play.fill" : "pause.fill")
                    .font(AppTheme.current.font(.icon, size: 18, weight: .medium))
                    .frame(width: 36, alignment: .leading)
                Spacer()
                Text("Live Radio")
                    .font(AppTheme.current.font(.title, size: 24, weight: .medium))
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(AppTheme.current.font(.icon, size: 18, weight: .medium))
                    .frame(width: 36, alignment: .trailing)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(height: 40)
            .padding(.horizontal, 18)
            .background(Color.bgChrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.dAccent).frame(height: 1)
            }

            VStack(spacing: 16) {
                Spacer(minLength: max(100, size.height * 0.18))

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(AppTheme.current.font(.icon, size: 62, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                radioMetadata(for: station, titleSize: 40, detailSize: 20)
                    .padding(.horizontal, 28)

                radioLiveStatus
                    .padding(.top, 28)

                retroMoonPodTransportButton(
                    icon: controller.isPlaying ? "pause.fill" : "play.fill",
                    size: 30,
                    frameSize: 52,
                    action: { controller.togglePlayPause() }
                )
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
        }
        .frame(width: panelWidth)
        .frame(minHeight: size.height)
        .background(Color.bgContent)
        .padding(.top, compositionTopInset)
        .padding(.horizontal, 28)
    }

    private func moonampRadioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        return VStack(spacing: 26) {
            Spacer(minLength: max(10, size.height * 0.018))

            moonampHeader
                .frame(maxWidth: min(900, size.width * 0.68))

            ZStack {
                MoonampNowPlayingSpectrum()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 14) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(AppTheme.current.font(.icon, size: 54, weight: .medium))
                        .foregroundStyle(Color.dAccent)
                    Text("LIVE STREAM")
                        .font(AppTheme.current.font(.control, size: 16, weight: .medium))
                        .tracking(1.6)
                        .foregroundStyle(Color.dAccent.opacity(0.80))
                }
            }
            .frame(width: min(1180, size.width - 92), height: min(500, max(310, size.height * 0.44)))
            .background(MoonampNowPlayingLCDBox())
            .overlay(Rectangle().stroke(Color(hex: "#090a13"), lineWidth: 5).padding(2))
            .overlay(Rectangle().stroke(Color(hex: "#5e607b"), lineWidth: 2).padding(8))
            .shadow(color: .black.opacity(0.36), radius: 26, y: 16)

            VStack(spacing: 16) {
                radioMetadata(for: station, titleSize: 39, detailSize: 20)
                    .foregroundStyle(Color(hex: "#c8d3de"))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 17)
                    .frame(width: min(980, size.width - 140))
                    .background(MoonampNowPlayingLCDBox())

                radioControls
                    .opacity(interactionOpacity)
                    .allowsHitTesting(allowsInteractionHitTesting)
            }

            Spacer(minLength: 84)
        }
        .padding(.horizontal, 46)
    }

    private func terminalRadioNowPlayingContent(for station: RadioStation, size: CGSize) -> some View {
        let iconSide = min(300, max(190, min(size.width, size.height) * 0.34))

        return VStack(spacing: 18) {
            Spacer(minLength: max(18, size.height * 0.035))

            TerminalBannerTitle(size: min(14, max(9, size.width * 0.014)))
                .frame(maxWidth: min(1040, size.width - 90))

            VStack(spacing: 0) {
                TerminalStatusLine(title: "LIVE RADIO", rightText: controller.isPlaying ? "RECEIVING" : "PAUSED")

                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 8) {
                        Text("┌─ STREAM ─┐")
                            .font(AppTheme.current.font(.metadata, size: 15, weight: .medium))
                            .foregroundStyle(Color.dAccentStrong)

                        ZStack {
                            Color.black.opacity(0.46)
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(AppTheme.current.font(.icon, size: iconSide * 0.25, weight: .medium))
                                .foregroundStyle(Color.dAccentStrong)
                                .shadow(color: Color.dAccent.opacity(0.55), radius: 5)
                        }
                        .frame(width: iconSide, height: iconSide)
                        .overlay(Rectangle().stroke(Color.dAccent, lineWidth: 2))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        terminalField(label: "STATION", value: station.name)
                        terminalField(label: "REGION", value: radioLocationLine(for: station))
                        terminalField(label: "GENRE", value: radioGenreLine(for: station))
                        terminalField(label: "FORMAT", value: radioQualityLine(for: station))

                        Spacer(minLength: 0)

                        radioLiveStatus
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(TerminalNowPlayingBox())

                        radioControls
                            .opacity(interactionOpacity)
                            .allowsHitTesting(allowsInteractionHitTesting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .frame(width: min(1080, size.width - 74))
            .frame(minHeight: min(560, max(430, size.height * 0.58)))
            .background(TerminalNowPlayingBox())

            Spacer(minLength: 72)
        }
        .padding(.horizontal, 38)
    }

    private func radioArtworkPlaceholder(side: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.bgElevated.opacity(0.72))
            RadialGradient(
                colors: [Color.dAccent.opacity(0.22), Color.clear],
                center: .center,
                startRadius: 12,
                endRadius: side * 0.52
            )
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(AppTheme.current.font(.icon, size: side * 0.22, weight: .medium))
                .foregroundStyle(Color.dAccent)
        }
        .frame(width: side, height: side)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.borderMedium.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live radio")
    }

    private func radioMetadata(
        for station: RadioStation,
        titleSize: CGFloat = 22,
        detailSize: CGFloat = 16
    ) -> some View {
        VStack(spacing: 8) {
            Text(AppTheme.current.displayText(station.name))
                .font(AppTheme.current.font(.title, size: titleSize, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.48)
                .multilineTextAlignment(.center)

            Text(AppTheme.current.displayText("\(radioLocationLine(for: station)) · \(radioQualityLine(for: station))"))
                .font(AppTheme.current.font(.body, size: detailSize, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .multilineTextAlignment(.center)
        }
    }

    private var radioLiveStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isPlaying ? Color.red : Color.textTertiary)
                .frame(width: 7, height: 7)
            Text(controller.isPlaying ? "LIVE" : "PAUSED")
                .font(AppTheme.current.font(.metadata, size: 11, weight: .semibold))
                .tracking(1.1)
        }
        .foregroundStyle(Color.textSecondary)
        .frame(height: 20)
    }

    private var radioControls: some View {
        Button {
            controller.togglePlayPause()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(AppTheme.current.font(.icon, size: 34, weight: .semibold))
                .foregroundStyle(AppTheme.current.transportChromeStyle == .moonamp ? Color(hex: "#596777") : Color.textPrimary)
                .frame(width: 64, height: 64)
                .background(NowPlayingPlayButtonBackground())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.isPlaying ? "Pause" : "Play")
    }

    private func radioLocationLine(for station: RadioStation) -> String {
        station.country ?? station.countryCode ?? "Live Radio"
    }

    private func radioGenreLine(for station: RadioStation) -> String {
        let genres = station.tags.prefix(2).joined(separator: ", ")
        return genres.isEmpty ? "Live Radio" : genres
    }

    private func radioQualityLine(for station: RadioStation) -> String {
        let parts = [
            station.codec?.uppercased(),
            station.bitrate > 0 ? "\(station.bitrate) kbps" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "Live stream" : parts.joined(separator: " · ")
    }

    private func sceneNowPlayingContent(for track: Track, size: CGSize) -> some View {
        let contentWidth = min(620, max(340, size.width * 0.54))

        return VStack {
            Spacer(minLength: 0)

            VStack(alignment: .center, spacing: 11) {
                VStack(alignment: .center, spacing: 3) {
                    ShowTrackInAlbumButton(track: track) {
                        Text(AppTheme.current.displayText(track.displayTitle))
                            .font(AppTheme.current.font(.title, size: 20, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.96))
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                    }

                    Text(AppTheme.current.displayText(track.displayArtist))
                        .font(AppTheme.current.font(.body, size: 13.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                }

                SceneNowPlayingScrubberView()
                    .frame(height: 18)
                    .allowsHitTesting(allowsInteractionHitTesting)

                sceneControls
                    .opacity(interactionOpacity)
                    .allowsHitTesting(allowsInteractionHitTesting)
            }
            .frame(width: contentWidth, alignment: .center)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, minHeight: size.height)
    }

    private func standardNowPlayingContent(for track: Track, size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: max(32, size.height * 0.08))

            ShowTrackInAlbumButton(track: track) {
                ArtworkView(
                    albumId: track.albumId,
                    artworkId: track.artworkId,
                    large: true,
                    decodeMaxPixelSize: Int(artworkSize(for: size) * 2),
                    cornerRadius: 10,
                    iconFont: .system(size: 76),
                    retainsPreviousImageWhileLoading: true
                )
                .frame(width: artworkSize(for: size), height: artworkSize(for: size))
                .shadow(
                    color: .black.opacity(AppTheme.current.transportChromeStyle == .moonPod ? 0.10 : 0.48),
                    radius: AppTheme.current.transportChromeStyle == .moonPod ? 8 : 34,
                    y: AppTheme.current.transportChromeStyle == .moonPod ? 3 : 16
                )
                .overlay {
                    if AppTheme.current.transportChromeStyle == .moonPod {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.borderMedium.opacity(0.22), lineWidth: 1)
                    }
                }
            }

            trackMetadata(for: track)
                .frame(width: min(720, max(360, size.width * 0.62)))
                .padding(.top, 28)

            if AppTheme.current.transportChromeStyle == .moonPod {
                MoonPodNowPlayingScrubberView()
                    .frame(width: min(500, max(320, size.width * 0.44)))
                    .padding(.top, 34)
            } else {
                ScrubberView()
                    .frame(width: min(500, max(320, size.width * 0.44)))
                    .padding(.top, 34)
            }

            controls
                .padding(.top, 24)
                .opacity(interactionOpacity)
                .allowsHitTesting(allowsInteractionHitTesting)

            Spacer(minLength: 64)
        }
        .padding(.horizontal, 40)
    }

    private func retroMoonPodNowPlayingContent(for track: Track, size: CGSize) -> some View {
        let panelWidth = min(980, max(620, size.width * 0.70))
        let compositionTopInset = max(82, min(150, size.height * 0.095))
        let metadataToScrubberSpacing = max(64, min(112, size.height * 0.14))
        let chromeHeight: CGFloat = 72
        let playbackStackHeight: CGFloat = 258 + metadataToScrubberSpacing
        let playbackStackTopInset = max(120, (size.height - chromeHeight - playbackStackHeight) / 2)
        let scrubberWidth = min(700, panelWidth - 72)
        let queuePositionText = controller.queue.isEmpty ? "0 of 0" : "\(controller.currentIndex + 1) of \(controller.queue.count)"

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: controller.isPlaying ? "play.fill" : "pause.fill")
                    .font(AppTheme.current.font(.icon, size: 18, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 36, alignment: .leading)

                Spacer()
                Text("Now Playing")
                    .font(AppTheme.current.font(.title, size: 24, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer()

                Image(systemName: "battery.100")
                    .font(AppTheme.current.font(.icon, size: 18, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 36, alignment: .trailing)
            }
            .frame(height: 40)
            .padding(.horizontal, 18)
            .background(Color.bgChrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.dAccent).frame(height: 1)
            }

            HStack {
                Text(queuePositionText)
                    .font(AppTheme.current.font(.numeric, size: 17, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Image(systemName: "shuffle")
                    .font(AppTheme.current.font(.icon, size: 17, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
            }
            .frame(height: 32)
            .padding(.horizontal, 18)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: playbackStackTopInset)

                VStack(spacing: 5) {
                    ShowTrackInAlbumButton(track: track) {
                        Text(AppTheme.current.displayText(track.displayTitle))
                            .font(AppTheme.current.font(.title, size: 40, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(AppTheme.current.displayText(track.displayArtist))
                        .font(AppTheme.current.font(.metadata, size: 22, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(AppTheme.current.displayText(track.displayAlbum))
                        .font(AppTheme.current.font(.metadata, size: 18, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)

                Spacer()
                    .frame(height: metadataToScrubberSpacing)

                RetroMoonPodNowPlayingScrubberView()
                    .frame(width: scrubberWidth)

                HStack(spacing: 38) {
                    retroMoonPodTransportButton(
                        icon: "backward.fill",
                        size: 23,
                        frameSize: 42,
                        action: { controller.skipPrevious() }
                    )
                    retroMoonPodTransportButton(
                        icon: controller.isPlaying ? "pause.fill" : "play.fill",
                        size: 30,
                        frameSize: 52,
                        action: { controller.togglePlayPause() }
                    )
                    retroMoonPodTransportButton(
                        icon: "forward.fill",
                        size: 23,
                        frameSize: 42,
                        action: { controller.skipNext() }
                    )
                }
                .padding(.top, 18)

                Spacer(minLength: 0)
            }
            .frame(minHeight: max(0, size.height - chromeHeight), alignment: .top)
        }
        .frame(width: panelWidth)
        .frame(minHeight: size.height)
        .background(Color.bgContent)
        .padding(.top, compositionTopInset)
        .padding(.horizontal, 28)
    }

    private func retroMoonPodTransportButton(
        icon: String,
        size: CGFloat,
        frameSize: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: size, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moonampNowPlayingContent(for track: Track, size: CGSize) -> some View {
        let timeBoxHeight = min(170, max(112, size.height * 0.16))
        let timeArtworkSize = min(120, max(86, timeBoxHeight * 0.74))

        return VStack(spacing: 26) {
            Spacer(minLength: max(10, size.height * 0.018))

            moonampHeader
                .frame(maxWidth: min(900, size.width * 0.68))

            ZStack {
                MoonampNowPlayingSpectrum()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MoonampNowPlayingTime(track: track, artworkSize: timeArtworkSize)
                    .frame(width: min(640, max(470, size.width * 0.42)), height: timeBoxHeight)
                    .padding(22)
            }
            .frame(width: min(1180, size.width - 92), height: min(500, max(310, size.height * 0.44)))
            .background(MoonampNowPlayingLCDBox())
            .overlay(Rectangle().stroke(Color(hex: "#090a13"), lineWidth: 5).padding(2))
            .overlay(Rectangle().stroke(Color(hex: "#5e607b"), lineWidth: 2).padding(8))
            .shadow(color: .black.opacity(0.36), radius: 26, y: 16)

            VStack(spacing: 16) {
                VStack(alignment: .center, spacing: 8) {
                    ShowTrackInAlbumButton(track: track) {
                        Text(AppTheme.current.displayText(track.displayTitle))
                            .font(AppTheme.current.font(.title, size: 39, weight: .medium))
                            .foregroundStyle(Color(hex: "#c8d3de"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.42)
                    }
                    Text(AppTheme.current.displayText(artistAlbumLine(for: track)))
                        .font(AppTheme.current.font(.body, size: 24, weight: .medium))
                        .foregroundStyle(Color(hex: "#9eadbd"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.52)

                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        moonampInlineInfo(value: bitRateText(for: track), label: "kbps")
                        moonampInlineInfo(value: sampleRateText(for: track), label: "kHz")
                        Text(channelText(for: track))
                            .font(AppTheme.current.font(.control, size: 19, weight: .medium))
                            .foregroundStyle(Color(hex: "#c8d3de").opacity(0.84))
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 17)
                .frame(width: min(980, size.width - 140))
                .background(MoonampNowPlayingLCDBox())

                ScrubberView()
                    .frame(width: min(760, size.width - 220))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(MoonampNowPlayingLCDBox())

                controls
                    .opacity(interactionOpacity)
                    .allowsHitTesting(allowsInteractionHitTesting)
            }

            Spacer(minLength: 84)
        }
        .padding(.horizontal, 46)
    }

    private func terminalNowPlayingContent(for track: Track, size: CGSize) -> some View {
        let artworkSide = min(300, max(190, min(size.width, size.height) * 0.34))

        return VStack(spacing: 18) {
            Spacer(minLength: max(18, size.height * 0.035))

            TerminalBannerTitle(size: min(14, max(9, size.width * 0.014)))
                .frame(maxWidth: min(1040, size.width - 90))

            VStack(spacing: 0) {
                TerminalStatusLine(title: "NOW PLAYING", rightText: controller.isPlaying ? "RUNNING" : "PAUSED")

                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 8) {
                        Text("┌─ ARTWORK ─┐")
                            .font(AppTheme.current.font(.metadata, size: 15, weight: .medium))
                            .foregroundStyle(Color.dAccentStrong)
                            .lineLimit(1)

                        ShowTrackInAlbumButton(track: track) {
                            ArtworkView(
                                albumId: track.albumId,
                                artworkId: track.artworkId,
                                large: true,
                                decodeMaxPixelSize: Int(artworkSide * 2),
                                cornerRadius: 0,
                                iconFont: .system(size: max(38, artworkSide * 0.22)),
                                retainsPreviousImageWhileLoading: true
                            )
                            .artworkTreatment(AppTheme.current.defaultArtworkTreatment)
                            .frame(width: artworkSide, height: artworkSide)
                            .overlay(Rectangle().stroke(Color.dAccent, lineWidth: 2))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ShowTrackInAlbumButton(track: track) {
                            terminalField(label: "TRACK", value: track.displayTitle)
                        }
                        terminalField(label: "ARTIST", value: track.displayArtist)
                        terminalField(label: "ALBUM", value: track.displayAlbum)
                        terminalField(label: "CODEC", value: (track.format ?? URL(string: track.fileURL)?.pathExtension ?? "audio").uppercased())

                        HStack(spacing: 14) {
                            terminalMetric(value: bitRateText(for: track), label: "KBPS")
                            terminalMetric(value: sampleRateText(for: track), label: "KHZ")
                            terminalMetric(value: channelText(for: track).uppercased(), label: "CH")
                        }

                        Spacer(minLength: 0)

                        ScrubberView()
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(TerminalNowPlayingBox())

                        controls
                            .opacity(interactionOpacity)
                            .allowsHitTesting(allowsInteractionHitTesting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .frame(width: min(1080, size.width - 74))
            .frame(minHeight: min(560, max(430, size.height * 0.58)))
            .background(TerminalNowPlayingBox())

            queuePeek(for: track)
                .frame(width: min(1080, size.width - 74))

            Spacer(minLength: 72)
        }
        .padding(.horizontal, 38)
    }

    private func terminalField(label: String, value: String) -> some View {
        let isTrack = label == "TRACK"
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(label)>")
                .font(AppTheme.current.font(.caption, size: 14, weight: .medium))
                .foregroundStyle(Color(hex: "#20c8ff"))
                .shadow(color: Color(hex: "#20c8ff").opacity(0.45), radius: 3)
            Text(AppTheme.current.displayText(value))
                .font(AppTheme.current.font(.title, size: isTrack ? 30 : 22, weight: .medium))
                .foregroundStyle(isTrack ? Color.dAccentStrong : Color.textPrimary)
                .shadow(color: Color.dAccent.opacity(isTrack ? 0.55 : 0.30), radius: isTrack ? 4 : 3)
                .lineLimit(1)
                .minimumScaleFactor(0.44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalNowPlayingBox())
    }

    private func terminalMetric(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(AppTheme.current.displayText(value))
                .font(AppTheme.current.font(.numeric, size: 20, weight: .medium))
                .foregroundStyle(Color.dAccentStrong)
                .shadow(color: Color.dAccent.opacity(0.50), radius: 4)
            Text(label)
                .font(AppTheme.current.font(.caption, size: 13, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .shadow(color: Color.dAccent.opacity(0.25), radius: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(TerminalNowPlayingBox())
    }

    private func queuePeek(for track: Track) -> some View {
        HStack(spacing: 8) {
            Text("QUEUE>")
                .font(AppTheme.current.font(.control, size: 14, weight: .medium))
                .foregroundStyle(Color(hex: "#20c8ff"))
                .shadow(color: Color(hex: "#20c8ff").opacity(0.45), radius: 3)
            Text(AppTheme.current.displayText(artistAlbumLine(for: track)))
                .font(AppTheme.current.font(.metadata, size: 14, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .shadow(color: Color.dAccent.opacity(0.25), radius: 3)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(TerminalNowPlayingBox())
    }

    private var moonampHeader: some View {
        HStack(spacing: 14) {
            MoonampNowPlayingGoldStripe()
            Text("MOONAMP")
                .font(AppTheme.current.font(.brand, size: 36, weight: .bold))
                .foregroundStyle(Color(hex: "#dfe5f2"))
                .shadow(color: Color.black.opacity(0.65), radius: 0, x: 2, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.50)
                .layoutPriority(1)
            MoonampNowPlayingGoldStripe()
        }
        .frame(height: 48)
    }

    private func moonampInlineInfo(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(AppTheme.current.font(.numeric, size: 18, weight: .medium))
                .foregroundStyle(Color(hex: "#c8d3de").opacity(0.88))
                .frame(minWidth: 42, alignment: .trailing)

            Text(label)
                .font(AppTheme.current.font(.control, size: 16, weight: .medium))
                .foregroundStyle(Color(hex: "#eef1f7").opacity(0.72))
        }
    }

    private func trackMetadata(for track: Track) -> some View {
        VStack(spacing: 8) {
            ShowTrackInAlbumButton(track: track) {
                Text(AppTheme.current.displayText(track.displayTitle))
                    .font(AppTheme.current.font(.title, size: 22, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }

            Text(AppTheme.current.displayText(artistAlbumLine(for: track)))
                .font(AppTheme.current.font(.body, size: 16, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)

        }
    }

    private func artistAlbumLine(for track: Track) -> String {
        let artist = track.displayArtist
        let album = track.displayAlbum
        guard album != "Unknown Album" else { return artist }
        return "\(artist) - \(album)"
    }

    private var controls: some View {
        HStack(spacing: 26) {
            TransportIconButton(
                icon: "shuffle",
                size: 18,
                frameSize: 38,
                isActive: controller.isShuffled,
                action: { controller.toggleShuffle() }
            )

            TransportIconButton(
                icon: "backward.fill",
                size: 28,
                frameSize: 50,
                action: { controller.skipPrevious() }
            )

            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(AppTheme.current.font(.icon, size: 34, weight: .semibold))
                    .foregroundStyle(AppTheme.current.transportChromeStyle == .moonamp ? Color(hex: "#596777") : Color.textPrimary)
                    .frame(width: 64, height: 64)
                    .background(NowPlayingPlayButtonBackground())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isPlaying ? "Pause" : "Play")

            TransportIconButton(
                icon: "forward.fill",
                size: 28,
                frameSize: 50,
                action: { controller.skipNext() }
            )

            TransportIconButton(
                icon: controller.repeatMode == .one ? "repeat.1" : "repeat",
                size: 18,
                frameSize: 38,
                isActive: controller.repeatMode != .off,
                action: { controller.cycleRepeatMode() }
            )
        }
    }

    private var sceneControls: some View {
        controls
    }

    private var queueDisclosure: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isSceneActive && controller.isPlaying {
                queueButton

                if isQueueExpanded {
                    queuePanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            } else {
                if isQueueExpanded {
                    queuePanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                queueButton
            }
        }
    }

    private var queueButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isQueueExpanded.toggle()
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "list.bullet")
                    .font(AppTheme.current.font(.icon, size: 14, weight: .semibold))
                Text("Up Next")
                    .font(AppTheme.current.font(.control, size: 12.5, weight: .semibold))
                Text(queueSummary)
                    .font(AppTheme.current.font(.numeric, size: 11.5))
                    .foregroundStyle(Color.textTertiary)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(height: 34)
            .padding(.horizontal, 13)
            .background(
                Group {
                    if AppTheme.current.transportChromeStyle == .retroMoonPod {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.bgChrome)
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.borderMedium, lineWidth: 0.5))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(isQueueExpanded ? "Hide Up Next" : "Show Up Next")
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(AppTheme.current.font(.title, size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(queueSummary)
                    .font(AppTheme.current.font(.numeric, size: 11.5))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Rectangle()
                .fill(Color.borderSoft)
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(controller.queue.enumerated()), id: \.element.dbId) { index, track in
                        NowPlayingQueueRow(
                            index: index,
                            track: track,
                            isCurrent: currentTrack?.hasSameIdentity(as: track) == true,
                            isPlaying: currentTrack?.hasSameIdentity(as: track) == true && controller.isPlaying,
                            accentColor: accentColor,
                            onPlay: { controller.play(track: track, in: controller.queue) }
                        )
                    }
                }
            }
        }
        .frame(width: 360, height: 340)
        .background(
            Group {
                if AppTheme.current.transportChromeStyle == .retroMoonPod {
                    Rectangle()
                        .fill(Color.bgElevated)
                } else {
                    RoundedRectangle(cornerRadius: DS.radiusCard)
                        .fill(Color.bgElevated.opacity(0.62))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusCard)
                                .strokeBorder(Color.borderMedium, lineWidth: 0.5)
                        )
                }
            }
        )
        .shadow(color: .black.opacity(AppTheme.current.transportChromeStyle == .retroMoonPod ? 0 : 0.28), radius: 24, y: 12)
    }

    private var queueSummary: String {
        guard !controller.queue.isEmpty else { return "0" }
        return "\(controller.currentIndex + 1)/\(controller.queue.count)"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ArtworkView(albumId: nil, large: true, cornerRadius: 14, iconFont: .system(size: 66))
                .frame(width: 220, height: 220)
                .opacity(0.72)

            VStack(spacing: 6) {
                Text("Not Playing")
                    .font(AppTheme.current.font(.title, size: 24, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Choose something from your library to start listening.")
                    .font(AppTheme.current.font(.body, size: 13))
                    .foregroundStyle(Color.textSecondary)
            }

            Button {
                appState.selectedSidebarItem = .albums
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                    Text("Browse Albums")
                }
                .font(AppTheme.current.font(.control, size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "#0a0a0e"))
                .frame(height: 32)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: DS.radiusControl).fill(Color.dAccent))
            }
            .buttonStyle(.plain)
        }
    }

    private func artworkSize(for size: CGSize) -> CGFloat {
        let available = min(size.width * 0.42, size.height * 0.48)
        return min(430, max(270, available))
    }

    private func bitRateText(for track: Track) -> String {
        guard let bitRate = track.bitRate, bitRate > 0 else { return "---" }
        return "\(bitRate > 1000 ? bitRate / 1000 : bitRate)"
    }

    private func sampleRateText(for track: Track) -> String {
        guard let sampleRate = track.sampleRate, sampleRate > 0 else { return "--" }
        return "\(Int((Double(sampleRate) / 1000).rounded()))"
    }

    private func channelText(for track: Track) -> String {
        guard let channelCount = track.channelCount, channelCount > 0 else { return "stereo" }
        return channelCount > 1 ? "stereo" : "mono"
    }

    private func loadAccentColor() async {
        guard let track = currentTrack else {
            accentColor = Color.dAccent
            return
        }
        let taskKey = accentColorTaskKey
        let artworkId = track.artworkId
        let albumId = track.albumId

        let cgImage = (try? appState.db.read { db -> CGImage? in
            let resolvedArtworkId: Int64?
            if let artworkId {
                resolvedArtworkId = artworkId
            } else if let albumId {
                resolvedArtworkId = try Album.fetchOne(db, key: albumId)?.artworkId
            } else {
                resolvedArtworkId = nil
            }

            guard let resolvedArtworkId,
                  let artwork = try Artwork.fetchOne(db, key: resolvedArtworkId)
            else { return nil }

            return artwork.imageLarge?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }) ?? nil

        guard let cgImage else { return }

        let result = await Task.detached(priority: .utility) {
            NowPlayingAccentColorResolver.resolve(from: cgImage)
        }.value

        if !Task.isCancelled, !result.isFallback, accentColorTaskKey == taskKey {
            accentColor = result.color
        }
    }

    private func showInteractions() {
        hideInteractionTask?.cancel()
        hideInteractionTask = nil
        isInteractionVisible = true
    }

    private func hideInteractions() {
        hideInteractionTask?.cancel()
        hideInteractionTask = nil
        guard !isQueueExpanded else { return }
        isInteractionVisible = false
    }

    private func scheduleInteractionHide() {
        hideInteractionTask?.cancel()
        hideInteractionTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isQueueExpanded else { return }
                isInteractionVisible = false
                hideInteractionTask = nil
            }
        }
    }
}

private struct NowPlayingPointerActivityReader: NSViewRepresentable {
    let onPointerActivity: () -> Void
    let onPointerExit: () -> Void
    let onWindowInactive: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        context.coordinator.onPointerActivity = onPointerActivity
        context.coordinator.onPointerExit = onPointerExit
        context.coordinator.onWindowInactive = onWindowInactive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPointerActivity: onPointerActivity,
            onPointerExit: onPointerExit,
            onWindowInactive: onWindowInactive
        )
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
        coordinator.detach(from: nsView.window)
    }

    final class Coordinator {
        var onPointerActivity: () -> Void
        var onPointerExit: () -> Void
        var onWindowInactive: () -> Void

        private weak var window: NSWindow?
        private var previousAcceptsMouseMovedEvents: Bool?
        private var didBecomeKeyObserver: NSObjectProtocol?
        private var didResignKeyObserver: NSObjectProtocol?
        private var mouseMovedMonitor: Any?

        init(
            onPointerActivity: @escaping () -> Void,
            onPointerExit: @escaping () -> Void,
            onWindowInactive: @escaping () -> Void
        ) {
            self.onPointerActivity = onPointerActivity
            self.onPointerExit = onPointerExit
            self.onWindowInactive = onWindowInactive
        }

        func attach(to newWindow: NSWindow?, view: NSView) {
            guard window !== newWindow else { return }
            detach(from: window)

            guard let newWindow else { return }
            window = newWindow
            previousAcceptsMouseMovedEvents = newWindow.acceptsMouseMovedEvents
            newWindow.acceptsMouseMovedEvents = true

            mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self,
                      event.window === newWindow,
                      newWindow.isKeyWindow,
                      self.windowContains(event: event, window: newWindow)
                else { return event }

                self.onPointerActivity()
                return event
            }

            didBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.windowContainsPointer(newWindow) else { return }
                self.onPointerActivity()
            }

            didResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowInactive()
            }
        }

        func detach(from detachedWindow: NSWindow?) {
            if let didBecomeKeyObserver {
                NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            }
            if let didResignKeyObserver {
                NotificationCenter.default.removeObserver(didResignKeyObserver)
            }
            didBecomeKeyObserver = nil
            didResignKeyObserver = nil

            if let mouseMovedMonitor {
                NSEvent.removeMonitor(mouseMovedMonitor)
            }
            mouseMovedMonitor = nil

            if let detachedWindow, detachedWindow === window, let previousAcceptsMouseMovedEvents {
                detachedWindow.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
            }
            previousAcceptsMouseMovedEvents = nil
            window = nil
        }

        private func windowContains(event: NSEvent, window: NSWindow) -> Bool {
            guard let contentView = window.contentView else { return false }
            let contentLocation = contentView.convert(event.locationInWindow, from: nil)
            return contentView.bounds.contains(contentLocation)
        }

        private func windowContainsPointer(_ window: NSWindow) -> Bool {
            guard let contentView = window.contentView else { return false }
            let contentLocation = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return contentView.bounds.contains(contentLocation)
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator? {
            didSet {
                coordinator?.attach(to: window, view: self)
            }
        }

        private var trackingAreaRef: NSTrackingArea?

        var isMouseInsideWindow: Bool {
            guard let window else { return false }
            let windowLocation = window.mouseLocationOutsideOfEventStream
            let localLocation = convert(windowLocation, from: nil)
            return bounds.contains(localLocation)
        }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }

            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self
            )
            addTrackingArea(trackingArea)
            trackingAreaRef = trackingArea
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            guard window?.isKeyWindow == true else { return }
            coordinator?.onPointerActivity()
        }

        override func mouseMoved(with event: NSEvent) {
            guard window?.isKeyWindow == true else { return }
            coordinator?.onPointerActivity()
        }

        override func mouseExited(with event: NSEvent) {
            coordinator?.onPointerExit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window, view: self)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                coordinator?.detach(from: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct NowPlayingAccentColorResult {
    let color: Color
    let isFallback: Bool
}

enum NowPlayingAccentColorResolver {
    static let defaultColor = Color.dAccent
    private static let sampleSize = 16

    static func accentColor(from cgImage: CGImage?) -> Color {
        resolve(from: cgImage).color
    }

    static func resolve(from cgImage: CGImage?) -> NowPlayingAccentColorResult {
        guard let cgImage,
              let color = extractDominantColor(from: cgImage)
        else {
            return NowPlayingAccentColorResult(color: defaultColor, isFallback: true)
        }

        return NowPlayingAccentColorResult(color: color, isFallback: false)
    }

    static func extractDominantColor(from cgImage: CGImage) -> Color? {
        let width = sampleSize
        let height = sampleSize
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var bestHue = 0.0
        var bestScore = 0.0

        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let hsb = hsbComponents(red: r, green: g, blue: b)

            guard hsb.saturation > 0.16,
                  hsb.brightness > 0.18,
                  hsb.brightness < 0.92
            else { continue }

            let brightnessWeight = 1 - abs(hsb.brightness - 0.58)
            let score = hsb.saturation * hsb.saturation * max(0.25, brightnessWeight)
            if score > bestScore {
                bestScore = score
                bestHue = hsb.hue
            }
        }

        guard bestScore > 0 else { return nil }
        return Color(hue: bestHue, saturation: 0.50, brightness: 0.50)
    }

    private static func hsbComponents(red r: Double, green g: Double, blue b: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let saturation = maxC > 0 ? delta / maxC : 0

        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = (g - b) / delta + (g < b ? 6 : 0)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
        }

        return (hue, saturation, maxC)
    }
}

private struct NowPlayingPlayButtonBackground: View {
    var body: some View {
        if AppTheme.current.transportChromeStyle == .terminal {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.dAccent)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(hex: "#fff2a9").opacity(0.82))
                        .frame(height: 2)
                        .padding(.horizontal, 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.dAccentStrong)
                        .frame(height: 3)
                        .padding(.horizontal, 1)
                }
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(Color.black.opacity(0.74), lineWidth: 1))
                .shadow(color: Color.dAccent.opacity(0.32), radius: 0, x: 2, y: 2)
        } else if AppTheme.current.transportChromeStyle == .moonamp {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: "#d7e1e7"))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 2)
                        .padding(1)
                        .mask(alignment: .top) { Rectangle().frame(height: 14) }
                }
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.black.opacity(0.58), lineWidth: 2)
                        .padding(1)
                        .mask(alignment: .bottom) { Rectangle().frame(height: 14) }
                }
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color(hex: "#6f7888"), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
        } else if AppTheme.current.transportChromeStyle == .moonPod {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.98),
                            Color(hex: "#dfe3e7").opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
                .overlay(Circle().stroke(Color.borderMedium.opacity(0.30), lineWidth: 1).padding(1))
                .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        } else if AppTheme.current.transportChromeStyle == .retroMoonPod {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.bgChrome)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.bgContent)
                        .frame(height: 1)
                        .padding(.horizontal, 1)
                }
        } else {
            Circle()
                .fill(Color.white.opacity(0.10))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.borderMedium, lineWidth: 0.6))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }

}

private struct SceneNowPlayingScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var isHovered = false
    @State private var suppressPublisherUpdatesUntil: Date?

    private var duration: TimeInterval {
        let engineDuration = controller.engine.duration
        if engineDuration.isFinite, engineDuration > 0 {
            return engineDuration
        }
        return controller.currentTrack?.duration ?? 0
    }

    private var displayTime: TimeInterval { isDragging ? dragValue : elapsed }
    private var remaining: TimeInterval { max(0, duration - displayTime) }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(formatTime(displayTime))
                .font(AppTheme.current.font(.numeric, size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 42, alignment: .trailing)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 0.26 : 0.18))
                        .frame(height: isHovered ? 5 : 4)

                    Capsule()
                        .fill(Color.white.opacity(0.86))
                        .frame(width: max(0, proxy.size.width * progress), height: isHovered ? 5 : 4)

                    if isHovered {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .shadow(color: .black.opacity(0.40), radius: 4, y: 1)
                            .offset(x: max(0, proxy.size.width * progress) - 4.5)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            isDragging = true
                            dragValue = max(0, min(duration, Double(value.location.x / proxy.size.width) * duration))
                        }
                        .onEnded { _ in
                            controller.engine.seek(to: dragValue)
                            elapsed = dragValue
                            suppressPublisherUpdatesUntil = Date().addingTimeInterval(0.35)
                            isDragging = false
                        }
                )
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)

            Text("-\(formatTime(remaining))")
                .font(AppTheme.current.font(.numeric, size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 42, alignment: .leading)
        }
        .shadow(color: .black.opacity(0.46), radius: 7, y: 2)
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { value in
            guard !isDragging else { return }
            if let suppressPublisherUpdatesUntil {
                if Date() < suppressPublisherUpdatesUntil { return }
                self.suppressPublisherUpdatesUntil = nil
            }
            elapsed = value
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonPodNowPlayingScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var isHovered = false
    @State private var suppressPublisherUpdatesUntil: Date?

    private var duration: TimeInterval {
        let engineDuration = controller.engine.duration
        if engineDuration.isFinite, engineDuration > 0 {
            return engineDuration
        }
        return controller.currentTrack?.duration ?? 0
    }
    private var displayTime: TimeInterval { isDragging ? dragValue : elapsed }
    private var remaining: TimeInterval { max(0, duration - displayTime) }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    var body: some View {
        let isRetroMoonPod = AppTheme.current.transportChromeStyle == .retroMoonPod

        VStack(spacing: 7) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: isRetroMoonPod ? 6 : 0, style: .continuous)
                        .fill(isRetroMoonPod ? Color.bgElevated2.opacity(0.82) : Color.white.opacity(0.88))
                        .overlay(RoundedRectangle(cornerRadius: isRetroMoonPod ? 6 : 0, style: .continuous).stroke(Color.borderStrong.opacity(isRetroMoonPod ? 0.76 : 0), lineWidth: isRetroMoonPod ? 1 : 0))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.borderSoft.opacity(isRetroMoonPod ? 0 : 0.40), lineWidth: 0.7))
                        .shadow(color: .black.opacity(isRetroMoonPod ? 0 : 0.10), radius: 2, y: 1)

                    if isRetroMoonPod {
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.dAccent)
                                .frame(width: max(0, proxy.size.width * progress))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(Color(hex: "#00a7c8"))
                            .frame(width: max(0, proxy.size.width * progress))
                    }

                    if isHovered && !isRetroMoonPod {
                        RoundedRectangle(cornerRadius: isRetroMoonPod ? 2 : 4, style: .continuous)
                            .fill(isRetroMoonPod ? Color.textPrimary : Color.white)
                            .frame(width: isRetroMoonPod ? 5 : 8, height: isRetroMoonPod ? 14 : 8)
                            .overlay(RoundedRectangle(cornerRadius: isRetroMoonPod ? 2 : 4, style: .continuous).stroke(isRetroMoonPod ? Color.bgContent : Color(hex: "#00a7c8"), lineWidth: 1))
                            .shadow(color: .black.opacity(isRetroMoonPod ? 0 : 0.22), radius: 2, y: 1)
                            .offset(x: max(0, proxy.size.width * progress) - 4)
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard proxy.size.width > 0 else { return }
                    isDragging = true
                    dragValue = max(0, min(duration, Double(value.location.x / proxy.size.width) * duration))
                }.onEnded { _ in
                    controller.engine.seek(to: dragValue)
                    elapsed = dragValue
                    suppressPublisherUpdatesUntil = Date().addingTimeInterval(0.35)
                    isDragging = false
                })
            }
            .frame(height: isRetroMoonPod ? 12 : 14)

            HStack {
                timeLabel(formatTime(displayTime), alignment: .leading)
                Spacer()
                timeLabel("-\(formatTime(remaining))", alignment: .trailing)
            }
        }
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { value in
            guard !isDragging else { return }
            if let suppressPublisherUpdatesUntil {
                if Date() < suppressPublisherUpdatesUntil { return }
                self.suppressPublisherUpdatesUntil = nil
            }
            elapsed = value
        }
    }

    private func timeLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(AppTheme.current.font(.numeric, size: AppTheme.current.isRetroMoonPod ? 12 : 15, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
            .frame(minWidth: 48, alignment: alignment)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RetroMoonPodNowPlayingScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var suppressPublisherUpdatesUntil: Date?

    private var duration: TimeInterval {
        let engineDuration = controller.engine.duration
        if engineDuration.isFinite, engineDuration > 0 {
            return engineDuration
        }
        return controller.currentTrack?.duration ?? 0
    }
    private var displayTime: TimeInterval { isDragging ? dragValue : elapsed }
    private var remaining: TimeInterval { max(0, duration - displayTime) }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.bgContent)
                        .overlay(Capsule().stroke(Color.dAccent, lineWidth: 2))

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.dAccent.opacity(0.18))
                            .frame(width: max(0, (proxy.size.width - 4) * progress))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                    .clipShape(Capsule())
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard proxy.size.width > 0 else { return }
                    isDragging = true
                    dragValue = max(0, min(duration, Double(value.location.x / proxy.size.width) * duration))
                }.onEnded { _ in
                    controller.engine.seek(to: dragValue)
                    elapsed = dragValue
                    suppressPublisherUpdatesUntil = Date().addingTimeInterval(0.35)
                    isDragging = false
                })
            }
            .frame(height: 24)

            HStack {
                Text(formatTime(displayTime))
                    .frame(minWidth: 78, alignment: .leading)
                Spacer()
                Text("-\(formatTime(remaining))")
                    .frame(minWidth: 78, alignment: .trailing)
            }
            .font(AppTheme.current.font(.numeric, size: 22, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
        }
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { value in
            guard !isDragging else { return }
            if let suppressPublisherUpdatesUntil {
                if Date() < suppressPublisherUpdatesUntil { return }
                self.suppressPublisherUpdatesUntil = nil
            }
            elapsed = value
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonampNowPlayingPanel: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: "#373a56"),
                        Color(hex: "#242740"),
                        Color(hex: "#17192c")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 3)
            }
            .overlay(Rectangle().stroke(Color(hex: "#090a13"), lineWidth: 5).padding(2))
            .overlay(Rectangle().stroke(Color(hex: "#5e607b"), lineWidth: 2).padding(9))
            .shadow(color: .black.opacity(0.32), radius: 22, y: 14)
    }
}

private struct MoonampNowPlayingLCDBox: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.black, Color(hex: "#070812")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(Rectangle().stroke(Color(hex: "#4e526f"), lineWidth: 2))
            .overlay(Rectangle().stroke(Color.black.opacity(0.9), lineWidth: 1).padding(2))
    }
}

private struct MoonampNowPlayingGoldStripe: View {
    var body: some View {
        VStack(spacing: 5) {
            Rectangle().fill(Color(hex: "#fff2a9")).frame(height: 5)
            Rectangle().fill(Color(hex: "#d6b547")).frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#11121d"))
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

private struct TerminalBannerTitle: View {
    let size: CGFloat

    // FIGlet "Banner3-D" style rendering of MOONLIGHT
    private static let art = """
    ███╗   ███╗ ██████╗  ██████╗ ███╗   ██╗██╗     ██╗ ██████╗ ██╗  ██╗████████╗
    ████╗ ████║██╔═══██╗██╔═══██╗████╗  ██║██║     ██║██╔════╝ ██║  ██║╚══██╔══╝
    ██╔████╔██║██║   ██║██║   ██║██╔██╗ ██║██║     ██║██║  ███╗███████║   ██║
    ██║╚██╔╝██║██║   ██║██║   ██║██║╚██╗██║██║     ██║██║   ██║██╔══██║   ██║
    ██║ ╚═╝ ██║╚██████╔╝╚██████╔╝██║ ╚████║███████╗██║╚██████╔╝██║  ██║   ██║
    ╚═╝     ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝
    """

    var body: some View {
        Text(Self.art)
            .font(AppTheme.current.font(.brand, size: size, weight: .medium))
            .foregroundStyle(Color.dAccentStrong)
            .shadow(color: Color.dAccent.opacity(0.52), radius: 6)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TerminalStatusLine: View {
    let title: String
    let rightText: String

    var body: some View {
        HStack {
            Text("┌─ \(title) ")
                .font(AppTheme.current.font(.control, size: 16, weight: .medium))
                .foregroundStyle(Color.dAccentStrong)
                .shadow(color: Color.dAccent.opacity(0.55), radius: 4)
            Rectangle()
                .fill(Color.dAccent.opacity(0.42))
                .frame(height: 1)
            Text(" \(rightText) ─┐")
                .font(AppTheme.current.font(.control, size: 16, weight: .medium))
                .foregroundStyle(Color(hex: "#20c8ff"))
                .shadow(color: Color(hex: "#20c8ff").opacity(0.45), radius: 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}

private struct TerminalNowPlayingBox: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.44))
            .overlay(Rectangle().stroke(Color.dAccent.opacity(0.82), lineWidth: 1))
            .overlay(Rectangle().stroke(Color.dAccentStrong.opacity(0.18), lineWidth: 1).padding(3))
    }
}

private struct MoonampNowPlayingSpectrum: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var phase: Double = 0
    @State private var levels: [Float] = Array(repeating: 0, count: 32)
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                MoonampNowPlayingLCDBox()

                Canvas { context, size in
                    let dot: CGFloat = 5
                    let gap: CGFloat = 5
                    let columns = max(1, Int((size.width - 22) / (dot + gap)))
                    let rows = max(1, Int((size.height - 18) / (dot + gap)))
                    let displayLevels = normalizedLevels(columnCount: columns)

                    for x in 0..<columns {
                        for y in 0..<rows {
                            let rect = CGRect(x: CGFloat(x) * (dot + gap) + 10, y: CGFloat(y) * (dot + gap) + 10, width: dot, height: dot)
                            context.fill(Path(rect), with: .color(Color(hex: "#151730").opacity(0.82)))
                        }
                    }

                    for x in 0..<columns {
                        let level = Double(displayLevels[x])
                        let activeRows = Int(max(1, round(level * Double(rows - 2))) + 1)
                        for y in 0..<activeRows {
                            let normalized = Double(y) / Double(max(1, rows - 1))
                            let color: Color = normalized > 0.72
                                ? Color(hex: "#ff4d16")
                                : (normalized > 0.50 ? Color(hex: "#ffe65b") : Color(hex: "#00d348"))
                            let drawY = size.height - CGFloat(y + 1) * (dot + gap) - 10
                            let rect = CGRect(x: CGFloat(x) * (dot + gap) + 12, y: drawY, width: dot, height: dot)
                            context.fill(Path(rect), with: .color(color))
                        }
                    }

                    let baselineY = size.height - 12
                    for x in 0..<columns {
                        let rect = CGRect(x: CGFloat(x) * (dot + gap) + 10, y: baselineY, width: dot, height: dot)
                        context.fill(Path(rect), with: .color(Color(hex: "#00a5e8")))
                    }
                }
                .padding(5)
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onReceive(timer) { _ in phase += 0.35 }
        .onReceive(audioLevelsPublisher) { newLevels in
            guard !newLevels.isEmpty else { return }
            levels = newLevels
        }
    }

    private var audioLevelsPublisher: AnyPublisher<[Float], Never> {
        if let provider = controller.engine as? AudioLevelProviding {
            return provider.audioLevelsPublisher
        }
        return Just(Array(repeating: Float(0), count: 32)).eraseToAnyPublisher()
    }

    private func normalizedLevels(columnCount: Int) -> [Float] {
        guard controller.isPlaying, controller.volume > 0.01 else {
            return Array(repeating: 0, count: columnCount)
        }

        guard levels.contains(where: { $0 > 0.01 }) else {
            var fallbackLevels: [Float] = []
            fallbackLevels.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let wave = sin(phase + Double(index) * 0.52)
                fallbackLevels.append(Float(0.14 + 0.10 * (wave + 1.0) * 0.5))
            }
            return fallbackLevels
        }

        let volumeScale = max(0, min(1, controller.volume))
        var normalized: [Float] = []
        normalized.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            let progress = Double(index) / Double(max(1, columnCount - 1))
            let source = progress * Double(levels.count - 1)
            let lower = Int(floor(source))
            let upper = min(levels.count - 1, lower + 1)
            let t = Float(source - Double(lower))
            let interpolated = levels[lower] * (1 - t) + levels[upper] * t
            let shimmer = Float(0.05 * (sin(phase + Double(index) * 0.34) + 1.0))
            normalized.append(min(1, max(0, (interpolated * 0.94 + shimmer) * volumeScale)))
        }
        return normalized
    }
}

private struct MoonampNowPlayingTime: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    let track: Track
    let artworkSize: CGFloat

    var body: some View {
        HStack(spacing: 18) {
            ShowTrackInAlbumButton(track: track) {
                ArtworkView(
                    albumId: track.albumId,
                    artworkId: track.artworkId,
                    large: true,
                    decodeMaxPixelSize: Int(artworkSize * 2),
                    cornerRadius: 2,
                    iconFont: .system(size: max(28, artworkSize * 0.42)),
                    retainsPreviousImageWhileLoading: true
                )
                .frame(width: artworkSize, height: artworkSize)
                .overlay(Rectangle().stroke(Color(hex: "#090a13"), lineWidth: 3))
                .overlay(Rectangle().stroke(Color(hex: "#5e607b"), lineWidth: 1).padding(4))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }

            Text(formatTime(elapsed))
                .font(AppTheme.current.font(.numeric, size: 68, weight: .medium))
                .foregroundStyle(Color(hex: "#c8d3de"))
                .lineLimit(1)
                .minimumScaleFactor(0.35)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoonampNowPlayingLCDBox())
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { elapsed = $0 }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ShowTrackInAlbumButton<Label: View>: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    let track: Track
    let label: Label

    init(track: Track, @ViewBuilder label: () -> Label) {
        self.track = track
        self.label = label()
    }

    var body: some View {
        if let albumId = track.albumId {
            Button {
                appState.showAlbum(albumId: albumId, revealingTrackID: track.dbId)
            } label: {
                label.opacity(isHovered ? 0.78 : 1)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .help("Show in Album")
            .accessibilityLabel("Show \(track.displayTitle) in Album")
        } else {
            label
        }
    }
}

private struct NowPlayingCircleButton: View {
    let icon: String
    var isActive = false
    var isDisabled = false
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(isHovered ? Color.white.opacity(0.16) : Color.white.opacity(0.09))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct NowPlayingChromeButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppTheme.current.transportChromeStyle == .retroMoonPod ? (isHovered ? Color.dAccent : Color.textPrimary) : (isHovered ? Color.textPrimary : Color.white.opacity(0.82)))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.current.transportChromeStyle == .retroMoonPod ? 2 : 8)
                .fill(isHovered ? Color.white.opacity(0.10) : .clear)
        )
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct NowPlayingSceneMenu: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false
    @State private var isPickerPresented = false

    private var availableScenes: [BuiltInScene] {
        BuiltInScenes.all.filter { $0.url != nil }
    }

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            Image(systemName: appState.sceneEnabled ? "sparkles.tv.fill" : "music.note")
                .font(AppTheme.current.font(.icon, size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppTheme.current.transportChromeStyle == .retroMoonPod ? (isHovered ? Color.dAccent : Color.textPrimary) : (isHovered ? Color.textPrimary : Color.white.opacity(0.82)))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.current.transportChromeStyle == .retroMoonPod ? 2 : 8)
                .fill(isHovered ? Color.white.opacity(0.10) : .clear)
        )
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            VStack(spacing: 3) {
                NowPlayingSceneOption(title: "Now Playing", isSelected: !appState.sceneEnabled) {
                    appState.disableScene()
                    isPickerPresented = false
                }

                ForEach(availableScenes) { scene in
                    NowPlayingSceneOption(
                        title: scene.title,
                        isSelected: appState.sceneEnabled && appState.selectedScene?.id == scene.id
                    ) {
                        appState.selectScene(scene)
                        isPickerPresented = false
                    }
                }
            }
            .padding(6)
            .frame(width: 196)
        }
        .help("Choose Now Playing Mode")
    }
}

private struct NowPlayingSceneOption: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.current.font(.body, size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.10) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct NowPlayingQueueRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let accentColor: Color
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isRetroMoonPod = AppTheme.current.isRetroMoonPod
        let selectedForeground = isRetroMoonPod && isCurrent ? Color.bgContent : Color.textPrimary
        let selectedSecondaryForeground = isRetroMoonPod && isCurrent ? Color.bgContent.opacity(0.86) : Color.textSecondary

        HStack(spacing: 10) {
            ZStack {
                if !track.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppTheme.current.font(.icon, size: 10))
                        .foregroundStyle(selectedSecondaryForeground)
                } else if isCurrent && isPlaying {
                    VUMeterInline(color: isRetroMoonPod ? Color.bgContent : accentColor)
                } else if isHovered {
                    Image(systemName: isCurrent ? "pause.fill" : "play.fill")
                        .font(AppTheme.current.font(.icon, size: 10))
                        .foregroundStyle(selectedForeground)
                } else {
                    Text("\(index + 1)")
                        .font(AppTheme.current.font(.numeric, size: 11))
                        .foregroundStyle(isRetroMoonPod && isCurrent ? Color.bgContent.opacity(0.86) : Color.textTertiary)
                }
            }
            .frame(width: 24)

            ArtworkView(albumId: track.albumId, artworkId: track.artworkId, cornerRadius: isRetroMoonPod ? 0 : 4, iconFont: .caption2)
                .frame(width: isRetroMoonPod ? 30 : 34, height: isRetroMoonPod ? 30 : 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppTheme.current.displayText(track.isAvailable ? track.displayTitle : "\(track.displayTitle) — Unavailable"))
                    .font(AppTheme.current.font(.table, size: 12.5, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(selectedForeground)
                    .lineLimit(1)
                Text(AppTheme.current.displayText(track.displayArtist))
                    .font(AppTheme.current.font(.metadata, size: 11.5))
                    .foregroundStyle(selectedSecondaryForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(track.durationFormatted)
                .font(AppTheme.current.font(.numeric, size: 11))
                .foregroundStyle(isRetroMoonPod && isCurrent ? Color.bgContent.opacity(0.86) : Color.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: isRetroMoonPod ? 40 : 48)
        .background(isCurrent ? (isRetroMoonPod ? Color.dAccent.opacity(0.90) : Color.white.opacity(0.10)) : (isHovered ? Color.bgHover : .clear))
        .opacity(track.isAvailable ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            guard track.isAvailable else { return }
            onPlay()
        }
        .contextMenu {
            Button("Play Now", action: onPlay)
                .disabled(!track.isAvailable)
            TrackRatingMenu(tracks: [track])
        }
    }
}
