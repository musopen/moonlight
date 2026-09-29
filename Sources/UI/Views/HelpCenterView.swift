// HelpCenterView.swift
//
// The in-app Help window and the text of its articles, covering topics such as adding a library,
// missing files, ratings, playlists, tags and privacy. Users can search or browse the article
// list, read step-by-step instructions, and open the contact form if they still need help.

import SwiftUI

/// The content model is deliberately kept beside the Help Center UI so new knowledge-base
/// articles can be added without changing navigation or presentation code.
struct HelpArticle: Identifiable, Hashable {
    struct Section: Hashable {
        let title: String
        let body: String
        let steps: [String]

        init(_ title: String, body: String, steps: [String] = []) {
            self.title = title
            self.body = body
            self.steps = steps
        }
    }

    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let sections: [Section]
    let note: String?

    init(
        id: String,
        title: String,
        summary: String,
        systemImage: String,
        sections: [Section],
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.sections = sections
        self.note = note
    }
}

enum MoonlightHelp {
    static let articles: [HelpArticle] = [
        HelpArticle(
            id: "getting-started",
            title: "Add your library",
            summary: "Choose a music folder and let Moonlight build a local library from it.",
            systemImage: "sparkles",
            sections: [
                .init("Add your first folder", body: "Moonlight plays music you already keep on your Mac. Choose a folder that contains your audio files; its contents are added to your local library.", steps: [
                    "Choose File > Add Music Folder… or use Command–O.",
                    "Select the folder containing your music.",
                    "Wait for the scan banner to finish."
                ])
            ]
        ),
        HelpArticle(
            id: "missing-files",
            title: "Missing files and recovery",
            summary: "Reconnect renamed, moved, or temporarily unavailable music without losing playlists, favorites, ratings, or play history.",
            systemImage: "link.badge.plus",
            sections: [
                .init("What Moonlight preserves", body: "A track’s Moonlight database record is its durable identity. When a successful scan no longer finds the file at its saved path, Moonlight marks the track as missing instead of deleting it. The track keeps the same Moonlight ID along with its playlists, favorite status, rating, play count, and playback history. It cannot play until its file is available again."),
                .init("Automatic recovery after a rename or move", body: "When possible, Moonlight uses the macOS volume and filesystem file identifier to recognize the same file at a new path. This commonly handles a rename or move on the same disk automatically during the next scan. Moonlight updates the path on the existing track record, so no recovery prompt or new track ID is needed.", steps: [
                    "Rename or move the file in Finder.",
                    "Choose File > Rescan Library, or wait for Moonlight’s folder monitoring to scan the change.",
                    "If macOS still identifies it as the same file, Moonlight reconnects it automatically. The scan summary reports it as Relinked."
                ]),
                .init("Open Resolve Missing Files", body: "If automatic recovery is not possible—often after copying a file to another disk—open Settings > Missing Files. The Missing Track column shows the old location. Suggested Match shows a conservative candidate from files Moonlight has discovered in your configured music folders.", steps: [
                    "Make sure the replacement file is inside a folder listed in Settings > Folders.",
                    "Rescan the library so Moonlight can discover the replacement.",
                    "Open Settings > Missing Files and review the missing track, proposed path, confidence, and matching reasons."
                ]),
                .init("Use a suggested match", body: "Suggestions compare inexpensive evidence such as filename, embedded title, artist, album, duration, file size, and format. Moonlight labels a suggestion High or Medium confidence, but never applies it silently. If two candidates are similarly convincing, Moonlight shows no suggestion rather than guessing.", steps: [
                    "Check that the missing track and suggested file are the same recording.",
                    "Click Use Match.",
                    "Confirm the reconnection. Moonlight keeps the original track ID and merges away any duplicate row created when the new file was scanned."
                ]),
                .init("Find the file manually", body: "Use Find… when there is no suggestion or you know the correct file. For persistent sandbox access, the selected file must be inside one of Moonlight’s configured music folders. If it is elsewhere, add its containing folder in Settings > Folders and scan it first.", steps: [
                    "Click Find… beside the missing track.",
                    "Choose the current or replacement audio file.",
                    "Click Reconnect. Moonlight updates the existing track record instead of creating a new identity."
                ]),
                .init("For the curious: track, recording, and musical work", body: "Moonlight’s durable identity represents one track in your local library: the database record connected to a particular audio file. It does not currently create a separate musical-work identity for an abstract piece, movement, composition, or performance. Two files containing the same Beethoven work remain two tracks, and similarly named movements are not automatically combined. This avoids making musical claims that filenames and tags cannot reliably support."),
                .init("The metadata Moonlight understands", body: "Moonlight reads descriptive tags such as title, artist, album artist, album, composer, genre, year, and disc and track numbers. These tags power browsing and grouping; composer is especially useful for classical libraries. They describe a track, but they are not its identity. Tags can be missing, misspelled, translated, edited, or shared by different performances and masters. Recovery suggestions therefore use only a conservative subset—filename, title, artist or album artist, and album—with duration, file size, and format as supporting evidence."),
                .init("A hierarchy of identity evidence", body: "Moonlight uses the strongest inexpensive evidence available and becomes more cautious as that evidence weakens.", steps: [
                    "The saved path is where Moonlight expects to find the file. A path is a location, not lasting proof of identity, because it changes when a file is renamed or moved.",
                    "A matching macOS volume identifier and filesystem file identifier is strong evidence that this is the same file at a new path. Moonlight may relink it automatically.",
                    "A filename and embedded tags are descriptive clues. Moonlight combines several agreeing clues into a High or Medium suggestion, but does not treat them as proof.",
                    "When exact filesystem identity is unavailable, your confirmation is authoritative. Moonlight reconnects the selected file to the existing database record."
                ]),
                .init("How a suggestion is judged", body: "An exact filename is particularly useful; Moonlight can also recognize a normalized filename after differences such as a leading track number, punctuation, capitalization, or accents are removed. Matching title, artist, album, duration, file size, and format add support. None is unique on its own: many albums contain an ‘Intro,’ different performances can have similar durations, and tag edits or transcoding can change size and format. Moonlight requires naming evidence, and if the two best candidates are too close, it proposes neither rather than breaking the tie arbitrarily."),
                .init("Why not use a hash or audio fingerprint?", body: "Each alternative solves a different problem and has a cost. A whole-file hash can prove that two files contain exactly the same bytes, but scanning every large audio file requires extra I/O, and changing an embedded tag changes the hash even when the sound does not. An audio fingerprint can recognize similar audio across some file or encoding changes, but adds CPU, storage, indexing, and implementation complexity; remasters, edits, and near-identical performances can still require judgment. Filesystem identifiers are cheap and strong for renames and moves on the same volume, but usually do not survive a copy to another disk. Metadata is portable and inexpensive, but not unique or always accurate."),
                .init("The tradeoff Moonlight chooses", body: "Moonlight automatically acts only on strong filesystem identity, uses metadata to offer reviewable suggestions, and asks you when the answer is ambiguous. A false positive is more damaging than leaving a track missing: reconnecting the wrong recording could attach playlists, favorite status, rating, and play history to it while merging away the newly scanned row. Preserving uncertainty keeps that personal data attached to the identity you intended."),
                .init("Unavailable folders and drives", body: "If Moonlight cannot access or completely enumerate an entire folder or disconnected drive, it records a failed scan and leaves the previous track states unchanged. This prevents a temporary mount or permission problem from making a whole library appear missing. Moonlight shows a persistent Music folder unavailable notice instead of silently treating the tracks as healthy. Reconnect the drive, or click Reconnect… and choose the folder’s current location. When relative paths match after a library-root move, Moonlight keeps the existing track IDs and reconnects those files before scanning the remainder."),
                .init("Safety rules", body: "Moonlight does not hash entire audio files, create audio fingerprints, or automatically accept fuzzy matches. A missing track remains in the library until you reconnect it or explicitly remove it. Do not remove its music folder from Settings as a troubleshooting step: removing a folder intentionally removes that folder’s tracks from the Moonlight library.")
            ],
            note: "The filesystem determines whether the audio is available. Moonlight’s database determines whether the track and its personal library data continue to exist."
        ),
        HelpArticle(
            id: "ratings",
            title: "Track ratings",
            summary: "Rate tracks from one to five stars while keeping unrated tracks distinct.",
            systemImage: "star",
            sections: [
                .init("Rate a track", body: "Ratings are stored only in Moonlight’s local library database; Moonlight does not write them into your audio files. Show the Rating column from the Songs column menu, or use the Rate submenu in a track’s context menu."),
                .init("Unrated is not one star", body: "Clearing a rating returns the track to Unrated. One star is a real rating, while Unrated means you have not assigned any rating."),
                .init("Ratings and Favorites", body: "Ratings and Favorites are independent. Rating a track does not favorite it, favoriting it does not assign a rating, and clearing either value does not change the other."),
                .init("Files can move", body: "A rating belongs to the track’s durable Moonlight identity rather than its file path. Renaming or moving a recognized file, temporarily disconnecting a drive, or reconnecting a missing file does not erase its rating.")
            ],
            note: "Deleting Moonlight’s library database also deletes local ratings. Audio files do not contain a backup of them."
        ),
        HelpArticle(
            id: "music-library",
            title: "Your music library",
            summary: "How Moonlight reads, organizes, and keeps your collection current.",
            systemImage: "books.vertical",
            sections: [
                .init("Your files stay yours", body: "Moonlight builds a local index of the music folders you choose. It does not move, rename, or delete audio files when scanning."),
                .init("Scanning", body: "Moonlight scans a folder when you add it and checks known folders again when the app launches. It also watches for changes and periodically refreshes the library. Use File > Rescan Library for an on-demand incremental scan."),
                .init("Why Moonlight adds a unique ID to each file", body: "A file path and its ordinary music tags are not a lasting identity. A file can be renamed, moved to another folder or drive, or copied to another device. When Moonlight cannot recognize it as the same track, its ratings, favorites, play counts, and playlist membership can become disconnected.\n\nTo reduce that risk, Moonlight can add its own unique identifier—a Moonlight UUID—to compatible, writable files. When Moonlight sees that UUID after a move, rename, or on another device, it can reconnect the file with its existing library data.\n\nThis does minimally modify the file’s metadata: Moonlight appends only its own ID, in ID3 for MP3 files and equivalent tag fields in other supported formats. It does not change audio, replace your existing tags, or alter metadata unrelated to Moonlight. Files that cannot be safely rewritten are left unchanged.\n\nThis is optional. You can turn it off in Settings > Folders; with the option off, Moonlight does not add IDs to newly scanned files."),
                .init("How grouping works", body: "Albums, artists, composers, and genres are derived from the tags in your files. Composer is a separate view because artist credit alone is often not enough to navigate classical music."),
                .init("When a track is missing", body: "Moonlight preserves the track’s database record and personal library data instead of deleting it. See Missing files and recovery for automatic relinking, suggested matches, and manual recovery.", steps: [
                    "Choose File > Rescan Library.",
                    "Open Settings > Missing Files if Moonlight could not reconnect the file automatically.",
                    "Review Settings > Scan Errors when an entire folder or drive could not be scanned."
                ])
            ]
        ),
        HelpArticle(
            id: "playback",
            title: "Playback and queue",
            summary: "Understand what Moonlight will play next and how queue controls affect it.",
            systemImage: "play.circle",
            sections: [
                .init("The queue", body: "The queue is the current sequence of tracks. Open Up Next from the transport bar to see it. Double-click a queued track to start playing it."),
                .init("Shuffle and repeat", body: "Use the playback controls to turn shuffle or repeat on and off. These controls change how Moonlight moves through the current queue.")
            ]
        ),
        HelpArticle(
            id: "playlists",
            title: "Playlists",
            summary: "Build and manage collections without changing your music files.",
            systemImage: "music.note.list",
            sections: [
                .init("Add tracks", body: "Drag selected tracks onto a playlist in the sidebar. You can also use track or album actions where available to add music to a playlist."),
                .init("Manage playlists", body: "Control-click a playlist in the sidebar to rename or delete it. Deleting a playlist never deletes the music files it contains.")
            ]
        ),
        HelpArticle(
            id: "metadata",
            title: "Tags and artwork",
            summary: "Understand the metadata Moonlight uses to organize your music.",
            systemImage: "tag",
            sections: [
                .init("What Moonlight reads", body: "Moonlight reads common audio tags including title, artist, album artist, album, composer, genre, year, disc and track numbers. It also reads embedded artwork where available."),
                .init("Why metadata matters", body: "Album, artist, composer, and genre views are derived from your tags. Consistent tags make grouping and sorting more accurate, especially in large or classical collections."),
                .init("Edit tags", body: "Use the track or album editing actions to update supported tags. Moonlight saves the edits back to the audio file, then refreshes the library’s derived views."),
                .init("Artwork", body: "Artwork is read from your music files when available and shown throughout the library and player. If an album appears without cover art, check that its files have embedded artwork.")
            ]
        ),
        HelpArticle(
            id: "formats",
            title: "Supported formats",
            summary: "Audio formats Moonlight currently recognizes when scanning your folders.",
            systemImage: "waveform",
            sections: [
                .init("Current formats", body: "Moonlight currently scans MP3, M4A, AAC, FLAC, ALAC, WAV, AIFF, AIF, and M4B files."),
                .init("If a file will not play", body: "Playback support ultimately depends on macOS and the file’s encoding. First make sure the file appears in Songs and inspect the format column or Now Playing metadata. If it is absent, rescan and review Scan Errors in Settings.")
            ]
        ),
        HelpArticle(
            id: "privacy-integrations",
            title: "Privacy and integrations",
            summary: "See what stays on your Mac and what optional connections can share.",
            systemImage: "hand.raised",
            sections: [
                .init("Local library", body: "Your library index, playlists, and playback state live locally on your Mac. Moonlight uses the access you grant to the folders you select."),
                .init("Analytics", body: "Moonlight sends anonymous usage statistics to Google Analytics, such as app launches, playback starts, and library scans. It never sends your music, file names, or personal information, and it does not use an advertising identifier. It is on by default; you can turn it off in Settings > Privacy."),
                .init("Last.fm", body: "When you connect Last.fm in Settings > Integrations, Moonlight sends tagged artist, track, album, and playback timing information for scrobbling. If Last.fm is temporarily unavailable, failed scrobbles may remain stored locally until they can be sent.")
            ]
        )
    ]
}

