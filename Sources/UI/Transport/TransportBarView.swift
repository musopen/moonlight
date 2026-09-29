// TransportBarView.swift
//
// The playback bar along the bottom of the main window. From left to right it shows the current
// song or radio station, the play, skip and shuffle controls with a time bar, and buttons for
// the "Up Next" list, the mini player, AirPlay output and volume. It also shows an alert when a song cannot play,
// offering to reconnect the music folder or fix missing files.

import AVFoundation
import SwiftUI
import Combine

struct TransportBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var controller: PlaybackController
    @Environment(\.openSettings) private var openSettings
    @State private var isQueuePresented = false

    var body: some View {
        let chromeStyle = appState.selectedTheme.transportChromeStyle
        let isMoonamp = chromeStyle == .moonamp
        let isTerminal = chromeStyle == .terminal
        let isMoonPod = chromeStyle == .moonPod
        let isRetroMoonPod = chromeStyle == .retroMoonPod

        ZStack(alignment: .top) {
            // Background: native vibrancy blurring in-window content
            TransportVibrancy()
                .ignoresSafeArea()

            Color.bgTransport
                .ignoresSafeArea()

            if isMoonamp {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.10), location: 0),
                        .init(color: Color.clear, location: 0.34),
                        .init(color: Color.black.opacity(0.24), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            if isMoonPod {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.82), location: 0),
                        .init(color: Color.white.opacity(0.16), location: 0.42),
                        .init(color: Color.black.opacity(0.10), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            if isRetroMoonPod || isTerminal {
                Color.bgContent
                .ignoresSafeArea()
            }

            if isTerminal {
                ScanlineOverlay()
                    .ignoresSafeArea()
            }

            Rectangle()
                .fill(isMoonamp ? Color.borderStrong.opacity(0.58) : (isMoonPod ? Color.white.opacity(0.86) : ((isRetroMoonPod || isTerminal) ? Color.borderStrong.opacity(0.70) : Color.borderSoft)))
                .frame(height: (isMoonamp || isMoonPod || isRetroMoonPod || isTerminal) ? 1 : 0.5)

            HStack(spacing: 0) {
                // Left: now-playing card
                NowPlayingCardView(
                    track: controller.currentTrack,
                    radioStation: controller.currentRadioStation
                )
                    .frame(width: 330)
                    .padding(.leading, 16)

                Spacer()

                // Center: controls + scrubber
                VStack(spacing: 4) {
                    TransportControlsView()
                    if controller.currentRadioStation != nil {
                        RadioLiveProgressView()
                    } else {
                        ScrubberView()
                    }
                }
                .frame(maxWidth: 600)

                Spacer()

                // Right: queue, mini-player, AirPlay, volume
                HStack(spacing: 6) {
                    TransportIconButton(icon: "list.bullet", isActive: isQueuePresented, action: {
                        isQueuePresented.toggle()
                    })
                    .disabled(controller.currentRadioStation != nil)
                    .opacity(controller.currentRadioStation == nil ? 1 : 0.35)
                    .help("Show Up Next")
                    .popover(isPresented: $isQueuePresented, arrowEdge: .top) {
                        QueuePopoverView()
                            .environmentObject(controller)
                    }
                    TransportIconButton(icon: "pip.enter", size: 14, action: {
                        appState.enterMiniPlayer()
                    })
                    .disabled(controller.currentRadioStation != nil)
                    .opacity(controller.currentRadioStation == nil ? 1 : 0.35)
                    AirPlayRoutePickerButton(
                        player: (controller.engine as? AirPlayRouteProviding)?.airPlayRoutePickerPlayer
                    )
                    Spacer().frame(width: 2)
                    VolumeSliderView()
                        .frame(width: 100)
                }
                .frame(width: 330, alignment: .trailing)
                .padding(.trailing, 16)
            }
            .frame(height: DS.transportHeight)
        }
        .frame(height: DS.transportHeight)
        .alert(
            playbackErrorTitle,
            isPresented: Binding(
                get: { controller.playbackError != nil },
                set: { isPresented in
                    if !isPresented {
                        controller.dismissPlaybackError()
                    }
                }
            )
        ) {
            if let track = controller.unavailableTrackForPlayback {
                if controller.playbackFolderUnavailable, let folderId = track.folderId {
                    Button("Reconnect Folder…") {
                        controller.dismissPlaybackError()
                        appState.showReconnectFolderPicker(for: folderId)
                    }
                } else {
                    Button("Resolve Missing Files…") {
                        controller.dismissPlaybackError()
                        appState.prepareMissingFilesSettings()
                        openSettings()
                    }
                }
            }
            Button(controller.unavailableTrackForPlayback == nil ? "OK" : "Cancel", role: .cancel) {
                controller.dismissPlaybackError()
            }
        } message: {
            Text(controller.playbackError ?? "This track could not be played.")
        }
    }

    private var playbackErrorTitle: String {
        if controller.playbackFolderUnavailable {
            return "Music Folder Unavailable"
        }
        return controller.unavailableTrackForPlayback == nil ? "Playback Error" : "File Unavailable"
    }
}

