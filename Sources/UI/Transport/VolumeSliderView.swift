// VolumeSliderView.swift
//
// The volume slider in the playback bar. Dragging along it changes the volume; when audio goes
// to an AirPlay device that controls its own volume, the slider is greyed out and a tooltip
// explains why.

import SwiftUI

struct VolumeSliderView: View {
    @EnvironmentObject var controller: PlaybackController
    private var isEnabled: Bool { controller.volumeMode != .unavailableRouteVolume }
    private var foregroundOpacity: Double { isEnabled ? 1 : 0.35 }
    private var fillOpacity: Double { isEnabled ? 0.55 : 0.22 }
    private var fillColor: Color {
        switch AppTheme.current.transportChromeStyle {
        case .terminal:
            Color(hex: "#20c8ff").opacity(isEnabled ? 0.86 : 0.30)
        case .moonamp:
            Color.dAccentStrong.opacity(isEnabled ? 0.82 : 0.28)
        case .moonPod:
            Color(hex: "#00a7c8").opacity(isEnabled ? 0.86 : 0.30)
        case .retroMoonPod:
            Color.dAccent.opacity(isEnabled ? 0.86 : 0.30)
        case .standard:
            Color.white.opacity(fillOpacity)
        }
    }
    private var helpText: String {
        switch controller.volumeMode {
        case .playerVolume:
            "Volume"
        case .routeVolume:
            "AirPlay volume"
        case .unavailableRouteVolume:
            "Volume is controlled by the AirPlay device"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.volume < 0.01 ? "speaker.fill" : "speaker.wave.1.fill")
                .font(AppTheme.current.font(.icon, size: 12))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 14)
                .opacity(foregroundOpacity)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: AppTheme.current.transportChromeStyle == .terminal ? 0 : 2)
                        .fill(Color.borderMedium)
                        .frame(height: 2.5)

                    RoundedRectangle(cornerRadius: AppTheme.current.transportChromeStyle == .terminal ? 0 : 2)
                        .fill(fillColor)
                        .frame(width: max(0, proxy.size.width * Double(controller.volume)), height: 2.5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard isEnabled else { return }
                    controller.setVolume(Float(max(0, min(1, value.location.x / proxy.size.width))))
                })
            }
            .frame(height: 14)
            .opacity(foregroundOpacity)
        }
        .help(helpText)
    }
}
