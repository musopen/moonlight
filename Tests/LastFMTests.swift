import Foundation
import GRDB
import XCTest
@testable import Moonlight

final class LastFMAPIClientTests: XCTestCase {
    func testSignatureMatchesLastFMDesktopAuthenticationExample() {
        let signature = LastFMAPIClient.signature(
            parameters: [
                "api_key": "xxxxxxxxxx",
                "method": "auth.getSession",
                "token": "yyyyyy"
            ],
            secret: "ilovecher"
        )

        XCTAssertEqual(signature, "b87d61da3cda91a8b6746c4aef55d6f8")
    }

    func testSignatureExcludesTransportParameters() {
        let required = [
            "api_key": "key",
            "method": "track.scrobble",
            "track": "Clair de lune"
        ]
        let withExcludedParameters = required.merging([
            "format": "json",
            "callback": "callbackFunction",
            "api_sig": "old-signature"
        ]) { _, new in new }

        XCTAssertEqual(
            LastFMAPIClient.signature(parameters: required, secret: "secret"),
            LastFMAPIClient.signature(parameters: withExcludedParameters, secret: "secret")
        )
    }

    func testSignatureSortsBatchParameterNamesUsingASCIIOrder() {
        let signature = LastFMAPIClient.signature(
            parameters: [
                "artist[1]": "One",
                "artist[2]": "Two",
                "artist[10]": "Ten"
            ],
            secret: "secret"
        )

        XCTAssertEqual(signature, "fa850af9d7b368523e652a50c8f15454")
    }

    func testFormEncodingUsesUTF8PercentEncoding() {
        let encoded = LastFMAPIClient.formEncoded([
            "artist": "Claude Debussy",
            "track": "La mer & lumière"
        ])

        XCTAssertEqual(
            encoded,
            "artist=Claude%20Debussy&track=La%20mer%20%26%20lumi%C3%A8re"
        )
    }

