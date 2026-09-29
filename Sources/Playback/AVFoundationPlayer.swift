// AVFoundationPlayer.swift
//
// The Mac's audio player: it actually plays track files using Apple's built-in media framework. It
// reports play/pause state and playback position, lines up the next song in advance for gapless
// playback, and reports errors for files that cannot play. It also measures the loudness of each
// song to drive the on-screen level meter, and exposes the current audio output for AirPlay.

import AVFoundation
import Combine
import Foundation

final class AVFoundationPlayer: NSObject, PlaybackEngine, AirPlayRouteProviding, AudioLevelProviding {
    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var currentItem: AVPlayerItem?
    private var queuedNextItem: AVPlayerItem?
    private var currentURL: URL?
    private var waveformURL: URL?
    private var waveformLevels: [Float] = []
    private var waveformTask: Task<Void, Never>?
    private var currentVolume: Float = 1.0

    private let stateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let audioLevelsSubject = CurrentValueSubject<[Float], Never>(Array(repeating: 0, count: 32))
    private let itemTransitionSubject = PassthroughSubject<Void, Never>()
    private let externalPlaybackActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let audioOutputDeviceUniqueIDSubject = CurrentValueSubject<String?, Never>(nil)
    private var cancellables = Set<AnyCancellable>()
    private var itemStatusCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var queuedNextFailure: String?

