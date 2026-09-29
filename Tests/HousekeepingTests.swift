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
