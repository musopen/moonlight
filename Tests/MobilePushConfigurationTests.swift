import Foundation
import XCTest
@testable import Moonlight

/// Guards the build configuration that silent push depends on.
///
/// Silent pushes schedule automatic fetches; launch, activation and Sync Now
/// also fetch explicitly. XcodeGen rewrites both
/// `.entitlements` files from `project.yml` on every run, so an entitlement added
/// directly to the plist disappears at the next `xcodegen generate` with no build
/// error — the app just quietly stops receiving remote changes. These assertions
/// read the generated artifacts, so they fail for either mistake.
final class MobilePushConfigurationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func plist(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testBothTargetsDeclareThePushEntitlement() throws {
        for (path, key) in [
            ("Moonlight.entitlements", "com.apple.developer.aps-environment"),
            ("MoonlightMobile.entitlements", "aps-environment")
        ] {
            let entitlements = try plist(at: path)
            XCTAssertEqual(
                entitlements[key] as? String,
                "$(APS_ENVIRONMENT)",
                "\(path) is missing its platform's push entitlement: \(key)"
            )
            let otherKey = key == "aps-environment" ? "com.apple.developer.aps-environment" : "aps-environment"
            XCTAssertNil(entitlements[otherKey], "\(path) must use the platform-specific entitlement")
        }
    }

    func testProjectDefinesBothPushEnvironments() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)

        // Two targets, so two declarations; without them the generated
        // entitlements above are reverted on the next generate.
        let entitlementLines = project.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(entitlementLines.filter { $0 == "com.apple.developer.aps-environment: $(APS_ENVIRONMENT)" }.count, 1)
        XCTAssertEqual(entitlementLines.filter { $0 == "aps-environment: $(APS_ENVIRONMENT)" }.count, 1)
        XCTAssertTrue(project.contains("APS_ENVIRONMENT: development"))
        XCTAssertTrue(project.contains("APS_ENVIRONMENT: production"))
    }

    func testMobileBackgroundModesAllowPlaybackAndSilentPush() throws {
        let backgroundModes = try XCTUnwrap(plist(at: "Sources/Mobile/MobileInfo.plist")["UIBackgroundModes"] as? [String])
        XCTAssertTrue(backgroundModes.contains("audio"))
        XCTAssertTrue(backgroundModes.contains("remote-notification"))
    }

    /// The iOS writer identity stores itself with `SecItem*`, so the group it
    /// lands in has to be declared rather than left to the default.
    func testMobileDeclaresTheKeychainAccessGroupItWritesInto() throws {
        let groups = try XCTUnwrap(plist(at: "MoonlightMobile.entitlements")["keychain-access-groups"] as? [String])
        XCTAssertTrue(groups.contains("$(AppIdentifierPrefix)$(MOONLIGHT_BUNDLE_ID)"))
    }
}
