// ContactService.swift
//
// Sends messages from the in-app Contact Us and feedback form to the Moonlight website. It checks
// that a message was written and that any email address looks valid, then reports friendly errors
// if sending fails.

import Foundation

struct ContactRequest: Codable, Equatable {
    let name: String
    let email: String
    let message: String
    let website: String
}

struct ContactResponse: Decodable, Equatable {
    let ok: Bool
}

struct ContactErrorResponse: Decodable {
    let error: String?
}

enum ContactServiceError: LocalizedError, Equatable {
    case notConfigured
    case invalidEmail
    case invalidMessage
    case server(message: String, statusCode: Int)
    case invalidResponse
    case network(message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Feedback isn't set up in this build of Moonlight."
        case .invalidEmail:
            "Please enter a valid email address."
        case .invalidMessage:
            "Please enter a message."
        case let .server(message, _):
            message
        case .invalidResponse:
            "The feedback service returned an unexpected response. Please try again later."
        case .network:
            "We couldn't send your feedback. Check your internet connection and try again."
        }
    }
}

protocol ContactHTTPTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ContactHTTPTransport {}

final class ContactService {
    /// Set per build via Config/Feedback.xcconfig (official value in gitignored Feedback.local.xcconfig);
    /// nil, which disables the form, unless an https URL is configured.
    static let configuredEndpoint: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MoonlightFeedbackURL") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }()

    static var isConfigured: Bool { configuredEndpoint != nil }

    private let endpoint: URL?
    private let transport: ContactHTTPTransport

    init(endpoint: URL? = ContactService.configuredEndpoint, transport: ContactHTTPTransport = URLSession.shared) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func submit(email: String, message: String, prefix: String = "") async throws {
        guard let endpoint else { throw ContactServiceError.notConfigured }
        let validatedRequest = try validatedRequest(email: email, message: message)
        let requestBody = ContactRequest(
            name: validatedRequest.name,
            email: validatedRequest.email,
            message: prefix + validatedRequest.message,
            website: validatedRequest.website
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            // Deliberately avoid logging user-provided content.
            throw ContactServiceError.network(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ContactServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(ContactErrorResponse.self, from: data)
            throw ContactServiceError.server(
                message: errorResponse?.error ?? "We couldn't send your feedback. Please try again later.",
                statusCode: httpResponse.statusCode
            )
        }

        guard (try? JSONDecoder().decode(ContactResponse.self, from: data))?.ok == true else {
            throw ContactServiceError.invalidResponse
        }
    }

    func validatedRequest(email: String, message: String) throws -> ContactRequest {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedEmail.isEmpty || Self.isValidEmail(trimmedEmail) else { throw ContactServiceError.invalidEmail }
        guard !trimmedMessage.isEmpty else { throw ContactServiceError.invalidMessage }

        return ContactRequest(
            name: "",
            email: trimmedEmail,
            message: trimmedMessage,
            website: ""
        )
    }

    private static func isValidEmail(_ email: String) -> Bool {
        let expression = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return email.range(of: expression, options: .regularExpression) != nil
    }
}