// MARK: - Now-playing card

private struct NowPlayingCardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    let track: Track?
    let radioStation: RadioStation?

    private var displayTitle: String {
        radioStation?.name ?? track?.displayTitle ?? "Not Playing"
    }

    private var displaySubtitle: String {
        if let radioStation {
            return radioStation.country ?? radioStation.countryCode ?? "Live Radio"
        }
        return track?.displayArtist ?? "-"
    }

    private var hasMedia: Bool { track != nil || radioStation != nil }

    var body: some View {
        Button {
            appState.showNowPlaying()
        } label: {
            let chromeStyle = AppTheme.current.transportChromeStyle
            let isMoonamp = chromeStyle == .moonamp
            let isTerminal = chromeStyle == .terminal
            let isMoonPod = chromeStyle == .moonPod
            let isRetroMoonPod = chromeStyle == .retroMoonPod

            HStack(spacing: isMoonamp ? 8 : ((isRetroMoonPod || isTerminal) ? 7 : 10)) {
                Group {
                    if radioStation != nil {
                        ZStack {
                            Color.dAccent.opacity(0.14)
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(AppTheme.current.font(.icon, size: 17, weight: .medium))
                                .foregroundStyle(Color.dAccent)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: (isMoonamp || isRetroMoonPod || isTerminal) ? 2 : (isMoonPod ? 6 : 4)))
                    } else {
                        ArtworkView(
                            albumId: track?.albumId,
                            artworkId: track?.artworkId,
                            cornerRadius: (isMoonamp || isRetroMoonPod || isTerminal) ? 2 : (isMoonPod ? 6 : 4),
                            iconFont: .caption2,
                            retainsPreviousImageWhileLoading: track != nil
                        )
                    }
                }
                .frame(width: isMoonamp ? 42 : ((isRetroMoonPod || isTerminal) ? 40 : DS.albumArtTransport), height: isMoonamp ? 42 : ((isRetroMoonPod || isTerminal) ? 40 : DS.albumArtTransport))
                .shadow(color: .black.opacity(isMoonamp ? 0.25 : ((isMoonPod || isRetroMoonPod) ? 0 : 0.45)), radius: isMoonamp ? 0 : ((isMoonPod || isRetroMoonPod) ? 0 : 10), y: isMoonamp ? 0 : ((isMoonPod || isRetroMoonPod) ? 0 : 4))
                .overlay {
                    if isMoonPod {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.borderMedium.opacity(0.22), lineWidth: 0.75)
                    }
                }
                .overlay {
                    if isHovered, track != nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(.black.opacity(0.56), in: Circle())
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }

                if isTerminal {
                    VUMeterInline(color: Color(hex: "#20c8ff"))
                        .frame(width: 14)
                        .padding(.leading, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Text("PLAYING: \(AppTheme.current.displayText(hasMedia ? displayTitle : "AWAITING INPUT"))")
                                .font(AppTheme.current.font(.metadata, size: 11, weight: .medium))
                                .foregroundStyle(Color.dAccentStrong)
                                .lineLimit(1)
                            if hasMedia {
                                TerminalCursorView()
                                    .font(AppTheme.current.font(.metadata, size: 11, weight: .medium))
                                    .foregroundStyle(Color.dAccentStrong.opacity(0.72))
                            }
                        }
                        if !hasMedia {
                            HStack(spacing: 3) {
                                Text("ARTIST: > ")
                                    .font(AppTheme.current.font(.caption, size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.textSecondary)
                                TerminalCursorView()
                                    .font(AppTheme.current.font(.caption, size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.dAccent)
                            }
                        } else {
                            Text("ARTIST: \(AppTheme.current.displayText(displaySubtitle))")
                                .font(AppTheme.current.font(.caption, size: 10.5, weight: .medium))
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .background(TerminalBoxBackground())
                } else if isMoonamp {
                    VUMeterInline(color: Color.dAccent)
                        .frame(width: 14)
                        .padding(.leading, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppTheme.current.displayText(hasMedia ? displayTitle : "NOT PLAYING"))
                            .font(AppTheme.current.font(.body, size: 12, weight: .semibold))
                            .foregroundStyle(Color.dAccent)
                            .lineLimit(1)
                        Text(AppTheme.current.displayText(hasMedia ? displaySubtitle : "READY"))
                            .font(AppTheme.current.font(.caption, size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dAccent.opacity(0.68))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .background(
                        RetroBeveledBackground(
                            fill: Color.black.opacity(0.86),
                            topHighlight: Color.black.opacity(0.75),
                            bottomShadow: Color.borderStrong.opacity(0.25),
                            cornerRadius: 2
                        )
                    )
                } else if isMoonPod || isRetroMoonPod {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppTheme.current.displayText(displayTitle))
                            .font(AppTheme.current.font(.metadata, size: isRetroMoonPod ? 12 : 12.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Text(AppTheme.current.displayText(hasMedia ? displaySubtitle : "Choose a track"))
                            .font(AppTheme.current.font(.metadata, size: isRetroMoonPod ? 10 : 10.5))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, isRetroMoonPod ? 8 : 10)
                    .padding(.vertical, isRetroMoonPod ? 5 : 6)
                    .frame(maxWidth: .infinity, minHeight: isRetroMoonPod ? 40 : 44, alignment: .leading)
                    .background(isRetroMoonPod ? AnyView(RetroMoonPodLCDBackground()) : AnyView(MoonPodLCDBackground()))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppTheme.current.displayText(displayTitle))
                            .font(AppTheme.current.font(.body, size: 12.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Text(AppTheme.current.displayText(displaySubtitle))
                            .font(AppTheme.current.font(.caption, size: 11.5))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help("Show Now Playing")
    }
}

// MARK: - Transport controls

private struct TransportControlsView: View {
    @EnvironmentObject var controller: PlaybackController

    var body: some View {
        let isRadio = controller.currentRadioStation != nil

        HStack(spacing: 10) {
            TransportIconButton(
                icon: "shuffle",
                size: 14,
                isActive: controller.isShuffled,
                action: { controller.toggleShuffle() }
            )
            .disabled(isRadio)
            .opacity(isRadio ? 0.35 : 1)
            TransportIconButton(
                icon: "backward.fill",
                size: 18,
                frameSize: 34,
                action: { controller.skipPrevious() }
            )
            .disabled(isRadio)
            .opacity(isRadio ? 0.35 : 1)
            TransportIconButton(
                icon: controller.isPlaying ? "pause" : "play.fill",
                size: 24,
                frameSize: 44,
                action: { controller.togglePlayPause() }
            )
            TransportIconButton(
                icon: "forward.fill",
                size: 18,
                frameSize: 34,
                action: { controller.skipNext() }
            )
            .disabled(isRadio)
            .opacity(isRadio ? 0.35 : 1)
            TransportIconButton(
                icon: controller.repeatMode == .one ? "repeat.1" : "repeat",
                size: 14,
                isActive: controller.repeatMode != .off,
                action: { controller.cycleRepeatMode() }
            )
            .disabled(isRadio)
            .opacity(isRadio ? 0.35 : 1)
        }
    }
}

private struct RadioLiveProgressView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.dAccent)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(AppTheme.current.font(.metadata, size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(height: 16)
    }
}

private struct AirPlayRoutePickerButton: View {
    let player: AVPlayer?
    @State private var isHovered = false

    var body: some View {
        let chromeStyle = AppTheme.current.transportChromeStyle

        AirPlayRoutePickerView(player: player)
            .frame(width: 28, height: 28)
            .background(
                Group {
                    if chromeStyle == .terminal {
                        TerminalControlBackground(isHovered: isHovered)
                    } else if chromeStyle == .moonamp {
                        RetroBeveledBackground(
                            fill: isHovered ? Color.bgElevated2.opacity(0.96) : Color.bgElevated.opacity(0.90),
                            topHighlight: Color.borderStrong.opacity(0.56),
                            bottomShadow: Color.black.opacity(0.50),
                            cornerRadius: 2
                        )
                    } else if chromeStyle == .moonPod {
                        MoonPodControlBackground(isHovered: isHovered)
                    } else if chromeStyle == .retroMoonPod {
                        RetroMoonPodControlBackground(isHovered: isHovered)
                    } else {
                        Circle()
                            .fill(isHovered ? Color.bgHover : .clear)
                    }
                }
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help("Choose AirPlay Output")
    }
}

struct TransportIconButton: View {
    let icon: String
    var size: CGFloat = 15
    var frameSize: CGFloat = 28
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let chromeStyle = AppTheme.current.transportChromeStyle
        let isMoonamp = chromeStyle == .moonamp
        let isTerminal = chromeStyle == .terminal
        let isMoonPod = chromeStyle == .moonPod
        let isRetroMoonPod = chromeStyle == .retroMoonPod

        Button(action: action) {
            ZStack {
                if isTerminal {
                    TerminalControlBackground(isHovered: isHovered)
                } else if isMoonamp {
                    RetroBeveledBackground(
                        fill: isHovered ? Color.bgElevated2.opacity(0.98) : Color.bgElevated.opacity(0.92),
                        topHighlight: Color.borderStrong.opacity(0.62),
                        bottomShadow: Color.black.opacity(0.52),
                        cornerRadius: 2
                    )
                } else if isMoonPod {
                    MoonPodControlBackground(isHovered: isHovered)
                } else if isRetroMoonPod {
                    RetroMoonPodControlBackground(isHovered: isHovered)
                } else {
                    Circle()
                        .fill(isHovered ? Color.bgHover : .clear)
                }

                Image(systemName: icon)
                    .font(AppTheme.current.font(.icon, size: isMoonamp ? max(11, size - 1) : size, weight: (isMoonamp || isMoonPod || isRetroMoonPod || isTerminal) ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.dAccent : (isHovered ? Color.textPrimary : Color.textSecondary))
            }
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frameSize, height: frameSize)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct TerminalCursorView: View {
    @State private var visible = true

    var body: some View {
        Text("█")
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.65).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

private struct TerminalBoxBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.52))
            .overlay(Rectangle().stroke(Color.dAccent.opacity(0.86), lineWidth: 1))
            .overlay(Rectangle().stroke(Color.black.opacity(0.90), lineWidth: 1).padding(2))
    }
}

private struct TerminalControlBackground: View {
    let isHovered: Bool

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.dAccent.opacity(0.16) : Color.bgElevated.opacity(0.88))
            .overlay(Rectangle().stroke(isHovered ? Color.dAccentStrong : Color.dAccent.opacity(0.70), lineWidth: 1))
    }
}

private struct MoonPodLCDBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: "#d7eef5"),
                        Color(hex: "#eef9fb")
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.borderMedium.opacity(0.28), lineWidth: 1)
                    .padding(1)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

private struct MoonPodControlBackground: View {
    let isHovered: Bool

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isHovered ? 0.98 : 0.90),
                        Color(hex: "#dfe3e7").opacity(isHovered ? 0.98 : 0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
            .overlay(Circle().stroke(Color.borderMedium.opacity(0.30), lineWidth: 1).padding(1))
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0.10), radius: isHovered ? 4 : 2, y: 1)
    }
}

private struct RetroMoonPodLCDBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.bgElevated)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.bgContent)
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
    }
}

private struct RetroMoonPodControlBackground: View {
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isHovered ? Color.bgElevated : Color.bgChrome)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.bgContent.opacity(isHovered ? 1 : 0.72))
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
    }
}

private struct RetroBeveledBackground: View {
    let fill: Color
    let topHighlight: Color
    let bottomShadow: Color
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(topHighlight)
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(topHighlight.opacity(0.78))
                    .frame(width: 1)
                    .padding(.vertical, 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(bottomShadow)
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(bottomShadow)
                    .frame(width: 1)
                    .padding(.vertical, 1)
            }
    }
}
