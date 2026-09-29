// LastFMIntegration.swift
//
// Manages the user's connection to Last.fm, a service that keeps a history of the music you listen
// to. It walks the user through signing in via the Last.fm website, remembers the connection,
// reports its status to Settings, and handles disconnecting or an expired sign-in.

import AppKit
import Foundation

enum LastFMConnectionStatus: Equatable {
    case unavailable
    case disconnected
    case requestingAuthorization
    case awaitingAuthorization
    case connecting
    case connected(username: String)
    case needsReconnection
    case error(String)
}

@MainActor
final class LastFMIntegration: ObservableObject {
    @Published private(set) var status: LastFMConnectionStatus

    let coordinator: LastFMScrobbleCoordinator

    private let configuration: LastFMConfiguration
    private let apiClient: LastFMAPIProviding
    private let sessionStore: LastFMSessionStoring
    private let openURL: (URL) -> Void
    private var pendingToken: String?

    init(
        db: DatabaseManager,
        configuration: LastFMConfiguration = .bundled(),
        apiClient: LastFMAPIProviding? = nil,
        sessionStore: LastFMSessionStoring = LastFMKeychainStore(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        let resolvedClient = apiClient ?? LastFMAPIClient(configuration: configuration)
        self.apiClient = resolvedClient
        self.sessionStore = sessionStore
        self.openURL = openURL
        self.coordinator = LastFMScrobbleCoordinator(
            db: db,
            apiClient: resolvedClient,
            sessionStore: sessionStore
        )

        if !configuration.isConfigured {
            status = .unavailable
        } else if let session = try? sessionStore.loadSession() {
            status = .connected(username: session.username)
        } else {
            status = .disconnected
        }

        coordinator.onSessionInvalidated = { [weak self] in
            self?.invalidateSession()
        }
        if case .connected = status {
            coordinator.sessionDidBecomeAvailable()
        }
    }

    func beginAuthorization() {
        guard configuration.isConfigured else {
            status = .unavailable
            return
        }
        status = .requestingAuthorization
        pendingToken = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await apiClient.fetchRequestToken()
                guard let url = authorizationURL(token: token) else {
                    throw LastFMAPIError.invalidResponse
                }
                pendingToken = token
                status = .awaitingAuthorization
                openURL(url)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func completeAuthorization() {
        guard let pendingToken else {
            status = .error("Start Last.fm authorization first.")
            return
        }
        status = .connecting

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await apiClient.fetchSession(token: pendingToken)
                try sessionStore.saveSession(session)
                self.pendingToken = nil
                status = .connected(username: session.username)
                coordinator.sessionDidBecomeAvailable()
            } catch let error as LastFMAPIError {
                if case .api(code: 14, message: _) = error {
                    status = .awaitingAuthorization
                } else if case .api(code: 15, message: _) = error {
                    self.pendingToken = nil
                    status = .error("The Last.fm authorization expired. Please connect again.")
                } else {
                    status = .error(error.localizedDescription)
                }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        try? sessionStore.deleteSession()
        pendingToken = nil
        coordinator.disconnectAndClear()
        status = configuration.isConfigured ? .disconnected : .unavailable
    }

    private func invalidateSession() {
        try? sessionStore.deleteSession()
        pendingToken = nil
        coordinator.sessionDidBecomeInvalid()
        status = .needsReconnection
    }

    private func authorizationURL(token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: configuration.apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components?.url
    }
}
