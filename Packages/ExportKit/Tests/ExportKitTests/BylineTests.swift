import XCTest
@testable import ExportKit

/// The export footer byline (Settings ▸ Appearance → "Include my name…").
final class BylineTests: XCTestCase {
    func testBylineAppearsOnlyWhenProvided() {
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(buildCreatedLine(generatedAt: d, byline: "Jane Doe").contains("by Jane Doe"))
        // No byline → date only, never a dangling "by".
        XCTAssertFalse(buildCreatedLine(generatedAt: d, byline: nil).contains(" by "))
        XCTAssertFalse(buildCreatedLine(generatedAt: d, byline: "").contains(" by "))
    }
}
