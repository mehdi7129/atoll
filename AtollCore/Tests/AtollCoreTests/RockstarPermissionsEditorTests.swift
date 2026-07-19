import XCTest
@testable import AtollCore

final class RockstarPermissionsEditorTests: XCTestCase {

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - park

    func testParkRemovesDenyAndReturnsRules() throws {
        let settings = json([
            "permissions": ["deny": ["Bash(rm -rf *)", "Bash(sudo *)"], "defaultMode": "bypassPermissions"],
            "hooks": ["Stop": []],
        ])
        let result = try XCTUnwrap(RockstarPermissionsEditor.park(in: settings))
        XCTAssertEqual(result.parked, ["Bash(rm -rf *)", "Bash(sudo *)"])
        let updated = object(result.updated)
        let permissions = try XCTUnwrap(updated["permissions"] as? [String: Any])
        XCTAssertNil(permissions["deny"])
        // Le reste de permissions et du fichier est intact.
        XCTAssertEqual(permissions["defaultMode"] as? String, "bypassPermissions")
        XCTAssertNotNil(updated["hooks"])
    }

    func testParkWithoutDenyIsNoOp() throws {
        XCTAssertNil(try RockstarPermissionsEditor.park(in: json(["permissions": [String: Any]()])))
        XCTAssertNil(try RockstarPermissionsEditor.park(in: json(["other": 1])))
        XCTAssertNil(try RockstarPermissionsEditor.park(in: nil))
        XCTAssertNil(try RockstarPermissionsEditor.park(in: json(["permissions": ["deny": [String]()]])))
    }

    func testParkRemovesEmptyPermissionsObject() throws {
        let settings = json(["permissions": ["deny": ["Bash(sudo *)"]]])
        let result = try XCTUnwrap(RockstarPermissionsEditor.park(in: settings))
        // permissions ne contenait QUE deny → l'objet vide est retiré, pas laissé en ruine.
        XCTAssertNil(object(result.updated)["permissions"])
    }

    func testParkRefusesUnparseableSettings() {
        XCTAssertThrowsError(try RockstarPermissionsEditor.park(in: Data("pas du json".utf8))) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
    }

    func testParkRefusesUnexpectedShapes() {
        // permissions présent mais pas un objet → refus, jamais d'écrasement.
        XCTAssertThrowsError(try RockstarPermissionsEditor.park(in: json(["permissions": "oops"]))) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
        // deny présent mais pas [String] (format futur ?) → refus.
        XCTAssertThrowsError(try RockstarPermissionsEditor.park(
            in: json(["permissions": ["deny": [["rule": "Bash(sudo *)"]]]]))) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
    }

    func testRestoreRefusesUnexpectedShapes() {
        XCTAssertThrowsError(try RockstarPermissionsEditor.restore(
            into: Data("pas du json".utf8), parked: ["Bash(sudo *)"])) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
        XCTAssertThrowsError(try RockstarPermissionsEditor.restore(
            into: json(["permissions": ["deny": 42]]), parked: ["Bash(sudo *)"])) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
    }

    func testMergeParkedKeepsPreviousFirstWithoutDuplicates() {
        XCTAssertEqual(
            RockstarPermissionsEditor.mergeParked(
                previous: ["a", "b"], new: ["b", "c"]),
            ["a", "b", "c"])
        XCTAssertEqual(RockstarPermissionsEditor.mergeParked(previous: [], new: ["x"]), ["x"])
        XCTAssertEqual(RockstarPermissionsEditor.mergeParked(previous: ["x"], new: []), ["x"])
    }

    // MARK: - restore

    func testRestoreReinsertsRulesInOriginalOrder() throws {
        let parked = ["Bash(rm -rf *)", "Bash(sudo *)"]
        let updated = try RockstarPermissionsEditor.restore(into: json(["permissions": [String: Any]()]), parked: parked)
        let permissions = try XCTUnwrap(object(updated)["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], parked)
    }

    func testRestoreMergesWithRulesAddedMeanwhile() throws {
        let settings = json(["permissions": ["deny": ["Read(./.env)", "Bash(sudo *)"]]])
        let updated = try RockstarPermissionsEditor.restore(
            into: settings, parked: ["Bash(rm -rf *)", "Bash(sudo *)"])
        let permissions = try XCTUnwrap(object(updated)["permissions"] as? [String: Any])
        // Parquées d'abord (ordre d'origine), puis les ajouts, sans doublon.
        XCTAssertEqual(permissions["deny"] as? [String],
                       ["Bash(rm -rf *)", "Bash(sudo *)", "Read(./.env)"])
    }

    func testRestoreIntoMissingSettingsCreatesPermissions() throws {
        let updated = try RockstarPermissionsEditor.restore(into: nil, parked: ["Bash(sudo *)"])
        let permissions = try XCTUnwrap(object(updated)["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(sudo *)"])
    }

    func testRestoreWithNothingParkedKeepsFileIdentical() throws {
        let settings = json(["permissions": ["deny": ["Bash(sudo *)"]], "model": "opus"])
        let updated = try RockstarPermissionsEditor.restore(into: settings, parked: [])
        let permissions = try XCTUnwrap(object(updated)["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(sudo *)"])
        XCTAssertEqual(object(updated)["model"] as? String, "opus")
    }

    // MARK: - aller-retour

    func testParkThenRestoreRoundTrips() throws {
        let original = json([
            "permissions": ["deny": ["Bash(rm -rf *)", "Read(./.env)"], "defaultMode": "plan"],
            "statusLine": ["type": "command"],
        ])
        let parked = try XCTUnwrap(RockstarPermissionsEditor.park(in: original))
        let restored = try RockstarPermissionsEditor.restore(into: parked.updated, parked: parked.parked)
        let permissions = try XCTUnwrap(object(restored)["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm -rf *)", "Read(./.env)"])
        XCTAssertEqual(permissions["defaultMode"] as? String, "plan")
        XCTAssertNotNil(object(restored)["statusLine"])
    }

    // MARK: - fichier de parking

    func testParkedRulesEncodeDecodeRoundTrip() throws {
        let rules = RockstarPermissionsEditor.ParkedRules(
            deny: ["Bash(sudo *)"], parkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try RockstarPermissionsEditor.encodeParked(rules)
        XCTAssertEqual(RockstarPermissionsEditor.decodeParked(data), rules)
    }

    func testDecodeParkedRejectsGarbage() {
        XCTAssertNil(RockstarPermissionsEditor.decodeParked(Data("{}".utf8)))
        XCTAssertNil(RockstarPermissionsEditor.decodeParked(Data("nope".utf8)))
    }

    func testDenyRulesReadsCurrentRules() {
        let settings = json(["permissions": ["deny": ["Bash(sudo *)"]]])
        XCTAssertEqual(RockstarPermissionsEditor.denyRules(in: settings), ["Bash(sudo *)"])
        XCTAssertEqual(RockstarPermissionsEditor.denyRules(in: nil), [])
    }
}
