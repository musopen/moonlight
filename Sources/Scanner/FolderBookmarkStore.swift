// FolderBookmarkStore.swift
//
// Remembers which music folders the user has added to the Mac library, and keeps Moonlight's
// permission to read them after the app restarts. It prevents the same folder being added twice,
// reconnects folders that have moved, and removes folders from the library when asked.

import AppKit
import GRDB

enum FolderRegistrationResult: Equatable {
    case added(id: Int64, url: URL)
    case duplicate(id: Int64, url: URL)
}

actor FolderBookmarkStore {
    private let db: DatabaseManager
    /// Security-scoped access is process-wide, but it is reference counted. Keep
    /// one resolved URL per saved folder alive for the lifetime of the library so
    /// playback, metadata editing, and file monitoring retain their access after
    /// the launch scan completes.
    private var accessedFolders: [Int64: URL] = [:]

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Registers a folder once. A folder can arrive through the picker, Finder
    /// drag-and-drop, or an older bookmark whose URL spelling differs, so
    /// compare canonical file URLs instead of relying only on SQLite's exact
    /// `url` string uniqueness.
    func addFolder(url: URL) throws -> FolderRegistrationResult {
        let canonicalURL = Self.canonicalFolderURL(url)
        guard (try? canonicalURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw CocoaError(.fileNoSuchFile)
        }

        if let existingID = try existingFolderID(for: canonicalURL) {
            return .duplicate(id: existingID, url: canonicalURL)
        }

        let bookmarkData = try canonicalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let id = try db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO folders (url, bookmark_data, date_added, library_root_id, is_writable, portable_identity, filesystem_type)
                VALUES (?, ?, ?, ?, ?, 1, ?)
            """, arguments: [
                canonicalURL.absoluteString,
                bookmarkData,
                Date(),
                UUID().uuidString.uppercased(),
                FileManager.default.isWritableFile(atPath: canonicalURL.path),
                Self.filesystemType(for: canonicalURL)
            ])
            return db.lastInsertedRowID
        }

        // Resolve the stored bookmark (rather than relying on the transient URL
        // returned by the open panel) and begin the app-lifetime security scope.
        _ = resolvedFolders()
        return .added(id: id, url: canonicalURL)
    }

    nonisolated static func canonicalFolderURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func filesystemType(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeTypeNameKey]))?.volumeTypeName?.lowercased()
    }

    func resolvedFolders() -> [(url: URL, id: Int64)] {
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, url, bookmark_data FROM folders")
        }) ?? []

        return rows.compactMap { row -> (url: URL, id: Int64)? in
            guard let id = row["id"] as? Int64 else { return nil }
            let storedURL = (row["url"] as String?).flatMap(URL.init(string:))
            guard let data = row["bookmark_data"] as? Data else {
                return storedURL.map { ($0, id) }
            }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                // Keep unresolved folders visible in Settings so the user can
                // reconnect them instead of making the library appear healthy.
                return storedURL.map { ($0, id) }
            }

            if isStale {
                refreshBookmark(for: url, id: id)
            }
            beginAccessing(url, for: id)
            return (url, id)
        }
    }

    /// Replaces a folder's security-scoped bookmark while retaining its database
    /// identity. Track paths are reconciled separately so their durable IDs and
    /// Moonlight relationships can be preserved deliberately.
    func reconnectFolder(id: Int64, to url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let bookmarkData = try standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let previousURL = try db.read { db -> URL in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT url FROM folders WHERE id = ?",
                arguments: [id]
            ), let url = URL(string: value) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }

        try db.write { db in
            try db.execute(
                sql: "UPDATE folders SET url = ?, bookmark_data = ? WHERE id = ?",
                arguments: [standardizedURL.absoluteString, bookmarkData, id]
            )
        }
        beginAccessing(standardizedURL, for: id)
        return previousURL
    }

    func hasFolders() -> Bool {
        (try? db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders")
        }) ?? 0 > 0
    }

    func removeFolder(id: Int64) throws {
        if let url = accessedFolders.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        try db.write { db in
            try db.execute(sql: "UPDATE scan_jobs SET folder_id = NULL WHERE folder_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
        }
    }

    private func existingFolderID(for canonicalURL: URL) throws -> Int64? {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, url FROM folders")
            return rows.first { row in
                guard let storedURLString: String = row["url"],
                      let storedURL = URL(string: storedURLString) else { return false }
                return Self.canonicalFolderURL(storedURL) == canonicalURL
            }?["id"]
        }
    }

    private func beginAccessing(_ url: URL, for id: Int64) {
        if let previousURL = accessedFolders[id] {
            guard previousURL.standardizedFileURL != url.standardizedFileURL else { return }
            previousURL.stopAccessingSecurityScopedResource()
        }

        guard url.startAccessingSecurityScopedResource() else { return }
        accessedFolders[id] = url
    }

    private func refreshBookmark(for url: URL, id: Int64) {
        guard let refreshedData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        try? db.write { db in
            let previousURLString = try String.fetchOne(
                db,
                sql: "SELECT url FROM folders WHERE id = ?",
                arguments: [id]
            )
            let trackRows = try Row.fetchAll(
                db,
                sql: "SELECT id, file_url FROM tracks WHERE folder_id = ?",
                arguments: [id]
            )

            if let previousURLString,
               let previousURL = URL(string: previousURLString),
               previousURL.standardizedFileURL != url.standardizedFileURL {
                let oldRootPath = previousURL.standardizedFileURL.path
                for row in trackRows {
                    guard let trackId: Int64 = row["id"],
                          let fileURLString: String = row["file_url"],
                          let fileURL = URL(string: fileURLString) else { continue }
                    let oldFilePath = fileURL.standardizedFileURL.path
                    guard oldFilePath.hasPrefix(oldRootPath + "/") else { continue }
                    let relativePath = String(oldFilePath.dropFirst(oldRootPath.count + 1))
                    let newFileURL = url.appendingPathComponent(relativePath)
                    try db.execute(
                        sql: "UPDATE tracks SET file_url = ? WHERE id = ?",
                        arguments: [newFileURL.absoluteString, trackId]
                    )
                }
            }

            try db.execute(
                sql: "UPDATE folders SET url = ?, bookmark_data = ? WHERE id = ?",
                arguments: [url.absoluteString, refreshedData, id]
            )
        }
    }
}
