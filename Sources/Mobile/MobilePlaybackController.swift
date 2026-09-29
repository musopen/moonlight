// MobilePlaybackController.swift
//
// Plays music on iPhone and iPad. It keeps the play queue, handles play, pause, skip and seeking,
// and responds to headphone, lock screen and Control Center buttons. It also shows the current
// song on the lock screen, and reports back when a file turns out to be missing so the library can
// mark it unavailable.

import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class MobilePlaybackController: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    var didBeginTrack: ((Track) -> Void)?
    var artworkDataProvider: ((Track) -> Data?)?

    /// Called when a track the library advertises as playable turns out not to be.
    /// The library model uses this to correct `availability_status` and tell the
    /// user, instead of leaving the transport claiming to play silence.
    var didFailTrack: ((Track, String) -> Void)?

    private let player = AVPlayer()
    private var queue: [Track] = []
    private var timeObserver: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?

    init() {
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func play(_ track: Track, queue: [Track]) {
        guard track.isAvailable else { return }

        // Resolve through the container resolver rather than trusting the stored
        // string: rows written before v14 hold an absolute path from a previous
        // install, and the user can delete files out from under us via Files.app.
        guard let url = ContainerPathResolver.existingURL(forStoredFileURL: track.fileURL) else {
            didFailTrack?(track, "\(track.displayTitle) is no longer on this device.")
            return
        }

        self.queue = queue.filter(\.isAvailable)
        if currentTrack?.trackSyncId == track.trackSyncId, player.currentItem != nil {
            activateAudioSession(for: .playbackRequested)
            player.play()
            isPlaying = true
            updateNowPlayingRate()
            return
        }
        currentTrack = track
        currentTime = 0
        duration = track.duration ?? 0
        replaceCurrentItem(with: AVPlayerItem(url: url))
        activateAudioSession(for: .playbackRequested)
        player.play()
        isPlaying = true
        updateNowPlaying()
        didBeginTrack?(track)
    }

    func togglePlayPause() {
        guard player.currentItem != nil else { return }
        if isPlaying { player.pause() } else { activateAudioSession(for: .playbackRequested); player.play() }
        isPlaying.toggle()
        updateNowPlayingRate()
    }

    func seek(to value: TimeInterval) {
        let bounded = min(max(0, value), max(duration, 0))
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = bounded
        updateNowPlayingRate()
    }

    func next() {
        guard let currentTrack, let index = queue.firstIndex(where: { $0.trackSyncId == currentTrack.trackSyncId }), !queue.isEmpty else { return }
        play(queue[(index + 1) % queue.count], queue: queue)
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let currentTrack, let index = queue.firstIndex(where: { $0.trackSyncId == currentTrack.trackSyncId }), !queue.isEmpty else { return }
        play(queue[(index - 1 + queue.count) % queue.count], queue: queue)
    }

    /// Swaps in a new item and rebinds failure observation to it. `AVPlayer`
    /// reports a bad file only through the item's `status`, so an item installed
    /// without this observer fails silently and forever.
    private func replaceCurrentItem(with item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let resolved = item.duration.seconds
                    if resolved.isFinite && resolved > 0 { self.duration = resolved }
                    self.updateNowPlaying()
                case .failed:
                    self.handlePlaybackFailure(item.error)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func handlePlaybackFailure(_ error: Error?) {
        guard let track = currentTrack else { return }
        let reason = error?.localizedDescription ?? "the file could not be opened."
        let message = "\(track.displayTitle) could not be played: \(reason)"
        guard case .stopAndPresentError(let presentedMessage) = MobilePlaybackItemPolicy.action(
            for: .failed(message)
        ) else { return }
        player.pause()
        isPlaying = false
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        didFailTrack?(track, presentedMessage)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Category only. Activating a non-mixable `.playback` session here
            // would stop whatever the user is already listening to, just for
            // launching Moonlight to browse. Activation happens at the real
            // playback entry points instead.
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            activateAudioSession(for: .launch)
        } catch {
            NSLog("Moonlight Mobile: audio session setup failed: \(error)")
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite { self.duration = seconds }
            }
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let failedItem = note.object as? AVPlayerItem,
                  failedItem === self.player.currentItem else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self.handlePlaybackFailure(error) }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            player.pause(); isPlaying = false; updateNowPlayingRate()
        } else if let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
            // iOS deactivated the session on `.began`; resuming without
            // reactivating leaves the transport claiming to play, in silence.
            activateAudioSession(for: .interruptionEndedShouldResume)
            player.play(); isPlaying = true; updateNowPlayingRate()
        }
    }

    private func activateAudioSession(for event: MobileAudioSessionEvent) {
        guard MobileAudioSessionPolicy.requiresActivation(for: event) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        player.pause(); isPlaying = false; updateNowPlayingRate()
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(
            for: track,
            duration: duration,
            currentTime: currentTime,
            isPlaying: isPlaying,
            artworkData: artworkDataProvider?(track)
        )
    }

    static func nowPlayingInfo(
        for track: Track,
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        artworkData: Data?
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artworkData, let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return info
    }

    private func updateNowPlayingRate() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
