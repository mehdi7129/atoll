import XCTest
@testable import AtollCore

final class CodexModelTests: XCTestCase {
    private func page(_ model: String?, next: String? = nil) -> Data {
        var payload: [String: Any] = ["data": model.map {
            [["id": $0, "model": $0, "displayName": $0, "isDefault": true, "hidden": false]]
        } ?? []]
        if let next { payload["nextCursor"] = next }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testUnavailableKeepsDiagnosticAndIsDifferentFromEmptyCatalog() {
        XCTAssertEqual(CodexModel.readCatalog { _, _ in .unavailable("Connexion refusée") },
                       .unavailable("Connexion refusée"))
        XCTAssertEqual(CodexModel.readCatalog { _, _ in .available(self.page(nil)) }, .available([]))
        XCTAssertEqual(CodexModel.readCatalog { _, _ in .available(Data("{}".utf8)) },
                       .unavailable("Réponse model/list non reconnue."))
    }

    func testPaginationRequiresAllPagesAndRejectsRepeatedCursor() {
        var calls = 0
        let catalog = CodexModel.readCatalog { cursor, remaining in
            calls += 1
            XCTAssertGreaterThan(remaining, 0)
            return .available(self.page(cursor == nil ? "first" : "second", next: cursor == nil ? "p2" : nil))
        }
        guard case .available(let models) = catalog else { return XCTFail("Catalogue complet refusé") }
        XCTAssertEqual(models.map(\.model), ["first", "second"])
        XCTAssertEqual(calls, 2)
        let repeated = CodexModel.readCatalog { _, _ in .available(self.page("first", next: "p2")) }
        XCTAssertEqual(repeated, .unavailable("Catalogue incomplet : pagination répétée."))
        let partial = CodexModel.readCatalog { cursor, _ in
            cursor == nil ? .available(self.page("first", next: "p2")) : .unavailable("CLI arrêté")
        }
        XCTAssertEqual(partial, .unavailable("CLI arrêté"))
    }

    func testDeadlineAndPageLimitNeverReturnPartialCatalog() {
        var clock = Date(timeIntervalSince1970: 100)
        var calls = 0
        let expired = CodexModel.readCatalog(timeout: 1, now: { clock }) { _, _ in
            calls += 1
            clock = clock.addingTimeInterval(2)
            return .available(self.page("first", next: "p2"))
        }
        XCTAssertEqual(expired, .unavailable("Délai de lecture du catalogue dépassé."))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(CodexModel.readCatalog(pageLimit: 1) { _, _ in .available(self.page("first", next: "p2")) },
                       .unavailable("Catalogue incomplet : trop de pages."))
    }
}
