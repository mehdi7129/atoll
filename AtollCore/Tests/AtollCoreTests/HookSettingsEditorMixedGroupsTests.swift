import XCTest
@testable import AtollCore

final class HookSettingsEditorMixedGroupsTests: XCTestCase {
    private let command = "\"$HOME/.atoll/bin/atoll-bridge\""
    private let oldCommand = "\"/old/.atoll/bin/atoll-bridge\" --legacy"

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Plusieurs groupes et doublons tiers légitimes ; les métadonnées inconnues
    /// sont des sentinelles de préservation, pas des propriétés interprétées.
    private func fixture(event: String) throws -> (input: Data, foreign: [String: Any]) {
        let before: [String: Any] = ["matcher": "", "hooks": [
            ["type": "command", "command": "before-command"]
        ]]
        let first: [String: Any] = ["type": "command", "command": "first-command", "timeout": 13,
                                    "futureHook": ["values": [1, 2], "enabled": true]]
        let second: [String: Any] = ["type": "command", "command": "echo atoll-bridge", "async": true]
        let third: [String: Any] = ["type": "command", "command": "third-command"]
        let firstGroup: [String: Any] = ["matcher": "Bash|Edit", "futureGroup": ["label": "keep", "n": 7],
                                        "hooks": [first, second, first, third]]
        let secondGroup: [String: Any] = ["matcher": "Write", "futureGroup": ["label": "other"],
                                         "hooks": [third]]
        let after: [String: Any] = ["hooks": [["type": "command", "command": "after-command"]]]
        let oldAsync: [String: Any] = ["type": "command", "command": oldCommand, "async": true]
        let oldBlocking: [String: Any] = ["type": "command", "command": oldCommand, "timeout": 5]
        var mixedFirst = firstGroup
        mixedFirst["hooks"] = [oldAsync, first, oldBlocking, second, first, third]
        var mixedSecond = secondGroup
        mixedSecond["hooks"] = [third, oldAsync]
        let allAtoll: [String: Any] = ["matcher": "*", "hooks": [oldAsync, oldBlocking]]
        let unrelated: [[String: Any]] = [["matcher": "*", "hooks": [third], "futureEvent": true]]
        let foreign: [String: Any] = [
            "permissions": ["deny": ["Bash(example)"]],
            "statusLine": ["type": "command", "command": "my-status"],
            "futureRoot": ["keep": [1, 2, 3]],
            "hooks": [event: [before, firstGroup, secondGroup, after], "FutureEvent": unrelated]
        ]
        var input = foreign
        input["hooks"] = [event: [before, mixedFirst, allAtoll, mixedSecond, after], "FutureEvent": unrelated]
        return (try encode(input), foreign)
    }

    private func groups(_ data: Data, event: String) throws -> [[String: Any]] {
        let settings = try decode(data)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        return try XCTUnwrap(hooks[event] as? [[String: Any]])
    }

    private func managedHooks(_ data: Data, event: String) throws -> [[String: Any]] {
        try groups(data, event: event).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { [command, oldCommand].contains($0["command"] as? String ?? "") }
    }

    func testInstallReplacesMixedManagedHooksForEveryManagedEvent() throws {
        for event in HookSettingsEditor.managedEvents {
            let fixture = try fixture(event: event.name)
            let installed = try HookSettingsEditor.install(into: fixture.input, command: command)
            let managed = try managedHooks(installed, event: event.name)
            XCTAssertEqual(managed.count, 1, "A08-single-managed: \(event.name)")
            XCTAssertEqual(managed.first?["command"] as? String, command, "A08-current-command")
            XCTAssertTrue(HookSettingsEditor.isInstalled(in: installed))
        }
    }

    func testInstallPreservesForeignGroupsOrderMatchersAndMetadata() throws {
        let fixture = try fixture(event: "Stop")
        let installed = try HookSettingsEditor.install(into: fixture.input, command: command)
        let expectedHooks = try XCTUnwrap(fixture.foreign["hooks"] as? [String: Any])
        let expectedGroups = try XCTUnwrap(expectedHooks["Stop"] as? [[String: Any]])
        let actualGroups = try groups(installed, event: "Stop")
        XCTAssertEqual(Array(actualGroups.dropLast()) as NSArray, expectedGroups as NSArray,
                       "A08-foreign-groups: ordre, matcher, doublons et métadonnées inchangés")
        let root = try decode(installed)
        for key in ["permissions", "statusLine", "futureRoot"] {
            XCTAssertEqual(root[key] as? NSDictionary, fixture.foreign[key] as? NSDictionary,
                           "A08-foreign-root: \(key)")
        }
        XCTAssertEqual(try groups(installed, event: "FutureEvent") as NSArray,
                       expectedHooks["FutureEvent"] as? NSArray)
    }

    func testMixedGroupReinstallIsByteIdempotent() throws {
        let fixture = try fixture(event: "Stop")
        let once = try HookSettingsEditor.install(into: fixture.input, command: command)
        var current = once
        for _ in 0..<4 {
            current = try HookSettingsEditor.install(into: current, command: command)
            XCTAssertEqual(current, once, "A08-idempotence")
            XCTAssertEqual(try managedHooks(current, event: "Stop").count, 1, "A08-no-stale-duplicate")
        }
    }

