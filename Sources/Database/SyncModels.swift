// SyncModels.swift
//
// The shared building blocks of iCloud sync (keeping the library's personal data the same across
// the user's devices). They include timestamps that decide which edit wins, an ID for this device,
// a to-send list of pending changes, checks on which songs may be synced, and a scheme for
// ordering playlist songs that tolerates edits from several devices.

import Foundation
import GRDB
#if os(iOS)
import Security
#endif

/// A wall-clock revision whose lexical order is its conflict order. The writer ID
/// is part of the value, so equal timestamps resolve identically on every device.
struct SyncRevision: RawRepresentable, Codable, Comparable, Hashable, Sendable {
    static let timestampWidth = 17
    static let maximumFutureSkew: TimeInterval = 5 * 60

    let rawValue: String

    static func make(at date: Date = Date(), writerID: String) -> SyncRevision {
        let milliseconds = max(0, Int64((date.timeIntervalSince1970 * 1_000).rounded()))
        return SyncRevision(rawValue: String(format: "%0*lld_%@", timestampWidth, milliseconds, writerID.uppercased()))
    }

    var timestamp: Date? {
        guard rawValue.count > Self.timestampWidth,
              rawValue.index(rawValue.startIndex, offsetBy: Self.timestampWidth) < rawValue.endIndex,
              let milliseconds = Int64(rawValue.prefix(Self.timestampWidth)) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    /// Clamps a hostile or badly skewed future revision while retaining the
    /// synchronized writer ID as the deterministic tie-break.
    func clamped(receivedAt: Date = Date()) -> SyncRevision {
        guard let timestamp, timestamp.timeIntervalSince(receivedAt) > Self.maximumFutureSkew else { return self }
        let separator = rawValue.index(rawValue.startIndex, offsetBy: Self.timestampWidth)
        let writer = String(rawValue[rawValue.index(after: separator)...])
        return .make(at: receivedAt, writerID: writer)
    }

    func isAcceptable(receivedAt: Date = Date()) -> Bool {
        guard let timestamp else { return false }
        return timestamp.timeIntervalSince(receivedAt) <= Self.maximumFutureSkew
    }

    static func < (lhs: SyncRevision, rhs: SyncRevision) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SyncDeviceIdentity {
    static func id(in db: Database) throws -> String {
#if os(iOS)
        let marker: String
        if let data = try Data.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'installation_marker'"),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            marker = existing
        } else {
            marker = UUID().uuidString.uppercased()
            try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('installation_marker', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [Data(marker.utf8)])
        }
        if let stored = MobileWriterIdentity.read(marker: marker) {
            try persist(stored, in: db)
            return stored
        }
        // ThisDeviceOnly keychain values are not restored onto a different
        // device. A migrated SQLite database therefore receives a fresh writer
        // identity instead of cloning the old device's single-writer counter.
        let value = UUID().uuidString.uppercased()
        try MobileWriterIdentity.store(value, marker: marker)
        try persist(value, in: db)
        return value
#else
        if let data = try Data.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'device_id'"),
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.uppercased()
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES ('device_id', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [Data(value.utf8)]
        )
        return value
#endif
    }

    private static func persist(_ value: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES ('device_id', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            arguments: [Data(value.utf8)]
        )
    }
}

#if os(iOS)
private enum MobileWriterIdentity {
    private static let service = "com.musopen.moonlight.play-counter-writer"

    static func read(marker: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: marker,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil else { return nil }
        return value.uppercased()
    }

    static func store(_ value: String, marker: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: marker
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}
#endif

/// Local evidence only: neither CloudKit nor metadata archives may grant it.
/// Evidence survives local file removal so already-synced tombstones and counter
/// components can still be delivered. A scan detecting removed/changed tags
/// revokes evidence when no remaining physical copy bears that identity.
enum SyncEligibility {
    static func isVerified(_ id: String, in db: Database) throws -> Bool {
        guard UUID(uuidString: id)?.uuidString == id else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM verified_track_identities WHERE track_sync_id=?)", arguments: [id]) ?? false
    }

    @discardableResult
    static func promote(_ id: String, in db: Database) throws -> Bool {
        let eligible = try isVerified(id, in: db)
        try db.execute(sql: "UPDATE logical_tracks SET is_promoted=? WHERE track_sync_id=? AND is_promoted != ?", arguments: [eligible, id, eligible])
        try db.execute(sql: "UPDATE tracks SET is_promoted=? WHERE track_sync_id=? AND is_promoted != ?", arguments: [eligible, id, eligible])
        return eligible
    }

