// LastFMScrobbleCoordinator.swift
//
// Watches playback and decides when a song counts as listened to under Last.fm's rules (more than
// 30 seconds long and played for half its length or four minutes). It tells Last.fm what is
// playing now and keeps a saved queue of listens, retrying later if the network or Last.fm is
// unavailable.

import Foundation
import GRDB

struct LastFMPlaybackAccumulator: Equatable {
    let duration: TimeInterval
    private(set) var listened: TimeInterval = 0
    private(set) var isPlaying = true
    private var lastPosition: TimeInterval
    private var lastUptime: TimeInterval

    init(duration: TimeInterval, position: TimeInterval, uptime: TimeInterval) {
        self.duration = duration
        self.lastPosition = position
        self.lastUptime = uptime
    }

    var requiredListeningTime: TimeInterval {
        min(duration / 2, 240)
    }

    var isEligible: Bool {
        duration > 30 && listened >= requiredListeningTime
    }

    mutating func tick(position: TimeInterval, uptime: TimeInterval) {
        defer {
            lastPosition = position
            lastUptime = uptime
        }
        guard isPlaying else { return }
        let positionDelta = position - lastPosition
        let wallDelta = max(0, uptime - lastUptime)
        guard positionDelta >= 0 else { return }
        listened += min(positionDelta, wallDelta + 0.5)
    }

    mutating func pause(position: TimeInterval, uptime: TimeInterval) {
        tick(position: position, uptime: uptime)
        isPlaying = false
    }

    mutating func resume(position: TimeInterval, uptime: TimeInterval) {
        isPlaying = true
        lastPosition = position
        lastUptime = uptime
    }

    mutating func seek(to position: TimeInterval, uptime: TimeInterval) {
        lastPosition = position
        lastUptime = uptime
    }
}

@MainActor
final class LastFMScrobbleCoordinator {
    var onSessionInvalidated: (() -> Void)?

    private struct CurrentPlay {
        let scrobble: LastFMScrobble
        var accumulator: LastFMPlaybackAccumulator
        var hasEnteredOutbox = false
    }

    private let db: DatabaseManager
    private let apiClient: LastFMAPIProviding
    private let sessionStore: LastFMSessionStoring
    private let dateProvider: () -> Date
    private let uptimeProvider: () -> TimeInterval
    private var currentPlay: CurrentPlay?
    private var drainTask: Task<Void, Never>?
    private var scheduledRetryTask: Task<Void, Never>?

    init(
        db: DatabaseManager,
        apiClient: LastFMAPIProviding,
        sessionStore: LastFMSessionStoring,
        dateProvider: @escaping () -> Date = Date.init,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.db = db
        self.apiClient = apiClient
        self.sessionStore = sessionStore
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
    }

    func trackDidStart(_ track: Track, position: TimeInterval) {
        currentPlay = nil
        guard let session = try? sessionStore.loadSession(),
              let metadata = LastFMTrackMetadata(track: track)
        else { return }

        let now = dateProvider()
        sendNowPlaying(metadata, sessionKey: session.key)

        guard let duration = track.duration, duration.isFinite, duration > 30 else { return }
        let scrobble = LastFMScrobble(
            metadata: metadata,
            startedAt: Int(now.timeIntervalSince1970)
        )
        currentPlay = CurrentPlay(
            scrobble: scrobble,
            accumulator: LastFMPlaybackAccumulator(
                duration: duration,
                position: position,
                uptime: uptimeProvider()
            )
        )
    }

    func playbackPositionDidChange(_ position: TimeInterval) {
        guard var currentPlay else { return }
        currentPlay.accumulator.tick(position: position, uptime: uptimeProvider())
        self.currentPlay = currentPlay
        enqueueCurrentPlayIfEligible()
    }

    func playbackDidPause(position: TimeInterval) {
        guard var currentPlay else { return }
        currentPlay.accumulator.pause(position: position, uptime: uptimeProvider())
        self.currentPlay = currentPlay
        enqueueCurrentPlayIfEligible()
    }

    func playbackDidResume(position: TimeInterval) {
        guard var currentPlay else { return }
        currentPlay.accumulator.resume(position: position, uptime: uptimeProvider())
        self.currentPlay = currentPlay
    }

