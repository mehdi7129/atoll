import XCTest
@testable import AtollCore

final class RequestPresentationTests: XCTestCase {
    func testExternalResolutionCannotRetargetAnImmediateDecision() {
        var presentation = RequestPresentation()
        let now = Date(timeIntervalSince1970: 100)
        let a = RequestPresentation.Item(provider: .claude, requestID: "a", receivedAt: now)
        let b = RequestPresentation.Item(provider: .codex, requestID: "b", receivedAt: now)
        presentation.update([a, b], now: now)
        XCTAssertTrue(presentation.mayDecide(in: [a, b], now: now))
        XCTAssertFalse(presentation.mayDecide(in: [b], now: now))
        presentation.update([b], now: now)
        XCTAssertFalse(presentation.mayDecide(in: [b], now: now.addingTimeInterval(0.2)))
        XCTAssertTrue(presentation.mayDecide(in: [b], now: now.addingTimeInterval(0.5)))
        presentation.update([b], now: now.addingTimeInterval(0.6))
        XCTAssertTrue(presentation.mayDecide(in: [b], now: now.addingTimeInterval(0.6)))
        presentation.update([], now: now)
        XCTAssertFalse(presentation.mayDecide(in: [], now: now))
    }

    func testVoluntaryNavigationDoesNotWaitForTheExternalReplacementGrace() {
        var presentation = RequestPresentation()
        let now = Date(timeIntervalSince1970: 100)
        let items = (1...3).map { RequestPresentation.Item(provider: .codex, requestID: "\($0)", receivedAt: now) }
        presentation.update(items, now: now)
        presentation.update(Array(items.dropFirst()), now: now)
        XCTAssertFalse(presentation.mayDecide(in: Array(items.dropFirst()), now: now))
        presentation.move(1, in: Array(items.dropFirst()))
        XCTAssertEqual(presentation.current(in: items), items[2].id)
        XCTAssertTrue(presentation.mayDecide(in: items, now: now))
    }

    func testCodexFirstIsNotPreemptedByClaudeEvenWithAnOlderDate() {
        var presentation = RequestPresentation()
        let codex = RequestPresentation.Item(provider: .codex, requestID: "same", receivedAt: Date(timeIntervalSince1970: 20))
        let claude = RequestPresentation.Item(provider: .claude, requestID: "same", receivedAt: Date(timeIntervalSince1970: 10))
        presentation.update([codex])
        presentation.update([codex, claude])
        XCTAssertEqual(presentation.current(in: [codex, claude]), codex.id)
        presentation.move(1, in: [codex, claude])
        XCTAssertEqual(presentation.current(in: [codex, claude]), claude.id)
        presentation.update([codex])
        XCTAssertEqual(presentation.current(in: [codex]), codex.id)
        presentation.update([])
        XCTAssertNil(presentation.current(in: []))
    }

    func testTwoIdenticalToolsRemainIndependentRequests() {
        var presentation = RequestPresentation()
        let a = RequestPresentation.Item(provider: .codex, requestID: "a", receivedAt: .distantPast)
        let b = RequestPresentation.Item(provider: .codex, requestID: "b", receivedAt: Date())
        presentation.update([a, b])
        XCTAssertEqual(presentation.current(in: [a, b]), a.id)
        presentation.update([b])
        XCTAssertEqual(presentation.current(in: [b]), b.id)
    }
}
