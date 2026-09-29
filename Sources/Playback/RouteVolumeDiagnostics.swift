// RouteVolumeDiagnostics.swift
//
// In development builds only, writes a simple troubleshooting log about output-device volume
// control to moonlight-route-volume.log in the user's own temporary folder. The log is cleared
// each time the player starts. It is meant for diagnosing volume and AirPlay problems and does
// not affect how the app behaves. Release builds write nothing.

import Foundation

enum RouteVolumeDiagnostics {
    #if DEBUG
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("moonlight-route-volume.log")
    #endif

    static func reset() {
        #if DEBUG
        try? "Moonlight route volume diagnostics\n".write(to: logURL, atomically: true, encoding: .utf8)
        #endif
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "\(Date()) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
        #endif
    }
}
