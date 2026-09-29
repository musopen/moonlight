// MobileRuntimeSupport.swift
//
// Small shared rules used mainly by the iPhone and iPad app: running slow work in the background,
// deciding when to rebuild search after an import, when to fetch iCloud changes after a
// notification, when to switch on audio output, and when to stop playback and show an error.

import Foundation

enum MobileBackgroundWork {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await Task.detached(priority: .userInitiated, operation: operation).value
    }

    static func runThrowing<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}

enum MobileImportBatchPolicy {
    static func requiresSearchIndexRebuild(successfulImportCount: Int) -> Bool {
        successfulImportCount > 0
    }
}

enum CloudRemoteNotificationPolicy {
    static func shouldFetch(isCloudKitNotification: Bool, engineIsAvailable: Bool) -> Bool {
        isCloudKitNotification && engineIsAvailable
    }
}

enum MobileAudioSessionEvent {
    case launch
    case playbackRequested
    case interruptionEndedShouldResume
}

enum MobileAudioSessionPolicy {
    static func requiresActivation(for event: MobileAudioSessionEvent) -> Bool {
        switch event {
        case .launch:
            false
        case .playbackRequested, .interruptionEndedShouldResume:
            true
        }
    }
}

enum MobilePlaybackItemState: Equatable {
    case unknown
    case readyToPlay
    case failed(String)
}

enum MobilePlaybackItemAction: Equatable {
    case none
    case stopAndPresentError(String)
}

enum MobilePlaybackItemPolicy {
    static func action(for state: MobilePlaybackItemState) -> MobilePlaybackItemAction {
        switch state {
        case .unknown, .readyToPlay:
            .none
        case .failed(let message):
            .stopAndPresentError(message)
        }
    }
}
