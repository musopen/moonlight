// LastFMAPIClient.swift
//
// Talks to the Last.fm website on the user's behalf. It signs in, tells Last.fm which song is
// currently playing, and sends "scrobbles" (records of songs the user listened to), then reads
// back Last.fm's replies and errors.

import CryptoKit
import Foundation

protocol LastFMAPIProviding: AnyObject {
    func fetchRequestToken() async throws -> String
    func fetchSession(token: String) async throws -> LastFMSession
    func updateNowPlaying(sessionKey: String, track: LastFMTrackMetadata) async throws
    func submitScrobbles(sessionKey: String, scrobbles: [LastFMScrobble]) async throws -> LastFMSubmissionResult
}

protocol LastFMHTTPTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LastFMHTTPTransport {}

final class LastFMAPIClient: LastFMAPIProviding {
    private let configuration: LastFMConfiguration
    private let transport: LastFMHTTPTransport
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    init(configuration: LastFMConfiguration, transport: LastFMHTTPTransport = URLSession.shared) {
        self.configuration = configuration
        self.transport = transport
    }

    func fetchRequestToken() async throws -> String {
        let response = try await perform(method: "auth.getToken", parameters: [:], requestMethod: "GET")
        guard let token = response["token"] as? String, !token.isEmpty else {
            throw LastFMAPIError.invalidResponse
        }
        return token
    }

    func fetchSession(token: String) async throws -> LastFMSession {
        let response = try await perform(
            method: "auth.getSession",
            parameters: ["token": token],
            requestMethod: "GET"
        )
        guard let session = response["session"] as? [String: Any],
              let username = session["name"] as? String,
              let key = session["key"] as? String,
              !username.isEmpty,
              !key.isEmpty
        else { throw LastFMAPIError.invalidResponse }
        return LastFMSession(username: username, key: key)
    }

    func updateNowPlaying(sessionKey: String, track: LastFMTrackMetadata) async throws {
        var parameters = track.parameters
        parameters["sk"] = sessionKey
        _ = try await perform(
            method: "track.updateNowPlaying",
            parameters: parameters,
            requestMethod: "POST"
        )
    }

    func submitScrobbles(
        sessionKey: String,
        scrobbles: [LastFMScrobble]
    ) async throws -> LastFMSubmissionResult {
        guard !scrobbles.isEmpty, scrobbles.count <= 50 else {
            throw LastFMAPIError.invalidResponse
        }

        var parameters = ["sk": sessionKey]
        for (index, scrobble) in scrobbles.enumerated() {
            let suffix = scrobbles.count == 1 ? "" : "[\(index)]"
            for (key, value) in scrobble.metadata.parameters {
                parameters["\(key)\(suffix)"] = value
            }
            parameters["timestamp\(suffix)"] = String(scrobble.startedAt)
        }

        let response = try await perform(
            method: "track.scrobble",
            parameters: parameters,
            requestMethod: "POST"
        )
        guard let container = response["scrobbles"] as? [String: Any],
              let attributes = container["@attr"] as? [String: Any]
        else { throw LastFMAPIError.invalidResponse }

        return LastFMSubmissionResult(
            accepted: Self.integer(attributes["accepted"]),
            ignored: Self.integer(attributes["ignored"])
        )
    }

    func authorizationURL(token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: configuration.apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components?.url
    }

    private func perform(
        method: String,
        parameters: [String: String],
        requestMethod: String
    ) async throws -> [String: Any] {
        guard configuration.isConfigured else { throw LastFMAPIError.missingConfiguration }

        var signedParameters = parameters
        signedParameters["method"] = method
        signedParameters["api_key"] = configuration.apiKey
        signedParameters["api_sig"] = Self.signature(
            parameters: signedParameters,
            secret: configuration.sharedSecret
        )
        signedParameters["format"] = "json"

        var request: URLRequest
        if requestMethod == "GET" {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = Self.formEncoded(signedParameters)
            guard let url = components.url else { throw LastFMAPIError.invalidResponse }
            request = URLRequest(url: url)
        } else {
            request = URLRequest(url: endpoint)
            request.httpBody = Self.formEncoded(signedParameters).data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = requestMethod
        request.timeoutInterval = 20
        request.setValue("Moonlight/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw LastFMAPIError.transport(error.localizedDescription)
        }

        let httpResponse = response as? HTTPURLResponse
        let object: [String: Any]
        do {
            object = try Self.responseObject(from: data)
        } catch {
            if let httpResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw LastFMAPIError.httpStatus(httpResponse.statusCode)
            }
            throw LastFMAPIError.invalidResponse
        }
        if let code = Self.optionalInteger(object["error"]) {
            throw LastFMAPIError.api(code: code, message: object["message"] as? String ?? "Last.fm request failed.")
        }
        if let httpResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw LastFMAPIError.httpStatus(httpResponse.statusCode)
        }
        return object
    }

    static func signature(parameters: [String: String], secret: String) -> String {
        let source = parameters
            .filter { $0.key != "format" && $0.key != "callback" && $0.key != "api_sig" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func formEncoded(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(parameters[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func responseObject(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMAPIError.invalidResponse
        }
        return object
    }

    private static func integer(_ value: Any?) -> Int {
        optionalInteger(value) ?? 0
    }

    private static func optionalInteger(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
