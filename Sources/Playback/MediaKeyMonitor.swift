// MediaKeyMonitor.swift
//
// Listens for the play/pause, next and previous keys on a Mac keyboard, even when Moonlight is not
// the front app. Each key press is turned into a simple command, such as "next track", and handed
// to the playback controller.

import AppKit

enum MediaKeyCommand {
    case play
    case pause
    case playPause
    case next
    case previous

    var isPlayPauseRelated: Bool {
        switch self {
        case .play, .pause, .playPause:
            return true
        case .next, .previous:
            return false
        }
    }
}

final class MediaKeyMonitor {
    private enum SystemDefinedEvent {
        static let mediaKeySubtype: Int16 = 8
        static let keyDownState = 0x0A
        static let play = 16
        static let next = 17
        static let previous = 18
        static let fast = 19
        static let rewind = 20
    }

    private let handler: @MainActor (MediaKeyCommand) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(handler: @escaping @MainActor (MediaKeyCommand) -> Void) {
        self.handler = handler
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let command = Self.command(from: event) else { return event }
            self?.send(command)
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let command = Self.command(from: event) else { return }
            self?.send(command)
        }
    }

    private func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }

    private func send(_ command: MediaKeyCommand) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handler(command)
            }
            return
        }

        Task { @MainActor in
            handler(command)
        }
    }

    private static func command(from event: NSEvent) -> MediaKeyCommand? {
        guard event.subtype.rawValue == SystemDefinedEvent.mediaKeySubtype else { return nil }

        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyFlags = event.data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        guard keyState == SystemDefinedEvent.keyDownState else { return nil }

        switch keyCode {
        case SystemDefinedEvent.play:
            return .playPause
        case SystemDefinedEvent.next, SystemDefinedEvent.fast:
            return .next
        case SystemDefinedEvent.previous, SystemDefinedEvent.rewind:
            return .previous
        default:
            return nil
        }
    }
}