    func testAPIErrorInsideSuccessfulHTTPResponseIsThrown() async {
        let transport = LastFMStubTransport { request in
            let data = Data(#"{"error":9,"message":"Invalid session key"}"#.utf8)
            return (data, Self.response(for: request, statusCode: 200))
        }
        let client = LastFMAPIClient(
            configuration: LastFMConfiguration(apiKey: "key", sharedSecret: "secret"),
            transport: transport
        )

        do {
            try await client.updateNowPlaying(
                sessionKey: "session",
                track: LastFMTrackMetadata(artist: "Artist", track: "Track")
            )
            XCTFail("Expected Last.fm API error")
        } catch let error as LastFMAPIError {
            XCTAssertEqual(error, .api(code: 9, message: "Invalid session key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBatchScrobbleUsesIndexedPOSTParameters() async throws {
        var capturedRequest: URLRequest?
        let transport = LastFMStubTransport { request in
            capturedRequest = request
            let data = Data(#"{"scrobbles":{"@attr":{"accepted":"2","ignored":"0"}}}"#.utf8)
            return (data, Self.response(for: request, statusCode: 200))
        }
        let client = LastFMAPIClient(
            configuration: LastFMConfiguration(apiKey: "key", sharedSecret: "secret"),
            transport: transport
        )
        let metadata = LastFMTrackMetadata(artist: "Artist", track: "Track")

        let result = try await client.submitScrobbles(
            sessionKey: "session",
            scrobbles: [
                LastFMScrobble(metadata: metadata, startedAt: 100),
                LastFMScrobble(metadata: metadata, startedAt: 200)
            ]
        )

        XCTAssertEqual(result, LastFMSubmissionResult(accepted: 2, ignored: 0))
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        let body = String(data: try XCTUnwrap(capturedRequest?.httpBody), encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(body).contains("artist%5B0%5D=Artist"))
        XCTAssertTrue(try XCTUnwrap(body).contains("timestamp%5B1%5D=200"))
    }

    func testMalformedServerErrorPreservesHTTPStatusForRetryPolicy() async {
        let transport = LastFMStubTransport { request in
            (Data("temporarily unavailable".utf8), Self.response(for: request, statusCode: 503))
        }
        let client = LastFMAPIClient(
            configuration: LastFMConfiguration(apiKey: "key", sharedSecret: "secret"),
            transport: transport
        )

        do {
            _ = try await client.fetchRequestToken()
            XCTFail("Expected HTTP error")
        } catch let error as LastFMAPIError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertTrue(error.isRetryableScrobbleFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

final class LastFMPlaybackAccumulatorTests: XCTestCase {
    func testExactlyThirtySecondTrackNeverQualifies() {
        var playback = LastFMPlaybackAccumulator(duration: 30, position: 0, uptime: 0)
        playback.tick(position: 30, uptime: 30)
        XCTAssertFalse(playback.isEligible)
    }

    func testTrackQualifiesAfterHalfItsDuration() {
        var playback = LastFMPlaybackAccumulator(duration: 100, position: 0, uptime: 0)
        playback.tick(position: 49, uptime: 49)
        XCTAssertFalse(playback.isEligible)
        playback.tick(position: 50, uptime: 50)
        XCTAssertTrue(playback.isEligible)
    }

    func testLongTrackQualifiesAtFourMinutes() {
        var playback = LastFMPlaybackAccumulator(duration: 1_000, position: 0, uptime: 0)
        playback.tick(position: 239, uptime: 239)
        XCTAssertFalse(playback.isEligible)
        playback.tick(position: 240, uptime: 240)
        XCTAssertTrue(playback.isEligible)
    }

    func testPausedTimeDoesNotCount() {
        var playback = LastFMPlaybackAccumulator(duration: 100, position: 0, uptime: 0)
        playback.tick(position: 10, uptime: 10)
        playback.pause(position: 10, uptime: 10)
        playback.tick(position: 30, uptime: 30)
        playback.resume(position: 30, uptime: 30)
        playback.tick(position: 69, uptime: 69)
        XCTAssertFalse(playback.isEligible)
        playback.tick(position: 70, uptime: 70)
        XCTAssertTrue(playback.isEligible)
    }

    func testSeekedDistanceDoesNotCount() {
        var playback = LastFMPlaybackAccumulator(duration: 100, position: 0, uptime: 0)
        playback.tick(position: 10, uptime: 10)
        playback.seek(to: 80, uptime: 10)
        playback.tick(position: 90, uptime: 20)
        XCTAssertEqual(playback.listened, 20, accuracy: 0.001)
        XCTAssertFalse(playback.isEligible)
    }
}

final class LastFMMetadataTests: XCTestCase {
    func testMetadataComesFromTagsAndIsTrimmed() throws {
        let track = Track(
            fileURL: "file:///tmp/Filename%20Must%20Not%20Be%20Used.flac",
            title: "  Moonlight Sonata  ",
            artist: "  Beethoven ",
            albumArtist: " Performer ",
            album: " Piano Sonatas ",
            trackNumber: 14,
            duration: 315.6,
            dateAdded: Date()
        )

        let metadata = try XCTUnwrap(LastFMTrackMetadata(track: track))
        XCTAssertEqual(metadata.artist, "Beethoven")
        XCTAssertEqual(metadata.track, "Moonlight Sonata")
        XCTAssertEqual(metadata.album, "Piano Sonatas")
        XCTAssertEqual(metadata.albumArtist, "Performer")
        XCTAssertEqual(metadata.duration, 316)
        XCTAssertEqual(metadata.trackNumber, 14)
    }

    func testFilenameIsNotUsedWhenTagsAreMissing() {
        let track = Track(
            fileURL: "file:///tmp/Artist%20-%20Title.mp3",
            title: nil,
            artist: nil,
            dateAdded: Date()
        )

        XCTAssertNil(LastFMTrackMetadata(track: track))
    }
}

@MainActor
final class LastFMIntegrationTests: XCTestCase {
    private var db: DatabaseManager!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightLastFMAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: temporaryDirectory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDown() async throws {
        db = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testDesktopAuthorizationOpensBrowserThenStoresSession() async throws {
        let api = LastFMStubAPI()
        let sessionStore = LastFMMemorySessionStore()
        let browserOpened = expectation(description: "Last.fm authorization page opened")
        var openedURL: URL?
        let integration = LastFMIntegration(
            db: db,
            configuration: LastFMConfiguration(apiKey: "application-key", sharedSecret: "secret"),
            apiClient: api,
            sessionStore: sessionStore,
            openURL: { url in
                openedURL = url
                browserOpened.fulfill()
            }
        )

        integration.beginAuthorization()
        await fulfillment(of: [browserOpened], timeout: 2)

        XCTAssertEqual(integration.status, .awaitingAuthorization)
        let authorizationURL = try XCTUnwrap(openedURL)
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["api_key"], "application-key")
        XCTAssertEqual(query["token"], "token")

        integration.completeAuthorization()
        try await waitUntil { integration.status == .connected(username: "listener") }

        XCTAssertEqual(sessionStore.session, LastFMSession(username: "listener", key: "session"))
    }

    func testUnauthorizedTokenCanBeCompletedAgain() async throws {
        let api = LastFMStubAPI()
        let sessionStore = LastFMMemorySessionStore()
        let browserOpened = expectation(description: "Last.fm authorization page opened")
        let integration = LastFMIntegration(
            db: db,
            configuration: LastFMConfiguration(apiKey: "application-key", sharedSecret: "secret"),
            apiClient: api,
            sessionStore: sessionStore,
            openURL: { _ in browserOpened.fulfill() }
        )

        integration.beginAuthorization()
        await fulfillment(of: [browserOpened], timeout: 2)
        api.sessionError = .api(code: 14, message: "This token has not been authorized")
        integration.completeAuthorization()
        try await waitUntil { integration.status == .awaitingAuthorization }

        XCTAssertNil(sessionStore.session)
    }

    func testMissingBuildCredentialsDisablesIntegration() {
        let integration = LastFMIntegration(
            db: db,
            configuration: LastFMConfiguration(apiKey: "", sharedSecret: ""),
            apiClient: LastFMStubAPI(),
            sessionStore: LastFMMemorySessionStore(),
            openURL: { _ in XCTFail("Browser should not open") }
        )

        XCTAssertEqual(integration.status, .unavailable)
        integration.beginAuthorization()
        XCTAssertEqual(integration.status, .unavailable)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Last.fm integration state")
    }
}

@MainActor
final class LastFMCoordinatorTests: XCTestCase {
    private var db: DatabaseManager!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonlightLastFMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: temporaryDirectory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDown() async throws {
        db = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testRetryableFailureRemainsInPersistentOutboxWithBackoff() async throws {
        let sessionStore = LastFMMemorySessionStore(
            session: LastFMSession(username: "listener", key: "session")
        )
        let api = LastFMStubAPI()
        api.scrobbleError = .api(code: 11, message: "Service offline")
        let now = Date(timeIntervalSince1970: 1_000)
        var uptime: TimeInterval = 0
        let coordinator = LastFMScrobbleCoordinator(
            db: db,
            apiClient: api,
            sessionStore: sessionStore,
            dateProvider: { now },
            uptimeProvider: { uptime }
        )
        let track = Track(
            fileURL: "file:///tmp/test.flac",
            title: "Track",
            artist: "Artist",
            duration: 100,
            dateAdded: now
        )

        coordinator.trackDidStart(track, position: 0)
        uptime = 50
        coordinator.playbackPositionDidChange(50)

        let entry = try await waitForOutboxEntry(attemptCount: 1)
        XCTAssertEqual(entry.startedAt, 1_000)
        XCTAssertEqual(entry.nextAttemptAt, now.addingTimeInterval(30))
        coordinator.disconnectAndClear()
    }

    func testInvalidSessionRequestsReconnectionAndKeepsQueuedScrobble() async throws {
        let sessionStore = LastFMMemorySessionStore(
            session: LastFMSession(username: "listener", key: "session")
        )
        let api = LastFMStubAPI()
        api.scrobbleError = .api(code: 9, message: "Invalid session key")
        let now = Date(timeIntervalSince1970: 2_000)
        var uptime: TimeInterval = 0
        let coordinator = LastFMScrobbleCoordinator(
            db: db,
            apiClient: api,
            sessionStore: sessionStore,
            dateProvider: { now },
            uptimeProvider: { uptime }
        )
        let invalidated = expectation(description: "session invalidated")
        coordinator.onSessionInvalidated = {
            coordinator.sessionDidBecomeInvalid()
            invalidated.fulfill()
        }
        let track = Track(
            fileURL: "file:///tmp/test.flac",
            title: "Track",
            artist: "Artist",
            duration: 100,
            dateAdded: now
        )

        coordinator.trackDidStart(track, position: 0)
        uptime = 50
        coordinator.playbackPositionDidChange(50)

        await fulfillment(of: [invalidated], timeout: 2)
        let count = try db.read { db in
            try LastFMOutboxEntry.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
        coordinator.disconnectAndClear()
    }

    private func waitForOutboxEntry(attemptCount: Int) async throws -> LastFMOutboxEntry {
        for _ in 0..<200 {
            if let entry = try db.read({ db in
                try LastFMOutboxEntry.fetchOne(db)
            }), entry.attemptCount == attemptCount {
                return entry
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Last.fm outbox update")
        throw LastFMAPIError.invalidResponse
    }
}

private final class LastFMStubTransport: LastFMHTTPTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private final class LastFMStubAPI: LastFMAPIProviding {
    var scrobbleError: LastFMAPIError?
    var sessionError: LastFMAPIError?
    private(set) var submittedBatches: [[LastFMScrobble]] = []

    func fetchRequestToken() async throws -> String { "token" }

    func fetchSession(token: String) async throws -> LastFMSession {
        if let sessionError { throw sessionError }
        return LastFMSession(username: "listener", key: "session")
    }

    func updateNowPlaying(sessionKey: String, track: LastFMTrackMetadata) async throws {}

    func submitScrobbles(
        sessionKey: String,
        scrobbles: [LastFMScrobble]
    ) async throws -> LastFMSubmissionResult {
        submittedBatches.append(scrobbles)
        if let scrobbleError { throw scrobbleError }
        return LastFMSubmissionResult(accepted: scrobbles.count, ignored: 0)
    }
}

private final class LastFMMemorySessionStore: LastFMSessionStoring {
    var session: LastFMSession?

    init(session: LastFMSession? = nil) {
        self.session = session
    }

    func loadSession() throws -> LastFMSession? { session }
    func saveSession(_ session: LastFMSession) throws { self.session = session }
    func deleteSession() throws { session = nil }
}
