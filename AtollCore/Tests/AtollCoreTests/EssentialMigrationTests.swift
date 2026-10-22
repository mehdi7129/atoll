import XCTest
@testable import AtollCore

final class EssentialMigrationTests: XCTestCase {
    private let fm = FileManager.default
    private func fixture() throws -> (URL, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("atoll-essential-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("codex"))
    }
    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func write(_ data: Data, _ path: String, in root: URL) throws {
        let target = root.appendingPathComponent(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func soundFixture(_ root: URL) throws -> Data {
        let original = try json(["hooks": ["Stop": [["matcher": "*", "description": "groupe personnel", "hooks": [
            ["type": "command", "command": "afplay /tmp/fixture.aiff", "async": true],
            ["type": "command", "command": "echo tiers", "timeout": 19]
        ]]]], "permissions": ["deny": ["Bash(sudo *)"]], "statusLine": ["type": "command", "command": "echo statusline"]])
        let parking = try XCTUnwrap(SoundHookEditor.park(in: original))
        try write(parking.updated, ".claude/settings.json", in: root)
        try write(SoundHookEditor.encodeParked(.init(hooks: parking.parked, parkedAt: Date(), committedAt: Date())),
                  ".atoll/parked-sound-hooks.json", in: root)
        try write(json(["enabled": true, "choices": ["taskCompleted": "system:Glass"], "volumes": [:], "future": "conservé"]),
                  ".atoll/sound-settings.json", in: root)
        return original
    }

    func testUpgradeRestoresMixedSoundsAndDenyWithoutTouchingUserData() throws {
        let (root, codex) = try fixture()
        let original = try soundFixture(root)
        try write(RockstarPermissionsEditor.encodeParked(.init(deny: ["Read(.env)"], parkedAt: Date())),
                  ".atoll/rockstar-parked-deny.json", in: root)
        try write(json(["enabled": true, "maxHits": 4, "future": "conservé"]), ".atoll/proactive-recall.json", in: root)
        let protected = [".atoll/memory.db", ".atoll/learning/installed.json", ".atoll/learning/notes/a.md",
                         "codex/config.toml", "codex/skills/user/SKILL.md", ".claude/skills/atoll-useful/scripts/tool.py"]
        for path in protected { try write(Data(("personnel: " + path).utf8), path, in: root) }
        let store = EssentialMigrationStore(home: root, codexHome: codex) { phase in
            if phase == "before-write-restore-sounds" {
                let flag = try self.object(root.appendingPathComponent(".atoll/sound-settings.json"))
                XCTAssertEqual(flag["enabled"] as? Bool, false, "EM-sound-off-before-restore")
            }
        }
        _ = try store.run()
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        expected["permissions"] = ["deny": ["Read(.env)", "Bash(sudo *)"]]
        XCTAssertEqual(try object(root.appendingPathComponent(".claude/settings.json")) as NSDictionary, expected as NSDictionary,
                       "EM-foreign-groups-and-permissions")
        for path in protected { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(("personnel: " + path).utf8), "EM-protected-data") }
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".atoll/parked-sound-hooks.json").path))
        XCTAssertEqual(try object(root.appendingPathComponent(".atoll/proactive-recall.json"))["enabled"] as? Bool, false)
        XCTAssertEqual(try object(root.appendingPathComponent(".atoll/sound-settings.json"))["future"] as? String, "conservé")
        let before = try Data(contentsOf: root.appendingPathComponent(".claude/settings.json"))
        let journal = try fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("state-") }[0]
        let stamp = try fm.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date
        _ = try store.run()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/settings.json")), before, "EM-idempotent")
        XCTAssertEqual(try fm.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date, stamp, "EM-idempotent-journal")
    }

    func testCrashAfterRestorationKeepsParkingAndRetryDoesNotDuplicate() throws {
        let (root, codex) = try fixture()
        let original = try soundFixture(root)
        let crashed = EssentialMigrationStore(home: root, codexHome: codex) { phase in
            if phase == "before-remove-sounds-parking" { throw CocoaError(.userCancelled) }
        }
        XCTAssertThrowsError(try crashed.run())
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".atoll/parked-sound-hooks.json").path), "EM-parking-kept-after-crash")
        _ = try EssentialMigrationStore(home: root, codexHome: codex).run()
        XCTAssertEqual(try object(root.appendingPathComponent(".claude/settings.json")) as NSDictionary,
                       try JSONSerialization.jsonObject(with: original) as? NSDictionary, "EM-retry-no-duplicate")
    }

    func testCorruptParkingPreservesItAndSettingsForRetry() throws {
        let (root, codex) = try fixture()
        try write(Data("{broken".utf8), ".atoll/parked-sound-hooks.json", in: root)
        let original = try json(["model": "fable"])
        try write(original, ".claude/settings.json", in: root)
        XCTAssertThrowsError(try EssentialMigrationStore(home: root, codexHome: codex).run())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/settings.json")), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".atoll/parked-sound-hooks.json")), Data("{broken".utf8))
    }

    func testConcurrentSettingsChangeIsNeverOverwritten() throws {
        let (root, codex) = try fixture()
        let original = try json(["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": BridgePaths.hookCommand,
            "timeout": 86400]]]]]])
        let foreign = try json(["model": "édition concurrente"])
        try write(original, ".claude/settings.json", in: root)
        let store = EssentialMigrationStore(home: root, codexHome: codex) { phase in
            if phase == "before-write-claude-passive" { try self.write(foreign, ".claude/settings.json", in: root) }
        }
        XCTAssertThrowsError(try store.run(), "EM-concurrent-write-refused")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/settings.json")), foreign, "EM-concurrent-write-preserved")
    }

    func testSettingsSymlinkAndIncompleteHooksStaySelective() throws {
        let (root, codex) = try fixture()
        let settings = root.appendingPathComponent(".claude/settings.json")
        try write(json(["hooks": ["PermissionRequest": [["description": "groupe", "hooks": [
            ["type": "command", "command": BridgePaths.hookCommand, "timeout": 86400],
            ["type": "command", "command": "echo tiers", "timeout": 17]
        ]]]], "enabledPlugins": ["foreign@market": true]]), "dotfiles/claude.json", in: root)
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: settings, withDestinationURL: root.appendingPathComponent("dotfiles/claude.json"))
        _ = try EssentialMigrationStore(home: root, codexHome: codex).run()
        XCTAssertNoThrow(try fm.destinationOfSymbolicLink(atPath: settings.path), "EM-symlink-preserved")
        let value = try object(settings)
        let hooks = try XCTUnwrap(value["hooks"] as? [String: Any])
        XCTAssertNil(hooks["Stop"], "EM-removed-event-stays-removed")
        XCTAssertEqual((value["enabledPlugins"] as? [String: Bool])?["foreign@market"], true)
    }

    func testKnownRecallIsArchivedWithResourcesAndCustomRecallIsUntouched() throws {
        let (root, codex) = try fixture()
        try write(Data(RecallSkill.markdown.utf8), ".claude/skills/atoll-recall/SKILL.md", in: root)
        try write(Data("ressource unique".utf8), ".claude/skills/atoll-recall/scripts/unique.py", in: root)
        try write(Data("recall personnalisé".utf8), "codex/skills/atoll-recall/SKILL.md", in: root)
        let store = EssentialMigrationStore(home: root, codexHome: codex)
        let report = try store.run()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".claude/skills/atoll-recall/SKILL.md").path))
        let archive = try XCTUnwrap(fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("recall-claude-") })
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("scripts/unique.py")), Data("ressource unique".utf8), "EM-recall-resource-archive")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/skills/atoll-recall/scripts/unique.py")), Data("ressource unique".utf8))
        XCTAssertEqual(try Data(contentsOf: codex.appendingPathComponent("skills/atoll-recall/SKILL.md")), Data("recall personnalisé".utf8))
    }

    func testCodexReceiptRecognizesOnlyItsOwnedMarkdown() throws {
        let (root, codex) = try fixture()
        try CodexRecallSkill.install(home: codex, helperURL: root.appendingPathComponent("Atoll.app/Contents/Helpers/atoll-bridge"))
        _ = try EssentialMigrationStore(home: root, codexHome: codex).run()
        XCTAssertFalse(fm.fileExists(atPath: codex.appendingPathComponent("skills/atoll-recall/SKILL.md").path))
        XCTAssertTrue(fm.fileExists(atPath: codex.appendingPathComponent("skills/atoll-recall/.atoll-recall.json").path))
    }

    func testUnverifiedRecallArchiveNeverRetiresTheOriginal() throws {
        let (root, codex) = try fixture()
        try write(Data(RecallSkill.markdown.utf8), ".claude/skills/atoll-recall/SKILL.md", in: root)
        let directory = EssentialMigrationStore(home: root, codexHome: codex).directory
        let store = EssentialMigrationStore(home: root, codexHome: codex) { phase in
            if phase == "before-verify-recall-claude" {
                let archive = try XCTUnwrap(self.fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("recall-claude-") })
                try Data("archive tronquée".utf8).write(to: archive.appendingPathComponent("SKILL.md"))
            }
        }
        XCTAssertThrowsError(try store.run(), "EM-unverified-archive-refused")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/skills/atoll-recall/SKILL.md")),
                       Data(RecallSkill.markdown.utf8), "EM-original-recall-preserved")
    }

    func testInvalidSettingsAndJournalRemainRecoverable() throws {
        let (root, codex) = try fixture()
        try write(Data(), ".claude/settings.json", in: root)
        let store = EssentialMigrationStore(home: root, codexHome: codex)
        XCTAssertThrowsError(try store.run())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude/settings.json")), Data())
        try write(json([:]), ".claude/settings.json", in: root)
        _ = try store.run()
        let journal = try XCTUnwrap(fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("state-") })
        try Data("broken".utf8).write(to: journal)
        XCTAssertThrowsError(try store.run())
        XCTAssertEqual(try Data(contentsOf: journal), Data("broken".utf8))
    }

    func testOriginalProducerPreferencesAreNotReplacedByDisabledRetryValues() throws {
        let (root, codex) = try fixture()
        let store = EssentialMigrationStore(home: root, codexHome: codex)
        let original = try json(["soundsEnabled": true, "learningCurationWeekly": true])
        try store.preservePreferences(original)
        try store.preservePreferences(json(["soundsEnabled": false, "learningCurationWeekly": false]))
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("legacy-preferences.json")), original)
    }

    func testNumericAsyncIsActuallyRewrittenToJSONBoolean() throws {
        let (root, codex) = try fixture()
        try write(json(["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": BridgePaths.hookCommand,
            "timeout": 3, "async": 1]]]]]]), ".claude/settings.json", in: root)
        _ = try EssentialMigrationStore(home: root, codexHome: codex).run()
        let canonical = try json(object(root.appendingPathComponent(".claude/settings.json")))
        XCTAssertTrue(try XCTUnwrap(String(data: canonical, encoding: .utf8)).contains("\"async\":true"), "EM-numeric-async-must-be-boolean")
    }

    func testCorruptSoundConfigCannotKeepDenyRulesSuspended() throws {
        let (root, codex) = try fixture()
        _ = try soundFixture(root)
        try write(RockstarPermissionsEditor.encodeParked(.init(deny: ["Read(.env)"], parkedAt: Date())),
                  ".atoll/rockstar-parked-deny.json", in: root)
        try write(Data("broken".utf8), ".atoll/sound-settings.json", in: root)
        XCTAssertThrowsError(try EssentialMigrationStore(home: root, codexHome: codex).run())
        let permissions = try XCTUnwrap(object(root.appendingPathComponent(".claude/settings.json"))["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Read(.env)", "Bash(sudo *)"], "EM-deny-restored-despite-sound-error")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".atoll/parked-sound-hooks.json").path), "EM-sounds-not-restored-with-live-fallback")
    }

    func testCommonMigrationWithUnknownCodexHomeNeverTouchesAnotherAccount() throws {
        let (root, codex) = try fixture()
        try write(json(["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": BridgePaths.hookCommand,
            "timeout": 86400]]]]]]), ".claude/settings.json", in: root)
        try write(json(["enabled": true]), ".atoll/proactive-recall.json", in: root)
        let unrelated = Data("configuration d'un autre compte".utf8)
        try write(unrelated, "hooks.json", in: codex)
        let report = try EssentialMigrationStore(home: root, codexHome: nil).run()
        XCTAssertFalse(report.completedSteps.contains("codex-passive"))
        XCTAssertEqual(try object(root.appendingPathComponent(".atoll/proactive-recall.json"))["enabled"] as? Bool, false)
        let canonical = try json(object(root.appendingPathComponent(".claude/settings.json")))
        XCTAssertTrue(try XCTUnwrap(String(data: canonical, encoding: .utf8)).contains("\"async\":true"))
        XCTAssertEqual(try Data(contentsOf: codex.appendingPathComponent("hooks.json")), unrelated, "EM-unknown-home-no-account-fallback")
    }
}