    var state: PlaybackState { stateSubject.value }
    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }
    var duration: TimeInterval {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }
    var statePublisher: AnyPublisher<PlaybackState, Never> { stateSubject.eraseToAnyPublisher() }
    var timePublisher: AnyPublisher<TimeInterval, Never> { timeSubject.eraseToAnyPublisher() }
    var audioLevelsPublisher: AnyPublisher<[Float], Never> { audioLevelsSubject.eraseToAnyPublisher() }
    var itemTransitionPublisher: AnyPublisher<Void, Never> { itemTransitionSubject.eraseToAnyPublisher() }
    var airPlayRoutePickerPlayer: AVPlayer { player }
    var externalPlaybackActive: Bool { player.isExternalPlaybackActive }
    var audioOutputDeviceUniqueID: String? { player.audioOutputDeviceUniqueID }
    var externalPlaybackActivePublisher: AnyPublisher<Bool, Never> {
        externalPlaybackActiveSubject.eraseToAnyPublisher()
    }
    var audioOutputDeviceUniqueIDPublisher: AnyPublisher<String?, Never> {
        audioOutputDeviceUniqueIDSubject.eraseToAnyPublisher()
    }

    override init() {
        super.init()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        AVOutputContextSPI.attach(AVOutputContextSPI.sharedAudioContext, to: player)
        RouteVolumeDiagnostics.reset()
        RouteVolumeDiagnostics.log("AVFoundationPlayer init allowsExternalPlayback=\(player.allowsExternalPlayback) externalPlaybackActive=\(player.isExternalPlaybackActive) audioOutputDeviceUniqueID=\(player.audioOutputDeviceUniqueID ?? "nil")")
        externalPlaybackActiveSubject.send(player.isExternalPlaybackActive)
        audioOutputDeviceUniqueIDSubject.send(player.audioOutputDeviceUniqueID)

        player.publisher(for: \.isExternalPlaybackActive, options: [.initial, .new])
            .sink { [weak self] isActive in
                RouteVolumeDiagnostics.log("AVPlayer externalPlaybackActive changed: \(isActive)")
                self?.externalPlaybackActiveSubject.send(isActive)
            }
            .store(in: &cancellables)

        player.publisher(for: \.audioOutputDeviceUniqueID, options: [.initial, .new])
            .sink { [weak self] deviceUID in
                RouteVolumeDiagnostics.log("AVPlayer audioOutputDeviceUniqueID changed: \(deviceUID ?? "nil")")
                self?.audioOutputDeviceUniqueIDSubject.send(deviceUID)
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status == .playing else { return }
                guard self.stateSubject.value != .playing else { return }
                self.stateSubject.send(.playing)
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.timeSubject.send(time.seconds)
            self.publishAudioLevels(at: time.seconds)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    func play(url: URL, nextURL: URL? = nil) throws {
        let item = makeItem(url: url)
        player.removeAllItems()
        clearItemStatusObservers()
        currentItem = item
        queuedNextItem = nil
        queuedNextFailure = nil
        currentURL = url
        beginWaveformAnalysis(for: url)
        player.insert(item, after: nil)
        observeStatus(of: item)
        stateSubject.send(.loading)
        prepareNext(url: nextURL)
        player.play()
    }

    func prepareNext(url: URL?) {
        if let queuedNextItem {
            player.remove(queuedNextItem)
            removeStatusObserver(for: queuedNextItem)
            self.queuedNextItem = nil
        }
        queuedNextFailure = nil

        guard let currentItem, let url else { return }
        let item = makeItem(url: url)
        guard player.canInsert(item, after: currentItem) else { return }
        player.insert(item, after: currentItem)
        queuedNextItem = item
        observeStatus(of: item)
    }

    func pause() {
        player.pause()
        stateSubject.send(.paused)
        audioLevelsSubject.send(Array(repeating: 0, count: 32))
    }

    func resume() {
        stateSubject.send(.loading)
        player.play()
    }

    func stop() {
        clearPlaybackItems()
        stateSubject.send(.stopped)
    }

    private func clearPlaybackItems() {
        player.pause()
        player.removeAllItems()
        clearItemStatusObservers()
        currentItem = nil
        queuedNextItem = nil
        queuedNextFailure = nil
        currentURL = nil
        waveformLevels = []
        waveformURL = nil
        waveformTask?.cancel()
        timeSubject.send(0)
        audioLevelsSubject.send(Array(repeating: 0, count: 32))
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Float) {
        currentVolume = max(0, min(1, volume))
        player.volume = currentVolume
        publishAudioLevels(at: currentTime)
    }

    private func observeStatus(of item: AVPlayerItem) {
        let identifier = ObjectIdentifier(item)
        itemStatusCancellables[identifier] = item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, status == .failed else { return }
                let message = item.error?.localizedDescription ?? "This track could not be played."
                if item === self.currentItem {
                    self.failPlayback(message)
                } else if item === self.queuedNextItem {
                    // The current item is still playing. Surface this failure at the
                    // transition rather than reporting a global playback error early.
                    self.queuedNextFailure = message
                }
            }
    }

    private func removeStatusObserver(for item: AVPlayerItem) {
        itemStatusCancellables.removeValue(forKey: ObjectIdentifier(item))
    }

    private func clearItemStatusObservers() {
        itemStatusCancellables.removeAll()
    }

    private func failPlayback(_ message: String) {
        clearPlaybackItems()
        stateSubject.send(.error(message))
    }

    /// Options applied to every playback asset.
    ///
    /// Deliberately empty. Requesting precise duration and timing can require
    /// substantial advance parsing for formats without enough timing summary data.
    /// It delayed a 305 MB FLAC by about 60 seconds on a slow external volume. Track
    /// duration comes from the library scan, and playback does not require it.
    static let assetOptions: [String: Any] = [:]

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: Self.assetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        return item
    }

    private func beginWaveformAnalysis(for url: URL) {
        waveformTask?.cancel()
        waveformLevels = []
        waveformURL = nil
        audioLevelsSubject.send(Array(repeating: 0, count: 32))

        waveformTask = Task.detached(priority: .utility) { [weak self] in
            let levels = Self.analyzeWaveform(url: url, bucketCount: 512)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                self.waveformURL = url
                self.waveformLevels = levels
                self.publishAudioLevels(at: self.currentTime)
            }
        }
    }

    private func publishAudioLevels(at time: TimeInterval) {
        guard state == .playing, currentVolume > 0.001 else {
            audioLevelsSubject.send(Array(repeating: 0, count: 32))
            return
        }

        guard !waveformLevels.isEmpty else {
            audioLevelsSubject.send(Self.idleLevels(at: time).map { $0 * currentVolume })
            return
        }

        let duration = max(self.duration, 0.1)
        let center = Int((time / duration) * Double(waveformLevels.count - 1))
        let barCount = 32
        let half = barCount / 2
        let bars = (0..<barCount).map { index -> Float in
            let sourceIndex = min(waveformLevels.count - 1, max(0, center - half + index))
            let localMotion = Float(0.92 + 0.08 * sin(time * 12.0 + Double(index) * 0.73))
            return min(1, waveformLevels[sourceIndex] * localMotion * currentVolume)
        }
        audioLevelsSubject.send(bars)
    }

    private static func idleLevels(at time: TimeInterval) -> [Float] {
        (0..<32).map { index -> Float in
            let phase = time * 2.0 + Double(index) * 0.55
            let value = 0.10 + 0.04 * (sin(phase) + 1.0)
            return Float(value)
        }
    }

    private static func analyzeWaveform(url: URL, bucketCount: Int) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            return Array(repeating: 0, count: bucketCount)
        }

        let duration = max(asset.duration.seconds, 0.1)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32
        ]

        do {
            let reader = try AVAssetReader(asset: asset)
            guard !Task.isCancelled else { return Array(repeating: 0, count: bucketCount) }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return Array(repeating: 0, count: bucketCount) }
            reader.add(output)
            guard reader.startReading() else { return Array(repeating: 0, count: bucketCount) }

            var sumSquares = Array(repeating: Double(0), count: bucketCount)
            var sampleCounts = Array(repeating: Int(0), count: bucketCount)

            while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let sampleDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
                      let dataPointer,
                      length > 0
                else { continue }

                let sampleCount = length / MemoryLayout<Float>.size
                let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
                let sampleStride = max(1, sampleCount / 256)

                for sampleIndex in stride(from: 0, to: sampleCount, by: sampleStride) {
                    let progress = min(0.999, max(0, (pts + sampleDuration * Double(sampleIndex) / Double(max(1, sampleCount))) / duration))
                    let bucket = min(bucketCount - 1, max(0, Int(progress * Double(bucketCount))))
                    let sample = max(-1, min(1, Double(floatPointer[sampleIndex])))
                    sumSquares[bucket] += sample * sample
                    sampleCounts[bucket] += 1
                }
            }

            // `cancelReading()` must not be called here from another thread while
            // `copyNextSampleBuffer()` is active. On macOS 26, that concurrent
            // teardown can crash inside AVFoundation. A cancelled waveform is
            // disposable, so cooperative cancellation can safely wait for the
            // current sample read to complete before this reader is released.
            guard !Task.isCancelled else { return Array(repeating: 0, count: bucketCount) }

            let rawLevels = zip(sumSquares, sampleCounts).map { sum, count -> Float in
                guard count > 0 else { return 0 }
                return Float(sqrt(sum / Double(count)))
            }
            let maxLevel = max(rawLevels.max() ?? 0, 0.001)
            return rawLevels.map { min(1, pow($0 / maxLevel, 0.62)) }
        } catch {
            return Array(repeating: 0, count: bucketCount)
        }
    }

    @objc private func itemDidFinish(_ notification: Notification) {
        guard let finishedItem = notification.object as? AVPlayerItem,
              finishedItem === currentItem else { return }

        if let nextItem = queuedNextItem {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.currentItem === finishedItem, self.queuedNextItem === nextItem else { return }
                let nextFailure = self.queuedNextFailure
                    ?? (nextItem.status == .failed
                        ? nextItem.error?.localizedDescription ?? "This track could not be played."
                        : nil)
                self.removeStatusObserver(for: finishedItem)

                if let nextFailure {
                    self.failPlayback(nextFailure)
                    return
                }

                self.currentItem = nextItem
                self.queuedNextItem = nil
                self.queuedNextFailure = nil
                self.stateSubject.send(.playing)
                self.itemTransitionSubject.send()
            }
        } else {
            stateSubject.send(.stopped)
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        waveformTask?.cancel()
    }
}
