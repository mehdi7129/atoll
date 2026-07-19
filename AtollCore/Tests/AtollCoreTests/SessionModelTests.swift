import XCTest
@testable import AtollCore

final class SessionModelTests: XCTestCase {

    func testNeedsAttention() {
        XCTAssertFalse(AgentSession(projectName: "p", status: .working(tool: "Bash")).needsAttention)
        XCTAssertTrue(AgentSession(projectName: "p", status: .awaitingPermission(tool: "Edit")).needsAttention)
        // Session au repos (attente du prochain message) = PAS une alerte.
        XCTAssertFalse(AgentSession(projectName: "p", status: .awaitingInput).needsAttention)
        XCTAssertFalse(AgentSession(projectName: "p", status: .done).needsAttention)
    }

    func testIsActive() {
        XCTAssertTrue(AgentSession(projectName: "p", status: .working(tool: nil)).isActive)
        XCTAssertFalse(AgentSession(projectName: "p", status: .awaitingPermission(tool: "Edit")).isActive)
        XCTAssertFalse(AgentSession(projectName: "p", status: .awaitingInput).isActive)
        XCTAssertFalse(AgentSession(projectName: "p", status: .done).isActive)
    }

    func testStatusEquatableDistinguishesAssociatedValues() {
        XCTAssertEqual(AgentSession.Status.working(tool: "Bash"), .working(tool: "Bash"))
        XCTAssertNotEqual(AgentSession.Status.working(tool: "Bash"), .working(tool: "Edit"))
        XCTAssertNotEqual(AgentSession.Status.working(tool: nil), .awaitingInput)
    }

    func testMockDataIsPlausible() {
        XCTAssertFalse(MockData.sessions.isEmpty)
        XCTAssertTrue(MockData.sessions.contains(where: \.needsAttention))
        XCTAssertTrue(MockData.sessions.contains(where: \.isActive))
        XCTAssertTrue((0...1).contains(MockData.usage.fiveHourFraction))
        XCTAssertTrue((0...1).contains(MockData.usage.sevenDayFraction))
    }
}
