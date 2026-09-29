// AirPlayRoutePickerView.swift
//
// The AirPlay button in the playback bar. Clicking it opens the Mac's standard list of speakers
// and devices so the user can send audio to another output, and tells the rest of the app when
// that list is closed.

import AVFoundation
import AVKit
import SwiftUI

struct AirPlayRoutePickerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.delegate = context.coordinator
        configure(view)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        nsView.delegate = context.coordinator
        configure(nsView)
    }

    private func configure(_ view: AVRoutePickerView) {
        view.player = player
        AVOutputContextSPI.attachOutputContextID(from: player, to: view)
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        view.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.white.withAlphaComponent(0.96), for: .active)
        view.setRoutePickerButtonColor(.white, for: .activeHighlighted)
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            NotificationCenter.default.post(name: .moonlightAirPlayRoutePickerDidEnd, object: routePickerView)
        }
    }
}

extension Notification.Name {
    static let moonlightAirPlayRoutePickerDidEnd = Notification.Name("MoonlightAirPlayRoutePickerDidEnd")
}
