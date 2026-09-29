// MiniPlayerView.swift
//
// The compact mini player window, shown when the user shrinks Moonlight down to a small,
// resizable square. By default it shows the album artwork with controls that appear on hover;
// the Moonamp, Terminal and MoonPod themes each get their own retro-style version. It also
// adjusts the window's size limits and buttons when switching between the mini player and the
// full library window.

import SwiftUI
import AppKit
import Combine

enum MiniPlayerWindowMetrics {
    static let initialSize = NSSize(width: 360, height: 360)
    static let minSize = NSSize(width: 260, height: 260)
    static let maxSize = NSSize(width: 640, height: 640)
    static let emptyLibraryMinSize = NSSize(width: 600, height: 500)
    static let libraryMinSize = NSSize(width: 900, height: 560)
    static let libraryFallbackSize = NSSize(width: 1100, height: 720)
}

struct MiniPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: PlaybackController
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if AppTheme.current.transportChromeStyle == .moonPod || AppTheme.current.transportChromeStyle == .retroMoonPod {
                    MoonPodMiniPlayerView(size: proxy.size, isHovered: isHovered)
                } else if AppTheme.current.transportChromeStyle == .terminal {
                    TerminalMiniPlayerView(size: proxy.size, isHovered: isHovered)
                } else if AppTheme.current.transportChromeStyle == .moonamp {
                    MoonampMiniPlayerView(size: proxy.size, isHovered: isHovered)
                } else {
                    artworkMiniPlayer(size: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .ignoresSafeArea()
        .frame(minWidth: MiniPlayerWindowMetrics.minSize.width, minHeight: MiniPlayerWindowMetrics.minSize.height)
        .background(Color.bgBase)
    }

    private func artworkMiniPlayer(size: CGSize) -> some View {
        ZStack {
            ArtworkView(
                albumId: controller.currentTrack?.albumId,
                artworkId: controller.currentTrack?.artworkId,
                large: true,
                cornerRadius: 0,
                iconFont: .system(size: iconSize(for: size)),
                retainsPreviousImageWhileLoading: controller.currentTrack != nil
            )
            .frame(width: size.width, height: size.height)
            .background(Color.bgBase)
            .clipped()

            overlay(size: size)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: isHovered)
        }
    }

    private func overlay(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            bottomBackdrop(size: size)

            Button {
                appState.exitMiniPlayer()
            } label: {
                Image(systemName: "pip.exit")
                    .font(AppTheme.current.font(.icon, size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.42), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Return to Full Player")
            .padding(14)
            .zIndex(2)

            VStack(spacing: controlSpacing(for: size)) {
                Spacer()

                VStack(spacing: 3) {
                    Text(AppTheme.current.displayText(controller.currentTrack?.displayTitle ?? "Not Playing"))
                        .font(AppTheme.current.font(.title, size: titleSize(for: size), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.45), radius: 5, y: 1)

                    Text(AppTheme.current.displayText(controller.currentTrack?.displayArtist ?? "Choose a track from your library"))
                        .font(AppTheme.current.font(.body, size: subtitleSize(for: size), weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

                MiniPlayerControlsView(size: controlSize(for: size))
                    .disabled(controller.currentTrack == nil)
                    .opacity(controller.currentTrack == nil ? 0.5 : 1)

                MiniPlayerScrubberView()
                    .padding(.horizontal, scrubberHorizontalPadding(for: size))
                    .disabled(controller.currentTrack == nil)
                    .opacity(controller.currentTrack == nil ? 0.5 : 1)
            }
            .padding(.bottom, bottomPadding(for: size))
            .zIndex(1)
        }
    }

    private func bottomBackdrop(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                TransportVibrancy()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.8), location: 0.24),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.34), location: 0.28),
                        .init(color: .black.opacity(0.86), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: bottomBackdropHeight(for: size))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func shortestSide(_ size: CGSize) -> CGFloat {
        min(size.width, size.height)
    }

    private func iconSize(for size: CGSize) -> CGFloat {
        max(34, shortestSide(size) * 0.16)
    }

    private func titleSize(for size: CGSize) -> CGFloat {
        max(13, min(20, shortestSide(size) * 0.05))
    }

    private func subtitleSize(for size: CGSize) -> CGFloat {
        max(11, min(15, shortestSide(size) * 0.038))
    }

    private func controlSize(for size: CGSize) -> CGFloat {
        max(32, min(58, shortestSide(size) * 0.13))
    }

    private func controlSpacing(for size: CGSize) -> CGFloat {
        max(8, min(18, shortestSide(size) * 0.035))
    }

    private func bottomPadding(for size: CGSize) -> CGFloat {
        max(12, min(24, shortestSide(size) * 0.045))
    }

    private func bottomBackdropHeight(for size: CGSize) -> CGFloat {
        max(150, min(300, shortestSide(size) * 0.56))
    }

    private func scrubberHorizontalPadding(for size: CGSize) -> CGFloat {
        max(24, min(34, shortestSide(size) * 0.075))
    }
}

