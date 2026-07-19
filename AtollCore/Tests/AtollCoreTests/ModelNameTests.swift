import XCTest
@testable import AtollCore

final class ModelNameTests: XCTestCase {
    func testPrettifiesRawIDs() {
        XCTAssertEqual(ModelName.display("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.display("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testStripsContextSuffix() {
        XCTAssertEqual(ModelName.display("claude-fable-5[1m]"), "Fable 5")
    }

    func testPassesThroughDisplayNames() {
        // Déjà propre (statusline) → inchangé.
        XCTAssertEqual(ModelName.display("Opus 4.8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("Fable 5"), "Fable 5")
    }

    func testHandlesUnknownGracefully() {
        XCTAssertEqual(ModelName.display("gpt-4o"), "Gpt 4o")
        XCTAssertEqual(ModelName.display(""), "")
    }
}
