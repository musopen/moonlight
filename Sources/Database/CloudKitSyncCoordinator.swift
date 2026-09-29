// CloudKitSyncCoordinator.swift
//
// Runs iCloud sync: it sends this device's changes to ratings, favorites, playlists and play
// counts to the user's private iCloud storage and brings back changes made on their other
// devices. It also reports sync status and problems to the rest of the app. Only this personal
// library data syncs; music files and artwork never leave the device.

import CloudKit
import Combine
import Foundation
import GRDB
import OSLog
#if os(macOS)
import Security
#endif

enum CloudSyncProblem: String, Sendable {
    case notSignedIn = "Not signed into iCloud"
    case accountChanged = "iCloud account changed"
    case quotaExceeded = "iCloud storage quota exceeded"
    case zoneDeleted = "Moonlight's iCloud zone was deleted"
    case networkUnavailable = "Network unavailable"
    case throttled = "iCloud is temporarily throttling sync"
    case schemaTooNew = "Some data requires a newer Moonlight version"
    case changeTokenExpired = "A complete iCloud refresh is required"
    case fetchedBatchRejected = "Downloaded changes require sync recovery"
    case unknown = "Unable to sync"
}

private enum CloudSyncConfigurationError: LocalizedError {
    case missingCloudKitEntitlement

    var errorDescription: String? {
        "This copy of Moonlight is not configured for CloudKit. Please install a signed build with iCloud Sync enabled."
    }
}

final class CloudSyncStatus: ObservableObject {
    @Published var isEnabled = false
    @Published var isSyncing = false
    @Published var pendingChangeCount = 0
    @Published var lastSuccessfulSync: Date?
    @Published var problem: CloudSyncProblem?
    @Published var details: String?
    @Published var requiresFullResync = false
    @Published var lastProtected: Date?
    @Published var protectionProblem: String?
    /// A status must describe the actual sync state, not merely the absence of
    /// an error. In particular, a disabled sync service is never "up to date."
    var headline: String {
        guard isEnabled else { return "iCloud Sync is Off" }
        if let problem { return problem.rawValue }
        if isSyncing { return lastSuccessfulSync == nil ? "Connecting to iCloud…" : "Syncing…" }
        if pendingChangeCount > 0 { return "Changes ready to sync" }
        return lastSuccessfulSync == nil ? "Ready to sync" : "Up to date"
    }

    var explanation: String {
        guard isEnabled else {
            return "Moonlight keeps everything on this Mac until you choose to turn on iCloud Sync."
        }
        if let details { return details }
        if isSyncing { return "Checking your private iCloud metadata." }
        if pendingChangeCount > 0 { return "\(pendingChangeCount) local change\(pendingChangeCount == 1 ? "" : "s") will upload when iCloud is available." }
        if lastSuccessfulSync != nil { return "Your synchronized metadata matches the latest iCloud copy." }
        return "Ready to make the first private iCloud copy of your metadata."
    }
}

/// A deliberately narrow signal for changes that have been committed to the
/// synchronized library state. This is separate from `CloudSyncStatus`: status
/// updates describe transport activity, while this signal means read models may
/// now be stale.
final class SynchronizedLibraryChangeNotifier: ObservableObject {
    @Published private(set) var generation = 0

    func noteCommittedChange() {
        generation &+= 1
    }
}

private struct SyncOutboxSchedule: Equatable {
    var count: Int
    var nextDelivery: Date?
}

private actor SyncOperationGate {
    private var active = false

    func begin() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    func end() { active = false }
}

