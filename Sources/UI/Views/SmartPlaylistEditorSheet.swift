// SmartPlaylistEditorSheet.swift
//
// The window for creating a smart playlist, which fills itself automatically from rules rather
// than being built by hand. The user names it and adds conditions such as rating, genre, artist,
// year, length or when a song was last played, and sees a live count of matching songs before
// creating it.

import SwiftUI

private enum SmartConditionKind: String, CaseIterable, Identifiable {
    case favorite = "Favorite"
    case rating = "Rating at least"
    case playCount = "Play count at least"
    case lastPlayedBefore = "Last played before"
    case lastPlayedAfter = "Last played after"
    case genre = "Genre"
    case artist = "Artist"
    case composer = "Composer"
    case yearBefore = "Year before"
    case yearAfter = "Year after"
    case durationAtLeast = "Duration at least"
    case durationAtMost = "Duration at most"

    var id: String { rawValue }
}

private struct SmartCondition: Identifiable {
    let id = UUID()
    var kind: SmartConditionKind = .favorite
    var text = ""
    var number = 1
    var date = Date()

    var rule: SmartPlaylistRule? {
        switch kind {
        case .favorite: .favorite(true)
        case .rating: .ratingAtLeast(max(1, min(number, 5)))
        case .playCount: .playCountAtLeast(max(0, number))
        case .lastPlayedBefore: .lastPlayedBefore(date)
        case .lastPlayedAfter: .lastPlayedAfter(date)
        case .genre: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .genre(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .artist: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .artist(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .composer: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .composer(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .yearBefore: .yearBefore(max(1, number))
        case .yearAfter: .yearAfter(max(1, number))
        case .durationAtLeast: .durationAtLeast(Double(max(0, number)) * 60)
        case .durationAtMost: .durationAtMost(Double(max(0, number)) * 60)
        }
    }
}

struct SmartPlaylistEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var matchAll = true
    @State private var conditions = [SmartCondition()]
    @State private var previewCount = 0

    private var rule: SmartPlaylistRule? {
        let rules = conditions.compactMap(\.rule)
        guard !rules.isEmpty else { return nil }
        return matchAll ? .all(rules) : .any(rules)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Playlist name", text: $name)
                Picker("Match", selection: $matchAll) {
                    Text("All conditions").tag(true)
                    Text("Any condition").tag(false)
                }
                Section("Conditions") {
                    ForEach($conditions) { $condition in
                        HStack {
                            Picker("Condition", selection: $condition.kind) {
                                ForEach(SmartConditionKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                            }
                            .labelsHidden()
                            conditionValue($condition)
                            Button(role: .destructive) {
                                conditions.removeAll { $0.id == condition.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .disabled(conditions.count == 1)
                        }
                    }
                    Button("Add Condition") { conditions.append(SmartCondition()) }
                        .disabled(conditions.count >= SmartPlaylistRule.maxConditions)
                        .help("Smart playlists can have up to \(SmartPlaylistRule.maxConditions) conditions.")
                }
            }
            .padding()

            Divider()
            HStack {
                Label("\(previewCount) matching tracks", systemImage: "music.note.list")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule == nil)
            }
            .padding()
        }
        .frame(width: 640, height: 430)
        .task(id: previewKey) { refreshPreview() }
    }

    @ViewBuilder
    private func conditionValue(_ condition: Binding<SmartCondition>) -> some View {
        switch condition.wrappedValue.kind {
        case .genre, .artist, .composer:
            TextField("Value", text: condition.text).frame(maxWidth: 170)
        case .lastPlayedBefore, .lastPlayedAfter:
            DatePicker("Date", selection: condition.date, displayedComponents: .date).labelsHidden()
        case .rating:
            Stepper("\(condition.wrappedValue.number) stars", value: condition.number, in: 1...5)
        case .yearBefore, .yearAfter:
            Stepper("\(condition.wrappedValue.number)", value: condition.number, in: 1...9999)
        case .durationAtLeast, .durationAtMost:
            Stepper("\(condition.wrappedValue.number) min", value: condition.number, in: 0...1440)
        case .playCount:
            Stepper("\(condition.wrappedValue.number)", value: condition.number, in: 0...999_999)
        case .favorite:
            Text("is favorited").foregroundStyle(.secondary)
        }
    }

    private var previewKey: String {
        let pieces = conditions.map { "\($0.kind.rawValue)|\($0.text)|\($0.number)|\($0.date.timeIntervalSince1970)" }
        return "\(matchAll)|\(pieces.joined(separator: ","))|\(appState.libraryVersion)"
    }

    private func refreshPreview() {
        guard let rule else { previewCount = 0; return }
        previewCount = (try? appState.db.read { try SmartPlaylistEvaluator.tracks(matching: rule, in: $0).count }) ?? 0
    }

    private func create() {
        guard let rule else { return }
        if let playlist = appState.createSmartPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines), rule: rule), let id = playlist.id {
            appState.selectedSidebarItem = .playlist(id)
            dismiss()
        }
    }
}
