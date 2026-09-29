import XCTest
@testable import Moonlight

final class HelpContentTests: XCTestCase {
    func testMissingFileRecoveryIsProminentAndDocumentsBothRecoveryPaths() throws {
        let article = try XCTUnwrap(MoonlightHelp.articles.first { $0.id == "missing-files" })
        let articleIndex = try XCTUnwrap(MoonlightHelp.articles.firstIndex(of: article))
        let content = ([article.title, article.summary, article.note ?? ""]
                       + article.sections.flatMap { [$0.title, $0.body] + $0.steps })
            .joined(separator: " ")

        XCTAssertEqual(articleIndex, 1)
        XCTAssertTrue(content.contains("Settings > Missing Files"))
        XCTAssertTrue(content.contains("Use Match"))
        XCTAssertTrue(content.contains("Find…"))
        XCTAssertTrue(content.contains("same Moonlight ID"))
        XCTAssertTrue(content.contains("failed scan"))
        XCTAssertTrue(content.contains("persistent Music folder unavailable notice"))
        XCTAssertTrue(content.contains("click Reconnect…"))
        XCTAssertTrue(content.contains("does not hash entire audio files"))
        XCTAssertTrue(content.contains("does not currently create a separate musical-work identity"))
        XCTAssertTrue(content.contains("volume identifier and filesystem file identifier"))
        XCTAssertTrue(content.contains("Tags can be missing, misspelled, translated, edited"))
        XCTAssertTrue(content.contains("whole-file hash"))
        XCTAssertTrue(content.contains("audio fingerprint"))
        XCTAssertTrue(content.contains("A false positive is more damaging"))
    }
}