final class CloudKitSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    /// Set per build in Config/Signing.xcconfig so forks can use their own iCloud container.
    static let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "MoonlightCloudKitContainer") as? String
        ?? "iCloud.com.musopen.moonlight"
    static let zoneName = "MoonlightMetadata"
    static let schemaVersion = 1
    private static let rejectedBatchRecoveryKey = "rejected_batch_requires_full_resync"
    private let syncLog = Logger(subsystem: "com.musopen.moonlight", category: "CloudKitSync")

    let status = CloudSyncStatus()
    /// Emitted once after a transaction has changed materialized synchronized
    /// state. Consumers should use this to refresh cached read models.
    let synchronizedLibraryChanges = SynchronizedLibraryChangeNotifier()
    private let manager: DatabaseManager
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private let lock = NSLock()
    private var _engine: CKSyncEngine?
    private var scheduledSync: Task<Void, Never>?
    private var outboxObservation: AnyDatabaseCancellable?
    private var inFlightOutboxGenerations: [String: Int64] = [:]
    private let operationGate = SyncOperationGate()
    private let lifecycleGate = SyncOperationGate()
    private var configurationGeneration = 0

    private var engine: CKSyncEngine? {
        get { lock.withLock { _engine } }
        set { lock.withLock { _engine = newValue } }
    }

    init(manager: DatabaseManager) {
        self.manager = manager
        super.init()
        observeOutbox()
    }

    deinit {
        scheduledSync?.cancel()
        outboxObservation?.cancel()
    }

    func start() async {
        let generation = lock.withLock { configurationGeneration }
        await start(expectedGeneration: generation)
    }

    private func start(expectedGeneration: Int) async {
        guard await lifecycleGate.begin() else {
            // An app launch and a user changing the switch can overlap. Wait for
            // the stale startup to finish, then only start the newest request.
            try? await Task.sleep(for: .milliseconds(50))
            guard isCurrentConfiguration(expectedGeneration), engine == nil else { return }
            await start(expectedGeneration: expectedGeneration)
            return
        }
        await performStart(expectedGeneration: expectedGeneration)
        await lifecycleGate.end()
    }

    private func performStart(expectedGeneration: Int) async {
        let enabled = (try? manager.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = 'icloud_sync_enabled'") }) == "1"
        guard isCurrentConfiguration(expectedGeneration) else { return }
        await MainActor.run { status.isEnabled = enabled }
        guard enabled else { return }
        await MainActor.run {
            status.isSyncing = true
            status.problem = nil
            status.details = "Preparing a private iCloud sync…"
        }
        do {
            // Account validation comes before CKSyncEngine construction. Besides
            // making a missing iCloud sign-in a normal, recoverable status, this
            // avoids creating an engine for a service that cannot be used.
            try validateCloudKitEntitlement()
            try await validateAccount()
            guard isCurrentConfiguration(expectedGeneration) else { return }
            await loadPersistedStatus()

            let serialization: CKSyncEngine.State.Serialization? = try? manager.read { db in
                guard let data = try Data.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'engine_state'") else { return nil }
                return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            }
            var configuration = CKSyncEngine.Configuration(
                database: CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase,
                stateSerialization: serialization,
                delegate: self
            )
            configuration.automaticallySync = true
            let newEngine = CKSyncEngine(configuration)
            guard isCurrentConfiguration(expectedGeneration) else {
                await newEngine.cancelOperations()
                return
            }
            engine = newEngine
            newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            await loadOutboxIntoEngine(force: false)
            try await newEngine.fetchChanges()
            try await newEngine.sendChanges()
        } catch {
            if isCurrentConfiguration(expectedGeneration) { await report(error) }
        }
        if isCurrentConfiguration(expectedGeneration) {
            await MainActor.run { status.isSyncing = false }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        let generation = lock.withLock { () -> Int in
            configurationGeneration += 1
            return configurationGeneration
        }
        do {
            try manager.write { db in
                try db.execute(sql: "INSERT INTO settings (key, value) VALUES ('icloud_sync_enabled', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [enabled ? "1" : "0"])
            }
        } catch {
            await report(error)
            return
        }
        await MainActor.run {
            status.isEnabled = enabled
            status.problem = nil
            status.details = enabled ? "Preparing a private iCloud sync…" : nil
            status.isSyncing = enabled
        }
        if enabled { await start(expectedGeneration: generation) }
        else {
            await cancelEngine()
        }
    }

    func synchronize(force: Bool = true) async {
        guard let engine else { return }
        guard await operationGate.begin() else { return }
        await loadOutboxIntoEngine(force: force)
        await MainActor.run { status.isSyncing = true; status.problem = nil }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            await report(error)
        }
        await MainActor.run { status.isSyncing = false }
        await operationGate.end()
    }

    /// Silent CloudKit pushes are delivered by the platform app delegates. There
    /// is no payload-ingestion API on `CKSyncEngine`; receiving a valid CloudKit
    /// notification is the signal to ask the engine to fetch its pending changes.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard CloudRemoteNotificationPolicy.shouldFetch(
            isCloudKitNotification: CKNotification(fromRemoteNotificationDictionary: userInfo) != nil,
            engineIsAvailable: engine != nil
        ) else { return false }
        await synchronize(force: false)
        return true
    }

    /// Flushes delayed playback aggregates before the app becomes inactive. The
    /// outbox is durable, so an interrupted termination resumes safely on launch.
    func flushForLifecycleTransition() async {
        await synchronize(force: true)
    }

    /// Rebinds this installation to the current iCloud account/zone and uploads
    /// the complete promoted local state. This is the non-destructive recovery
    /// choice presented after an account change or zone deletion.
    func recoverKeepingLocalState() async {
        do {
            let accountID = try await currentAccountID()
            await cancelEngine()
            try manager.write { db in
                try db.execute(sql: "DELETE FROM cloudkit_records")
                try db.execute(sql: "DELETE FROM sync_outbox")
                try db.execute(sql: "DELETE FROM sync_state WHERE key IN ('engine_state', 'account_id', ?)", arguments: [Self.rejectedBatchRecoveryKey])
                try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('account_id', ?)", arguments: [Data(accountID.utf8)])
                try SyncOutbox.enqueueCompleteState(in: db)
            }
            await MainActor.run {
                status.problem = nil
                status.details = nil
                status.requiresFullResync = false
            }
            await start()
        } catch {
            await report(error)
        }
    }

    /// Accepts the current account/zone as authoritative. A restorable local
    /// snapshot is created before synchronized annotations and playlists reset.
    func recoverUsingCloudState() async {
        do {
            _ = try MetadataSnapshotStore.createRecoveryPoint(from: manager, label: "before-cloud-reset")
            let accountID = try await currentAccountID()
            await cancelEngine()
            try manager.write { db in
                try clearSynchronizedUserState(in: db)
                try db.execute(sql: "DELETE FROM cloudkit_records")
                try db.execute(sql: "DELETE FROM sync_outbox")
                try db.execute(sql: "DELETE FROM sync_state WHERE key IN ('engine_state', 'account_id', ?)", arguments: [Self.rejectedBatchRecoveryKey])
                try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('account_id', ?)", arguments: [Data(accountID.utf8)])
            }
            await noteSynchronizedStateReplacement()
            await MainActor.run {
                status.problem = nil
                status.details = nil
                status.requiresFullResync = false
            }
            await start()
        } catch {
            await report(error)
        }
    }

    func performFullRefetch() async {
        await cancelEngine()
        do {
            try manager.write { db in
                try db.execute(sql: "DELETE FROM cloudkit_records")
                try db.execute(sql: "DELETE FROM sync_state WHERE key IN ('engine_state', ?)", arguments: [Self.rejectedBatchRecoveryKey])
            }
        } catch {
            await report(error)
            return
        }
        await MainActor.run { status.requiresFullResync = false; status.problem = nil; status.details = nil }
        await start()
    }

    private func cancelEngine() async {
        scheduledSync?.cancel()
        await engine?.cancelOperations()
        engine = nil
    }

    private func isCurrentConfiguration(_ generation: Int) -> Bool {
        lock.withLock { configurationGeneration == generation }
    }

    private func currentAccountID() async throws -> String {
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        return try await container.userRecordID().recordName
    }

    /// CloudKit can emit a process-level diagnostic when a development build was
    /// installed without its iCloud entitlement. Detect that locally first so
    /// enabling the switch produces a useful recoverable error instead of
    /// entering CloudKit with an invalid process configuration.
    private func validateCloudKitEntitlement() throws {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) as? [String],
              services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        else {
            throw CloudSyncConfigurationError.missingCloudKitEntitlement
        }