    static func allows(recordType: String, recordName: String, in db: Database) throws -> Bool {
        let id: String?
        switch recordType {
        case "Playlist": return recordName.hasPrefix("playlist_")
        case "SyncedTrack":
            guard recordName.hasPrefix("track_") else { return false }
            id = String(recordName.dropFirst(6))
        case "PlaylistEntry":
            guard recordName.hasPrefix("entry_") else { return false }
            id = try String.fetchOne(db, sql: "SELECT track_sync_id FROM synced_playlist_entries WHERE playlist_entry_id=? UNION ALL SELECT t.track_sync_id FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE pt.playlist_entry_id=?", arguments: [String(recordName.dropFirst(6)), String(recordName.dropFirst(6))])
        case "PlayCounter":
            id = try String.fetchOne(db, sql: "SELECT track_sync_id FROM play_counters WHERE 'count_' || track_sync_id || '_' || device_id=?", arguments: [recordName])
        default: return false
        }
        guard let id else { return false }
        guard try isVerified(id, in: db) else { return false }
        if recordType == "SyncedTrack",
           let target = try String.fetchOne(db, sql: "SELECT merged_into FROM logical_tracks WHERE track_sync_id=?", arguments: [id]) {
            return try isVerified(target, in: db)
        }
        return true
    }

    static func quarantineIneligibleOutbox(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT record_type, record_name, coalesce_key FROM sync_outbox") {
            guard try !allows(recordType: row["record_type"], recordName: row["record_name"], in: db) else { continue }
            try db.execute(sql: "DELETE FROM sync_outbox WHERE coalesce_key=?", arguments: [row["coalesce_key"] as String])
        }
        try db.execute(sql: "UPDATE logical_tracks SET is_promoted=0 WHERE track_sync_id NOT IN (SELECT track_sync_id FROM verified_track_identities)")
        try db.execute(sql: "UPDATE tracks SET is_promoted=0 WHERE track_sync_id NOT IN (SELECT track_sync_id FROM verified_track_identities)")
    }

    /// Called with the actual file after scan/import/write; re-read the tag here
    /// so an id_state string or a successful write without readback is insufficient.
    static func verifyFile(_ url: URL, physicalFileID: String, in db: Database) throws {
        guard let embedded = PortableIdentityTag.read(from: url),
              let id = try String.fetchOne(db, sql: "SELECT track_sync_id FROM physical_files WHERE physical_file_id=? AND id_state='embedded'", arguments: [physicalFileID]),
              embedded == id else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO verified_track_identities (track_sync_id, verified_at) VALUES (?, ?)", arguments: [id, Date()])
        let hasState = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM track_annotations WHERE track_sync_id=? AND (rating_rev IS NOT NULL OR favorite_rev IS NOT NULL)) OR EXISTS(SELECT 1 FROM play_counters WHERE track_sync_id=?) OR EXISTS(SELECT 1 FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE t.track_sync_id=?)", arguments: [id, id, id]) ?? false
        guard hasState else { return }
        _ = try promote(id, in: db)
        try SyncOutbox.enqueue(recordType: "SyncedTrack", recordName: "track_\(id)", in: db)
        let writer = try SyncDeviceIdentity.id(in: db)
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM play_counters WHERE track_sync_id=? AND device_id=?)", arguments: [id, writer]) == true {
            try SyncOutbox.enqueue(recordType: "PlayCounter", recordName: "count_\(id)_\(writer)", in: db)
        }
        for entry in try String.fetchAll(db, sql: "SELECT pt.playlist_entry_id FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE t.track_sync_id=?", arguments: [id]) {
            try SyncOutbox.enqueue(recordType: "PlaylistEntry", recordName: "entry_\(entry)", in: db)
        }
    }

    static func revokeUnembedded(_ id: String, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM physical_files WHERE track_sync_id=? AND id_state='embedded')", arguments: [id]) != true else { return }
        try db.execute(sql: "DELETE FROM verified_track_identities WHERE track_sync_id=?", arguments: [id])
        try quarantineIneligibleOutbox(in: db)
    }
}

enum SyncOutbox {
    struct PendingItem: Equatable, Sendable {
        let recordType: String
        let recordName: String
        let generation: Int64

        var coalesceKey: String { "\(recordType):\(recordName)" }
    }

