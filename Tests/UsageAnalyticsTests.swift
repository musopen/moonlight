import Foundation
import XCTest
@testable import Moonlight

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    func testFreshInstallDefaultsUsageAnalyticsToEnabled() {
        XCTAssertTrue(UsageAnalytics.value(fromStoredPreference: nil))
    }

    func testExplicitUsageAnalyticsPreferenceIsPreserved() {
        XCTAssertFalse(UsageAnalytics.value(fromStoredPreference: false))
        XCTAssertTrue(UsageAnalytics.value(fromStoredPreference: true))
    }

    func testAcceptsFirebaseConfigurationForProductionBundleID() throws {
        let path = try writeConfiguration(bundleID: "com.musopen.moonlight")

        XCTAssertTrue(
            UsageAnalytics.hasMatchingBundleID(
                in: path,
                expectedBundleID: "com.musopen.moonlight"
            )
        )
    }

    func testRejectsFirebaseConfigurationForFormerBundleID() throws {
        let path = try writeConfiguration(bundleID: "org.musopen.moonlight")

        XCTAssertFalse(
            UsageAnalytics.hasMatchingBundleID(
                in: path,
                expectedBundleID: "com.musopen.moonlight"
            )
        )
    }

    private func writeConfiguration(bundleID: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("firebase-config-\(UUID().uuidString).plist")
        let configuration: [String: String] = ["BUNDLE_ID": bundleID]
        let data = try PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
