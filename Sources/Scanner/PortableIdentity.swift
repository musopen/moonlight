// PortableIdentity.swift
//
// Gives each music file a permanent ID written inside the file itself, so Moonlight can recognise
// the same song after it is moved, renamed or synced to another device. Changes are made on a
// copy, checked to ensure the actual audio was not altered, and only then swapped in. Work is
// queued and resumed if interrupted, and only on disks known to be safe.

import AVFoundation
import CryptoKit
import Darwin
import Foundation
import GRDB
import SPFKMetadataC

enum PortableIdentityState: String, Codable, Sendable {
    case embedded, absent, unsupported, unwritable, unknown
}

/// Portable identity is library-wide rather than a per-folder choice. It is on
/// by default so every eligible local file follows the same durable identity
/// policy. The stored value is reserved for a future global preference.
enum PortableIdentitySettings {
    static let enabledKey = "portable_identity_enabled"

    static func isEnabled(in db: Database) throws -> Bool {
        guard let value = try String.fetchOne(
            db,
            sql: "SELECT value FROM settings WHERE key = ?",
            arguments: [enabledKey]
        ) else {
            return true
        }
        return value != "0"
    }
}

enum TaggingJobState: String, Codable, Sendable {
    case pending, running, done
    case skippedUnsupported = "skipped_unsupported"
    case skippedUnwritable = "skipped_unwritable"
    case failedRetryable = "failed_retryable"
    case failedPermanent = "failed_permanent"
}

enum PortableIdentityError: LocalizedError {
    case unsupportedFormat(String)
    case unsafeFilesystem(String)
    case hardLinked
    case sourceChanged
    case existingIdentityMismatch(expected: String, found: String)
    case writeFailed
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value): "Portable identity is not supported for \(value)."
        case .unsafeFilesystem(let value): "Portable identity is disabled on the unproven filesystem \(value)."
        case .hardLinked: "Portable identity was skipped because this file has multiple hard links."
        case .sourceChanged: "The file changed after it was scanned; identity will be resolved again."
        case .existingIdentityMismatch(let expected, let found): "The file already carries Moonlight identifier \(found), not the pending identifier \(expected); it was left unchanged."
        case .writeFailed: "The Moonlight identifier could not be written."
        case .verificationFailed(let reason): "The replacement failed verification: \(reason)"
        }
    }
}

enum PortableIdentityTag {
    static let supportedExtensions: Set<String> = ["mp3", "flac", "ogg", "opus", "m4a"]

    static func read(from url: URL) -> String? {
        guard supportedExtensions.contains(url.pathExtension.lowercased()),
              let value = TagLibBridge.moonlightTrackID(url.path),
              UUID(uuidString: value) != nil else { return nil }
        return value.uppercased()
    }

    static func write(_ identity: String, to url: URL) throws {
        guard UUID(uuidString: identity) != nil else {
            throw PortableIdentityError.verificationFailed("the requested identifier is not a UUID")
        }
        guard TagLibBridge.setMoonlightTrackID(identity.uppercased(), path: url.path) else {
            throw PortableIdentityError.writeFailed
        }
    }

    static func isFullyEmbedded(_ identity: String, in url: URL) -> Bool {
        let expected = identity.uppercased()
        guard url.pathExtension.lowercased() == "mp3" else {
            return read(from: url) == expected
        }
        let frames = TagLibBridge.moonlightTrackIDFrames(url.path)
        return frames["UFID"]?.uppercased() == expected
            && frames["TXXX"]?.uppercased() == expected
    }
}

enum PortableIdentityFilesystemPolicy {
    /// Only filesystems that have passed Moonlight's crash/fault matrix belong
    /// here. APFS is the local baseline; exFAT and SMB intentionally fail closed.
    static let atomicReplaceAllowlist: Set<String> = ["apfs"]

    static func filesystemType(for url: URL) -> String {
        if let type = (try? url.resourceValues(forKeys: [.volumeTypeNameKey]))?.volumeTypeName {
            return type.lowercased()
        }
        // `volumeTypeNameKey` is nil for an app-container URL on iOS (including
        // the simulator), even though the underlying volume is APFS. `statfs`
        // reports the filesystem without broadening the fault-tested allowlist.
        var information = statfs()
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return "unknown" }
        defer { close(descriptor) }
        guard fstatfs(descriptor, &information) == 0 else { return "unknown" }
        return withUnsafePointer(to: &information.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0).lowercased()
            }
        }
    }

    static func permitsAtomicReplace(at url: URL) -> Bool {
        atomicReplaceAllowlist.contains(filesystemType(for: url))
    }
}

