// Schema.swift
//
// Defines the layout of the library database: the tables for songs, albums, artists, artwork,
// folders, playlists, scan history, the Last.fm queue and the bookkeeping that iCloud sync needs.
// The upgrade steps in Migrator.swift use these definitions to build or update the database.

import GRDB

enum Schema {
    static func createTables(_ db: Database) throws {
        try db.create(table: "artwork", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("content_hash", .blob).unique()
            t.column("source_url", .text)
            t.column("data_small", .blob)
            t.column("data_large", .blob)
            t.column("dominant_color_hex", .text)
        }

        try db.create(table: "artists", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
        }

        try db.create(table: "albums", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull()
            t.column("album_artist", .text)
            t.column("year", .integer)
            t.column("genre", .text)
            t.column("disc_count", .integer)
            t.column("artwork_id", .integer).references("artwork")
        }

        try db.create(table: "folders", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("url", .text).notNull().unique()
            t.column("bookmark_data", .blob).notNull()
            t.column("date_added", .datetime).notNull()
            t.column("library_root_id", .text).notNull().defaults(to: "")
            t.column("is_writable", .boolean).notNull().defaults(to: false)
            t.column("portable_identity", .boolean).notNull().defaults(to: true)
            t.column("filesystem_type", .text)
        }

        try db.create(table: "tracks", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("file_url", .text).notNull().unique()
            t.column("folder_id", .integer).references("folders", onDelete: .cascade)
            t.column("availability_status", .text).notNull().defaults(to: "available")
            t.column("file_resource_identifier", .blob)
            t.column("document_identifier", .integer)
            t.column("volume_uuid", .text)
            t.column("last_seen_at", .datetime)
            t.column("last_seen_scan_id", .integer)
            t.column("missing_since", .datetime)
            t.column("file_size", .integer)
            t.column("file_modified_at", .datetime)
            t.column("title", .text)
            t.column("artist", .text)
            t.column("album_artist", .text)
            t.column("album", .text)
            t.column("composer", .text)
            t.column("genre", .text)
            t.column("year", .integer)
            t.column("track_number", .integer)
            t.column("disc_number", .integer)
            t.column("duration", .double)
            t.column("bit_rate", .integer)
            t.column("sample_rate", .integer)
            t.column("channel_count", .integer)
            t.column("format", .text)
            t.column("is_favorite", .boolean).notNull().defaults(to: false)
            t.column("rating", .integer).check(sql: "rating IS NULL OR rating BETWEEN 1 AND 5")
            t.column("play_count", .integer).notNull().defaults(to: 0)
            t.column("last_played_at", .datetime)
            t.column("date_added", .datetime).notNull()
            t.column("artwork_id", .integer).references("artwork")
            t.column("artwork_source_url", .text)
            t.column("artwork_source_file_size", .integer)
            t.column("artwork_source_modified_at", .datetime)
            t.column("album_id", .integer).references("albums")
            t.column("artist_id", .integer).references("artists")
            // Compatibility projection for the normalized identity tables below.
            // Existing high-volume UI queries can continue reading `tracks` while
            // sync and recovery use the stable UUID.
            t.column("track_sync_id", .text).notNull().defaults(to: "")
            t.column("physical_file_id", .text).notNull().defaults(to: "")
            t.column("metadata_rev", .text)
            t.column("rating_rev", .text)
            t.column("favorite_rev", .text)
            t.column("merged_into", .text)
            t.column("is_promoted", .boolean).notNull().defaults(to: false)
            t.column("audio_hash", .text)
            t.column("id_state", .text).notNull().defaults(to: "unknown")
        }

        try db.create(table: "playlists", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("date_created", .datetime).notNull()
            t.column("date_modified", .datetime).notNull()
            t.column("playlist_sync_id", .text).notNull().defaults(to: "")
            t.column("kind", .text).notNull().defaults(to: "manual")
            t.column("name_rev", .text).notNull().defaults(to: "")
            t.column("sort_mode", .text).notNull().defaults(to: "manual")
            t.column("sort_mode_rev", .text).notNull().defaults(to: "")
            t.column("rule", .text)
            t.column("rule_rev", .text)
            t.column("deleted_at", .datetime)
        }

        try db.create(table: "playlist_tracks", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("playlist_id", .integer).notNull().references("playlists", onDelete: .cascade)
            t.column("track_id", .integer).notNull().references("tracks", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("playlist_entry_id", .text).notNull().defaults(to: "")
            t.column("ordering_key", .text).notNull().defaults(to: "")
            t.column("ordering_key_rev", .text).notNull().defaults(to: "")
            t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            t.column("deleted_at", .datetime)
        }
        try db.create(
            index: "playlist_tracks_playlist_position",
            on: "playlist_tracks",
            columns: ["playlist_id", "position"],
            ifNotExists: true
        )

        try db.create(table: "scan_jobs", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("folder_id", .integer).references("folders")
            t.column("started_at", .datetime).notNull()
            t.column("completed_at", .datetime)
            t.column("files_processed", .integer).notNull().defaults(to: 0)
            t.column("total_files", .integer).notNull().defaults(to: 0)
            t.column("skipped_files", .integer).notNull().defaults(to: 0)
            t.column("changed_files", .integer).notNull().defaults(to: 0)
            t.column("removed_files", .integer).notNull().defaults(to: 0)
            t.column("missing_files", .integer).notNull().defaults(to: 0)
            t.column("relinked_files", .integer).notNull().defaults(to: 0)
            t.column("error_count", .integer).notNull().defaults(to: 0)
            t.column("mode", .text).notNull().defaults(to: "incremental")
            t.column("trigger", .text).notNull().defaults(to: "manual")
            t.column("failure_message", .text)
            t.column("status", .text).notNull().defaults(to: "running")
        }

        try db.create(table: "scan_errors", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("scan_job_id", .integer).references("scan_jobs", onDelete: .cascade)
            t.column("file_url", .text).notNull()
            t.column("stable_file_url", .text).notNull().defaults(to: "")
            t.column("stage", .text).notNull().defaults(to: "metadata")
            t.column("category", .text).notNull().defaults(to: "error")
            t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            t.column("reason", .text).notNull()
        }

        try db.create(table: "settings", ifNotExists: true) { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text)
        }

        try createLastFMScrobbleOutbox(db)
        try createIdentityAndSyncTables(db)

        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
                title, artist, album_artist, album, composer, genre,
                content=tracks, content_rowid=id
            )
        """)
    }

    static func createIdentityAndSyncTables(_ db: Database) throws {
        try db.create(table: "logical_tracks", ifNotExists: true) { t in
            t.column("track_sync_id", .text).primaryKey()
            t.column("title", .text)
            t.column("artist", .text)
            t.column("album", .text)
            t.column("album_artist", .text)
            t.column("genre", .text)
            t.column("track_number", .integer)
            t.column("disc_number", .integer)
            t.column("year", .integer)
            t.column("duration_ms", .integer)
            t.column("is_promoted", .boolean).notNull().defaults(to: false)
            t.column("metadata_rev", .text)
            t.column("created_at", .datetime).notNull()
            t.column("merged_into", .text).references("logical_tracks", column: "track_sync_id")
        }

        try db.create(table: "physical_files", ifNotExists: true) { t in
            t.column("physical_file_id", .text).primaryKey()
            t.column("track_sync_id", .text).notNull().references("logical_tracks", column: "track_sync_id")
            t.column("library_root_id", .text).notNull()
            t.column("relative_path", .text).notNull()
            t.column("file_size", .integer)
            t.column("mtime", .datetime)
            t.column("format", .text)
            t.column("audio_hash", .text)
            t.column("id_state", .text).notNull().defaults(to: "unknown")
            t.column("is_preferred", .boolean).notNull().defaults(to: true)
            t.column("last_seen_at", .datetime)
            t.uniqueKey(["library_root_id", "relative_path"])
        }
        try db.create(index: "physical_files_track", on: "physical_files", columns: ["track_sync_id"], ifNotExists: true)

        try db.create(table: "track_annotations", ifNotExists: true) { t in
            t.column("track_sync_id", .text).primaryKey().references("logical_tracks", column: "track_sync_id")
            t.column("rating", .integer)
            t.column("rating_rev", .text)
            t.column("favorite", .boolean)
            t.column("favorite_rev", .text)
        }

        try db.create(table: "play_events", ifNotExists: true) { t in
            t.column("event_id", .text).primaryKey()
            t.column("track_sync_id", .text).notNull().references("logical_tracks", column: "track_sync_id")
            t.column("played_at", .datetime).notNull()
            t.column("played_ms", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "play_events_track", on: "play_events", columns: ["track_sync_id", "played_at"], ifNotExists: true)

        try db.create(table: "play_counters", ifNotExists: true) { t in
            t.column("track_sync_id", .text).notNull().references("logical_tracks", column: "track_sync_id")
            t.column("device_id", .text).notNull()
            t.column("count", .integer).notNull().defaults(to: 0)
            t.column("last_played_at", .datetime)
            t.primaryKey(["track_sync_id", "device_id"])
        }

        try db.create(table: "sync_outbox", ifNotExists: true) { t in
            t.column("coalesce_key", .text).primaryKey()
            t.column("record_type", .text).notNull()
            t.column("record_name", .text).notNull()
            t.column("enqueued_at", .datetime).notNull()
            t.column("deliver_after", .datetime)
            t.column("generation", .integer).notNull().defaults(to: 1)
        }
        try db.create(index: "sync_outbox_delivery", on: "sync_outbox", columns: ["deliver_after", "enqueued_at"], ifNotExists: true)
        try db.create(table: "cloudkit_records", ifNotExists: true) { t in
            t.column("record_name", .text).primaryKey()
            t.column("record_type", .text).notNull()
            t.column("system_fields", .blob).notNull()
            t.column("serialized_record", .blob)
            t.column("last_synced_at", .datetime).notNull()
        }
        try db.create(table: "sync_state", ifNotExists: true) { t in
            t.column("key", .text).primaryKey()
            t.column("value", .blob)
        }
        try db.create(table: "sync_revision_rejections", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("record_name", .text).notNull()
            t.column("field_name", .text).notNull()
            t.column("claimed_revision", .text).notNull()
            t.column("received_at", .datetime).notNull()
        }
        try db.create(table: "tagging_jobs", ifNotExists: true) { t in
            t.column("physical_file_id", .text).primaryKey().references("physical_files", column: "physical_file_id", onDelete: .cascade)
            t.column("state", .text).notNull()
            // Automatic jobs must never replace a UUID already embedded in a
            // file. Only an explicit identity-resolution action opts in.
            t.column("may_replace_existing_identity", .boolean).notNull().defaults(to: false)
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("last_error", .text)
            t.column("last_attempt_at", .datetime)
            t.column("next_attempt_at", .datetime)
        }
        try db.create(index: "tagging_jobs_runnable", on: "tagging_jobs", columns: ["state", "next_attempt_at"], ifNotExists: true)

        try db.create(table: "identity_conflicts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("track_sync_id", .text).notNull()
            t.column("physical_file_id", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("resolved_at", .datetime)
        }

        // Durable staging keeps referentially-incomplete CloudKit arrivals. The
        // compatibility UI can render placeholders until their track/playlist
        // records arrive; no entry is discarded because delivery order differed.
        try db.create(table: "synced_playlist_entries", ifNotExists: true) { t in
            t.column("playlist_entry_id", .text).primaryKey()
            t.column("playlist_sync_id", .text).notNull()
            t.column("track_sync_id", .text).notNull()
            t.column("ordering_key", .text).notNull()
            t.column("ordering_key_rev", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("deleted_at", .datetime)
        }
    }

    static func createLastFMScrobbleOutbox(_ db: Database) throws {
        try db.create(table: "lastfm_scrobble_outbox", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("artist", .text).notNull()
            t.column("track", .text).notNull()
            t.column("album", .text)
            t.column("album_artist", .text)
            t.column("duration", .integer)
            t.column("track_number", .integer)
            t.column("started_at", .integer).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("attempt_count", .integer).notNull().defaults(to: 0)
            t.column("next_attempt_at", .datetime).notNull()
        }

        try db.create(
            index: "lastfm_scrobble_outbox_next_attempt",
            on: "lastfm_scrobble_outbox",
            columns: ["next_attempt_at", "created_at"],
            ifNotExists: true
        )
    }
}
