import XCTest
@testable import AtollCore

final class RequestPresentationTests: XCTestCase {
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
