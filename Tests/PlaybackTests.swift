import XCTest
import AVFoundation
import Combine
@testable import Moonlight

@MainActor
final class PlaybackTests: XCTestCase {

    func testInitialState() {
        let db = makeTemporaryDatabase()
        let controller = PlaybackController(db: db, enableMediaKeyMonitor: false)
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(controller.queue.count, 0)
        XCTAssertEqual(controller.repeatMode, .off)
        XCTAssertFalse(controller.isShuffled)
    }

    func testShuffleToggle() {
        let db = makeTemporaryDatabase()
        let controller = PlaybackController(db: db, enableMediaKeyMonitor: false)
        XCTAssertFalse(controller.isShuffled)
        controller.toggleShuffle()
        XCTAssertTrue(controller.isShuffled)
        controller.toggleShuffle()
        XCTAssertFalse(controller.isShuffled)
    }

    func testRepeatModeCycle() {
        let db = makeTemporaryDatabase()
        let controller = PlaybackController(db: db, engine: TestPlaybackEngine(), enableMediaKeyMonitor: false)

        XCTAssertEqual(controller.repeatMode, .off)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.repeatMode, .all)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.repeatMode, .one)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.repeatMode, .off)
    }

    func testRadioStationPlaysFromItsBundledAddress() throws {
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: makeTemporaryDatabase(), engine: engine, enableMediaKeyMonitor: false)
        let catalog = try ReviewedRadioCatalog()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RadioPlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RadioViewModel(catalog: catalog, userState: try RadioUserState(catalog: catalog, directory: directory))
        let station = try XCTUnwrap(catalog.fetchStations(limit: 1).first)

        model.play(station, using: controller)

        XCTAssertEqual(engine.playedURL?.absoluteString, station.streamURL)
        XCTAssertEqual(controller.currentRadioStation?.stationUUID, station.stationUUID)
        XCTAssertNil(model.notice)
    }

    func testRadioPlaybackUsesSharedEngineAndLibraryTrackReplacesIt() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let streamURL = try XCTUnwrap(URL(string: "https://radio.example/live"))
        let station = RadioStation(
            id: 1,
            stationUUID: "11111111-1111-1111-1111-111111111111",
            changeUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            name: "Classical KUSC",
            streamURL: streamURL.absoluteString,
            tags: ["classical", "music"],
            countryCode: "US",
            country: "United States",
            codec: "MP3",
            bitrate: 192,
            votes: 100,
            clickCount: 200,
            isPopular: true,
            lastCheckOK: true,
            latitude: 34.05,
            longitude: -118.24
        )

        controller.playRadio(station: station, streamURL: streamURL)

        XCTAssertEqual(engine.playedURL, streamURL)
        XCTAssertEqual(controller.currentRadioStation, station)
        XCTAssertNil(controller.currentTrack)
        XCTAssertTrue(controller.queue.isEmpty)

        let track = try XCTUnwrap(insertTracks(count: 1, db: db).first)
        controller.play(track: track)

        XCTAssertNil(controller.currentRadioStation)
        XCTAssertEqual(controller.currentTrack?.dbId, track.dbId)
    }

    func testShuffleToggleReconfiguresPreparedNextWhenDisabled() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)
        engine.preparedNextURL = URL(fileURLWithPath: "/tmp/stale-prepared-item")
        controller.toggleShuffle()
        controller.toggleShuffle()

        XCTAssertEqual(engine.preparedNextURL, URL(string: controller.queue[controller.currentIndex + 1].fileURL))
    }

    func testDisablingShuffleRestoresOriginalQueueOrderFromCurrentTrack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 4, db: db)

        controller.play(track: tracks[1], in: tracks)
        controller.toggleShuffle()
        controller.toggleShuffle()

        XCTAssertEqual(controller.queue.map(\.fileURL), tracks.map(\.fileURL))
        XCTAssertEqual(controller.currentTrack?.fileURL, tracks[1].fileURL)
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(engine.preparedNextURL, URL(string: tracks[2].fileURL))
    }

    // MARK: - Playback startup regression guard
    //
    // Regression: commit 79a3701 built every asset with
    // AVURLAssetPreferPreciseDurationAndTimingKey, which can require substantial
    // advance parsing before playback for formats without timing summary data. Cost
    // scales with file size and read speed, so small files were unaffected and it
    // shipped unnoticed; a 305 MB FLAC on an external volume took ~60s to start.
    //
    // This is a tripwire on the setting, not a behaviour test. A behaviour test was
    // tried and abandoned: reproducing the stall needs both a very large file and a
    // slow volume (on a local SSD even 300 MB parses instantly), and AVAudioFile
    // cannot generate a fixture AVPlayer will play. Verify real startup by playing a
    // large file from a slow/external volume before shipping a release.

    func testPlaybackAssetsDoNotRequestWholeFileParsing() {
        XCTAssertNil(
            AVFoundationPlayer.assetOptions[AVURLAssetPreferPreciseDurationAndTimingKey],
            "Playback assets must not request precise duration/timing."
        )
    }

    func testResumeKeepsControllerStoppedUntilEngineReportsPlaying() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        engine.resumeState = .loading
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 1, db: db)

        controller.play(track: tracks[0], in: tracks)
        engine.setState(.loading)
        drainMainRunLoop()
        controller.pausePlayback()
        controller.resumePlayback()
        drainMainRunLoop()

        XCTAssertEqual(engine.state, .loading)
        XCTAssertFalse(controller.isPlaying)

        engine.setState(.playing)
        drainMainRunLoop()
        XCTAssertTrue(controller.isPlaying)
    }

    func testQueuedItemFailureStopsPlaybackAndPublishesAnError() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)
        engine.simulateQueuedItemFailure("The next track could not be played.")
        drainMainRunLoop()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTrack?.fileURL, tracks[0].fileURL)
        XCTAssertEqual(controller.playbackError, "The next track could not be played.")
    }

    func testMissingTrackCannotStartPlayback() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        var track = try XCTUnwrap(insertTracks(count: 1, db: db).first)
        track.availabilityStatus = "missing"
        try db.write { try track.update($0) }

        controller.play(track: track)

        XCTAssertNil(controller.currentTrack)
        XCTAssertNil(engine.playedURL)
        XCTAssertEqual(controller.playbackError, "This track's file is unavailable.")
    }

    func testMissingPathRequestsRecoveryBeforeStartingPlayback() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let track = try XCTUnwrap(insertTracks(count: 1, db: db).first)
        try FileManager.default.removeItem(at: try XCTUnwrap(URL(string: track.fileURL)))
        var requestedTrackId: Int64?
        controller.unavailableFileRecoveryHandler = { requestedTrackId = $0.dbId }

        controller.play(track: track)

        XCTAssertEqual(requestedTrackId, track.dbId)
        XCTAssertTrue(controller.isRecoveringUnavailableFile)
        XCTAssertNil(controller.playbackError)
        XCTAssertNil(engine.playedURL)
    }

    func testSuccessfulRecoveryRefreshesMovedPathAndRetriesPlayback() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let track = try XCTUnwrap(insertTracks(count: 1, db: db).first)
        let oldURL = try XCTUnwrap(URL(string: track.fileURL))
        try FileManager.default.removeItem(at: oldURL)
        let movedURL = oldURL.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).flac")
        try Data().write(to: movedURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: movedURL) }
        controller.unavailableFileRecoveryHandler = { _ in }

        controller.play(track: track)
        try db.write { db in
            try db.execute(
                sql: "UPDATE tracks SET file_url = ?, availability_status = 'available' WHERE id = ?",
                arguments: [movedURL.absoluteString, track.dbId]
            )
        }
        controller.completeUnavailableFileRecovery(folderUnavailable: false)

        XCTAssertFalse(controller.isRecoveringUnavailableFile)
        XCTAssertNil(controller.playbackError)
        XCTAssertEqual(controller.currentTrack?.dbId, track.dbId)
        XCTAssertEqual(engine.playedURL, movedURL)
    }

    func testFailedRecoveryReportsUnavailableFolderInsteadOfGenericPlaybackError() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let track = try XCTUnwrap(insertTracks(count: 1, db: db).first)
        try FileManager.default.removeItem(at: try XCTUnwrap(URL(string: track.fileURL)))
        controller.unavailableFileRecoveryHandler = { _ in }

        controller.play(track: track)
        controller.completeUnavailableFileRecovery(folderUnavailable: true)

        XCTAssertFalse(controller.isRecoveringUnavailableFile)
        XCTAssertTrue(controller.playbackFolderUnavailable)
        XCTAssertEqual(controller.unavailableTrackForPlayback?.dbId, track.dbId)
        XCTAssertEqual(
            controller.playbackError,
            "This track can’t be played because its music folder is unavailable. Reconnect the folder and try again."
        )
        XCTAssertNotEqual(controller.playbackError, "The operation could not be completed")
        XCTAssertNil(engine.playedURL)
    }

    func testQueuePreparationAndSkipIgnoreMissingTracks() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        var tracks = try insertTracks(count: 3, db: db)
        tracks[1].availabilityStatus = "missing"
        try db.write { try tracks[1].update($0) }

        controller.play(track: tracks[0], in: tracks)

        XCTAssertEqual(engine.preparedNextURL, URL(string: tracks[2].fileURL))
        controller.skipNext()
        XCTAssertEqual(controller.currentTrack?.dbId, tracks[2].dbId)
        XCTAssertEqual(engine.playedURL, URL(string: tracks[2].fileURL))
    }

    func testEngineInitialState() {
        let engine = AVFoundationPlayer()
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertEqual(engine.currentTime, 0)
    }

    func testAVFoundationEngineProvidesAudioRoutePickerPlayer() {
        let engine = AVFoundationPlayer()
        XCTAssertFalse(engine.airPlayRoutePickerPlayer.allowsExternalPlayback)
    }

    func testLocalVolumeControlsPlaybackEngine() {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.routeActivationResult = false
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )

        controller.setVolume(0.4)

        XCTAssertEqual(controller.volumeMode, .playerVolume)
        XCTAssertEqual(controller.volume, 0.4)
        XCTAssertEqual(engine.setVolumes.last, 0.4)
    }

    func testAirPlayVolumeUsesAvailableRouteVolume() {
        let db = makeTemporaryDatabase()
        let engine = TestAirPlayPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.currentVolume = 0.7
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )

        engine.setExternalPlaybackActive(true)
        engine.setAudioOutputDeviceUniqueID("airplay-device")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.volumeMode, .routeVolume)
        XCTAssertEqual(controller.volume, 0.7)
        XCTAssertEqual(routeVolumeController.activatedDeviceUIDs.last, "airplay-device")

        controller.setVolume(0.3)

        XCTAssertEqual(routeVolumeController.setVolumes, [0.3])
        XCTAssertEqual(controller.volume, 0.3)
    }

    func testAudioOutputDeviceUIDUsesAvailableRouteVolumeWithoutExternalPlayback() {
        let db = makeTemporaryDatabase()
        let engine = TestAirPlayPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.currentVolume = 0.8
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )

        engine.setAudioOutputDeviceUniqueID("airplay-audio-device")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.volumeMode, .routeVolume)
        XCTAssertEqual(controller.volume, 0.8)
        XCTAssertEqual(routeVolumeController.activatedDeviceUIDs.last, "airplay-audio-device")
    }

    func testOutputContextRouteVolumeWithoutAudioDeviceUID() {
        let db = makeTemporaryDatabase()
        let engine = TestAirPlayPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.routeActivationResult = true
        routeVolumeController.currentVolume = 0.55
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )

        routeVolumeController.emitRouteChange()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.volumeMode, .routeVolume)
        XCTAssertEqual(controller.volume, 0.55)
        XCTAssertGreaterThanOrEqual(routeVolumeController.routeActivationCount, 1)
    }

    func testAirPlayVolumeTracksExternalRouteVolumeChanges() {
        let db = makeTemporaryDatabase()
        let engine = TestAirPlayPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.currentVolume = 0.7
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )

        engine.setExternalPlaybackActive(true)
        engine.setAudioOutputDeviceUniqueID("airplay-device")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        routeVolumeController.emitVolume(0.45)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.volumeMode, .routeVolume)
        XCTAssertEqual(controller.volume, 0.45)
    }

    func testUnavailableAirPlayRouteVolumeIgnoresSliderChanges() {
        let db = makeTemporaryDatabase()
        let engine = TestAirPlayPlaybackEngine()
        let routeVolumeController = TestRouteVolumeController()
        routeVolumeController.activationResult = false
        let controller = PlaybackController(
            db: db,
            engine: engine,
            enableMediaKeyMonitor: false,
            routeVolumeController: routeVolumeController
        )
        controller.setVolume(0.6)

        engine.setExternalPlaybackActive(true)
        engine.setAudioOutputDeviceUniqueID("airplay-device")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.setVolume(0.2)

        XCTAssertEqual(controller.volumeMode, .unavailableRouteVolume)
        XCTAssertEqual(controller.volume, 0.6)
        XCTAssertEqual(engine.setVolumes.last, 0.6)
        XCTAssertTrue(routeVolumeController.setVolumes.isEmpty)
    }

    func testGaplessPlaybackDefaultsToEnabled() {
        let db = makeTemporaryDatabase()
        let controller = PlaybackController(db: db, engine: TestPlaybackEngine(), enableMediaKeyMonitor: false)

        XCTAssertTrue(controller.gaplessPlaybackEnabled)
    }

    func testGaplessPlaybackRestoresPersistedDisabledSetting() throws {
        let db = makeTemporaryDatabase()
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('gapless_playback_enabled', 'false')"
            )
        }

        let controller = PlaybackController(db: db, engine: TestPlaybackEngine(), enableMediaKeyMonitor: false)

        XCTAssertFalse(controller.gaplessPlaybackEnabled)
    }

    func testGaplessPlaybackPreparesNextTrackWhenEnabled() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)

        XCTAssertEqual(engine.playedURL, URL(string: tracks[0].fileURL))
        XCTAssertEqual(engine.preparedNextURL, URL(string: tracks[1].fileURL))
    }

    func testGaplessPlaybackDoesNotPrepareNextTrackWhenDisabled() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        controller.gaplessPlaybackEnabled = false
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)

        XCTAssertEqual(engine.playedURL, URL(string: tracks[0].fileURL))
        XCTAssertNil(engine.preparedNextURL)
    }

    func testPreparedItemTransitionUpdatesCurrentTrackAndPlayCountOnce() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)
        engine.simulatePreparedItemTransition()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.currentTrack?.fileURL, tracks[1].fileURL)
        XCTAssertEqual(try playCount(for: tracks[0], db: db), 1)
        XCTAssertEqual(try playCount(for: tracks[1], db: db), 1)
    }

    func testRepeatOneDoesNotPrepareDuplicateTrack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        controller.repeatMode = .one
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[0], in: tracks)

        XCTAssertNil(engine.preparedNextURL)
    }

    func testRepeatAllPreparesFirstTrackFromLastTrack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        controller.repeatMode = .all
        let tracks = try insertTracks(count: 2, db: db)

        controller.play(track: tracks[1], in: tracks)

        XCTAssertEqual(engine.preparedNextURL, URL(string: tracks[0].fileURL))
    }

    func testExplicitPauseDoesNotResumeWhenAlreadyPaused() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 1, db: db)

        controller.play(track: tracks[0], in: tracks)
        controller.pausePlayback()
        controller.pausePlayback()

        XCTAssertEqual(engine.state, .paused)
        XCTAssertFalse(controller.isPlaying)
    }

    func testDuplicateNextMediaCommandsOnlyAdvanceOnce() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 3, db: db)

        controller.play(track: tracks[0], in: tracks)
        controller.performMediaCommand(.next)
        controller.performMediaCommand(.next)

        XCTAssertEqual(controller.currentTrack?.fileURL, tracks[1].fileURL)
        XCTAssertEqual(controller.currentIndex, 1)
    }

    func testMediaPreviousSkipsTrackInsteadOfRestartingCurrentTrack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 3, db: db)

        controller.play(track: tracks[1], in: tracks)
        engine.seek(to: 12)
        controller.performMediaCommand(.previous)

        XCTAssertEqual(controller.currentTrack?.fileURL, tracks[0].fileURL)
        XCTAssertEqual(controller.currentIndex, 0)
    }

    func testDuplicatePlayPauseMediaCommandsDoNotFlipBack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 1, db: db)

        controller.play(track: tracks[0], in: tracks)
        controller.performMediaCommand(.playPause)
        controller.performMediaCommand(.pause)

        XCTAssertEqual(engine.state, .paused)
        XCTAssertFalse(controller.isPlaying)
    }

    func testDuplicatePauseThenToggleMediaCommandsDoNotFlipBack() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        let tracks = try insertTracks(count: 1, db: db)

        controller.play(track: tracks[0], in: tracks)
        controller.performMediaCommand(.pause)
        controller.performMediaCommand(.playPause)

        XCTAssertEqual(engine.state, .paused)
        XCTAssertFalse(controller.isPlaying)
    }

    func testStartupIgnoresPersistedLastSession() throws {
        let db = makeTemporaryDatabase()
        let tracks = try insertAlbumTracks(count: 3, db: db)
        try persistLastSession(track: tracks[1], position: 0, db: db)

        let controller = PlaybackController(db: db, engine: TestPlaybackEngine(), enableMediaKeyMonitor: false)

        XCTAssertNil(controller.currentTrack)
        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertEqual(controller.currentIndex, 0)
    }

    func testStartupWithPersistedLastSessionDoesNotStartPlayback() throws {
        let db = makeTemporaryDatabase()
        let engine = TestPlaybackEngine()
        let tracks = try insertAlbumTracks(count: 3, db: db)
        try persistLastSession(track: tracks[1], position: 12, db: db)

        let controller = PlaybackController(db: db, engine: engine, enableMediaKeyMonitor: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(controller.currentTrack)
        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(engine.playedURL)
        XCTAssertNil(engine.preparedNextURL)
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertEqual(engine.currentTime, 0)
    }

    private func makeTemporaryDatabase() -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightPlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try! DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    private func insertTracks(count: Int, db: DatabaseManager) throws -> [Track] {
        try (0..<count).map { index in
            let url = URL(fileURLWithPath: "/tmp/moonlight-gapless-\(UUID().uuidString)-\(index).flac")
            try Data().write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            var track = Track(
                fileURL: url.absoluteString,
                title: "Track \(index)",
                dateAdded: Date()
            )
            try db.write { db in
                try track.insert(db)
            }
            return track
        }
    }

    private func insertAlbumTracks(count: Int, db: DatabaseManager) throws -> [Track] {
        var album = Album(title: "Restore Album \(UUID().uuidString)")
        try db.write { db in
            try album.insert(db)
        }
        let albumId = try XCTUnwrap(album.id)

        return try (0..<count).map { index in
            let url = URL(fileURLWithPath: "/tmp/moonlight-restore-\(UUID().uuidString)-\(index).flac")
            try Data().write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            var track = Track(
                fileURL: url.absoluteString,
                title: "Track \(index)",
                album: album.title,
                trackNumber: index + 1,
                discNumber: 1,
                dateAdded: Date(),
                albumId: albumId
            )
            try db.write { db in
                try track.insert(db)
            }
            return track
        }
    }

    private func persistLastSession(track: Track, position: TimeInterval, db: DatabaseManager) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('last_track_url', ?)", arguments: [track.fileURL])
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('last_position', ?)", arguments: [String(position)])
        }
    }

    private func playCount(for track: Track, db: DatabaseManager) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE file_url = ?", arguments: [track.fileURL]) ?? 0
        }
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

