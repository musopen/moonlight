// PlaybackEngine.swift
//
// Describes the basic controls any audio player in Moonlight must offer, such as play, pause,
// stop, seek, set volume and queue the next track, plus its possible states (playing, paused,
// loading, error). Having this shared description lets the real player be swapped for a stand-in
// during testing.

import Foundation
import Combine

enum PlaybackState: Equatable {
    case stopped
    case playing
    case paused
    case loading
    case error(String)
}

protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var statePublisher: AnyPublisher<PlaybackState, Never> { get }
    var timePublisher: AnyPublisher<TimeInterval, Never> { get }
    var itemTransitionPublisher: AnyPublisher<Void, Never> { get }

    func play(url: URL) throws
    func play(url: URL, nextURL: URL?) throws
    func prepareNext(url: URL?)
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Float)
}

protocol AudioLevelProviding {
    var audioLevelsPublisher: AnyPublisher<[Float], Never> { get }
}

extension PlaybackEngine {
    func play(url: URL) throws {
        try play(url: url, nextURL: nil)
    }
}