#endif
    }

    private func clearSynchronizedUserState(in db: Database) throws {
        try db.execute(sql: "DELETE FROM track_annotations")
        try db.execute(sql: "DELETE FROM playlist_tracks")
        try db.execute(sql: "DELETE FROM synced_playlist_entries")
        try db.execute(sql: "DELETE FROM playlists")
        try db.execute(sql: "DELETE FROM play_counters")
        try db.execute(sql: "UPDATE logical_tracks SET is_promoted = 0, merged_into = NULL")
        try db.execute(sql: "UPDATE tracks SET rating = NULL, rating_rev = NULL, is_favorite = 0, favorite_rev = NULL, play_count = 0, last_played_at = NULL, is_promoted = 0")
        try db.execute(sql: "DELETE FROM tracks WHERE availability_status = 'unavailable' AND file_url LIKE 'moonlight-unavailable://%'")
    }

    private func validateAccount() async throws {
        let container = CKContainer(identifier: Self.containerIdentifier)
        let status = try await container.accountStatus()
        guard status == .available else { throw CKError(.notAuthenticated) }
        let userID = try await container.userRecordID()
        let accountID = userID.recordName
        let previous = try manager.read { try String.fetchOne($0, sql: "SELECT CAST(value AS TEXT) FROM sync_state WHERE key = 'account_id'") }
        if let previous, previous != accountID { throw AccountSwitchError() }
        try manager.write { db in
            try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('account_id', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [Data(accountID.utf8)])
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .willFetchChanges:
            syncLog.notice("CKSyncEngine will fetch changes")
        case .stateUpdate(let update):
            do {
                let data = try JSONEncoder().encode(update.stateSerialization)
                try manager.write { db in
                    try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('engine_state', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [data])
                }
            } catch {
                await report(error)
            }
        case .accountChange:
            await MainActor.run { status.problem = .accountChanged; status.details = "Choose whether to keep local metadata separate or replace it with the new account's data." }
        case .fetchedRecordZoneChanges(let changes):
            try? await applyFetchedRecords(changes.modifications.map(\.record))
            // Record deletions are intentionally not interpreted as logical
            // deletion. Moonlight records use explicit tombstone fields.
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                do {
                    try cache(record)
                    let generation = lock.withLock {
                        inFlightOutboxGenerations.removeValue(forKey: record.recordID.recordName)
                    }
                    if let generation {
                        try manager.write { db in
                            try SyncOutbox.acknowledge(
                                recordType: record.recordType,
                                recordName: record.recordID.recordName,
                                generation: generation,
                                in: db
                            )
                        }
                    }
                } catch {
                    await report(error)
                }
            }
            for failure in sent.failedRecordSaves {
                if failure.error.code == .serverRecordChanged,
                   let serverRecord = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    try? await applyFetchedRecords([serverRecord])
                    // The coalesced outbox remains pending; rebuild the outgoing
                    // record from the full server cache on the next send.
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                } else if Self.shouldRecreateMissingRecord(after: failure.error) {
                    // A remote deletion can leave this device with a cached
                    // change tag. Drop that stale system record and retry from
                    // the durable local state as a fresh save (usually a
                    // tombstone for a deleted playlist).
                    try? manager.write { db in
                        try db.execute(
                            sql: "DELETE FROM cloudkit_records WHERE record_name = ?",
                            arguments: [failure.record.recordID.recordName]
                        )
                    }
                    lock.withLock {
                        _ = inFlightOutboxGenerations.removeValue(forKey: failure.record.recordID.recordName)
                    }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                } else {
                    lock.withLock {
                        _ = inFlightOutboxGenerations.removeValue(forKey: failure.record.recordID.recordName)
                    }
                    await report(failure.error)
                }
            }
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { await report(failure.error) }
        case .didFetchChanges, .didSendChanges:
            let pending = (try? manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }) ?? 0
            let now = Date()
            try? manager.write { db in
                try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('last_success_at', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [Data(String(now.timeIntervalSince1970).utf8)])
            }
            var protected = false
            var protectionError: String?
            do {
                if try MetadataSnapshotStore.createIfDue(from: manager, now: now) != nil {
                    protected = true
                    try persistDate(now, key: "last_protected_at")
                    try? manager.write { try $0.execute(sql: "DELETE FROM sync_state WHERE key = 'last_protection_error'") }
                }
            } catch {
                protectionError = error.localizedDescription
                try? manager.write { db in
                    try db.execute(
                        sql: "INSERT INTO sync_state (key, value) VALUES ('last_protection_error', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        arguments: [Data(error.localizedDescription.utf8)]
                    )
                }
            }
            let didProtect = protected
            let protectionMessage = protectionError
            await MainActor.run {
                status.lastSuccessfulSync = now
                status.pendingChangeCount = pending
                if !status.requiresFullResync {
                    status.problem = nil
                    status.details = nil
                }
                if didProtect { status.lastProtected = now }
                status.protectionProblem = protectionMessage
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                await MainActor.run { status.problem = .zoneDeleted; status.requiresFullResync = true }
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            self?.record(for: recordID)
        }
    }

    private func loadOutboxIntoEngine(force: Bool) async {
        guard let engine else { return }
        try? manager.write { try SyncEligibility.quarantineIneligibleOutbox(in: $0) }
        let names = (try? manager.read { db in
            try Row.fetchAll(
                db,
                sql: force
                    ? "SELECT record_name FROM sync_outbox ORDER BY enqueued_at"
                    : "SELECT record_name FROM sync_outbox WHERE deliver_after IS NULL OR deliver_after <= ? ORDER BY enqueued_at",
                arguments: force ? StatementArguments() : [Date()]
            )
        }) ?? []
        let changes: [CKSyncEngine.PendingRecordZoneChange] = names.map { row in
            .saveRecord(CKRecord.ID(recordName: row["record_name"], zoneID: zoneID))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        let total = (try? manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }) ?? 0
        await MainActor.run { status.pendingChangeCount = total }
    }

    private func observeOutbox() {
        let observation = ValueObservation.tracking { db -> SyncOutboxSchedule in
            SyncOutboxSchedule(
                count: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0,
                nextDelivery: try Date.fetchOne(db, sql: "SELECT MIN(deliver_after) FROM sync_outbox")
            )
        }
        outboxObservation = observation.start(
            in: manager.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                Task { @MainActor in self?.status.details = "Outbox observation failed: \(error.localizedDescription)" }
            },
            onChange: { [weak self] schedule in
                self?.scheduleAutomaticSync(schedule)
            }
        )
    }

    private func scheduleAutomaticSync(_ schedule: SyncOutboxSchedule) {
        let oldTask = lock.withLock { () -> Task<Void, Never>? in
            let old = scheduledSync
            scheduledSync = nil
            return old
        }
        oldTask?.cancel()
        Task { @MainActor [weak self] in self?.status.pendingChangeCount = schedule.count }
        guard schedule.count > 0, engine != nil else { return }

        let delay = max(0, (schedule.nextDelivery ?? Date()).timeIntervalSinceNow)
        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            } else {
                // Coalesce bursts of rating, playlist, and favorite changes.
                try? await Task.sleep(for: .milliseconds(750))
            }
            guard !Task.isCancelled else { return }
            await self?.synchronize(force: false)
        }
        lock.withLock { scheduledSync = task }
    }

    private func persistDate(_ date: Date, key: String) throws {
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, Data(String(date.timeIntervalSince1970).utf8)]
            )
        }
    }

    private func loadPersistedStatus() async {
        let values = try? manager.read { db -> (Date?, Date?, String?, Bool) in
            func storedString(_ key: String) throws -> String? {
                guard let data = try Data.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            let lastSync = try storedString("last_success_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let lastProtected = try storedString("last_protected_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let rejectedBatchRequiresRecovery = try Data.fetchOne(
                db,
                sql: "SELECT value FROM sync_state WHERE key = ?",
                arguments: [Self.rejectedBatchRecoveryKey]
            ) != nil
            return (lastSync, lastProtected, try storedString("last_protection_error"), rejectedBatchRequiresRecovery)
        }
        await MainActor.run {
            status.lastSuccessfulSync = values?.0
            status.lastProtected = values?.1
            status.protectionProblem = values?.2
            if values?.3 == true {
                status.problem = .fetchedBatchRejected
                status.details = "A downloaded CloudKit batch could not be applied atomically. Use Sync Recovery before continuing."
                status.requiresFullResync = true
            }
        }
    }

    func record(for recordID: CKRecord.ID) -> CKRecord? {
        do {
            guard let pending = try manager.read({ try SyncOutbox.pending(recordName: recordID.recordName, in: $0) }) else {
                return nil
            }
            guard try manager.read({ try SyncEligibility.allows(recordType: pending.recordType, recordName: pending.recordName, in: $0) }) else { return nil }
            let cached = try manager.read { db -> CKRecord? in
                guard let data = try Data.fetchOne(db, sql: "SELECT serialized_record FROM cloudkit_records WHERE record_name = ?", arguments: [recordID.recordName]) else { return nil }
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
            }
            let prefix = recordID.recordName.split(separator: "_", maxSplits: 1).first.map(String.init) ?? ""
            let record: CKRecord?
            switch prefix {
            case "track": record = try makeTrackRecord(cached ?? CKRecord(recordType: "SyncedTrack", recordID: recordID), name: recordID.recordName)
            case "playlist": record = try makePlaylistRecord(cached ?? CKRecord(recordType: "Playlist", recordID: recordID), name: recordID.recordName)
            case "entry": record = try makeEntryRecord(cached ?? CKRecord(recordType: "PlaylistEntry", recordID: recordID), name: recordID.recordName)
            case "count": record = try makeCounterRecord(cached ?? CKRecord(recordType: "PlayCounter", recordID: recordID), name: recordID.recordName)
            default: record = nil
            }
            if record != nil {
                lock.withLock { inFlightOutboxGenerations[recordID.recordName] = pending.generation }
            }
            return record
        } catch { return nil }
    }

    private func makeTrackRecord(_ record: CKRecord, name: String) throws -> CKRecord {
        let id = String(name.dropFirst("track_".count))
        guard let row = try manager.read({ db in try Row.fetchOne(db, sql: """
            SELECT lt.*, ta.rating, ta.rating_rev, ta.favorite, ta.favorite_rev
            FROM logical_tracks lt LEFT JOIN track_annotations ta USING(track_sync_id)
            WHERE lt.track_sync_id = ?
        """, arguments: [id]) }) else { return record }
        record["schemaVersion"] = Self.schemaVersion
        record["trackSyncID"] = id
        // Cached CKRecords may contain legacy file metadata. An allowlist also
        // prevents an unknown file-derived field from being echoed back.
        let allowed: Set<String> = ["schemaVersion", "trackSyncID", "rating", "ratingRev", "favorite", "favoriteRev", "mergedInto"]
        for key in record.allKeys() where !allowed.contains(key) { record[key] = nil }
        set(record, "rating", row["rating"] as Int?); set(record, "ratingRev", row["rating_rev"] as String?)
        set(record, "favorite", row["favorite"] as Bool?); set(record, "favoriteRev", row["favorite_rev"] as String?)
        set(record, "mergedInto", row["merged_into"] as String?)
        return record
    }

    private func makePlaylistRecord(_ record: CKRecord, name: String) throws -> CKRecord {
        let id = String(name.dropFirst("playlist_".count))
        guard let row = try manager.read({ try Row.fetchOne($0, sql: "SELECT * FROM playlists WHERE playlist_sync_id = ?", arguments: [id]) }) else { return record }
        record["schemaVersion"] = Self.schemaVersion; record["playlistID"] = id
        set(record, "kind", row["kind"] as String?); set(record, "name", row["name"] as String?)
        set(record, "nameRev", row["name_rev"] as String?); set(record, "sortMode", row["sort_mode"] as String?)
        set(record, "sortModeRev", row["sort_mode_rev"] as String?); set(record, "rule", row["rule"] as String?)
        set(record, "ruleRev", row["rule_rev"] as String?); set(record, "createdAt", row["date_created"] as Date?)
        set(record, "deletedAt", row["deleted_at"] as Date?); return record
    }

    private func makeEntryRecord(_ record: CKRecord, name: String) throws -> CKRecord {
        let id = String(name.dropFirst("entry_".count))
        guard let row = try manager.read({ db in try Row.fetchOne(db, sql: """
            SELECT pt.*, p.playlist_sync_id, COALESCE(se.track_sync_id,t.track_sync_id) AS track_sync_id FROM playlist_tracks pt
            JOIN playlists p ON p.id = pt.playlist_id JOIN tracks t ON t.id = pt.track_id LEFT JOIN synced_playlist_entries se ON se.playlist_entry_id=pt.playlist_entry_id
            WHERE pt.playlist_entry_id = ?
        """, arguments: [id]) }) else { return record }
        record["schemaVersion"] = Self.schemaVersion; record["playlistEntryID"] = id
        set(record, "playlistID", row["playlist_sync_id"] as String?); set(record, "trackSyncID", row["track_sync_id"] as String?)
        set(record, "orderingKey", row["ordering_key"] as String?); set(record, "orderingKeyRev", row["ordering_key_rev"] as String?)
        set(record, "createdAt", row["created_at"] as Date?); set(record, "deletedAt", row["deleted_at"] as Date?); return record
    }

    private func makeCounterRecord(_ record: CKRecord, name: String) throws -> CKRecord {
        guard let row = try manager.read({ try Row.fetchOne($0, sql: "SELECT * FROM play_counters WHERE 'count_' || track_sync_id || '_' || device_id = ?", arguments: [name]) }) else { return record }
        record["schemaVersion"] = Self.schemaVersion
        set(record, "trackSyncID", row["track_sync_id"] as String?); set(record, "deviceID", row["device_id"] as String?)
        set(record, "count", row["count"] as Int?); set(record, "lastPlayedAt", row["last_played_at"] as Date?); return record
    }

    /// Applies one fetched CloudKit batch through the same merge layer exercised
    /// by `SQLiteSyncTransport`, then materializes resolvable entries once.
    func applyFetchedRecords(_ records: [CKRecord], receivedAt: Date = Date()) async throws {
        if records.contains(where: { ($0["schemaVersion"] as? Int ?? 1) > Self.schemaVersion }) {
            await MainActor.run { status.problem = .schemaTooNew }
        }
        let transportRecords = records.compactMap(transportRecord)
        // A fetched zone event can contain only record types this client does
        // not materialize (or no modifications at all). Caching those records
        // is still useful for CloudKit bookkeeping, but it must not invalidate
        // the library UI as though user-visible state had changed.
        do {
            guard !transportRecords.isEmpty else {
                guard !records.isEmpty else { return }
                try manager.write { db in
                    for record in records { try cache(record, in: db) }
                }
                return
            }
            try manager.write { db in
                try SyncRecordApplier.apply(
                    transportRecords,
                    to: db,
                    receivedAt: receivedAt,
                    revisionFilter: { [self] raw, recordName, field, date, database in
                        try acceptedRevision(raw, recordName: recordName, field: field, receivedAt: date, in: database)
                    }
                )
                for record in records { try cache(record, in: db) }
            }
            await noteSynchronizedStateReplacement()
        } catch {
            let details = "A downloaded CloudKit batch could not be applied atomically. Use Sync Recovery before continuing. \(error.localizedDescription)"
            try? manager.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [Self.rejectedBatchRecoveryKey, Data([1])]
                )
            }
            await MainActor.run {
                status.problem = .fetchedBatchRejected
                status.details = details
                status.requiresFullResync = true
                status.isSyncing = false
            }
            throw error
        }
    }

    /// Call only after another atomic synchronized-state replacement (such as
    /// an archive restore) has committed. Keeping the signal here gives every
    /// materialization path the same UI-refresh contract without coupling the
    /// coordinator to SwiftUI.
    func noteSynchronizedStateReplacement() async {
        await MainActor.run { synchronizedLibraryChanges.noteCommittedChange() }
    }

    private func transportRecord(_ record: CKRecord) -> SyncTransportRecord? {
        switch record.recordType {
        case "SyncedTrack":
            guard let id = record["trackSyncID"] as? String else { return nil }
            return .track(.init(
                id: id,
                rating: record["rating"] as? Int, ratingRev: record["ratingRev"] as? String,
                favorite: record["favorite"] as? Bool, favoriteRev: record["favoriteRev"] as? String,
                mergedInto: record["mergedInto"] as? String
            ))
        case "Playlist":
            guard let id = record["playlistID"] as? String else { return nil }
            return .playlist(.init(
                id: id, name: record["name"] as? String ?? "Untitled Playlist",
                nameRev: record["nameRev"] as? String ?? "", kind: record["kind"] as? String ?? "manual",
                sortMode: record["sortMode"] as? String ?? "manual", sortModeRev: record["sortModeRev"] as? String ?? "",
                rule: record["rule"] as? String, ruleRev: record["ruleRev"] as? String,
                createdAt: record["createdAt"] as? Date ?? Date(), deletedAt: record["deletedAt"] as? Date
            ))
        case "PlaylistEntry":
            guard let id = record["playlistEntryID"] as? String,
                  let playlistID = record["playlistID"] as? String,
                  let trackID = record["trackSyncID"] as? String else { return nil }
            return .entry(.init(
                id: id, playlistID: playlistID, trackID: trackID,
                orderingKey: record["orderingKey"] as? String ?? "U",
                orderingKeyRev: record["orderingKeyRev"] as? String ?? "",
                createdAt: record["createdAt"] as? Date ?? Date(), deletedAt: record["deletedAt"] as? Date
            ))
        case "PlayCounter":
            guard let trackID = record["trackSyncID"] as? String,
                  let deviceID = record["deviceID"] as? String else { return nil }
            return .counter(.init(
                trackID: trackID, deviceID: deviceID,
                count: record["count"] as? Int ?? 0, lastPlayedAt: record["lastPlayedAt"] as? Date
            ))
        default:
            return nil
        }
    }

    private func cache(_ record: CKRecord) throws {
        try manager.write { db in
            try cache(record, in: db)
        }
    }

    private func cache(_ record: CKRecord, in db: Database) throws {
        let full = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        // System fields are always stored. CKRecord's secure archive contains them;
        // retaining a separate column keeps the schema invariant explicit.
        try db.execute(sql: "INSERT INTO cloudkit_records (record_name, record_type, system_fields, serialized_record, last_synced_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(record_name) DO UPDATE SET record_type=excluded.record_type, system_fields=excluded.system_fields, serialized_record=excluded.serialized_record, last_synced_at=excluded.last_synced_at", arguments: [record.recordID.recordName, record.recordType, full, full, Date()])
    }

    private func set(_ record: CKRecord, _ key: String, _ value: String?) { record[key] = value as NSString? }
    private func set(_ record: CKRecord, _ key: String, _ value: Int?) { record[key] = value.map(NSNumber.init(value:)) }
    private func set(_ record: CKRecord, _ key: String, _ value: Bool?) { record[key] = value.map(NSNumber.init(value:)) }
    private func set(_ record: CKRecord, _ key: String, _ value: Date?) { record[key] = value as NSDate? }

    private func acceptedRevision(_ raw: String?, recordName: String, field: String, receivedAt: Date, in db: Database) throws -> String? {
        guard let raw else { return nil }
        guard SyncRevision(rawValue: raw).isAcceptable(receivedAt: receivedAt) else {
            try db.execute(sql: "INSERT INTO sync_revision_rejections (record_name, field_name, claimed_revision, received_at) VALUES (?, ?, ?, ?)", arguments: [recordName, field, raw, receivedAt])
            try db.execute(sql: "DELETE FROM sync_revision_rejections WHERE id NOT IN (SELECT id FROM sync_revision_rejections ORDER BY id DESC LIMIT 1000)")
            return nil
        }
        return raw
    }

    private func report(_ error: Error) async {
        let ckError = error as? CKError
        let problem: CloudSyncProblem
        switch ckError?.code {
        case .notAuthenticated: problem = .notSignedIn
        case .quotaExceeded: problem = .quotaExceeded
        case .zoneNotFound, .userDeletedZone: problem = .zoneDeleted
        case .networkFailure, .networkUnavailable: problem = .networkUnavailable
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: problem = .throttled
        case .changeTokenExpired: problem = .changeTokenExpired
        default: problem = error is AccountSwitchError ? .accountChanged : .unknown
        }
        if let retryAfter = ckError?.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
           retryAfter > 0 {
            scheduleEngineRetry(after: retryAfter)
        } else if ckError?.code == .changeTokenExpired {
            Task { [weak self] in await self?.performFullRefetch() }
        }
        await MainActor.run { status.problem = problem; status.details = error.localizedDescription; status.isSyncing = false }
    }

    private func scheduleEngineRetry(after delay: TimeInterval) {
        let oldTask = lock.withLock { () -> Task<Void, Never>? in
            let old = scheduledSync
            scheduledSync = nil
            return old
        }
        oldTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            await self?.synchronize(force: false)
        }
        lock.withLock { scheduledSync = task }
    }

    /// CloudKit reports a save using stale system fields for a record that was
    /// deleted elsewhere as `unknownItem` ("recordChangeTag specified, but
    /// record not found"). The retry must use a newly constructed CKRecord.
    static func shouldRecreateMissingRecord(after error: CKError) -> Bool {
        error.code == .unknownItem
    }
}

private struct AccountSwitchError: LocalizedError {
    var errorDescription: String? { "The iCloud account differs from the account that owns this local sync state." }
}