    func playbackDidSeek(to position: TimeInterval) {
        guard var currentPlay else { return }
        currentPlay.accumulator.seek(to: position, uptime: uptimeProvider())
        self.currentPlay = currentPlay
    }

    func playbackDidStop() {
        currentPlay = nil
    }

    func sessionDidBecomeAvailable() {
        drainOutbox()
    }

    func sessionDidBecomeInvalid() {
        currentPlay = nil
        drainTask?.cancel()
        drainTask = nil
        scheduledRetryTask?.cancel()
        scheduledRetryTask = nil
    }

    func disconnectAndClear() {
        sessionDidBecomeInvalid()
        try? db.write { db in
            try db.execute(sql: "DELETE FROM lastfm_scrobble_outbox")
        }
    }

    private func enqueueCurrentPlayIfEligible() {
        guard var currentPlay,
              currentPlay.accumulator.isEligible,
              !currentPlay.hasEnteredOutbox
        else { return }

        let entry = LastFMOutboxEntry(scrobble: currentPlay.scrobble, now: dateProvider())
        do {
            try db.write { db in try entry.insert(db) }
            currentPlay.hasEnteredOutbox = true
            self.currentPlay = currentPlay
            drainOutbox()
        } catch {
            NSLog("Moonlight: unable to queue a Last.fm scrobble: \(error.localizedDescription)")
        }
    }

    private func sendNowPlaying(_ metadata: LastFMTrackMetadata, sessionKey: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await apiClient.updateNowPlaying(sessionKey: sessionKey, track: metadata)
            } catch let error as LastFMAPIError where error.requiresReauthentication {
                onSessionInvalidated?()
            } catch {
                // Last.fm explicitly says failed Now Playing requests must not be retried.
            }
        }
    }

    private func drainOutbox() {
        guard drainTask == nil else { return }
        scheduledRetryTask?.cancel()
        scheduledRetryTask = nil
        drainTask = Task { [weak self] in
            guard let self else { return }
            await drainOutboxLoop()
            drainTask = nil
        }
    }

    private func drainOutboxLoop() async {
        while !Task.isCancelled {
            guard let session = try? sessionStore.loadSession() else { return }
            let now = dateProvider()
            let entries = (try? db.read { db in
                try LastFMOutboxEntry
                    .filter(Column("next_attempt_at") <= now)
                    .order(Column("created_at"), Column("id"))
                    .limit(50)
                    .fetchAll(db)
            }) ?? []

            guard !entries.isEmpty else {
                scheduleNextRetryIfNeeded()
                return
            }

            do {
                _ = try await apiClient.submitScrobbles(
                    sessionKey: session.key,
                    scrobbles: entries.map(\.scrobble)
                )
                delete(entries)
            } catch let error as LastFMAPIError {
                if error.requiresReauthentication {
                    onSessionInvalidated?()
                    return
                }
                if error.isRetryableScrobbleFailure {
                    reschedule(entries)
                    scheduleNextRetryIfNeeded()
                    return
                }
                delete(entries)
            } catch {
                reschedule(entries)
                scheduleNextRetryIfNeeded()
                return
            }
        }
    }

    private func delete(_ entries: [LastFMOutboxEntry]) {
        try? db.write { db in
            for entry in entries {
                try LastFMOutboxEntry.deleteOne(db, key: entry.id)
            }
        }
    }

    private func reschedule(_ entries: [LastFMOutboxEntry]) {
        let now = dateProvider()
        try? db.write { db in
            for var entry in entries {
                entry.attemptCount += 1
                let exponent = min(entry.attemptCount - 1, 7)
                let delay = min(3_600.0, 30.0 * pow(2.0, Double(exponent)))
                entry.nextAttemptAt = now.addingTimeInterval(delay)
                try entry.update(db)
            }
        }
    }

    private func scheduleNextRetryIfNeeded() {
        guard scheduledRetryTask == nil else { return }
        let nextAttempt = try? db.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT MIN(next_attempt_at) FROM lastfm_scrobble_outbox"
            )
        }
        guard let nextAttempt else { return }
        let delay = max(1, nextAttempt.timeIntervalSince(dateProvider()))
        scheduledRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            scheduledRetryTask = nil
            drainOutbox()
        }
    }
}
