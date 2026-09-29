// ScenePlayerView.swift
//
// Plays the optional looping background video (a "scene") behind the Now Playing screen. The
// video is always silent, repeats endlessly, and pauses or stops when scenes are turned off or
// the screen closes.

import AVFoundation
import SwiftUI

struct ScenePlayerView: NSViewRepresentable {
    let url: URL
    let isEnabled: Bool

    func makeNSView(context: Context) -> ScenePlayerContainerView {
        let view = ScenePlayerContainerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: ScenePlayerContainerView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.configure(url: url, isEnabled: isEnabled)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: ScenePlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private weak var view: ScenePlayerContainerView?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?
        private var scopedURL: URL?
        private var didStartSecurityScope = false

        func attach(to view: ScenePlayerContainerView) {
            self.view = view
            view.playerLayer.player = player
        }

        func configure(url: URL, isEnabled: Bool) {
            guard isEnabled else {
                pause()
                return
            }

            if currentURL != url {
                stop()
                start(url: url)
            } else {
                player?.play()
            }
        }

        func stop() {
            player?.pause()
            player?.removeAllItems()
            view?.playerLayer.player = nil
            looper = nil
            player = nil
            currentURL = nil

            if didStartSecurityScope {
                scopedURL?.stopAccessingSecurityScopedResource()
                didStartSecurityScope = false
            }
            scopedURL = nil
        }

        private func pause() {
            player?.pause()
        }

        private func start(url: URL) {
            didStartSecurityScope = url.startAccessingSecurityScopedResource()
            scopedURL = url

            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.volume = 0
            queuePlayer.actionAtItemEnd = .none
            queuePlayer.allowsExternalPlayback = false

            player = queuePlayer
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            currentURL = url
            view?.playerLayer.player = queuePlayer
            queuePlayer.play()
        }
    }
}

final class ScenePlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