enum AudioEssenceHasher {
    static func hash(url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return try hashMP3(url)
        case "flac": return try hashFLAC(url)
        case "ogg", "opus": return try hashOggPackets(url)
        case "m4a": return try hashDecodedAudio(url)
        default: throw PortableIdentityError.unsupportedFormat(url.pathExtension)
        }
    }

    private static func hashMP3(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: 10) ?? Data()
        var start: UInt64 = 0
        if prefix.count == 10, prefix.starts(with: [0x49, 0x44, 0x33]) {
            let size = prefix[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
            start = UInt64(10 + size + ((prefix[5] & 0x10) != 0 ? 10 : 0))
        }
        var end = fileSize
        if fileSize >= 128 {
            try handle.seek(toOffset: fileSize - 128)
            if (try handle.read(upToCount: 3) ?? Data()) == Data("TAG".utf8) { end -= 128 }
        }
        guard end >= start else { throw PortableIdentityError.verificationFailed("invalid MPEG tag boundaries") }
        // Exclude a trailing APEv2 block when its footer is present.
        if end >= 32 {
            try handle.seek(toOffset: end - 32)
            let footer = try handle.read(upToCount: 32) ?? Data()
            if footer.prefix(8) == Data("APETAGEX".utf8) {
                let size = footer.withUnsafeBytes { bytes -> UInt32 in
                    bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
                }
                if UInt64(size) <= end - start { end -= UInt64(size) }
            }
        }
        guard end >= start else { throw PortableIdentityError.verificationFailed("invalid MPEG tag boundaries") }
        return try hashRange(handle: handle, start: start, length: end - start, domain: "MP3")
    }

    private static func hashFLAC(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw PortableIdentityError.verificationFailed("missing FLAC marker")
        }
        var hasher = SHA256()
        hasher.update(data: Data("FLAC".utf8))
        var isLast = false
        while !isLast {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                throw PortableIdentityError.verificationFailed("truncated FLAC metadata")
            }
            isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard let payload = try handle.read(upToCount: length), payload.count == length else {
                throw PortableIdentityError.verificationFailed("truncated FLAC metadata block")
            }
            if type == 0 { hasher.update(data: payload) } // STREAMINFO
        }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashOggPackets(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var offset = 0
        var packet = Data()
        var packets: [Data] = []
        var finalGranule: UInt64 = 0
        while offset < data.count {
            guard offset + 27 <= data.count, data[offset..<(offset + 4)] == Data("OggS".utf8) else {
                throw PortableIdentityError.verificationFailed("invalid Ogg page")
            }
            let granule = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 6, as: UInt64.self).littleEndian }
            let segmentCount = Int(data[offset + 26])
            guard offset + 27 + segmentCount <= data.count else { throw PortableIdentityError.verificationFailed("truncated Ogg lacing table") }
            let lacing = data[(offset + 27)..<(offset + 27 + segmentCount)]
            var payloadOffset = offset + 27 + segmentCount
            for lengthByte in lacing {
                let length = Int(lengthByte)
                guard payloadOffset + length <= data.count else { throw PortableIdentityError.verificationFailed("truncated Ogg packet") }
                packet.append(data[payloadOffset..<(payloadOffset + length)])
                payloadOffset += length
                if length < 255 { packets.append(packet); packet = Data() }
            }
            if granule != UInt64.max { finalGranule = granule }
            offset = payloadOffset
        }
        guard packet.isEmpty, !packets.isEmpty else { throw PortableIdentityError.verificationFailed("unterminated Ogg packet") }
        var hasher = SHA256()
        hasher.update(data: Data("OGG".utf8))
        for (index, value) in packets.enumerated() {
            let isVorbisComment = index == 1 && value.starts(with: [0x03, 0x76, 0x6f, 0x72, 0x62, 0x69, 0x73])
            let isOpusComment = index == 1 && value.starts(with: Data("OpusTags".utf8))
            guard !isVorbisComment && !isOpusComment else { continue }
            var length = UInt64(value.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: value)
        }
        var granule = finalGranule.littleEndian
        withUnsafeBytes(of: &granule) { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    /// MP4 sample-table canonicalization is intentionally isolated behind this
    /// implementation. AVAssetReader hashes decoded linear PCM, which is slower
    /// but proves the safety property required during a before/after rewrite and
    /// naturally accounts for codec cookies and edit-list trimming.
    private static func hashDecodedAudio(_ url: URL) throws -> String {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard tracks.count == 1, asset.tracks(withMediaType: .video).isEmpty else {
            throw PortableIdentityError.unsupportedFormat("non-audio-only M4A")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? PortableIdentityError.verificationFailed("could not read M4A audio") }
        var hasher = SHA256()
        hasher.update(data: Data("M4A-PCM".utf8))
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer else { throw PortableIdentityError.verificationFailed("could not access decoded M4A samples") }
            hasher.update(data: Data(bytes: pointer, count: length))
        }
        guard reader.status == .completed else { throw reader.error ?? PortableIdentityError.verificationFailed("M4A read did not complete") }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashRange(handle: FileHandle, start: UInt64, length: UInt64, domain: String) throws -> String {
        try handle.seek(toOffset: start)
        var remaining = length
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        while remaining > 0 {
            let amount = Int(min(remaining, 1_048_576))
            guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                throw PortableIdentityError.verificationFailed("truncated audio essence")
            }
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }
}

