// MissingFilesSettingsView.swift
//
// The Missing Files page in Settings. It lists songs whose files can no longer be found and
// helps reconnect them, either by accepting a suggested match or by locating the file by hand,
// without losing their playlists, ratings or play history. If a whole folder or drive is
// unreachable, it asks the user to reconnect that first.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MissingFilesSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var rows: [MissingFileRecoveryRow] = []
    @State private var isLoading = false
    @State private var resolvingTrackId: Int64?
    @State private var pendingSuggestion: MissingFileSuggestion?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.borderSoft)

            if !appState.unavailableLibraryFolders.isEmpty {
                unavailableFoldersBanner
                Divider().overlay(Color.borderSoft)
            }

            if let errorMessage {
                errorBanner(errorMessage)
                Divider().overlay(Color.borderSoft)
            }

            content

            Divider().overlay(Color.borderSoft)
            footer
        }
        .task(id: appState.libraryVersion) {
            reload()
        }
        .confirmationDialog(
            "Reconnect this missing track?",
            isPresented: Binding(
                get: { pendingSuggestion != nil },
                set: { if !$0 { pendingSuggestion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let suggestion = pendingSuggestion {
                Button("Use \(suggestion.candidate.displayTitle)") {
                    pendingSuggestion = nil
                    resolve(
                        missingTrackId: suggestion.missingTrackId,
                        to: URL(string: suggestion.candidate.fileURL)
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSuggestion = nil
            }
        } message: {
            if let suggestion = pendingSuggestion {
                Text("Moonlight will keep the original track ID and its playlists, favorite, rating, and play history, then reconnect it to \(suggestion.candidate.displayTitle).")
            }
        }
    }

    private var unavailableFoldersBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Some tracks cannot be checked yet", systemImage: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Moonlight keeps tracks available when an entire folder or drive cannot be read. Reconnect the folder first; a successful scan will then relink or mark individual files missing.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(appState.unavailableLibraryFolders.values.sorted(by: { $0.folderId < $1.folderId })) { issue in
                HStack {
                    Text(issue.url.path(percentEncoded: false))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reconnect…") {
                        appState.showReconnectFolderPicker(for: issue.folderId)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resolve Missing Files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Reconnect tracks without losing their Moonlight metadata.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            Text(rows.isEmpty ? "No missing files" : "\(rows.count) missing")
                .font(.system(size: 11))
                .foregroundStyle(rows.isEmpty ? Color.textTertiary : .orange)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dAccent)
            .disabled(isLoading || resolvingTrackId != nil)
            .help("Refresh missing files and suggestions")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && rows.isEmpty {
            ProgressView("Finding missing tracks…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgContent)
        } else if rows.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.dAccent)
                Text("All files are connected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text("Tracks whose files disappear will remain in your library and appear here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgContent)
        } else {
            Table(rows) {
                TableColumn("Missing Track") { row in
                    missingTrackCell(row.track)
                }
                .width(min: 190, ideal: 245)

                TableColumn("Suggested Match") { row in
                    suggestionCell(row.suggestion)
                }
                .width(min: 190, ideal: 245)

                TableColumn("") { row in
                    actionCell(row)
                }
                .width(min: 145, ideal: 160, max: 175)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .background(Color.bgContent)
        }
    }

    private func missingTrackCell(_ track: Track) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(missingTrackDetail(track))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                Text(path(for: track.fileURL))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.textQuaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .help(path(for: track.fileURL))
    }

    @ViewBuilder
    private func suggestionCell(_ suggestion: MissingFileSuggestion?) -> some View {
        if let suggestion {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.candidate.displayTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    confidenceBadge(suggestion.confidence)
                }
                Text(path(for: suggestion.candidate.fileURL))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(suggestion.reasons.prefix(3).joined(separator: " • "))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textQuaternary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .help(path(for: suggestion.candidate.fileURL))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("No confident match")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textSecondary)
                Text("Locate the file manually")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func actionCell(_ row: MissingFileRecoveryRow) -> some View {
        HStack(spacing: 8) {
            if let suggestion = row.suggestion {
                Button("Use Match") {
                    pendingSuggestion = suggestion
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.dAccent)
                .disabled(resolvingTrackId != nil)
            }

            Button("Find…") {
                showFilePicker(for: row.track)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(resolvingTrackId != nil)

            if resolvingTrackId == row.id {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.textTertiary)
            Text("Suggestions use filenames and embedded metadata only. Moonlight never relinks an ambiguous file automatically.")
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button("Dismiss") {
                errorMessage = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func confidenceBadge(_ confidence: MissingFileMatchConfidence) -> some View {
        Text(confidence.displayName.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(confidence == .high ? Color.dAccent : .orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill((confidence == .high ? Color.dAccent : Color.orange).opacity(0.12))
            )
    }

    private func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try appState.missingFileRecoveryRows()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolve(missingTrackId: Int64, to url: URL?) {
        guard let url else {
            errorMessage = "Moonlight could not read the selected file location."
            return
        }
        resolvingTrackId = missingTrackId
        errorMessage = nil
        Task {
            do {
                try await appState.resolveMissingTrack(id: missingTrackId, to: url)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            resolvingTrackId = nil
        }
    }

    private func showFilePicker(for track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MetadataExtractor.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the current file for \(track.displayTitle). The file must be inside a Moonlight music folder."
        panel.prompt = "Reconnect"
        panel.directoryURL = nearestExistingDirectory(for: track.fileURL)
        panel.begin { response in
            guard response == .OK, let url = panel.url, let trackId = track.dbId else { return }
            resolve(missingTrackId: trackId, to: url)
        }
    }

    private func nearestExistingDirectory(for value: String) -> URL? {
        guard var url = URL(string: value)?.deletingLastPathComponent() else { return nil }
        while url.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func missingTrackDetail(_ track: Track) -> String {
        [track.displayArtist, track.displayAlbum]
            .filter { !$0.isEmpty && $0 != "Unknown Artist" && $0 != "Unknown Album" }
            .joined(separator: " — ")
    }

    private func path(for value: String) -> String {
        URL(string: value)?.path(percentEncoded: false) ?? value
    }
}
