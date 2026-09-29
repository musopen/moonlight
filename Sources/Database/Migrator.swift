// Migrator.swift
//
// Upgrades the library database step by step when a newer version of Moonlight changes how data is
// stored. Each numbered step adds or reshapes tables and copies existing data forward, so users
// keep their library, playlists and ratings after updating.

import Foundation
import GRDB

enum Migrator {
    static func migrate(_ writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try Schema.createTables(db)
        }

        migrator.registerMigration("v2_artwork_on_tracks") { db in
            let columns = try db.columns(in: "tracks")
            guard !columns.contains(where: { $0.name == "artwork_id" }) else { return }
            try db.alter(table: "tracks") { t in
                t.add(column: "artwork_id", .integer).references("artwork")
            }
        }

        migrator.registerMigration("v3_tracks_fts_album_artist") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS tracks_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE tracks_fts USING fts5(
                    title, artist, album_artist, album, composer, genre,
                    content=tracks, content_rowid=id
                )
            """)
            try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild')")
        }

        migrator.registerMigration("v4_scan_summaries") { db in
            let scanJobColumns = try db.columns(in: "scan_jobs").map(\.name)
            func addScanJobColumn(_ name: String, _ definition: String) throws {
                guard !scanJobColumns.contains(name) else { return }
                try db.execute(sql: "ALTER TABLE scan_jobs ADD COLUMN \(name) \(definition)")
            }

            try addScanJobColumn("total_files", "INTEGER NOT NULL DEFAULT 0")
            try addScanJobColumn("skipped_files", "INTEGER NOT NULL DEFAULT 0")
            try addScanJobColumn("changed_files", "INTEGER NOT NULL DEFAULT 0")
            try addScanJobColumn("removed_files", "INTEGER NOT NULL DEFAULT 0")
            try addScanJobColumn("error_count", "INTEGER NOT NULL DEFAULT 0")
            try addScanJobColumn("mode", "TEXT NOT NULL DEFAULT 'incremental'")
            try addScanJobColumn("trigger", "TEXT NOT NULL DEFAULT 'manual'")
            try addScanJobColumn("failure_message", "TEXT")

            let scanErrorColumns = try db.columns(in: "scan_errors").map(\.name)
            func addScanErrorColumn(_ name: String, _ definition: String) throws {
                guard !scanErrorColumns.contains(name) else { return }
                try db.execute(sql: "ALTER TABLE scan_errors ADD COLUMN \(name) \(definition)")
            }

            try addScanErrorColumn("stable_file_url", "TEXT NOT NULL DEFAULT ''")
            try addScanErrorColumn("stage", "TEXT NOT NULL DEFAULT 'metadata'")
            try addScanErrorColumn("category", "TEXT NOT NULL DEFAULT 'error'")
            try addScanErrorColumn("created_at", "DATETIME")
            try db.execute(sql: "UPDATE scan_errors SET stable_file_url = file_url WHERE stable_file_url = ''")
            try db.execute(sql: "UPDATE scan_errors SET created_at = CURRENT_TIMESTAMP WHERE created_at IS NULL")
        }

        migrator.registerMigration("v5_lastfm_scrobble_outbox") { db in
            try Schema.createLastFMScrobbleOutbox(db)
        }

        migrator.registerMigration("v6_deduplicated_artwork") { db in
            let artworkColumns = try db.columns(in: "artwork").map(\.name)
            if !artworkColumns.contains("content_hash") {
                try db.execute(sql: "ALTER TABLE artwork ADD COLUMN content_hash BLOB")
            }

            let trackColumns = try db.columns(in: "tracks").map(\.name)
            if !trackColumns.contains("artwork_source_url") {
                try db.execute(sql: "ALTER TABLE tracks ADD COLUMN artwork_source_url TEXT")
            }
            if !trackColumns.contains("artwork_source_file_size") {
                try db.execute(sql: "ALTER TABLE tracks ADD COLUMN artwork_source_file_size INTEGER")
            }
            if !trackColumns.contains("artwork_source_modified_at") {
                try db.execute(sql: "ALTER TABLE tracks ADD COLUMN artwork_source_modified_at DATETIME")
            }

            let rows = try Row.fetchAll(db, sql: "SELECT id, data_large FROM artwork")
            for row in rows {
                guard let id: Int64 = row["id"],
                      let data: Data = row["data_large"],
                      let prepared = ArtworkStore.prepare(from: data) else { continue }
                try db.execute(sql: """
                    UPDATE artwork
                    SET content_hash = ?, data_small = ?, data_large = ?
                    WHERE id = ?
                """, arguments: [prepared.contentHash, prepared.thumbnailData, prepared.displayData, id])
            }

            try db.execute(sql: """
                UPDATE tracks
                SET artwork_id = (
                    SELECT MIN(canonical.id)
                    FROM artwork AS canonical
                    WHERE canonical.content_hash = (
                        SELECT content_hash FROM artwork WHERE id = tracks.artwork_id
                    )
                )
                WHERE artwork_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM artwork WHERE id = tracks.artwork_id AND content_hash IS NOT NULL)
            """)
            try db.execute(sql: """
                UPDATE albums
                SET artwork_id = (
                    SELECT MIN(canonical.id)
                    FROM artwork AS canonical
                    WHERE canonical.content_hash = (
                        SELECT content_hash FROM artwork WHERE id = albums.artwork_id
                    )
                )
                WHERE artwork_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM artwork WHERE id = albums.artwork_id AND content_hash IS NOT NULL)
            """)
            try db.execute(sql: """
                DELETE FROM artwork
                WHERE content_hash IS NOT NULL
                  AND id NOT IN (
                    SELECT MIN(id) FROM artwork
                    WHERE content_hash IS NOT NULL
                    GROUP BY content_hash
                  )
            """)
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS artwork_content_hash ON artwork(content_hash)")
            if !rows.isEmpty {
                try db.execute(sql: """
                    INSERT INTO settings (key, value) VALUES ('artwork_storage_maintenance_needed', '1')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
            }
        }

        migrator.registerMigration("v7_durable_track_identity") { db in
            let trackColumns = try db.columns(in: "tracks").map(\.name)
            func addTrackColumn(_ name: String, _ definition: String) throws {
                guard !trackColumns.contains(name) else { return }
                try db.execute(sql: "ALTER TABLE tracks ADD COLUMN \(name) \(definition)")
            }

            let hasFoldersTable = try db.tableExists("folders")
            try addTrackColumn(
                "folder_id",
                hasFoldersTable ? "INTEGER REFERENCES folders(id) ON DELETE CASCADE" : "INTEGER"
            )
            try addTrackColumn("availability_status", "TEXT NOT NULL DEFAULT 'available'")
            try addTrackColumn("document_identifier", "INTEGER")
            try addTrackColumn("volume_uuid", "TEXT")
            try addTrackColumn("last_seen_at", "DATETIME")
            try addTrackColumn("last_seen_scan_id", "INTEGER")
            try addTrackColumn("missing_since", "DATETIME")

            if try db.tableExists("scan_jobs") {
                let scanJobColumns = try db.columns(in: "scan_jobs").map(\.name)
                if !scanJobColumns.contains("missing_files") {
                    try db.execute(sql: "ALTER TABLE scan_jobs ADD COLUMN missing_files INTEGER NOT NULL DEFAULT 0")
                }
                if !scanJobColumns.contains("relinked_files") {
                    try db.execute(sql: "ALTER TABLE scan_jobs ADD COLUMN relinked_files INTEGER NOT NULL DEFAULT 0")
                }
            }

            // Saved roots may overlap. The longest matching root owns the track.
            if hasFoldersTable, trackColumns.contains("file_url") {
                try db.execute(sql: """
                    UPDATE tracks
                    SET folder_id = (
                        SELECT folders.id
                        FROM folders
                        WHERE substr(tracks.file_url, 1, length(rtrim(folders.url, '/')) + 1)
                              = rtrim(folders.url, '/') || '/'
                        ORDER BY length(folders.url) DESC
                        LIMIT 1
                    )
                    WHERE folder_id IS NULL
                """)
            }

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS tracks_folder_status ON tracks(folder_id, availability_status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS tracks_document_identity ON tracks(volume_uuid, document_identifier)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS tracks_last_seen_scan ON tracks(folder_id, last_seen_scan_id)")
        }

        migrator.registerMigration("v8_file_resource_identity") { db in
            let trackColumns = try db.columns(in: "tracks").map(\.name)
            if !trackColumns.contains("file_resource_identifier") {
                try db.execute(sql: "ALTER TABLE tracks ADD COLUMN file_resource_identifier BLOB")
            }
            try db.create(
                index: "tracks_file_resource_identity",
                on: "tracks",
                columns: ["volume_uuid", "file_resource_identifier"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v9_track_ratings") { db in
            let trackColumns = try db.columns(in: "tracks").map(\.name)
            guard !trackColumns.contains("rating") else { return }
            try db.execute(sql: """
                ALTER TABLE tracks
                ADD COLUMN rating INTEGER NULL
                CHECK (rating IS NULL OR rating BETWEEN 1 AND 5)
            """)
        }

        migrator.registerMigration("v10_playlist_order_index") { db in
            guard try db.tableExists("playlist_tracks") else { return }
            try db.create(
                index: "playlist_tracks_playlist_position",
                on: "playlist_tracks",
                columns: ["playlist_id", "position"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v11_cross_device_identity") { db in
            try migrateCrossDeviceIdentity(db)
        }

        migrator.registerMigration("v12_sync_delivery_and_recovery") { db in
            if try db.tableExists("sync_outbox") {
                let columns = Set(try db.columns(in: "sync_outbox").map(\.name))
                if !columns.contains("deliver_after") {
                    try db.execute(sql: "ALTER TABLE sync_outbox ADD COLUMN deliver_after DATETIME")
                    try db.execute(sql: "UPDATE sync_outbox SET deliver_after = enqueued_at WHERE deliver_after IS NULL")
                }
                try db.create(
                    index: "sync_outbox_delivery",
                    on: "sync_outbox",
                    columns: ["deliver_after", "enqueued_at"],
                    ifNotExists: true
                )
            }
            try db.create(table: "sync_revision_rejections", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("record_name", .text).notNull()
                t.column("field_name", .text).notNull()
                t.column("claimed_revision", .text).notNull()
                t.column("received_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v13_sync_outbox_generation") { db in
            guard try db.tableExists("sync_outbox") else { return }
            let columns = Set(try db.columns(in: "sync_outbox").map(\.name))
            if !columns.contains("generation") {
                try db.execute(sql: "ALTER TABLE sync_outbox ADD COLUMN generation INTEGER NOT NULL DEFAULT 1")
            }
        }

        // iOS stored absolute app-container paths in tracks.file_url, which are
        // invalidated by every app update, restore and reinstall. Rebase them onto
        // container-relative references using the relative path physical_files
        // already recorded. No-op on macOS, where no mobile roots exist.
        migrator.registerMigration("v14_container_relative_paths") { db in
            guard try db.tableExists("physical_files"), try db.tableExists("tracks") else { return }
            try db.execute(
                sql: "UPDATE physical_files SET library_root_id = ? WHERE library_root_id = 'mobile-container'",
                arguments: [ContainerFileRoot.manual.rawValue]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS id, p.library_root_id AS root, p.relative_path AS relative_path
                FROM tracks t
                JOIN physical_files p ON p.physical_file_id = t.physical_file_id
                WHERE p.library_root_id = ? AND t.file_url NOT LIKE 'moonlight-%'
                """, arguments: [ContainerFileRoot.manual.rawValue])

            for row in rows {
                let id: Int64 = row["id"]
                guard let rawRoot: String = row["root"], let root = ContainerFileRoot(rawValue: rawRoot),
                      let relativePath: String = row["relative_path"],
                      let reference = ContainerFileReference(root: root, relativePath: relativePath)
                else { continue }
                try db.execute(
                    sql: "UPDATE tracks SET file_url = ? WHERE id = ?",
                    arguments: [reference.rawValue, id]
                )
            }
        }

        // v11 added these nullable columns to existing playlist rows. A small
        // number of earlier development databases recorded that migration before
        // all rows were backfilled, which made strict Playlist decoding fail.
        migrator.registerMigration("v15_repair_playlist_sync_fields") { db in
            guard try db.tableExists("playlists") else { return }
            let hasSyncState = try db.tableExists("sync_state")
            let deviceID = hasSyncState
                ? (try String.fetchOne(db, sql: "SELECT CAST(value AS TEXT) FROM sync_state WHERE key = 'device_id'"))
                    ?? UUID().uuidString.uppercased()
                : UUID().uuidString.uppercased()
            if hasSyncState {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO sync_state (key, value) VALUES ('device_id', ?)",
                    arguments: [Data(deviceID.utf8)]
                )
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, date_modified
                FROM playlists
                WHERE playlist_sync_id IS NULL OR playlist_sync_id = ''
                   OR name_rev IS NULL OR name_rev = ''
                   OR sort_mode_rev IS NULL OR sort_mode_rev = ''
            """)
            for row in rows {
                let id: Int64 = row["id"]
                let date: Date = row["date_modified"] ?? Date()
                let revision = SyncRevision.make(at: date, writerID: deviceID).rawValue
                try db.execute(sql: """
                    UPDATE playlists
                    SET playlist_sync_id = COALESCE(NULLIF(playlist_sync_id, ''), ?),
                        kind = COALESCE(NULLIF(kind, ''), 'manual'),
                        name_rev = COALESCE(NULLIF(name_rev, ''), ?),
                        sort_mode = COALESCE(NULLIF(sort_mode, ''), 'manual'),
                        sort_mode_rev = COALESCE(NULLIF(sort_mode_rev, ''), ?)
                    WHERE id = ?
                """, arguments: [UUID().uuidString.uppercased(), revision, revision, id])
            }
        }

        migrator.registerMigration("v16_safe_identity_tagging") { db in
            guard try db.tableExists("tagging_jobs") else { return }
            let columns = Set(try db.columns(in: "tagging_jobs").map(\.name))
            guard !columns.contains("may_replace_existing_identity") else { return }
            try db.execute(sql: "ALTER TABLE tagging_jobs ADD COLUMN may_replace_existing_identity INTEGER NOT NULL DEFAULT 0")
        }

        migrator.registerMigration("v17_verified_sync_identity") { db in
            guard try db.tableExists("logical_tracks") else { return }
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS verified_track_identities (track_sync_id TEXT PRIMARY KEY NOT NULL REFERENCES logical_tracks(track_sync_id), verified_at DATETIME NOT NULL)")
            // Legacy promotion/id_state alone is not proof. Preserve user state;
            // normal scan/import/tag verification releases eligible records later.
            try db.execute(sql: "UPDATE logical_tracks SET is_promoted=0")
            try db.execute(sql: "UPDATE tracks SET is_promoted=0")
            try db.execute(sql: "DELETE FROM sync_outbox WHERE record_type != 'Playlist'")
        }

        try migrator.migrate(writer)
    }

    private static func migrateCrossDeviceIdentity(_ db: Database) throws {
        // Some focused migration tests intentionally construct only the legacy
        // table under test. The identity migration applies once the complete v1
        // library schema exists; it must not turn an isolated old table into a
        // fatal launch.
        guard try db.tableExists("folders"),
              try db.tableExists("tracks"),
              try db.tableExists("playlists"),
              try db.tableExists("playlist_tracks") else { return }
        func addColumn(_ table: String, _ existing: inout Set<String>, _ name: String, _ definition: String) throws {
            guard !existing.contains(name) else { return }
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
            existing.insert(name)
        }

        var folderColumns = Set(try db.columns(in: "folders").map(\.name))
        try addColumn("folders", &folderColumns, "library_root_id", "TEXT")
        try addColumn("folders", &folderColumns, "is_writable", "INTEGER NOT NULL DEFAULT 0")
        try addColumn("folders", &folderColumns, "portable_identity", "INTEGER NOT NULL DEFAULT 1")
        try addColumn("folders", &folderColumns, "filesystem_type", "TEXT")
        for id in try Int64.fetchAll(db, sql: "SELECT id FROM folders WHERE library_root_id IS NULL OR library_root_id = ''") {
            try db.execute(sql: "UPDATE folders SET library_root_id = ? WHERE id = ?", arguments: [UUID().uuidString, id])
        }
        try db.create(index: "folders_library_root_id", on: "folders", columns: ["library_root_id"], unique: true, ifNotExists: true)

        // Create the new tables before generating the installation identity used
        // to stamp migrated field revisions.
        try Schema.createIdentityAndSyncTables(db)

        var trackColumns = Set(try db.columns(in: "tracks").map(\.name))
        try addColumn("tracks", &trackColumns, "track_sync_id", "TEXT")
        try addColumn("tracks", &trackColumns, "physical_file_id", "TEXT")
        try addColumn("tracks", &trackColumns, "metadata_rev", "TEXT")
        try addColumn("tracks", &trackColumns, "rating_rev", "TEXT")
        try addColumn("tracks", &trackColumns, "favorite_rev", "TEXT")
        try addColumn("tracks", &trackColumns, "merged_into", "TEXT")
        try addColumn("tracks", &trackColumns, "is_promoted", "INTEGER NOT NULL DEFAULT 0")
        try addColumn("tracks", &trackColumns, "audio_hash", "TEXT")
        try addColumn("tracks", &trackColumns, "id_state", "TEXT NOT NULL DEFAULT 'unknown'")

        let deviceID = UUID().uuidString.uppercased()
        try db.execute(sql: "INSERT OR IGNORE INTO sync_state (key, value) VALUES ('device_id', ?)", arguments: [Data(deviceID.utf8)])
        let now = Date()
        for row in try Row.fetchAll(db, sql: "SELECT id, date_added FROM tracks WHERE track_sync_id IS NULL OR track_sync_id = ''") {
            let id: Int64 = row["id"]
            let trackSyncID = UUID().uuidString.uppercased()
            let physicalFileID = UUID().uuidString.uppercased()
            let createdAt: Date = row["date_added"] ?? now
            let rev = SyncRevision.make(at: createdAt, writerID: deviceID).rawValue
            try db.execute(sql: "UPDATE tracks SET track_sync_id = ?, physical_file_id = ?, metadata_rev = ? WHERE id = ?", arguments: [trackSyncID, physicalFileID, rev, id])
        }
        try db.create(index: "tracks_track_sync_id", on: "tracks", columns: ["track_sync_id"], ifNotExists: true)
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS tracks_physical_file_id ON tracks(physical_file_id) WHERE physical_file_id != ''")

        var playlistColumns = Set(try db.columns(in: "playlists").map(\.name))
        try addColumn("playlists", &playlistColumns, "playlist_sync_id", "TEXT")
        try addColumn("playlists", &playlistColumns, "kind", "TEXT NOT NULL DEFAULT 'manual'")
        try addColumn("playlists", &playlistColumns, "name_rev", "TEXT")
        try addColumn("playlists", &playlistColumns, "sort_mode", "TEXT NOT NULL DEFAULT 'manual'")
        try addColumn("playlists", &playlistColumns, "sort_mode_rev", "TEXT")
        try addColumn("playlists", &playlistColumns, "rule", "TEXT")
        try addColumn("playlists", &playlistColumns, "rule_rev", "TEXT")
        try addColumn("playlists", &playlistColumns, "deleted_at", "DATETIME")
        for row in try Row.fetchAll(db, sql: "SELECT id, date_modified FROM playlists WHERE playlist_sync_id IS NULL OR playlist_sync_id = ''") {
            let id: Int64 = row["id"]
            let date: Date = row["date_modified"] ?? now
            let rev = SyncRevision.make(at: date, writerID: deviceID).rawValue
            try db.execute(sql: "UPDATE playlists SET playlist_sync_id = ?, name_rev = ?, sort_mode_rev = ? WHERE id = ?", arguments: [UUID().uuidString.uppercased(), rev, rev, id])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS playlists_sync_id ON playlists(playlist_sync_id) WHERE playlist_sync_id != ''")

        var entryColumns = Set(try db.columns(in: "playlist_tracks").map(\.name))
        try addColumn("playlist_tracks", &entryColumns, "playlist_entry_id", "TEXT")
        try addColumn("playlist_tracks", &entryColumns, "ordering_key", "TEXT")
        try addColumn("playlist_tracks", &entryColumns, "ordering_key_rev", "TEXT")
        try addColumn("playlist_tracks", &entryColumns, "created_at", "DATETIME")
        try addColumn("playlist_tracks", &entryColumns, "deleted_at", "DATETIME")
        for row in try Row.fetchAll(db, sql: "SELECT id, position FROM playlist_tracks WHERE playlist_entry_id IS NULL OR playlist_entry_id = ''") {
            let id: Int64 = row["id"]
            let position: Int = row["position"]
            let rev = SyncRevision.make(at: now, writerID: deviceID).rawValue
            try db.execute(sql: "UPDATE playlist_tracks SET playlist_entry_id = ?, ordering_key = ?, ordering_key_rev = ?, created_at = ? WHERE id = ?", arguments: [UUID().uuidString.uppercased(), FractionalOrderingKey.initial(at: position), rev, now, id])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS playlist_tracks_entry_id ON playlist_tracks(playlist_entry_id) WHERE playlist_entry_id != ''")

        // Populate the normalized authority without deleting or rewriting existing rows.
        try db.execute(sql: """
            INSERT OR IGNORE INTO logical_tracks
                (track_sync_id, title, artist, album, album_artist, genre, track_number,
                 disc_number, year, duration_ms, is_promoted, metadata_rev, created_at, merged_into)
            SELECT track_sync_id, title, artist, album, album_artist, genre, track_number,
                   disc_number, year, CAST(COALESCE(duration, 0) * 1000 AS INTEGER),
                   is_promoted, metadata_rev, date_added, merged_into
            FROM tracks
        """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO track_annotations (track_sync_id, rating, rating_rev, favorite, favorite_rev)
            SELECT track_sync_id, rating, rating_rev, is_favorite, favorite_rev FROM tracks
        """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO physical_files
                (physical_file_id, track_sync_id, library_root_id, relative_path, file_size,
                 mtime, format, audio_hash, id_state, is_preferred, last_seen_at)
            SELECT t.physical_file_id, t.track_sync_id,
                   COALESCE(f.library_root_id, 'legacy-unscoped'),
                   CASE WHEN f.url IS NOT NULL AND instr(t.file_url, f.url) = 1
                        THEN ltrim(substr(t.file_url, length(f.url) + 1), '/')
                        ELSE t.file_url END,
                   t.file_size, t.file_modified_at, t.format, t.audio_hash,
                   t.id_state, 1, t.last_seen_at
            FROM tracks t LEFT JOIN folders f ON f.id = t.folder_id
        """)
    }
}