private class TestPlaybackEngine: PlaybackEngine {
    private let stateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let itemTransitionSubject = PassthroughSubject<Void, Never>()

    var playedURL: URL?
    var preparedNextURL: URL?
    var setVolumes: [Float] = []
    var playState: PlaybackState = .playing
    var resumeState: PlaybackState = .playing

    var state: PlaybackState { stateSubject.value }
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var statePublisher: AnyPublisher<PlaybackState, Never> { stateSubject.eraseToAnyPublisher() }
    var timePublisher: AnyPublisher<TimeInterval, Never> { timeSubject.eraseToAnyPublisher() }
    var itemTransitionPublisher: AnyPublisher<Void, Never> { itemTransitionSubject.eraseToAnyPublisher() }

    func play(url: URL, nextURL: URL?) throws {
        playedURL = url
        preparedNextURL = nextURL
        stateSubject.send(playState)
    }

    func prepareNext(url: URL?) {
        preparedNextURL = url
    }

    func pause() {
        stateSubject.send(.paused)
    }

    func resume() {
        stateSubject.send(resumeState)
    }

    func stop() {
        stateSubject.send(.stopped)
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        timeSubject.send(time)
    }

    func setVolume(_ volume: Float) {
        setVolumes.append(volume)
    }

    func simulatePreparedItemTransition() {
        itemTransitionSubject.send()
    }