    func testMixedGroupRecallToggleLeavesExactlyOneHookInRequestedMode() throws {
        let fixture = try fixture(event: "UserPromptSubmit")
        var current = fixture.input
        for enabled in [false, true, false] {
            current = try HookSettingsEditor.install(into: current, command: command, proactiveRecall: enabled)
            let managed = try managedHooks(current, event: "UserPromptSubmit")
            XCTAssertEqual(managed.count, 1, "A08-recall-single")
            let hook = try XCTUnwrap(managed.last)
            XCTAssertEqual(hook["command"] as? String, command)
            XCTAssertEqual(hook["timeout"] as? Int, enabled ? 5 : 10, "A08-recall-timeout")
            XCTAssertEqual((hook["async"] as? Bool) == true, !enabled, "A08-recall-async")
            XCTAssertEqual(HookSettingsEditor.installedProactiveRecall(in: current), enabled,
                           "A08-recall-detection")
            XCTAssertTrue(HookSettingsEditor.isInstalled(in: current))
            let removed = try HookSettingsEditor.uninstall(from: current)
            XCTAssertEqual(try decode(removed) as NSDictionary, fixture.foreign as NSDictionary,
                           "A08-recall-foreign")
        }
    }

    func testMixedGroupUninstallPreservesExactlyTheForeignConfiguration() throws {
        let fixture = try fixture(event: "Stop")
        let direct = try HookSettingsEditor.uninstall(from: fixture.input)
        let installed = try HookSettingsEditor.install(into: fixture.input, command: command)
        let removed = try HookSettingsEditor.uninstall(from: installed)
        XCTAssertEqual(try decode(direct) as NSDictionary, fixture.foreign as NSDictionary,
                       "A08-direct-uninstall")
        XCTAssertEqual(removed, direct, "A08-install-uninstall")
        XCTAssertEqual(try HookSettingsEditor.uninstall(from: removed), removed)
    }

    func testInstallRefusesPresentMalformedHooksRootAndUninstallPreservesIt() throws {
        // Ces racines sont déjà non conformes au CLI. Le refus évite seulement
        // de remplacer une structure inconnue par une installation Atoll.
        for root: Any in [NSNull(), [], ["unexpected"], "text", 37, true] {
            let object: [String: Any] = ["hooks": root, "model": "unchanged"]
            let data = try encode(object)
            XCTAssertThrowsError(try HookSettingsEditor.install(into: data, command: command),
                                 "A08-malformed-root") { error in
                XCTAssertEqual(error as? HookSettingsEditor.EditorError, .unparseableSettings)
            }
            XCTAssertEqual(try decode(HookSettingsEditor.uninstall(from: data)) as NSDictionary,
                           object as NSDictionary)
            XCTAssertFalse(HookSettingsEditor.isInstalled(in: data))
        }
        for data in [nil, Data("{}".utf8), Data("{\"hooks\":{}}".utf8)] {
            XCTAssertTrue(HookSettingsEditor.isInstalled(in:
                try HookSettingsEditor.install(into: data, command: command)))
        }
    }

    func testUnknownOrEmptyGroupsRemainUntouchedBesideManagedHooks() throws {
        // Fixtures non conformes au CLI : le retrait chirurgical ne les normalise pas.
        let untouched: [[String: Any]] = [["hooks": [], "future": "empty"], ["future": "missing"],
                                          ["hooks": ["unknown"], "future": "mixed-types"]]
        let input = try encode(["hooks": ["Stop": untouched + [["hooks": [[
            "type": "command", "command": oldCommand
        ]]]]]])
        let installed = try HookSettingsEditor.install(into: input, command: command)
        XCTAssertEqual(Array(try groups(installed, event: "Stop").dropLast()) as NSArray,
                       untouched as NSArray, "A08-unknown-groups")
        XCTAssertEqual(try groups(HookSettingsEditor.uninstall(from: installed), event: "Stop") as NSArray,
                       untouched as NSArray)
    }

    func testDuplicateDetectionFindsMixedAndPureInstalledDuplicates() throws {
        let installed = try HookSettingsEditor.install(into: nil, command: command)
        for event in HookSettingsEditor.managedEvents {
            var settings = try decode(installed)
            var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
            let canonical = try groups(installed, event: event.name)
            hooks[event.name] = canonical + canonical
            settings["hooks"] = hooks
            let duplicate = try encode(settings)
            XCTAssertTrue(HookSettingsEditor.isInstalled(in: duplicate), "A08-detection-backup-contract")
            XCTAssertTrue(HookSettingsEditor.hasDuplicateManagedHooks(in: duplicate), "A08-detect-pure")
            let repaired = try HookSettingsEditor.install(into: duplicate, command: command)
            XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: repaired), "A08-duplicate-repaired")
        }

        var settings = try decode(installed)
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let mixed = try fixture(event: "Stop")
        hooks["Stop"] = try groups(mixed.input, event: "Stop") + groups(installed, event: "Stop")
        settings["hooks"] = hooks
        let legacy = try encode(settings)
        XCTAssertTrue(HookSettingsEditor.isInstalled(in: legacy))
        XCTAssertTrue(HookSettingsEditor.hasDuplicateManagedHooks(in: legacy), "A08-detect-mixed")
    }

    func testDuplicateDetectionIgnoresForeignUnknownAndSingleManagedHooks() throws {
        let installed = try HookSettingsEditor.install(into: nil, command: command)
        XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: installed), "A08-no-false-duplicate")
        let mixed = try fixture(event: "Stop")
        XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: try encode(mixed.foreign)),
                       "A08-foreign-duplicate")
        let foreignEvent = try encode(["hooks": ["FutureEvent": [["hooks": [
            ["type": "command", "command": command], ["type": "command", "command": command]
        ]]]]])
        XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: foreignEvent), "A08-unknown-event")
        let singleMixed = try encode(["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": command], ["type": "command", "command": "foreign"]
        ]]]]])
        XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: singleMixed), "A08-single-mixed")
        for data in [nil, Data("".utf8), Data("{}".utf8), Data("{\"hooks\":null}".utf8)] {
            XCTAssertFalse(HookSettingsEditor.hasDuplicateManagedHooks(in: data))
        }
    }
}
