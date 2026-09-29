// ScanTypes.swift
//
// Defines the basic terms used when scanning a music library: the kind of scan (quick, full
// rebuild, or live), what started it (the user, app launch, a schedule, a folder change or a new
// folder), and a running summary of files processed, changed, missing and failed.

import Foundation

enum ScanMode: String, Codable, CaseIterable {
    case incremental
    case fullRebuild
    case liveIncremental

    var skipsUnchangedFiles: Bool {
        self != .fullRebuild
    }

    var displayName: String {
        switch self {
        case .incremental: return "Incremental Scan"
        case .fullRebuild: return "Full Rebuild"
        case .liveIncremental: return "Live Scan"
        }
    }
}

enum ScanTrigger: String, Codable, CaseIterable {
    case manual
    case launch
    case scheduled
    case live
    case folderAdded
}

struct ScanSummary: Equatable, Identifiable {
    var id: Int64 { jobId ?? -1 }

    var jobId: Int64?
    var mode: ScanMode
    var trigger: ScanTrigger
    var totalFiles: Int
    var processedFiles: Int
    var skippedFiles: Int
    var changedFiles: Int
    var removedFiles: Int
    var missingFiles: Int
    var relinkedFiles: Int
    var errorCount: Int
    var failureMessage: String?

    var hasLibraryChanges: Bool {
        changedFiles > 0 || removedFiles > 0 || missingFiles > 0 || relinkedFiles > 0 || errorCount > 0
    }

    var failed: Bool { failureMessage != nil }

    static let idle = ScanSummary(
        jobId: nil,
        mode: .incremental,
        trigger: .manual,
        totalFiles: 0,
        processedFiles: 0,
        skippedFiles: 0,
        changedFiles: 0,
        removedFiles: 0,
        missingFiles: 0,
        relinkedFiles: 0,
        errorCount: 0,
        failureMessage: nil
    )
}