private struct MiniPlayerControlsView: View {
    @EnvironmentObject private var controller: PlaybackController
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.6) {
            MiniPlayerIconButton(
                icon: "backward.fill",
                size: size * 0.48,
                frameSize: size,
                action: { controller.skipPrevious() }
            )

            MiniPlayerIconButton(
                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                size: size * 0.62,
                frameSize: size * 1.15,
                action: { controller.togglePlayPause() }
            )

            MiniPlayerIconButton(
                icon: "forward.fill",
                size: size * 0.48,
                frameSize: size,
                action: { controller.skipNext() }
            )
        }
    }
}

private struct MiniPlayerIconButton: View {
    let icon: String
    let size: CGFloat
    let frameSize: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.9))
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MiniPlayerScrubberView: View {
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
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.18))
                        .frame(height: isHovered ? 5 : 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.92))
                        .frame(width: max(0, proxy.size.width * progress), height: isHovered ? 5 : 4)

                    if isHovered {
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .offset(x: max(0, proxy.size.width * progress) - 5)
                    }
                }
                .frame(maxHeight: .infinity)
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
            .frame(height: 16)
            .animation(.easeInOut(duration: 0.12), value: isHovered)

            HStack {
                timeLabel(formatTime(displayTime), alignment: .leading)

                Spacer(minLength: 12)

                timeLabel("-\(formatTime(remaining))", alignment: .trailing)
            }
        }
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
            .font(AppTheme.current.font(.numeric, size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, alignment: alignment)
            .shadow(color: .black.opacity(0.42), radius: 3, y: 1)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonampMiniPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: PlaybackController

    let size: CGSize
    let isHovered: Bool

    private var track: Track? { controller.currentTrack }
    private var shortestSide: CGFloat { min(size.width, size.height) }
    private var scale: CGFloat { max(0.72, min(1.34, shortestSide / 360)) }
    private var inset: CGFloat { max(12, min(24, shortestSide * 0.045)) }
    private var bottomInset: CGFloat { inset + max(8, 14 * scale) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MoonampPanelBackground()

            VStack(spacing: 8 * scale) {
                header

                HStack(spacing: 12 * scale) {
                    MoonampSpectrumView()
                        .frame(width: max(86, size.width * 0.31), height: max(62, size.height * 0.21))

                    MoonampTimeDisplay()
                        .frame(maxWidth: .infinity, minHeight: max(62, size.height * 0.21))
                }

                moonampTextDisplay

                infoRow

                MoonampMiniScrubberView()
                    .disabled(track == nil)
                    .opacity(track == nil ? 0.52 : 1)

                HStack(spacing: 8 * scale) {
                    MoonampMiniButton(icon: "backward.end.fill", size: 13 * scale) {
                        controller.skipPrevious()
                    }
                    MoonampMiniButton(icon: controller.isPlaying ? "pause.fill" : "play.fill", size: 15 * scale) {
                        controller.togglePlayPause()
                    }
                    MoonampMiniButton(icon: "forward.end.fill", size: 13 * scale) {
                        controller.skipNext()
                    }

                    Spacer(minLength: 6)

                    MoonampToggleButton(title: "SHUFFLE", isActive: controller.isShuffled) {
                        controller.toggleShuffle()
                    }
                }
                .disabled(track == nil)
                .opacity(track == nil ? 0.54 : 1)
            }
            .padding(.top, inset)
            .padding(.horizontal, inset)
            .padding(.bottom, bottomInset)

            Button {
                appState.exitMiniPlayer()
            } label: {
                Image(systemName: "pip.exit")
                    .font(AppTheme.current.font(.icon, size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "#d9dfec"))
                    .frame(width: 28, height: 28)
                    .background(MoonampBeveledBox(fill: Color(hex: "#2e334c"), cornerRadius: 2))
            }
            .buttonStyle(.plain)
            .help("Return to Full Player")
            .padding(inset)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.14), value: isHovered)
        }
        .background(Color(hex: "#15172a"))
    }

    private var header: some View {
        HStack(spacing: 9 * scale) {
            MoonampGoldStripe()
                .frame(minWidth: 26 * scale)
            Text("MOONAMP")
                .font(AppTheme.current.font(.brand, size: max(17, min(31 * scale, size.width * 0.105)), weight: .bold))
                .foregroundStyle(Color(hex: "#dfe5f2"))
                .shadow(color: Color.black.opacity(0.65), radius: 0, x: 2, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .layoutPriority(1)
            MoonampGoldStripe()
                .frame(minWidth: 26 * scale)
        }
        .frame(height: max(31, 42 * scale))
    }

    private var moonampTextDisplay: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(AppTheme.current.displayText(track?.displayTitle ?? "NOT PLAYING"))
                .font(AppTheme.current.font(.title, size: max(21, 30 * scale), weight: .medium))
                .foregroundStyle(Color(hex: "#00ff32"))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(AppTheme.current.displayText(track?.displayArtist ?? "CHOOSE A TRACK"))
                .font(AppTheme.current.font(.body, size: max(17, 24 * scale), weight: .medium))
                .foregroundStyle(Color(hex: "#00ff32"))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, minHeight: max(62, size.height * 0.18), alignment: .leading)
        .background(MoonampLCDBox())
    }

    private var infoRow: some View {
        HStack(spacing: 10 * scale) {
            MoonampInfoReadout(value: bitRateText, label: "kbps", scale: scale)
            MoonampInfoReadout(value: sampleRateText, label: "kHz", scale: scale)
            Spacer(minLength: 4)
            Text(channelText)
                .font(AppTheme.current.font(.control, size: max(17, 22 * scale), weight: .medium))
                .foregroundStyle(Color(hex: "#00ff32"))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    private var bitRateText: String {
        guard let bitRate = track?.bitRate, bitRate > 0 else { return "---" }
        return "\(bitRate > 1000 ? bitRate / 1000 : bitRate)"
    }

    private var sampleRateText: String {
        guard let sampleRate = track?.sampleRate, sampleRate > 0 else { return "--" }
        return "\(Int((Double(sampleRate) / 1000).rounded()))"
    }

    private var channelText: String {
        guard let channelCount = track?.channelCount, channelCount > 0 else { return "stereo" }
        return channelCount > 1 ? "stereo" : "mono"
    }
}

private struct MoonampPanelBackground: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: "#363951"),
                        Color(hex: "#22243c"),
                        Color(hex: "#15172a")
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
            .overlay {
                Rectangle()
                    .stroke(Color(hex: "#090a13"), lineWidth: 5)
                    .padding(2)
            }
            .overlay {
                Rectangle()
                    .stroke(Color(hex: "#5e607b"), lineWidth: 2)
                    .padding(7)
            }
            .ignoresSafeArea()
    }
}

