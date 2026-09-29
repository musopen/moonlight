import Foundation
import XCTest
@testable import Moonlight

final class ContactServiceTests: XCTestCase {
    private static let endpoint = URL(string: "https://feedback.example.com/api/contact")!

    func testUnconfiguredServiceRefusesToSendWithoutCallingTransport() async {
        let transport = ContactStubTransport { _ in
            XCTFail("Transport should not be called without an endpoint")
            throw URLError(.badURL)
        }
        do {
            try await ContactService(endpoint: nil, transport: transport).submit(email: "", message: "Hello")
            XCTFail("Expected notConfigured")
        } catch let error as ContactServiceError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSuccessfulSubmissionUsesExpectedRequest() async throws {
        var capturedRequest: URLRequest?
        let transport = ContactStubTransport { request in
            capturedRequest = request
            return (Data(#"{"ok":true}"#.utf8), Self.response(for: request, statusCode: 200))
        }

        try await ContactService(endpoint: Self.endpoint, transport: transport).submit(
            email: " ada@example.com ",
            message: "  Please add playlists. "
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, Self.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            try JSONDecoder().decode(ContactRequest.self, from: XCTUnwrap(request.httpBody)),
            ContactRequest(name: "", email: "ada@example.com", message: "Please add playlists.", website: "")
        )
    }

    func testInvalidLocalInputDoesNotCallTransport() async {
        let transport = ContactStubTransport { _ in
            XCTFail("Transport should not be called for invalid input")
            throw URLError(.badURL)
        }

        do {
            try await ContactService(endpoint: Self.endpoint, transport: transport).submit(email: "not-an-email", message: "Hello")
            XCTFail("Expected local validation error")
        } catch let error as ContactServiceError {
            XCTAssertEqual(error, .invalidEmail)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyEmailIsAllowed() throws {
        let request = try ContactService().validatedRequest(email: "   ", message: "A useful note")

        XCTAssertEqual(request, ContactRequest(name: "", email: "", message: "A useful note", website: ""))
    }

    func testSubmissionPrefixIsAddedAfterValidation() async throws {
        var capturedRequest: URLRequest?
        let transport = ContactStubTransport { request in
            capturedRequest = request
            return (Data(#"{"ok":true}"#.utf8), Self.response(for: request, statusCode: 200))
        }

        try await ContactService(endpoint: Self.endpoint, transport: transport).submit(
            email: "",
            message: "Please add a sepia palette.",
            prefix: "[Theme suggestion]\\n\\n"
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            try JSONDecoder().decode(ContactRequest.self, from: XCTUnwrap(request.httpBody)).message,
            "[Theme suggestion]\\n\\nPlease add a sepia palette."
        )
    }

    func testSubmissionPrefixDoesNotAllowEmptyMessage() async {
        let transport = ContactStubTransport { _ in
            XCTFail("Transport should not be called for an empty message")
            throw URLError(.badURL)
        }

        await assertError(
            .invalidMessage,
            from: ContactService(endpoint: Self.endpoint, transport: transport),
            message: "   ",
            prefix: "[Theme suggestion]\\n\\n"
        )
    }

    func testStationReportIncludesStationDetailsOnSeparateLines() {
        let station = RadioStation(
            id: 1,
            stationUUID: "11111111-1111-1111-1111-111111111111",
            changeUUID: "",
            name: "Classical\nKUSC",
            streamURL: "https://radio.example/live",
            tags: [],
            countryCode: "US",
            country: "United States",
            codec: "MP3",
            bitrate: 128,
            votes: 0,
            clickCount: 0,
            isPopular: false,
            lastCheckOK: true,
            latitude: nil,
            longitude: nil
        )

        let prefix = ContactFeedbackTopic.radioStation(station).submissionPrefix

        XCTAssertEqual(prefix, """
            [Station report]
            Station: Classical KUSC
            Station ID: 11111111-1111-1111-1111-111111111111
            Stream: https://radio.example/live
            Country: US


            """)
    }

    func testValidationErrorUsesServerMessage() async {
        let service = ContactService(endpoint: Self.endpoint, transport: ContactStubTransport { request in
            (Data(#"{"error":"Please provide a valid email address."}"#.utf8), Self.response(for: request, statusCode: 422))
        })

        await assertError(.server(message: "Please provide a valid email address.", statusCode: 422), from: service)
    }

    func testServerFailureUsesFallbackMessage() async {
        let service = ContactService(endpoint: Self.endpoint, transport: ContactStubTransport { request in
            (Data(), Self.response(for: request, statusCode: 502))
        })

        await assertError(.server(message: "We couldn't send your feedback. Please try again later.", statusCode: 502), from: service)
    }

    func testOfflineFailureIsReportedAsNetworkError() async {
        let service = ContactService(endpoint: Self.endpoint, transport: ContactStubTransport { _ in throw URLError(.notConnectedToInternet) })

        do {
            try await service.submit(email: "ada@example.com", message: "Hello")
            XCTFail("Expected network error")
        } catch let error as ContactServiceError {
            guard case .network = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertError(
        _ expected: ContactServiceError,
        from service: ContactService,
        message: String = "Hello",
        prefix: String = ""
    ) async {
        do {
            try await service.submit(email: "ada@example.com", message: message, prefix: prefix)
            XCTFail("Expected error")
        } catch let error as ContactServiceError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class ContactStubTransport: ContactHTTPTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}
