// ContainerPathResolver.swift
//
// On iPhone and iPad, works out where each imported song actually lives on the device. The app's
// storage folder can move whenever the app is updated, so songs are saved as a location relative
// to Moonlight's Music folder and turned into a real file path only when needed. It also keeps
// that audio out of iCloud Backup.

import Foundation

/// Resolves `ContainerFileReference` values against the app container as it
/// exists right now.
///
/// Every path that reaches the filesystem on iOS goes through here. Nothing else
/// should build a URL from `tracks.file_url` directly, because the container path
/// a reference resolves to changes on every app update.
enum ContainerPathResolver {
    /// User-managed audio. Lives in `Documents` so Finder file sharing and the
    /// Files app can reach it.
    private static let manualDirectoryName = "Music"

    /// Returns the root directory, creating it if needed.
    ///
    /// Audio is excluded from backup: it is large, and it is
    /// recoverable either from the user's own files or from the paired Mac.
    static func directory(for _: ContainerFileRoot) throws -> URL {
        var directory = try baseDirectory(.documentDirectory)
            .appendingPathComponent(manualDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    /// The location a reference points at. The file may or may not exist.
    static func url(for reference: ContainerFileReference) throws -> URL {
        try directory(for: reference.root).appendingPathComponent(reference.relativePath)
    }

    /// Resolves a stored `tracks.file_url`. Falls back to plain URL parsing so
    /// rows written before container references existed still resolve.
    static func url(forStoredFileURL rawValue: String) -> URL? {
        if let reference = ContainerFileReference(rawValue: rawValue) {
            return try? url(for: reference)
        }
        return URL(string: rawValue)
    }

    /// As `url(forStoredFileURL:)`, but nil when nothing is actually on disk.
    /// Callers use this to tell "the file moved" apart from "the file is gone".
    static func existingURL(forStoredFileURL rawValue: String) -> URL? {
        guard let url = url(forStoredFileURL: rawValue), url.isFileURL else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Builds a reference for a file already inside one of the roots.
    static func reference(for url: URL, root: ContainerFileRoot) throws -> ContainerFileReference? {
        let base = try directory(for: root).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return ContainerFileReference(root: root, relativePath: String(path.dropFirst(base.count + 1)))
    }

    private static func baseDirectory(_ directory: FileManager.SearchPathDirectory) throws -> URL {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