struct HelpCenterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedArticleID: String

    init(initialArticleID: String? = nil) {
        _selectedArticleID = State(initialValue: initialArticleID ?? MoonlightHelp.articles[0].id)
    }

    private var displayedArticles: [HelpArticle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MoonlightHelp.articles }
        return MoonlightHelp.articles.filter { article in
            let sectionContent = article.sections.flatMap { [$0.title, $0.body] + $0.steps }
            let content = ([article.title, article.summary, article.note ?? ""] + sectionContent)
                .joined(separator: " ")
            return content.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedArticle: HelpArticle {
        displayedArticles.first(where: { $0.id == selectedArticleID })
            ?? displayedArticles.first
            ?? MoonlightHelp.articles[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            helpSidebar
            articleDetail
        }
        .background(Color.bgBase)
        .preferredColorScheme(appState.selectedTheme.colorScheme)
        .onChange(of: searchText) { _ in
            guard !displayedArticles.contains(where: { $0.id == selectedArticleID }),
                  let first = displayedArticles.first else { return }
            selectedArticleID = first.id
        }
    }

    private var helpSidebar: some View {
        VStack(spacing: 0) {
            Text("Moonlight Help")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            TextField("Search help", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 2) {
                    if displayedArticles.isEmpty {
                        Text("No matching help articles")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                            .padding(.top, 20)
                    } else {
                        ForEach(displayedArticles) { article in
                            HelpSidebarRow(article: article, isSelected: article.id == selectedArticleID) {
                                selectedArticleID = article.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Divider().overlay(Color.borderSoft)

            Button(action: { appState.showContactFeedback() }) {
                Label("Contact Us…", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dAccent)
        }
        .frame(width: 264)
        .background(
            ZStack {
                SidebarVibrancy()
                Color.bgSidebar
                LinearGradient(
                    stops: [
                        .init(color: Color.bgSidebarSheen, location: 0),
                        .init(color: .clear, location: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.borderSoft.opacity(0.7))
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var articleDetail: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Label(selectedArticle.title, systemImage: selectedArticle.systemImage)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .padding(.bottom, 10)

                    Text(selectedArticle.summary)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 28)

                    if let note = selectedArticle.note {
                        HelpNote(text: note)
                            .padding(.bottom, 24)
                    }

                    ForEach(Array(selectedArticle.sections.enumerated()), id: \.offset) { _, section in
                        HelpArticleSection(section: section)
                            .padding(.bottom, 26)
                    }
                }
                .frame(maxWidth: 650, alignment: .leading)
                .padding(.horizontal, 42)
                .padding(.vertical, 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgContent)
    }
}

private struct HelpSidebarRow: View {
    let article: HelpArticle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: article.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(article.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .fill(isSelected ? Color.dAccent.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HelpArticleSection: View {
    let section: HelpArticle.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(section.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            Text(section.body)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(index + 1).")
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.dAccent)
                            Text(step)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 3)
            }
        }
    }
}

private struct HelpNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.dAccent)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .fill(Color.dAccent.opacity(0.10))
        )
    }
}