    func simulateQueuedItemFailure(_ message: String) {
        preparedNextURL = nil
        stateSubject.send(.error(message))
    }

    func setState(_ state: PlaybackState) {
        stateSubject.send(state)
    }
}

private final class TestAirPlayPlaybackEngine: TestPlaybackEngine, AirPlayRouteProviding {
    private let externalPlaybackActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let audioOutputDeviceUniqueIDSubject = CurrentValueSubject<String?, Never>(nil)

    let airPlayRoutePickerPlayer = AVPlayer()
    var externalPlaybackActive: Bool { externalPlaybackActiveSubject.value }
    var audioOutputDeviceUniqueID: String? { audioOutputDeviceUniqueIDSubject.value }
    var externalPlaybackActivePublisher: AnyPublisher<Bool, Never> {
        externalPlaybackActiveSubject.eraseToAnyPublisher()
    }
    var audioOutputDeviceUniqueIDPublisher: AnyPublisher<String?, Never> {
        audioOutputDeviceUniqueIDSubject.eraseToAnyPublisher()
    }

    func setExternalPlaybackActive(_ isActive: Bool) {
        externalPlaybackActiveSubject.send(isActive)
    }

    func setAudioOutputDeviceUniqueID(_ deviceUID: String?) {
        audioOutputDeviceUniqueIDSubject.send(deviceUID)
    }
}

