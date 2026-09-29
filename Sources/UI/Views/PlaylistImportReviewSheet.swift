// PlaylistImportReviewSheet.swift
//
// A review window shown before importing playlist files from elsewhere. For each playlist it
// shows how many songs were found in the library and lists any that were not. The user can
// remove repeated songs, save a report of what was missing, then import or cancel.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlaylistImportReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let review: PlaylistImportReview
    @State private var removeRepeatedTracks = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(review.previews) { preview in
                    Section(preview.suggestedName) {
                        Label("\(preview.resolvedCount) of \(preview.items.count) tracks found", systemImage: "checkmark.circle")
                        if !preview.unresolvedItems.isEmpty {
                            DisclosureGroup("\(preview.unresolvedItems.count) not found") {
                                ForEach(preview.unresolvedItems) { item in
                                    Text("Line \(item.entry.lineNumber): \(item.entry.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remove repeated tracks (keep the first occurrence)", isOn: $removeRepeatedTracks)
                Text("Only tracks already in this Moonlight library will be imported. Unresolved entries are left out; no guessed matches are made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            HStack {
                if review.previews.contains(where: { !$0.unresolvedItems.isEmpty }) {
                    Button("Save Report…", action: saveReport)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 460)
        .alert("Could Not Import Playlists", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func commit() {
        do {
            try appState.commitPlaylistImport(review, removeRepeatedTracks: removeRepeatedTracks)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moonlight Playlist Import Report.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let sections = review.previews.compactMap { preview -> String? in
                let unresolved = preview.unresolvedItems
                guard !unresolved.isEmpty else { return nil }
                let lines = unresolved.map { "Line \($0.entry.lineNumber): \($0.entry.displayName)" }
                return "\(preview.sourceURL.lastPathComponent)\n" + lines.joined(separator: "\n")
            }
            do {
                try sections.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