private struct MoonampGoldStripe: View {
    var body: some View {
        VStack(spacing: 4) {
            Rectangle().fill(Color(hex: "#fff2a9")).frame(height: 4)
            Rectangle().fill(Color(hex: "#d6b547")).frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#11121d"))
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

private struct MoonampLCDBox: View {
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

private struct MoonampBeveledBox: View {
    let fill: Color
    var cornerRadius: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.70), lineWidth: 2)
                    .padding(1)
                    .mask(alignment: .top) { Rectangle().frame(height: 8) }
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.58), lineWidth: 2)
                    .padding(1)
                    .mask(alignment: .bottom) { Rectangle().frame(height: 8) }
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color(hex: "#6f7888"), lineWidth: 1))
    }
}

private struct MoonampSpectrumView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var phase: Double = 0
    @State private var levels: [Float] = Array(repeating: 0, count: 32)
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                MoonampLCDBox()

                Canvas { context, size in
                    let dot: CGFloat = 4
                    let gap: CGFloat = 4
                    let columns = max(1, Int(size.width / (dot + gap)))
                    let rows = max(1, Int(size.height / (dot + gap)))
                    let displayLevels = normalizedLevels(columnCount: columns)

                    for x in 0..<columns {
                        for y in 0..<rows {
                            let rect = CGRect(x: CGFloat(x) * (dot + gap) + 8, y: CGFloat(y) * (dot + gap) + 8, width: dot, height: dot)
                            context.fill(Path(rect), with: .color(Color(hex: "#151730").opacity(0.82)))
                        }
                    }

                    for x in 0..<columns {
                        let activeRows = Int(round(Double(displayLevels[x]) * Double(rows)))
                        for y in 0..<activeRows {
                            let normalized = Double(y) / Double(max(1, rows - 1))
                            let color: Color
                            if normalized > 0.72 {
                                color = Color(hex: "#ff4d16")
                            } else if normalized > 0.50 {
                                color = Color(hex: "#ffe65b")
                            } else {
                                color = Color(hex: "#00d348")
                            }
                            let drawY = size.height - CGFloat(y + 1) * (dot + gap) - 8
                            let rect = CGRect(x: CGFloat(x) * (dot + gap) + 10, y: drawY, width: dot, height: dot)
                            context.fill(Path(rect), with: .color(color))
                        }
                    }

                    let baselineY = size.height - 10
                    for x in 0..<columns {
                        let rect = CGRect(x: CGFloat(x) * (dot + gap) + 8, y: baselineY, width: dot, height: dot)
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
            var fallback: [Float] = []
            fallback.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let wave = sin(phase + Double(index) * 0.58)
                fallback.append(Float(0.10 + 0.04 * (wave + 1.0)))
            }
            return fallback
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
            let shimmer = Float(0.04 * (sin(phase + Double(index) * 0.41) + 1.0))
            normalized.append(min(1, max(0, (interpolated + shimmer) * volumeScale)))
        }
        return normalized
    }
}

