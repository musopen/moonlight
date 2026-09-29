// ContainerFileReference.swift
//
// On iPhone and iPad, iOS moves the app's private folder whenever the app is updated or restored,
// so full file paths stop working. This file defines a short, relative way to record where a song
// lives inside the app's folder so it can always be found again. The Mac app is unaffected.

import Foundation

/// The app-owned container directory an iOS audio file lives in.
enum ContainerFileRoot: String, CaseIterable, Codable, Sendable {
    /// Added through the Files app or Finder file sharing.
    case manual = "mobile-manual"

    /// The URI scheme used in `tracks.file_url` for files under this root.
    var scheme: String { "moonlight-manual" }

    init?(scheme: String) {
        guard let match = Self.allCases.first(where: { $0.scheme == scheme }) else { return nil }
        self = match
    }
}

/// A container-relative reference to an audio file, as stored in `tracks.file_url`
/// on iOS.
///
/// An absolute path cannot be persisted on iOS: the `<UUID>` segment of the data
/// container (`/var/mobile/Containers/Data/Application/<UUID>/…`) is reassigned on
/// every app update, restore and reinstall, so stored absolute URLs resolve to
/// nothing while every row still reports as available. Rows therefore hold
/// `moonlight-manual:///Song.flac`, resolved against the live container at access
/// time. macOS continues to store ordinary `file://` URLs and is unaffected.
///
/// This type is pure encoding — it knows nothing about the filesystem. Resolution
/// against real directories is `ContainerPathResolver`, which is iOS-only.
struct ContainerFileReference: Equatable, Hashable, Sendable {
    let root: ContainerFileRoot

    /// Path relative to the root directory. Never empty, never absolute, and
    /// guaranteed free of `.` and `..` components so a reference can never escape
    /// its root.
    let relativePath: String

    init?(root: ContainerFileRoot, relativePath: String) {
        guard Self.isSafeRelativePath(relativePath) else { return nil }
        self.root = root
        self.relativePath = relativePath
    }

    /// Parses a stored `file_url` value. Returns nil for anything that is not a
    /// container reference, including the `file://` URLs macOS writes.
    init?(rawValue: String) {
        guard let separator = rawValue.range(of: "://") else { return nil }
        guard let root = ContainerFileRoot(scheme: String(rawValue[rawValue.startIndex..<separator.lowerBound])) else { return nil }

        // The authority component is always empty, so the path begins at the
        // third slash: "moonlight-manual:///Song.flac".
        var path = String(rawValue[separator.upperBound...])
        guard path.hasPrefix("/") else { return nil }
        path.removeFirst()

        guard let decoded = path.removingPercentEncoding else { return nil }
        self.init(root: root, relativePath: decoded)
    }

    /// The value to persist in `tracks.file_url`.
    var rawValue: String {
        let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return "\(root.scheme):///\(encoded)"
    }

    /// True when a stored `file_url` is a container reference rather than a
    /// `file://` URL. Cheaper than a full parse for hot read paths.
    static func isContainerReference(_ rawValue: String) -> Bool {
        ContainerFileRoot.allCases.contains { rawValue.hasPrefix("\($0.scheme)://") }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }
}
