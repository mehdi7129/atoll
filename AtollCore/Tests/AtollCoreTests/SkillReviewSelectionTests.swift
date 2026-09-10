import XCTest
@testable import AtollCore

final class SkillReviewSelectionTests: XCTestCase {
    func testDecisionInTheMiddleContinuesAtSameRankThenPreviousAtEnd() {
        let ids = ["claude:one", "codex:two", "codex:three"]
        XCTAssertEqual(SkillProposal.nextSelection(ids[1], previous: ids, current: [ids[0], ids[2]]), ids[2])
        XCTAssertEqual(SkillProposal.nextSelection(ids[2], previous: ids, current: Array(ids.prefix(2))), ids[1])
        XCTAssertNil(SkillProposal.nextSelection(ids[0], previous: ids, current: []))
    }

    func testOtherDecisionsOrReorderingDoNotMoveTheSelectedProposal() {
        let ids = ["claude:same", "codex:same", "codex:another"]
        XCTAssertEqual(SkillProposal.nextSelection(ids[1], previous: ids, current: [ids[1], ids[2]]), ids[1])
        XCTAssertEqual(SkillProposal.nextSelection(ids[1], previous: ids, current: ids.reversed()), ids[1])
        XCTAssertEqual(SkillProposal.nextSelection(nil, previous: [], current: ids), ids[0])
    }
}