private struct MoonampTimeDisplay: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.isPlaying ? "play.fill" : "pause.fill")
                .font(AppTheme.current.font(.icon, size: 24, weight: .bold))
                .foregroundStyle(Color(hex: "#00ff32"))
            Text(formatTime(elapsed))
                .font(AppTheme.current.font(.numeric, size: 48, weight: .medium))
                .foregroundStyle(Color(hex: "#00ff32"))
                .lineLimit(1)
                .minimumScaleFactor(0.35)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(MoonampLCDBox())
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { elapsed = $0 }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonampInfoReadout: View {
    let value: String
    let label: String
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            Text(value)
                .font(AppTheme.current.font(.numeric, size: max(17, 22 * scale), weight: .medium))
                .foregroundStyle(Color(hex: "#00ff32"))
                .frame(minWidth: max(43, 50 * scale))
                .padding(.horizontal, 5 * scale)
                .padding(.vertical, 5 * scale)
                .background(MoonampLCDBox())

            Text(label)
                .font(AppTheme.current.font(.control, size: max(14, 18 * scale), weight: .medium))
                .foregroundStyle(Color(hex: "#eef1f7"))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }
}

private struct MoonampMiniScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var suppressPublisherUpdatesUntil: Date?

    private var duration: TimeInterval { controller.engine.duration }
    private var displayTime: TimeInterval { isDragging ? dragValue : elapsed }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(hex: "#090a13"))
                    .overlay(Rectangle().stroke(Color(hex: "#555875"), lineWidth: 2))

                Rectangle()
                    .fill(Color(hex: "#7a7790"))
                    .frame(height: 2)
                    .padding(.horizontal, 6)

                MoonampBeveledBox(fill: Color(hex: "#dfd8a3"), cornerRadius: 2)
                    .frame(width: 38, height: 22)
                    .offset(x: max(4, min(proxy.size.width - 42, proxy.size.width * progress - 19)))
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
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
        .frame(height: 36)
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
}

private struct MoonampMiniButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: size, weight: .semibold))
                .foregroundStyle(Color(hex: "#596777"))
                .frame(width: 44, height: 36)
                .background(MoonampBeveledBox(fill: isHovered ? Color(hex: "#eff6fa") : Color(hex: "#d7e1e7"), cornerRadius: 2))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MoonampToggleButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(isActive ? Color(hex: "#00ff32") : Color(hex: "#596777"))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(AppTheme.current.font(.control, size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: "#2f3848"))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(MoonampBeveledBox(fill: isHovered ? Color(hex: "#eff6fa") : Color(hex: "#d7e1e7"), cornerRadius: 2))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct TerminalMiniPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: PlaybackController

    let size: CGSize
    let isHovered: Bool

    private var track: Track? { controller.currentTrack }
    private var scale: CGFloat { max(0.74, min(1.25, min(size.width, size.height) / 360)) }
    private var inset: CGFloat { max(12, min(22, min(size.width, size.height) * 0.052)) }
    private var queueText: String {
        guard !controller.queue.isEmpty else { return "QUEUE 000/000" }
        return String(format: "QUEUE %03d/%03d", controller.currentIndex + 1, controller.queue.count)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.bgContent.ignoresSafeArea()

            // Phosphor screen ambient
            RadialGradient(
                gradient: Gradient(colors: [Color.dAccent.opacity(0.06), Color.clear]),
                center: .center,
                startRadius: 30,
                endRadius: 260
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack {
                    Text("┌─ TERMINAL PLAYER")
                        .font(AppTheme.current.font(.control, size: 13 * scale, weight: .medium))
                        .foregroundStyle(Color.dAccentStrong)
                        .shadow(color: Color.dAccent.opacity(0.55), radius: 4)
                    Spacer()
                    Text(controller.isPlaying ? "RUN" : "PAUSE")
                        .font(AppTheme.current.font(.control, size: 13 * scale, weight: .medium))
                        .foregroundStyle(Color(hex: "#20c8ff"))
                        .shadow(color: Color(hex: "#20c8ff").opacity(0.45), radius: 3)
                }

                terminalLine(label: "TRACK", value: track?.displayTitle ?? "NO SIGNAL", size: max(18, 25 * scale), primary: true)
                terminalLine(label: "ARTIST", value: track?.displayArtist ?? "STANDBY", size: max(14, 18 * scale))
                terminalLine(label: "ALBUM", value: track?.displayAlbum ?? "NONE", size: max(12, 15 * scale))

                TerminalMiniMeter(isPlaying: controller.isPlaying)
                    .frame(height: max(18, 26 * scale))
                    .padding(.vertical, 2)

                HStack {
                    Text(queueText)
                    Spacer()
                    Text(controller.repeatMode == .off ? "REP OFF" : "REP ON")
                }
                .font(AppTheme.current.font(.metadata, size: 12 * scale, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .shadow(color: Color.dAccent.opacity(0.25), radius: 3)

                TerminalMiniScrubberView()
                    .frame(height: max(34, 42 * scale))

                HStack(spacing: 8 * scale) {
                    terminalButton("<<") { controller.skipPrevious() }
                    terminalButton(controller.isPlaying ? "PAUSE" : "PLAY") { controller.togglePlayPause() }
                    terminalButton(">>") { controller.skipNext() }
                }
                .disabled(track == nil)
                .opacity(track == nil ? 0.48 : 1)

                Spacer(minLength: 0)
            }
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TerminalMiniFrame())
            .overlay(TerminalVignetteOverlay())

            Button {
                appState.exitMiniPlayer()
            } label: {
                Image(systemName: "pip.exit")
                    .font(AppTheme.current.font(.icon, size: 13, weight: .medium))
                    .foregroundStyle(Color.dAccentStrong)
                    .frame(width: 30, height: 30)
                    .background(TerminalMiniBox())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.72)
            .padding(10)
            .help("Return to Full Player")
        }
    }

    private func terminalLine(label: String, value: String, size: CGFloat, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label)>")
                .font(AppTheme.current.font(.caption, size: max(10, size * 0.54), weight: .medium))
                .foregroundStyle(Color(hex: "#20c8ff"))
                .shadow(color: Color(hex: "#20c8ff").opacity(0.45), radius: 3)
            HStack(spacing: 3) {
                Text(AppTheme.current.displayText(value))
                    .font(AppTheme.current.font(primary ? .title : .metadata, size: size, weight: .medium))
                    .foregroundStyle(primary ? Color.dAccentStrong : Color.textPrimary)
                    .shadow(color: Color.dAccent.opacity(primary ? 0.55 : 0.30), radius: primary ? 4 : 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
                if primary {
                    TerminalCursorView()
                        .font(AppTheme.current.font(.title, size: size, weight: .medium))
                        .foregroundStyle(Color.dAccentStrong.opacity(0.72))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalMiniBox())
    }

    private func terminalButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.current.font(.control, size: 13 * scale, weight: .medium))
                .foregroundStyle(Color.dAccentStrong)
                .shadow(color: Color.dAccent.opacity(0.50), radius: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 32 * scale)
                .background(TerminalMiniBox())
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalCursorView: View {
    @State private var visible = true

    var body: some View {
        Text("█")
            .shadow(color: Color.dAccentStrong.opacity(0.70), radius: 6)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.65).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

private struct TerminalMiniFrame: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.34))
            .overlay(Rectangle().stroke(Color.dAccent.opacity(0.82), lineWidth: 1))
            .overlay(Rectangle().stroke(Color.dAccentStrong.opacity(0.16), lineWidth: 1).padding(3))
    }
}

