// EmptyLibraryView.swift
//
// The welcome screen shown when the library has no music yet. It invites the user to add a music
// folder, and offers a switch to add a small Moonlight ID to scanned files so ratings, playlists
// and play counts stay attached if a file is moved or renamed.

import SwiftUI

struct EmptyLibraryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            VStack(spacing: 20) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("No Music Yet")
                    .font(.title2).bold()

                Text("Add a folder containing your music to get started.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                Button(action: { appState.showFolderPicker() }) {
                    Label("Add Music Folder…", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 40)

            portableIdentityBanner
                .padding(.bottom, 42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var portableIdentityBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Add a unique ID to scanned files")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 6)

                Text(appState.portableIdentityEnabled() ? "Enabled" : "Disabled")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                Toggle("Add Moonlight IDs to imported or scanned files", isOn: Binding(
                    get: { appState.portableIdentityEnabled() },
                    set: { appState.setPortableIdentityEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.dAccent)
                .labelsHidden()
            }

            Text("When enabled, Moonlight adds a small ID to file metadata so ratings, playlists, and play counts stay connected if a file moves, is renamed, or is used on another device. Audio and existing tags stay unchanged. [Learn more](https://moonlight.local/help/music-library)")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textSecondary)
                .tint(Color.dAccent)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.host == "moonlight.local", url.path == "/help/music-library" else {
                        return .systemAction
                    }
                    appState.showHelp(articleID: "music-library")
                    return .handled
                })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.dAccent.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.dAccent.opacity(0.12), lineWidth: 0.75)
        }
    }
}
