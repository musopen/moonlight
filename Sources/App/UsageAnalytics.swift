// UsageAnalytics.swift
//
// Sends anonymous usage statistics (app opened, playback started, library scan finished) to Google
// Firebase Analytics. It only runs when a matching Firebase settings file is bundled with the app,
// and it respects the user's on/off choice, which is on by default for new installs.

import Foundation
import FirebaseAnalytics
import FirebaseCore

@MainActor
enum UsageAnalytics {
    private static let enabledKey = "usageAnalyticsEnabled"
    private static var configured = false

    static var isEnabled: Bool {
        // An absent value means this is a fresh install, where analytics is enabled
        // by default. Explicit choices remain stored and are never overwritten.
        get { value(fromStoredPreference: UserDefaults.standard.object(forKey: enabledKey)) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            guard configured else { return }
            Analytics.setAnalyticsCollectionEnabled(newValue)
            if newValue {
                logAppOpen()
            }
        }
    }

    static func value(fromStoredPreference preference: Any?) -> Bool {
        preference as? Bool ?? true
    }

    static func configureIfAvailable() {
        guard !configured else { return }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            print("Firebase Analytics not configured: GoogleService-Info.plist is missing.")
            return
        }
        guard hasMatchingBundleID(in: path),
              let options = FirebaseOptions(contentsOfFile: path) else {
            print("Firebase Analytics not configured: GoogleService-Info.plist is invalid.")
            return
        }

        FirebaseApp.configure(options: options)
        configured = true
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
    }

    /// Keeps a stale Firebase plist for the former bundle ID from silently
    /// configuring analytics in a production build.
    static func hasMatchingBundleID(in configurationPath: String, expectedBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let expectedBundleID,
              let configuration = NSDictionary(contentsOfFile: configurationPath),
              let configuredBundleID = configuration["BUNDLE_ID"] as? String else {
            return false
        }

        guard configuredBundleID == expectedBundleID else {
            print("Firebase Analytics not configured: GoogleService-Info.plist bundle ID does not match this app.")
            return false
        }

        return true
    }

    static func logAppOpen() {
        logEvent(AnalyticsEventAppOpen)
    }

    static func logPlaybackStarted(queueSize: Int, shuffled: Bool) {
        logEvent("playback_started", parameters: [
            "queue_size": queueSize,
            "shuffled": shuffled
        ])
    }

    static func logScanCompleted(_ summary: Any) {
        let values = reflectedScanSummaryValues(summary)
        logEvent("library_scan_completed", parameters: [
            "mode": values.mode,
            "trigger": values.trigger,
            "total_files": values.totalFiles,
            "processed_files": values.processedFiles,
            "skipped_files": values.skippedFiles,
            "changed_files": values.changedFiles,
            "removed_files": values.removedFiles,
            "missing_files": values.missingFiles,
            "relinked_files": values.relinkedFiles,
            "error_count": values.errorCount
        ])
    }

    private static func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        guard configured, isEnabled else { return }
        Analytics.logEvent(name, parameters: parameters)
    }

    private static func reflectedScanSummaryValues(_ summary: Any) -> (
        mode: String,
        trigger: String,
        totalFiles: Int,
        processedFiles: Int,
        skippedFiles: Int,
        changedFiles: Int,
        removedFiles: Int,
        missingFiles: Int,
        relinkedFiles: Int,
        errorCount: Int
    ) {
        var values: [String: Any] = [:]
        for child in Mirror(reflecting: summary).children {
            guard let label = child.label else { continue }
            values[label] = child.value
        }

        return (
            mode: reflectedRawValue(values["mode"]),
            trigger: reflectedRawValue(values["trigger"]),
            totalFiles: values["totalFiles"] as? Int ?? 0,
            processedFiles: values["processedFiles"] as? Int ?? 0,
            skippedFiles: values["skippedFiles"] as? Int ?? 0,
            changedFiles: values["changedFiles"] as? Int ?? 0,
            removedFiles: values["removedFiles"] as? Int ?? 0,
            missingFiles: values["missingFiles"] as? Int ?? 0,
            relinkedFiles: values["relinkedFiles"] as? Int ?? 0,
            errorCount: values["errorCount"] as? Int ?? 0
        )
    }

    private static func reflectedRawValue(_ value: Any?) -> String {
        guard let value else { return "unknown" }
        let mirror = Mirror(reflecting: value)
        if let rawValue = mirror.children.first(where: { $0.label == "rawValue" })?.value as? String {
            return rawValue
        }
        return String(describing: value)
    }
}
