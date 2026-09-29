// LastFMConfiguration.swift
//
// Holds the app's Last.fm access keys, which are read from the app's built-in settings. If the
// keys are missing, the Last.fm feature is shown as unavailable.

import Foundation

struct LastFMConfiguration: Equatable {
    let apiKey: String
    let sharedSecret: String

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func bundled(in bundle: Bundle = .main) -> LastFMConfiguration {
        LastFMConfiguration(
            apiKey: bundle.object(forInfoDictionaryKey: "LastFMAPIKey") as? String ?? "",
            sharedSecret: bundle.object(forInfoDictionaryKey: "LastFMSharedSecret") as? String ?? ""
        )
    }
}
