// ScrubberView.swift
//
// The time bar in the playback bar showing how far through the current song you are, with
// elapsed time on the left and time remaining on the right. Clicking or dragging along it jumps
// to a different point in the song. Its colors and shape follow the selected theme.

import SwiftUI
import Combine

struct ScrubberView: View {
    @EnvironmentObject var controller: PlaybackController
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
        return displayTime / duration
    }
    private var trackColor: Color {
        switch AppTheme.current.transportChromeStyle {
        case .terminal:
            Color.dAccent.opacity(0.22)
        case .moonamp, .moonPod:
            Color.borderMedium
        case .retroMoonPod:
            Color.borderStrong.opacity(0.58)
        case .standard:
            Color.white.opacity(0.28)
        }
    }
    private var progressColor: Color {
        switch AppTheme.current.transportChromeStyle {
        case .terminal:
            Color(hex: "#20c8ff")
        case .moonamp:
            Color.dAccentStrong
        case .moonPod:
            Color(hex: "#00a7c8")
        case .retroMoonPod:
            Color.dAccent
        case .standard:
            Color.white.opacity(0.68)
        }
    }
    private var barHeight: CGFloat {
        switch AppTheme.current.transportChromeStyle {
        case .terminal:
            isHovered ? 6 : 5
        case .moonamp, .moonPod, .retroMoonPod:
            isHovered ? 4 : 3
        case .standard:
            isHovered ? 6 : 5
        }
    }
    private let timeLabelWidth: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(displayTime))
                .font(AppTheme.current.font(.numeric, size: 11))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: timeLabelWidth, alignment: .trailing)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: AppTheme.current.transportChromeStyle == .terminal ? 0 : (AppTheme.current.transportChromeStyle == .retroMoonPod ? barHeight / 2 : 2))
                        .fill(trackColor)
                        .frame(height: barHeight)
                        .overlay {
                            if AppTheme.current.transportChromeStyle == .terminal {
                                Rectangle().stroke(Color.dAccent.opacity(0.72), lineWidth: 1)
                            }
                        }

                    // Fill
                    if AppTheme.current.transportChromeStyle == .retroMoonPod || AppTheme.current.transportChromeStyle == .terminal {
                        Rectangle()
                            .fill(progressColor)
                            .frame(width: max(0, proxy.size.width * progress), height: barHeight)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: max(0, proxy.size.width * progress), height: barHeight)
                    }

                    // Thumb — only on hover
                    if isHovered && AppTheme.current.transportChromeStyle != .retroMoonPod && AppTheme.current.transportChromeStyle != .terminal {
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
            .frame(height: 16)
            .animation(.easeInOut(duration: 0.12), value: isHovered)

            Text("-\(formatTime(remaining))")
                .font(AppTheme.current.font(.numeric, size: 11))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: timeLabelWidth, alignment: .leading)
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
