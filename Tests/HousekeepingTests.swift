import Foundation
import XCTest
@testable import Moonlight

final class HousekeepingTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCIExecutesForMainPushesAndPullRequests() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("  push:\n    branches: [main]"))
        XCTAssertTrue(workflow.contains("  pull_request:"))
    }

    func testRecoveryOperationsClearAStaleErrorBeforeRetrying() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/UI/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let protectBlock = try XCTUnwrap(source.range(of: "Button(\"Create Recovery Copy\")"))
        let restoreBlock = try XCTUnwrap(source.range(of: "Button(\"Restore Snapshot\""))
        XCTAssertTrue(source[protectBlock.lowerBound...].prefix(240).contains("operationError = nil"))
        XCTAssertTrue(source[restoreBlock.lowerBound...].prefix(320).contains("operationError = nil"))
    }

    func testTransportSecurityExceptionIsLimitedToMediaPlayback() throws {
        for relativePath in ["Sources/App/Info.plist", "Sources/Mobile/MobileInfo.plist"] {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            let transportSecurity = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])

            XCTAssertEqual(transportSecurity["NSAllowsArbitraryLoadsForMedia"] as? Bool, true)
            XCTAssertNil(
                transportSecurity["NSAllowsArbitraryLoads"],
                "\(relativePath) must not disable App Transport Security for non-media requests"
            )
        }
    }
}


@MainActor
final class InteractionDiagnosticsTests: XCTestCase {
    func testRecordingIsOptInAndUsesSessionTokens() {
        let recorder = InteractionDiagnostics()
        recorder.record("ignored")
        XCTAssertFalse(recorder.hasEvents)
        recorder.beginRecording()
        recorder.record("album.tap", albumID: 987654321)
        XCTAssertTrue(recorder.report.contains("album.tap album=1"))
        XCTAssertFalse(recorder.report.contains("987654321"))
        recorder.stop()
        recorder.record("after.stop")
        XCTAssertFalse(recorder.report.contains("after.stop"))
        recorder.beginRecording()
        XCTAssertFalse(recorder.report.contains("album.tap"))
        recorder.record("new.album", albumID: 123456789)
        XCTAssertTrue(recorder.report.contains("new.album album=1"))
        recorder.stop()
    }

    func testRecordingRetainsOnlyLatestEvents() {
        let recorder = InteractionDiagnostics()
        recorder.beginRecording()
        for index in 0..<4100 { recorder.record("event.\(index)") }
        let report = recorder.report
        XCTAssertTrue(report.contains("Earlier events discarded: 101"))
        XCTAssertFalse(report.contains(" event.0\n"))
        XCTAssertTrue(report.contains(" event.4099\n"))
        recorder.stop()
    }
}