actor PortableIdentityTagger {
    private let db: DatabaseManager
    private let fileManager: FileManager

    init(db: DatabaseManager, fileManager: FileManager = .default) {
        self.db = db
        self.fileManager = fileManager
    }

    nonisolated static func sweepOrphanedTemporaryFiles(
        in root: URL,
        olderThan age: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Int {
        guard root.isFileURL, age >= 0 else { return 0 }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        let cutoff = now.addingTimeInterval(-age)
        var removed = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix(".moonlight-") else { continue }
            let suffix = name.dropFirst(".moonlight-".count)
            guard suffix.count > 36,
                  suffix[suffix.index(suffix.startIndex, offsetBy: 36)] == "-",
                  UUID(uuidString: String(suffix.prefix(36))) != nil else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt <= cutoff else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    func recoverInterruptedJobs() {
        try? db.write { database in
            try database.execute(sql: "UPDATE tagging_jobs SET state = 'pending' WHERE state = 'running'")
            if try PortableIdentitySettings.isEnabled(in: database) {
                // Older builds could skip a file because its individual folder
                // had identity tagging disabled. The policy is now global, so
                // retry only files that are still eligible for tagging.
                try database.execute(sql: """
                    UPDATE tagging_jobs SET state = 'pending', next_attempt_at = NULL
                    WHERE state = 'skipped_unwritable'
                      AND physical_file_id IN (
                        SELECT physical_file_id FROM physical_files
                        WHERE id_state IN ('absent', 'unknown')
                      )
                """)
            }
        }
    }

    func processPending(limit: Int = 2) async {
        recoverInterruptedJobs()
        let jobs = (try? db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT tj.physical_file_id, tj.may_replace_existing_identity,
                       pf.track_sync_id, pf.relative_path, pf.file_size, pf.mtime,
                       f.url AS root_url
                FROM tagging_jobs tj
                JOIN physical_files pf USING(physical_file_id)
                JOIN folders f USING(library_root_id)
                WHERE tj.state IN ('pending', 'failed_retryable')
                  AND (tj.next_attempt_at IS NULL OR tj.next_attempt_at <= ?)
                ORDER BY COALESCE(tj.last_attempt_at, '1970-01-01'), tj.physical_file_id
                LIMIT ?
            """, arguments: [Date(), limit])
        }) ?? []
        for job in jobs { await process(job) }
    }

    func drainPending(batchSize: Int = 2) async {
        while !Task.isCancelled {
            let runnable = (try? db.read { database in
                try Int.fetchOne(database, sql: """
                    SELECT COUNT(*) FROM tagging_jobs
                    WHERE state IN ('pending', 'failed_retryable')
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                """, arguments: [Date()])
            }) ?? 0
            guard runnable > 0 else { return }
            await processPending(limit: max(1, batchSize))
            await Task.yield()
        }
    }

    private func process(_ row: Row) async {
        let physicalID: String = row["physical_file_id"]
        let identity: String = row["track_sync_id"]
        let mayReplaceExistingIdentity: Bool = row["may_replace_existing_identity"]
        guard let rootString: String = row["root_url"], let root = URL(string: rootString) else {
            mark(physicalID, state: .failedPermanent, error: "Invalid library root")
            return
        }
        let relativePath: String = row["relative_path"]
        let url = root.appendingPathComponent(relativePath)
        let portable = (try? db.read { try PortableIdentitySettings.isEnabled(in: $0) }) ?? true
        guard portable else { mark(physicalID, state: .skippedUnwritable, error: nil); return }
        mark(physicalID, state: .running, error: nil)
        do {
            try tag(
                url: url,
                identity: identity,
                expectedSize: row["file_size"],
                expectedMtime: row["mtime"],
                allowReplacingExistingIdentity: mayReplaceExistingIdentity
            )
            let newValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let essence = try AudioEssenceHasher.hash(url: url)
            try db.write { database in
                try database.execute(sql: "UPDATE tagging_jobs SET state = 'done', last_error = NULL, last_attempt_at = ? WHERE physical_file_id = ?", arguments: [Date(), physicalID])
                try database.execute(sql: "UPDATE physical_files SET id_state = 'embedded', file_size = ?, mtime = ?, audio_hash = ? WHERE physical_file_id = ?", arguments: [newValues.fileSize, newValues.contentModificationDate, essence, physicalID])
                try database.execute(sql: "UPDATE tracks SET id_state = 'embedded', file_size = ?, file_modified_at = ?, audio_hash = ? WHERE physical_file_id = ?", arguments: [newValues.fileSize, newValues.contentModificationDate, essence, physicalID])
                try SyncEligibility.verifyFile(url, physicalFileID: physicalID, in: database)
            }
        } catch let error as PortableIdentityError {
            switch error {
            case .unsupportedFormat:
                mark(physicalID, state: .skippedUnsupported, error: errorDescription(error))
            case .unsafeFilesystem, .hardLinked:
                mark(physicalID, state: .skippedUnwritable, error: errorDescription(error))
            case .sourceChanged:
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    try? db.write { database in
                        try database.execute(sql: "UPDATE physical_files SET file_size = ?, mtime = ?, id_state = 'absent' WHERE physical_file_id = ?", arguments: [values.fileSize, values.contentModificationDate, physicalID])
                        try database.execute(sql: "UPDATE tracks SET file_size = ?, file_modified_at = ?, id_state = 'absent' WHERE physical_file_id = ?", arguments: [values.fileSize, values.contentModificationDate, physicalID])
                    }
                }
                mark(physicalID, state: .pending, error: errorDescription(error))
            case .existingIdentityMismatch(_, let found):
                try? db.write { database in
                    try database.execute(sql: """
                        INSERT INTO identity_conflicts
                            (id, track_sync_id, physical_file_id, reason, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [
                            UUID().uuidString.uppercased(),
                            found,
                            physicalID,
                            "A pending identity write found a different Moonlight identifier already embedded in this file. The file was left unchanged.",
                            Date()
                        ])
                }
                mark(physicalID, state: .failedPermanent, error: errorDescription(error))
            case .writeFailed, .verificationFailed:
                let attempts = ((try? db.read { try Int.fetchOne($0, sql: "SELECT attempts FROM tagging_jobs WHERE physical_file_id = ?", arguments: [physicalID]) }) ?? 0) + 1
                mark(physicalID, state: attempts >= 5 ? .failedPermanent : .failedRetryable, error: errorDescription(error), attempts: attempts)
            }
        } catch {
            let attempts = ((try? db.read { try Int.fetchOne($0, sql: "SELECT attempts FROM tagging_jobs WHERE physical_file_id = ?", arguments: [physicalID]) }) ?? 0) + 1
            let permanent = attempts >= 5
            mark(physicalID, state: permanent ? .failedPermanent : .failedRetryable, error: errorDescription(error), attempts: attempts)
        }
    }

    func tag(
        url: URL,
        identity: String,
        expectedSize: Int64?,
        expectedMtime: Date?,
        allowReplacingExistingIdentity: Bool = false
    ) throws {
        let ext = url.pathExtension.lowercased()
        let expectedIdentity = identity.uppercased()
        guard PortableIdentityTag.supportedExtensions.contains(ext) else { throw PortableIdentityError.unsupportedFormat(ext) }
        guard fileManager.isWritableFile(atPath: url.path) else { throw PortableIdentityError.unsafeFilesystem("read-only") }
        let filesystem = PortableIdentityFilesystemPolicy.filesystemType(for: url)
        guard PortableIdentityFilesystemPolicy.permitsAtomicReplace(at: url) else { throw PortableIdentityError.unsafeFilesystem(filesystem) }
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .linkCountKey])
        if let expectedSize, Int64(resources.fileSize ?? -1) != expectedSize { throw PortableIdentityError.sourceChanged }
        if let expectedMtime, let actual = resources.contentModificationDate,
           abs(actual.timeIntervalSince(expectedMtime)) > 0.001 { throw PortableIdentityError.sourceChanged }
        if (resources.linkCount ?? 1) > 1 { throw PortableIdentityError.hardLinked }
        if !allowReplacingExistingIdentity,
           let existingIdentity = PortableIdentityTag.read(from: url),
           existingIdentity != expectedIdentity {
            throw PortableIdentityError.existingIdentityMismatch(expected: expectedIdentity, found: existingIdentity)
        }
        if PortableIdentityTag.isFullyEmbedded(expectedIdentity, in: url) { return }

        let beforeTags = normalizedTags((TagLibBridge.getProperties(url.path) as? [String: String]) ?? [:])
        let beforeHash = try AudioEssenceHasher.hash(url: url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".moonlight-\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: url, to: temporary)
        try PortableIdentityTag.write(expectedIdentity, to: temporary)

        let afterTags = normalizedTags((TagLibBridge.getProperties(temporary.path) as? [String: String]) ?? [:])
        guard beforeTags == afterTags else { throw PortableIdentityError.verificationFailed("existing metadata changed") }
        guard PortableIdentityTag.isFullyEmbedded(expectedIdentity, in: temporary) else { throw PortableIdentityError.verificationFailed("identifier did not read back from every required frame") }
        let afterHash = try AudioEssenceHasher.hash(url: temporary)
        guard beforeHash == afterHash else { throw PortableIdentityError.verificationFailed("audio essence changed") }

        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        guard PortableIdentityTag.isFullyEmbedded(expectedIdentity, in: url) else {
            throw PortableIdentityError.verificationFailed("installed file did not retain its identifier")
        }
    }

    private func mark(_ id: String, state: TaggingJobState, error: String?, attempts: Int? = nil) {
        try? db.write { database in
            let storedAttempts = try Int.fetchOne(database, sql: "SELECT attempts FROM tagging_jobs WHERE physical_file_id = ?", arguments: [id]) ?? 0
            let currentAttempts = attempts ?? storedAttempts
            let delay = min(pow(2.0, Double(currentAttempts)) * 60, 24 * 60 * 60)
            let next = state == .failedRetryable ? Date().addingTimeInterval(delay) : nil
            try database.execute(sql: "UPDATE tagging_jobs SET state = ?, attempts = ?, last_error = ?, last_attempt_at = ?, next_attempt_at = ? WHERE physical_file_id = ?", arguments: [state.rawValue, currentAttempts, error, Date(), next, id])
            if state == .skippedUnsupported {
                try database.execute(sql: "UPDATE physical_files SET id_state = 'unsupported' WHERE physical_file_id = ?", arguments: [id])
                try database.execute(sql: "UPDATE tracks SET id_state = 'unsupported' WHERE physical_file_id = ?", arguments: [id])
            } else if state == .skippedUnwritable {
                try database.execute(sql: "UPDATE physical_files SET id_state = 'unwritable' WHERE physical_file_id = ?", arguments: [id])
                try database.execute(sql: "UPDATE tracks SET id_state = 'unwritable' WHERE physical_file_id = ?", arguments: [id])
            }
        }
    }

    private func errorDescription(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    private func normalizedTags(_ tags: [String: String]) -> [String: String] {
        tags.filter { key, _ in
            let normalized = key.uppercased()
            return normalized != "MOONLIGHT_TRACK_ID"
                && !normalized.contains("MOONLIGHT.APP/TRACK-ID")
                && !normalized.contains("COM.MOONLIGHT.APP")
        }
    }
}