private struct TerminalMiniBox: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.46))
            .overlay(Rectangle().stroke(Color.dAccent.opacity(0.74), lineWidth: 1))
    }
}

private struct TerminalMiniMeter: View {
    let isPlaying: Bool
    @State private var levels: [CGFloat] = Array(repeating: 0.3, count: 16)
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { proxy in
            let barCount = max(8, Int(proxy.size.width / 14))
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = i < levels.count ? levels[i] : 0.3
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(i % 5 == 0 ? Color(hex: "#20c8ff") : Color.dAccent)
                            .frame(height: proxy.size.height * level)
                    }
                    .opacity(isPlaying ? 0.88 : 0.26)
                    .animation(.easeInOut(duration: 0.12), value: level)
                }
            }
        }
        .onAppear { if isPlaying { startAnimation() } }
        .onDisappear { timer?.invalidate(); timer = nil }
        .onChange(of: isPlaying) { playing in
            if playing { startAnimation() } else { stopAnimation() }
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            levels = levels.indices.map { _ in CGFloat.random(in: 0.10...0.96) }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        withAnimation(.easeOut(duration: 0.4)) {
            levels = levels.map { _ in 0.12 }
        }
    }
}

private struct TerminalMiniScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0

    private var duration: TimeInterval {
        let engineDuration = controller.engine.duration
        if engineDuration.isFinite, engineDuration > 0 {
            return engineDuration
        }
        return controller.currentTrack?.duration ?? 0
    }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.dAccent.opacity(0.14))
                        .overlay(Rectangle().stroke(Color.dAccent.opacity(0.78), lineWidth: 1))
                    Rectangle()
                        .fill(Color(hex: "#20c8ff").opacity(0.90))
                        .frame(width: max(0, proxy.size.width * progress))
                }
            }
            .frame(height: 10)

            HStack {
                Text(formatTime(elapsed))
                Spacer()
                Text("-\(formatTime(max(0, duration - elapsed)))")
            }
            .font(AppTheme.current.font(.numeric, size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.textSecondary)
        }
        .onAppear { elapsed = controller.engine.currentTime }
        .onReceive(controller.engine.timePublisher) { elapsed = $0 }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonPodMiniPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: PlaybackController

    let size: CGSize
    let isHovered: Bool

    private var track: Track? { controller.currentTrack }
    private var isRetroMoonPod: Bool { AppTheme.current.transportChromeStyle == .retroMoonPod }
    private var queuePositionText: String {
        guard !controller.queue.isEmpty else { return "Not Playing" }
        return "\(controller.currentIndex + 1) of \(controller.queue.count)"
    }
    private var artSize: CGFloat {
        let side = min(size.width, size.height)
        return max(86, min(150, side * 0.35))
    }
    private var outerPadding: CGFloat {
        max(18, min(34, min(size.width, size.height) * 0.07))
    }

    var body: some View {
        if isRetroMoonPod {
            retroMoonPodBody
        } else {
            standardMoonPodBody
        }
    }

    private var standardMoonPodBody: some View {
        ZStack(alignment: .topTrailing) {
            miniBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: contentSpacing) {
                Text(queuePositionText)
                    .font(AppTheme.current.font(.metadata, size: titleCounterSize, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(alignment: .center, spacing: max(18, min(34, size.width * 0.08))) {
                    ArtworkView(
                        albumId: track?.albumId,
                        artworkId: track?.artworkId,
                        large: true,
                        decodeMaxPixelSize: Int(artSize * 2),
                        cornerRadius: 0,
                        iconFont: .system(size: max(28, artSize * 0.30)),
                        retainsPreviousImageWhileLoading: track != nil
                    )
                    .frame(width: artSize, height: artSize)
                    .overlay(Rectangle().stroke(Color.textPrimary.opacity(0.68), lineWidth: 1.5))
                    .background(Color.white)

                    VStack(alignment: .leading, spacing: max(6, min(12, size.height * 0.025))) {
                        moonPodText(AppTheme.current.displayText(track?.displayTitle ?? "Not Playing"), size: metadataTitleSize)
                        moonPodText(AppTheme.current.displayText(track?.displayArtist ?? "Choose a track"), size: metadataLineSize)
                        moonPodText(AppTheme.current.displayText(track?.displayAlbum ?? ""), size: metadataLineSize)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                MoonPodMiniScrubberView()
                    .padding(.top, scrubberTopOffset)
                    .disabled(track == nil)
                    .opacity(track == nil ? 0.45 : 1)

                MoonPodMiniControlsView()
                    .opacity(isHovered ? 1 : 0)
                    .disabled(track == nil)
                    .animation(.easeInOut(duration: 0.14), value: isHovered)
            }
            .padding(outerPadding)

            Button {
                appState.exitMiniPlayer()
            } label: {
                Image(systemName: "pip.exit")
                    .font(AppTheme.current.font(.icon, size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(exitButtonBackground)
            }
            .buttonStyle(.plain)
            .help("Return to Full Player")
            .padding(12)
            .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.14), value: isHovered)
        }
    }

    private var retroMoonPodBody: some View {
        ZStack(alignment: .topTrailing) {
            miniBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: controller.isPlaying ? "play.fill" : "pause.fill")
                        .font(AppTheme.current.font(.icon, size: 13, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 26, alignment: .leading)

                    Spacer()
                    Text("Now Playing")
                        .font(AppTheme.current.font(.title, size: max(16, min(22, size.width * 0.058)), weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()

                    Image(systemName: "battery.100")
                        .font(AppTheme.current.font(.icon, size: 13, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 26, alignment: .trailing)
                }
                .frame(height: max(30, min(38, size.height * 0.12)))
                .padding(.horizontal, 14)
                .background(Color.bgChrome)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.dAccent).frame(height: 1)
                }

                HStack {
                    Text(queuePositionText)
                        .font(AppTheme.current.font(.numeric, size: titleCounterSize, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()
                    Image(systemName: "shuffle")
                        .font(AppTheme.current.font(.icon, size: titleCounterSize, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                }
                .frame(height: max(24, min(32, size.height * 0.10)))
                .padding(.horizontal, 14)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(alignment: .center, spacing: max(5, min(9, size.height * 0.020))) {
                        moonPodText(AppTheme.current.displayText(track?.displayTitle ?? "Not Playing"), size: metadataTitleSize)
                        moonPodText(AppTheme.current.displayText(track?.displayArtist ?? "Choose a track"), size: metadataLineSize)
                        moonPodText(AppTheme.current.displayText(track?.displayAlbum ?? ""), size: metadataLineSize)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, outerPadding)

                    Spacer()
                        .frame(height: max(26, min(52, size.height * 0.12)))

                    MoonPodMiniScrubberView()
                        .padding(.horizontal, outerPadding)
                        .disabled(track == nil)
                        .opacity(track == nil ? 0.45 : 1)

                    MoonPodMiniControlsView()
                        .disabled(track == nil)
                        .opacity(track == nil ? 0.45 : 1)

                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }

            Button {
                appState.exitMiniPlayer()
            } label: {
                Image(systemName: "pip.exit")
                    .font(AppTheme.current.font(.icon, size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(exitButtonBackground)
            }
            .buttonStyle(.plain)
            .help("Return to Full Player")
            .padding(12)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.14), value: isHovered)
        }
    }

    @ViewBuilder
    private var miniBackground: some View {
        if isRetroMoonPod {
            Rectangle()
                .fill(Color.bgContent)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.bgContent)
                        .frame(height: 2)
                }
        } else {
            LinearGradient(
                colors: [
                    Color(hex: "#fbfaf6"),
                    Color(hex: "#eff3f4")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var exitButtonBackground: some View {
        if isRetroMoonPod {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.bgElevated)
        } else {
            Circle()
                .fill(Color.white.opacity(0.76))
                .overlay(Circle().strokeBorder(Color.borderSoft, lineWidth: 0.6))
        }
    }

    private var contentSpacing: CGFloat {
        isRetroMoonPod ? max(12, min(22, size.height * 0.048)) : max(16, min(28, size.height * 0.055))
    }

    private var titleCounterSize: CGFloat {
        isRetroMoonPod ? max(10, min(13, size.width * 0.034)) : max(12, min(16, size.width * 0.042))
    }

    private var scrubberTopOffset: CGFloat {
        isRetroMoonPod ? max(6, min(14, size.height * 0.026)) : max(10, min(20, size.height * 0.035))
    }

    private var metadataTitleSize: CGFloat {
        isRetroMoonPod ? max(15, min(22, size.width * 0.064)) : max(22, min(36, size.width * 0.10))
    }

    private var metadataLineSize: CGFloat {
        isRetroMoonPod ? max(12, min(18, size.width * 0.052)) : max(18, min(29, size.width * 0.078))
    }

    private func moonPodText(_ text: String, size: CGFloat) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(AppTheme.current.font(.metadata, size: size, weight: .medium))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
    }
}

private struct MoonPodMiniScrubberView: View {
    @EnvironmentObject private var controller: PlaybackController
    @State private var elapsed: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var isHovered = false
    @State private var suppressPublisherUpdatesUntil: Date?

    private var duration: TimeInterval { controller.engine.duration }
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
                    if isRetroMoonPod {
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
                    } else {
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(Color.white.opacity(0.88))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.borderSoft.opacity(0.40), lineWidth: 0.7))
                            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)

                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(Color(hex: "#00a7c8"))
                            .frame(width: max(0, proxy.size.width * progress))

                        if isHovered {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color(hex: "#00a7c8"), lineWidth: 1))
                                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                                .offset(x: max(0, proxy.size.width * progress) - 4)
                        }
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
            .frame(height: isRetroMoonPod ? 20 : 14)

            HStack {
                timeLabel(formatTime(displayTime), alignment: .leading)
                Spacer()
                timeLabel("-\(formatTime(remaining))", alignment: .trailing)
            }
        }
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
            .font(AppTheme.current.font(.numeric, size: AppTheme.current.isRetroMoonPod ? 15 : 25, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
            .frame(minWidth: 72, alignment: alignment)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MoonPodMiniControlsView: View {
    @EnvironmentObject private var controller: PlaybackController

    var body: some View {
        let isRetroMoonPod = AppTheme.current.transportChromeStyle == .retroMoonPod

        HStack(spacing: isRetroMoonPod ? 28 : 18) {
            controlButton(icon: "backward.fill", size: isRetroMoonPod ? 17 : 14, action: { controller.skipPrevious() })
            controlButton(icon: controller.isPlaying ? "pause.fill" : "play.fill", size: isRetroMoonPod ? 23 : 14, action: { controller.togglePlayPause() })
            controlButton(icon: "forward.fill", size: isRetroMoonPod ? 17 : 14, action: { controller.skipNext() })
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isRetroMoonPod ? 10 : 0)
    }

    private func controlButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        let isRetroMoonPod = AppTheme.current.transportChromeStyle == .retroMoonPod

        return Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: size, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: isRetroMoonPod ? 34 : 34, height: isRetroMoonPod ? 32 : 34)
                .background {
                    if !isRetroMoonPod {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, Color(hex: "#dfe3e7")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
                            .overlay(Circle().stroke(Color.borderMedium.opacity(0.30), lineWidth: 1).padding(1))
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct WindowModeWindowConfigurator: NSViewRepresentable {
    let mode: WindowMode
    let theme: AppTheme
    let showsWindowButtons: Bool
    let isEmptyLibrary: Bool
    private let windowButtonLeftInset: CGFloat = 16
    private let windowButtonTopInset: CGFloat = 16

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window, mode: mode, theme: theme, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window, mode: mode, theme: theme, context: context)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func configure(window: NSWindow?, mode: WindowMode, theme: AppTheme, context: Context) {
        guard let window else { return }
        configureTitlebar(for: window, mode: mode, theme: theme)
        updateWindowButtons(for: window, areVisible: showsWindowButtons)
        if mode == .library {
            window.minSize = isEmptyLibrary
                ? MiniPlayerWindowMetrics.emptyLibraryMinSize
                : MiniPlayerWindowMetrics.libraryMinSize
            if isEmptyLibrary, !context.coordinator.didSizeEmptyLibrary {
                context.coordinator.didSizeEmptyLibrary = true
                resize(window: window, contentSize: NSSize(width: 675, height: 600))
            }
        }
        guard context.coordinator.lastMode != mode else { return }
        let previousMode = context.coordinator.lastMode
        context.coordinator.lastMode = mode

        switch mode {
        case .miniPlayer:
            if previousMode != .miniPlayer {
                context.coordinator.lastLibraryFrame = window.frame
            }
            window.minSize = MiniPlayerWindowMetrics.minSize
            window.maxSize = MiniPlayerWindowMetrics.maxSize
            context.coordinator.constrainSquareResizing(for: window)
            resize(
                window: window,
                contentSize: MiniPlayerWindowMetrics.initialSize,
                centeredIn: context.coordinator.lastLibraryFrame
            )
        case .library:
            context.coordinator.restoreWindowDelegate(for: window)
            window.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            window.minSize = isEmptyLibrary
                ? MiniPlayerWindowMetrics.emptyLibraryMinSize
                : MiniPlayerWindowMetrics.libraryMinSize
            if previousMode == .miniPlayer {
                if let lastLibraryFrame = context.coordinator.lastLibraryFrame {
                    window.setFrame(constrainedToVisibleScreen(lastLibraryFrame, for: window), display: true, animate: false)
                } else {
                    resize(window: window, contentSize: MiniPlayerWindowMetrics.libraryFallbackSize)
                }
            }
        }
    }

    private func configureTitlebar(for window: NSWindow, mode: WindowMode, theme: AppTheme) {
        let isMiniPlayer = mode == .miniPlayer
        window.styleMask.insert(.titled)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = isMiniPlayer
        window.isOpaque = !isMiniPlayer
        window.backgroundColor = isMiniPlayer ? .clear : theme.palette.windowLibraryBackground
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        insetWindowButtons(for: window)
    }

    private func insetWindowButtons(for window: NSWindow) {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let superview = closeButton.superview else { return }

        let closeFrame = closeButton.frame
        let desiredY: CGFloat
        if superview.isFlipped {
            desiredY = windowButtonTopInset
        } else {
            desiredY = superview.bounds.height - windowButtonTopInset - closeFrame.height
        }

        for button in buttons {
            let offsetFromClose = button.frame.minX - closeFrame.minX
            button.setFrameOrigin(NSPoint(
                x: windowButtonLeftInset + offsetFromClose,
                y: desiredY
            ))
        }
    }

    private func updateWindowButtons(for window: NSWindow, areVisible: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.isHidden = !areVisible
            button.alphaValue = areVisible ? 1 : 0
        }
    }

    private func resize(window: NSWindow, contentSize: NSSize, centeredIn anchorFrame: NSRect? = nil) {
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = centeredOrigin(for: frame, in: anchorFrame ?? window.screen?.visibleFrame)
        window.setFrame(constrainedToVisibleScreen(frame, for: window), display: true, animate: false)
    }

    private func centeredOrigin(for frame: NSRect, in anchorFrame: NSRect?) -> NSPoint {
        guard let anchorFrame else { return frame.origin }
        return NSPoint(
            x: anchorFrame.midX - frame.width / 2,
            y: anchorFrame.midY - frame.height / 2
        )
    }

    private func constrainedToVisibleScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let visibleFrame = window.screen?.visibleFrame else { return frame }

        var constrainedFrame = frame
        if constrainedFrame.width <= visibleFrame.width {
            constrainedFrame.origin.x = min(
                max(constrainedFrame.minX, visibleFrame.minX),
                visibleFrame.maxX - constrainedFrame.width
            )
        } else {
            constrainedFrame.origin.x = visibleFrame.minX
        }

        if constrainedFrame.height <= visibleFrame.height {
            constrainedFrame.origin.y = min(
                max(constrainedFrame.minY, visibleFrame.minY),
                visibleFrame.maxY - constrainedFrame.height
            )
        } else {
            constrainedFrame.origin.y = visibleFrame.minY
        }

        return constrainedFrame
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var lastMode: WindowMode?
        weak var previousDelegate: NSWindowDelegate?
        var lastLibraryFrame: NSRect?
        var didSizeEmptyLibrary = false

        func constrainSquareResizing(for window: NSWindow) {
            guard window.delegate !== self else { return }
            previousDelegate = window.delegate
            window.delegate = self
        }

        func restoreWindowDelegate(for window: NSWindow) {
            guard window.delegate === self else { return }
            window.delegate = previousDelegate
            previousDelegate = nil
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            let minimum = max(sender.minSize.width, sender.minSize.height)
            let maximum = min(sender.maxSize.width, sender.maxSize.height)
            let side = min(maximum, max(minimum, max(frameSize.width, frameSize.height)))
            return NSSize(width: side, height: side)
        }
    }
}