    enum Delivery {
        case prompt
        case playbackBatch

        fileprivate func deadline(from date: Date) -> Date {
            switch self {
            case .prompt: date
            case .playbackBatch: date.addingTimeInterval(3 * 60)
            }
        }
    }

    static func enqueue(
        recordType: String,
        recordName: String,
        in db: Database,
        at date: Date = Date(),
        delivery: Delivery = .prompt
    ) throws {
        guard try SyncEligibility.allows(recordType: recordType, recordName: recordName, in: db) else {
            try db.execute(sql: "DELETE FROM sync_outbox WHERE coalesce_key=?", arguments: ["\(recordType):\(recordName)"])
            return
        }
        let deadline = delivery.deadline(from: date)
        try db.execute(sql: """
            INSERT INTO sync_outbox (coalesce_key, record_type, record_name, enqueued_at, deliver_after, generation)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(coalesce_key) DO UPDATE SET
                enqueued_at = excluded.enqueued_at,
                deliver_after = MIN(sync_outbox.deliver_after, excluded.deliver_after),
                generation = sync_outbox.generation + 1
        """, arguments: ["\(recordType):\(recordName)", recordType, recordName, date, deadline])
    }

    static func pending(recordName: String, in db: Database) throws -> PendingItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT record_type, record_name, generation FROM sync_outbox WHERE record_name = ?",
            arguments: [recordName]
        ) else { return nil }
        return PendingItem(recordType: row["record_type"], recordName: row["record_name"], generation: row["generation"])
    }

    static func acknowledge(
        recordType: String,
        recordName: String,
        generation: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM sync_outbox WHERE coalesce_key = ? AND generation <= ?",
            arguments: ["\(recordType):\(recordName)", generation]
        )
    }

    static func acknowledge(_ item: PendingItem, in db: Database) throws {
        try acknowledge(
            recordType: item.recordType,
            recordName: item.recordName,
            generation: item.generation,
            in: db
        )
    }

    /// Rebuilds the durable upload intent from current local state. Only this
    /// installation's PlayCounter rows are uploaded; foreign device counters are
    /// immutable on this device.
    static func enqueueCompleteState(in db: Database, at date: Date = Date()) throws {
        for id in try String.fetchAll(db, sql: "SELECT track_sync_id FROM logical_tracks WHERE is_promoted = 1") {
            try enqueue(recordType: "SyncedTrack", recordName: "track_\(id)", in: db, at: date)
        }
        for id in try String.fetchAll(db, sql: "SELECT playlist_sync_id FROM playlists WHERE playlist_sync_id IS NOT NULL AND playlist_sync_id != ''") {
            try enqueue(recordType: "Playlist", recordName: "playlist_\(id)", in: db, at: date)
        }
        for id in try String.fetchAll(db, sql: "SELECT playlist_entry_id FROM playlist_tracks WHERE playlist_entry_id IS NOT NULL AND playlist_entry_id != ''") {
            try enqueue(recordType: "PlaylistEntry", recordName: "entry_\(id)", in: db, at: date)
        }
        let deviceID = try SyncDeviceIdentity.id(in: db)
        for trackID in try String.fetchAll(db, sql: "SELECT track_sync_id FROM play_counters WHERE device_id = ?", arguments: [deviceID]) {
            try enqueue(recordType: "PlayCounter", recordName: "count_\(trackID)_\(deviceID)", in: db, at: date)
        }
    }
}

enum SyncIdentityBridge {
    /// Imports compatibility rows created by tests, older code, or an incomplete
    /// previous launch into the normalized authority before synchronized state is
    /// attached to them.
    static func ensureLogicalTrack(forLocalTrackID trackID: Int64, in db: Database) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [trackID]) else { return nil }
        var syncID: String = row["track_sync_id"] ?? ""
        if syncID.isEmpty {
            syncID = UUID().uuidString.uppercased()
            let physicalID = UUID().uuidString.uppercased()
            try db.execute(sql: "UPDATE tracks SET track_sync_id = ?, physical_file_id = ? WHERE id = ?", arguments: [syncID, physicalID, trackID])
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO logical_tracks
                (track_sync_id, title, artist, album, album_artist, genre, track_number,
                 disc_number, year, duration_ms, is_promoted, metadata_rev, created_at, merged_into)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            syncID, row["title"] as String?, row["artist"] as String?, row["album"] as String?,
            row["album_artist"] as String?, row["genre"] as String?, row["track_number"] as Int?,
            row["disc_number"] as Int?, row["year"] as Int?, Int(((row["duration"] as Double?) ?? 0) * 1_000),
            row["is_promoted"] as Bool? ?? false, row["metadata_rev"] as String?,
            row["date_added"] as Date? ?? Date(), row["merged_into"] as String?
        ])
        return syncID
    }
}

