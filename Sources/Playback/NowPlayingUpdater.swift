// NowPlayingUpdater.swift
//
// Keeps the system's "Now Playing" display in step with Moonlight, showing the current song or
// radio station with its title, artist, album and progress. It also lets the system's own play,
// pause, skip and scrub controls operate Moonlight's player.

import Foundation
import MediaPlayer
import Combine

@MainActor
final class NowPlayingUpdater {
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var cancellables = Set<AnyCancellable>()

    init(controller: PlaybackController) {
        registerCommands(controller: controller)
        observe(controller: controller)
    }

    private func registerCommands(controller: PlaybackController) {
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.performMediaCommand(.play) }
            return .success
        }

        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.performMediaCommand(.pause) }
            return .success
        }

        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.performMediaCommand(.playPause) }
            return .success
        }

        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.performMediaCommand(.next) }
            return .success
        }

        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.performMediaCommand(.previous) }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak controller] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in controller?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func observe(controller: PlaybackController) {
        Publishers.CombineLatest(controller.$currentTrack, controller.$currentRadioStation)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] track, station in
                self?.updateInfo(
                    track: track,
                    station: station,
                    elapsed: controller?.engine.currentTime ?? 0,
                    isPlaying: controller?.engine.state == .playing
                )
            }
            .store(in: &cancellables)

        controller.engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] state in
                self?.updateInfo(
                    track: controller?.currentTrack,
                    station: controller?.currentRadioStation,
                    elapsed: controller?.engine.currentTime ?? 0,
                    isPlaying: state == .playing
                )
            }
            .store(in: &cancellables)

        controller.engine.timePublisher
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak controller] elapsed in
                guard controller?.engine.state == .playing,
                      controller?.currentRadioStation == nil else { return }
                self?.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            }
            .store(in: &cancellables)
    }

    private func updateInfo(
        track: Track?,
        station: RadioStation?,
        elapsed: TimeInterval,
        isPlaying: Bool
    ) {
        if let station {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: station.name,
                MPMediaItemPropertyArtist: "Live Radio",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            ]
            if let country = station.country ?? station.countryCode {
                info[MPMediaItemPropertyAlbumTitle] = country
            }
            infoCenter.nowPlayingInfo = info
            infoCenter.playbackState = isPlaying ? .playing : .paused
            return
        }

        guard let track else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = track.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }
}
