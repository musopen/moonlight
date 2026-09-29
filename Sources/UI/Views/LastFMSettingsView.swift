// LastFMSettingsView.swift
//
// The Integrations page in Settings, where the user connects or disconnects a Last.fm account.
// Once connected, Moonlight reports what is playing and adds finished plays to the user's
// Last.fm listening history (known as "scrobbling"). The page shows the connection status and
// explains what information is shared.

import SwiftUI

struct LastFMSettingsView: View {
    @ObservedObject var integration: LastFMIntegration

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Integrations")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.dAccent)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last.fm")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Publish Now Playing updates and add eligible local plays to your Last.fm listening history.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    statusControl
                }

                Divider().overlay(Color.borderSoft)

                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                }

                Text("Moonlight sends tagged artist, track, album, and playback timing information only while this integration is connected. Failed scrobbles may be held locally until Last.fm is available.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Last.fm privacy policy", destination: URL(string: "https://www.last.fm/legal/privacy")!)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dAccent)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.bgContent)
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        switch integration.status {
        case .unavailable:
            Text("Not configured")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        case .requestingAuthorization, .connecting:
            ProgressView()
                .controlSize(.small)
        case .awaitingAuthorization:
            HStack(spacing: 8) {
                Button("Cancel") { integration.disconnect() }
                Button("Complete Connection") { integration.completeAuthorization() }
                    .keyboardShortcut(.defaultAction)
            }
        case .connected:
            Button("Disconnect", role: .destructive) { integration.disconnect() }
        case .disconnected, .needsReconnection, .error:
            Button("Connect Last.fm") { integration.beginAuthorization() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var statusLabel: String {
        switch integration.status {
        case .unavailable: "Unavailable"
        case .disconnected: "Not connected"
        case .requestingAuthorization: "Starting authorization"
        case .awaitingAuthorization: "Authorization required"
        case .connecting: "Connecting"
        case let .connected(username): "Connected as \(username)"
        case .needsReconnection: "Reconnect required"
        case .error: "Connection error"
        }
    }

    private var statusDetail: String {
        switch integration.status {
        case .unavailable:
            "This build does not include Last.fm API credentials."
        case .disconnected:
            "Connect your account to begin scrobbling."
        case .requestingAuthorization:
            "Requesting a one-time authorization token from Last.fm…"
        case .awaitingAuthorization:
            "Authorize Moonlight in your browser, then return here and complete the connection."
        case .connecting:
            "Creating your Last.fm session…"
        case let .connected(username):
            "Scrobbling is active for \(username)."
        case .needsReconnection:
            "Last.fm rejected the saved session. Connect again to resume scrobbling."
        case let .error(message):
            message
        }
    }

    private var statusIcon: String {
        switch integration.status {
        case .connected: "checkmark.circle.fill"
        case .requestingAuthorization, .awaitingAuthorization, .connecting: "clock.fill"
        case .needsReconnection, .error: "exclamationmark.triangle.fill"
        case .unavailable, .disconnected: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch integration.status {
        case .connected: .green
        case .needsReconnection, .error: .orange
        default: Color.textTertiary
        }
    }
}