/// Base-62 fractional ordering. Generated keys never end in the minimum digit,
/// preserving space for future insertions. Existing integer positions are migrated
/// to fixed-width keys with wide gaps.
enum FractionalOrderingKey {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let indexByCharacter = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func initial(at position: Int) -> String {
        encode(max(0, position + 1) * 1_000_000, width: 10)
    }

    static func between(_ lower: String?, _ upper: String?) -> String {
        if lower == nil, upper == nil { return "U" }
        if let upper, lower == nil { return before(upper) }
        if let lower, upper == nil { return after(lower) }
        let lower = lower!
        let upper = upper!
        if lower < upper { return betweenFinite(lower, upper) }
        if upper < lower { return betweenFinite(upper, lower) }
        return after(lower)
    }

    private static func betweenFinite(_ lower: String, _ upper: String) -> String {
        var prefix = ""
        var offset = 0
        while true {
            let low = digit(in: lower, at: offset) ?? 0
            let high = digit(in: upper, at: offset) ?? (alphabet.count - 1)
            if low == high {
                prefix.append(alphabet[low])
                offset += 1
                continue
            }
            if high - low > 1 {
                prefix.append(alphabet[(low + high) / 2])
                return prefix
            }
            prefix.append(alphabet[low])
            offset += 1
            if offset >= lower.count {
                prefix.append(alphabet[alphabet.count / 2])
                return prefix
            }
        }
    }

    private static func before(_ upper: String) -> String {
        var prefix = ""
        for character in upper {
            let value = indexByCharacter[character] ?? 0
            if value == 1 {
                // There is no nonzero digit below 1. Extend beneath it instead
                // of retaining 1, which can produce a key above a short bound
                // such as "01" after enough prepends.
                return prefix + "0" + String(alphabet[alphabet.count / 2])
            }
            if value > 1 {
                prefix.append(alphabet[value / 2])
                return prefix
            }
            prefix.append(character)
        }
        // This boundary is unreachable for keys generated by this implementation,
        // because they never end in the minimum digit.
        return "0" + String(alphabet[alphabet.count / 2]) + upper
    }

    private static func after(_ lower: String) -> String {
        lower + String(alphabet[alphabet.count / 2])
    }

    private static func digit(in string: String, at offset: Int) -> Int? {
        guard offset < string.count else { return nil }
        let index = string.index(string.startIndex, offsetBy: offset)
        return indexByCharacter[string[index]]
    }

    private static func encode(_ value: Int, width: Int) -> String {
        var number = value
        var digits: [Character] = []
        repeat {
            digits.append(alphabet[number % alphabet.count])
            number /= alphabet.count
        } while number > 0
        while digits.count < width { digits.append(alphabet[0]) }
        return String(digits.reversed())
    }
}

struct SyncedTrackState: Equatable, Sendable {
    var trackSyncID: String
    var rating: Int?
    var ratingRev: SyncRevision?
    var favorite: Bool?
    var favoriteRev: SyncRevision?
    var title: String?
    var artist: String?
    var album: String?
    var metadataRev: SyncRevision?
    var mergedInto: String?

    mutating func merge(_ incoming: SyncedTrackState, receivedAt: Date = Date()) {
        if wins(incoming.ratingRev, over: ratingRev, receivedAt: receivedAt) {
            rating = incoming.rating
            ratingRev = incoming.ratingRev
        }
        if wins(incoming.favoriteRev, over: favoriteRev, receivedAt: receivedAt) {
            favorite = incoming.favorite
            favoriteRev = incoming.favoriteRev
        }
        // Descriptive fields are retained only as legacy in-memory inputs.
        // They never participate in synchronized state.
        if let incomingMerge = incoming.mergedInto,
           mergedInto == nil || incomingMerge < mergedInto! {
            mergedInto = incomingMerge
        }
    }

    private func wins(_ candidate: SyncRevision?, over current: SyncRevision?, receivedAt: Date) -> Bool {
        guard let candidate, candidate.isAcceptable(receivedAt: receivedAt) else { return false }
        guard let current else { return true }
        return candidate > current
    }
}