private final class TestRouteVolumeController: RouteVolumeControlling {
    private let volumeSubject = PassthroughSubject<Float, Never>()
    private let routeChangeSubject = PassthroughSubject<Void, Never>()

    var currentVolume: Float?
    var activationResult = true
    var routeActivationResult = false
    var routeActivationCount = 0
    var activatedDeviceUIDs: [String] = []
    var deactivateCount = 0
    var setVolumes: [Float] = []
    var volumePublisher: AnyPublisher<Float, Never> {
        volumeSubject.eraseToAnyPublisher()
    }
    var routeChangePublisher: AnyPublisher<Void, Never> {
        routeChangeSubject.eraseToAnyPublisher()
    }

    func activateRoute() -> Bool {
        routeActivationCount += 1
        return routeActivationResult
    }

    func activate(deviceUID: String) -> Bool {
        activatedDeviceUIDs.append(deviceUID)
        return activationResult
    }

    func deactivate() {
        deactivateCount += 1
    }

    func setVolume(_ volume: Float) -> Bool {
        setVolumes.append(volume)
        currentVolume = volume
        return true
    }

    func emitVolume(_ volume: Float) {
        currentVolume = volume
        volumeSubject.send(volume)
    }

    func emitRouteChange() {
        routeChangeSubject.send(())
    }
}
