# Moonlight: technical overview

A short orientation for contributors. See [README.md](README.md) for build steps and
[CONTRIBUTING.md](CONTRIBUTING.md) for how to send changes.

## Building blocks

| Area | Technology |
|---|---|
| Interface | SwiftUI, with AppKit where large lists need it |
| Library database | SQLite via [GRDB](https://github.com/groue/GRDB.swift), with full-text search |
| Playback | AVFoundation |
| Reading and writing tags | AVFoundation for reading, TagLib (via `LocalPackages/spfk-metadata`) for writing |
| Sync between devices | CloudKit, for library data only; audio files never leave the device |
| Project and dependencies | XcodeGen (`project.yml`) and Swift Package Manager |

The Mac app runs in Apple's sandbox and reaches music folders through bookmarks the
user grants. The iPhone and iPad app lives in `Sources/Mobile` and shares part of the
database and scanner code with the Mac app (see `project.yml`).

## Where things are

| Folder | What it holds |
|---|---|
| `Sources/App` | App startup, menus and shared app state |
| `Sources/Database` | Library database, playlists and iCloud sync |
| `Sources/Scanner` | Finding music files and reading or editing their tags |
| `Sources/Playback` | Audio playback, the play queue and media keys |
| `Sources/Radio` | Internet radio and its bundled station list |
| `Sources/LastFM` | Last.fm scrobbling |
| `Sources/Services` | The feedback form |
| `Sources/UI` | Every screen and control in the Mac app |
| `Sources/Mobile` | The iPhone and iPad app |
| `Tests`, `MobileTests` | Automated tests for the Mac and iOS apps |

## Conventions

- **Generated project.** The `.xcodeproj` is generated from `project.yml`. Edit that file
  and run `xcodegen generate`; don't edit the project directly.
- **File headers.** Every Swift file in `Sources/` starts with a short plain-English comment
  saying what it does. Keep it accurate, and add one to new files.
- **Your own identity.** The team ID, bundle ID and iCloud container live in
  `Config/Signing.xcconfig`. Override them in a gitignored `Config/Signing.local.xcconfig`
  (see the example file) and never hard-code them elsewhere.
- **Optional services.** Last.fm, the feedback form and analytics are off unless you supply
  your own keys; see the README.
- **Careful with music files.** Code that writes to audio files must back up, verify and
  restore on failure, and be tested against the fixtures in `Tests/Fixtures`.

## Tests

```sh
xcodebuild test -project Moonlight.xcodeproj -scheme Moonlight -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Moonlight.xcodeproj -scheme MoonlightMobile -destination "platform=iOS Simulator,name=iPhone 17 Pro" CODE_SIGNING_ALLOWED=NO
```
