import XCTest
@testable import AtollCore

final class CodexSetupTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atoll-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testMigrationRepairsOldPermissionWithoutChangingForeignHooksOrTrust() throws {
        try temporary { root in
            let settings = root.appendingPathComponent("hooks.json")
            let bin = root.appendingPathComponent("bin")
            let original = try JSONSerialization.data(withJSONObject: [
                "description": "personnelle", "hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [
                    ["command": CodexHookSettingsEditor.command, "async": true, "timeout": 3],
                    ["command": "echo personal", "enabled": false, "timeout": 17]
                ]]]]
            ])
            try original.write(to: settings)
            let config = root.appendingPathComponent("config.toml")
            try Data("trust = 'untouched'".utf8).write(to: config)
            XCTAssertTrue(try CodexHookInstallation.migrateIfInstalled(settingsURL: settings,
                binDirectory: bin, helperURL: root.appendingPathComponent("l'app déplacée/helper")))
            let result = try Data(contentsOf: settings)
            let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("hooks.json.atoll-migration-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
            XCTAssertFalse(CodexHookSettingsEditor.needsMigration(result))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
            let foreign = try XCTUnwrap(hooks["PermissionRequest"]?.first)
            XCTAssertEqual(foreign["matcher"] as? String, "Bash")
            let handlers = try XCTUnwrap(foreign["hooks"] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 2)
            XCTAssertEqual(handlers[0]["timeout"] as? Int, 600)
            let handler = handlers[1]
            XCTAssertEqual(handler["command"] as? String, "echo personal")
            XCTAssertEqual(handler["enabled"] as? Bool, false)
            XCTAssertEqual(try String(contentsOf: config), "trust = 'untouched'")
            let wrapper = CodexHookInstallation.wrapperURL(binDirectory: bin)
            let before = try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let wrapperBefore = try wrapper.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            XCTAssertFalse(try CodexHookInstallation.migrateIfInstalled(settingsURL: settings,
                binDirectory: bin, helperURL: root.appendingPathComponent("l'app déplacée/helper")))
            XCTAssertEqual(try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
            XCTAssertEqual(try wrapper.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, wrapperBefore)
        }
    }

    func testNoInstallOnEmptyHomeAndCorruptFileRefusesAllWrites() throws {
        try temporary { root in
            let settings = root.appendingPathComponent("hooks.json"), bin = root.appendingPathComponent("bin")
            XCTAssertFalse(try CodexHookInstallation.migrateIfInstalled(settingsURL: settings, binDirectory: bin, helperURL: root))
            for bad in [Data(), Data("{bad".utf8)] {
                try bad.write(to: settings)
                XCTAssertThrowsError(try CodexHookInstallation.migrateIfInstalled(settingsURL: settings, binDirectory: bin, helperURL: root))
                XCTAssertEqual(try Data(contentsOf: settings), bad)
                XCTAssertFalse(FileManager.default.fileExists(atPath: bin.path))
            }
        }
    }

    func testNumericAsyncIsMigratedToJSONBoolean() throws {
        var raw = String(decoding: try CodexHookSettingsEditor.edit(nil, install: true), as: UTF8.self)
        raw = raw.replacingOccurrences(of: "\"async\" : true", with: "\"async\" : 1")
        let data = Data(raw.utf8)
        XCTAssertTrue(CodexHookSettingsEditor.needsMigration(data))
        XCTAssertFalse(CodexHookSettingsEditor.sameJSON(data, try CodexHookSettingsEditor.edit(data, install: true)))
    }

    func testMigrationPreservesRemovedEventsCustomTimeoutAndFormatting() throws {
        try temporary { root in
            let settings = root.appendingPathComponent("hooks.json")
            var json = try JSONSerialization.jsonObject(with: CodexHookSettingsEditor.edit(nil, install: true)) as! [String: Any]
            var hooks = json["hooks"] as! [String: [[String: Any]]]
            hooks.removeValue(forKey: "Stop")
            var group = hooks["PermissionRequest"]![0]
            var handlers = group["hooks"] as! [[String: Any]]
            handlers[0]["timeout"] = 999
            handlers[0]["statusMessage"] = "Mon message"
            group["hooks"] = handlers
            hooks["PermissionRequest"] = [group]
            json["hooks"] = hooks
            let original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try original.write(to: settings)
            let before = try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            XCTAssertFalse(CodexHookSettingsEditor.needsMigration(original))
            XCTAssertFalse(try CodexHookInstallation.migrateIfInstalled(settingsURL: settings,
                binDirectory: root.appendingPathComponent("bin"), helperURL: root.appendingPathComponent("helper")))
            XCTAssertEqual(try Data(contentsOf: settings), original)
            XCTAssertEqual(try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/atoll-codex-bridge").path))
        }
    }

    func testMigrationPreservesShortTimeoutWhenHandlerIsCustomized() throws {
        for customization: [String: Any] in [
            ["statusMessage": "Mon attente courte"], ["async": false], ["customFlag": true]
        ] {
            var handler: [String: Any] = ["type": "command", "command": CodexHookSettingsEditor.command,
                                          "timeout": 3]
            handler.merge(customization) { _, new in new }
            let original = try JSONSerialization.data(withJSONObject: [
                "hooks": ["PermissionRequest": [["hooks": [handler]]]]
            ])
            XCTAssertFalse(CodexHookSettingsEditor.needsMigration(original), "\(customization)")
            XCTAssertTrue(CodexHookSettingsEditor.sameJSON(original, try CodexHookSettingsEditor.migrate(original)))
        }
    }

    func testHomeSelectionPrioritySymlinkIdempotenceAndInvalidSelection() throws {
        try temporary { root in
            let actual = root.appendingPathComponent("avec espaces")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("lien")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
            let selection = root.appendingPathComponent("selection.json")
            try CodexPaths.selectHome(link.path, selectionURL: selection)
            let chosen = try CodexPaths.readSelection(at: selection)
            XCTAssertEqual(chosen, actual.resolvingSymlinksInPath().path)
            XCTAssertEqual(CodexPaths.resolveHome(configuredPath: chosen,
                environment: ["CODEX_HOME": "/wrong"], userHome: root).path, chosen)
            let date = try selection.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try CodexPaths.selectHome(link.path, selectionURL: selection)
            XCTAssertEqual(try selection.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
            XCTAssertThrowsError(try CodexPaths.selectHome("relative", selectionURL: selection))
            for bad in ["", "{}", "{\"home\":\"relative\"}"] {
                try Data(bad.utf8).write(to: selection)
                XCTAssertThrowsError(try CodexPaths.readSelection(at: selection))
            }
            try CodexPaths.selectHome(nil, selectionURL: selection)
            XCTAssertNil(try CodexPaths.readSelection(at: selection))
            try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: root.appendingPathComponent("absent"))
            XCTAssertThrowsError(try CodexPaths.readSelection(at: selection))
            try CodexPaths.selectHome(nil, selectionURL: selection)
            XCTAssertNil(try CodexPaths.readSelection(at: selection))
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: selection.path))
        }
    }

    func testTrustDisabledAndObsoleteAreDifferentFromPresent() throws {
        let base: [String: Any] = ["command": CodexHookSettingsEditor.command,
            "eventName": "permissionRequest", "async": false, "timeoutSec": 600,
            "statusMessage": "Waiting for approval in Atoll", "enabled": true, "trustStatus": "trusted"]
        func diagnostic(_ edits: [String: Any]) throws -> CodexHookDiagnostics {
            var hook = base; hook.merge(edits, uniquingKeysWith: { _, new in new })
            let data = try JSONSerialization.data(withJSONObject: ["data": [["hooks": [hook], "errors": []]]])
            return try XCTUnwrap(CodexHookDiagnostics(data: data))
        }
        XCTAssertEqual(try diagnostic([:]).untrustedCount, 0)
        XCTAssertEqual(try diagnostic(["trustStatus": "modified"]).untrustedCount, 1)
        XCTAssertEqual(try diagnostic(["enabled": false]).disabledCount, 1)
        XCTAssertEqual(try diagnostic(["async": true, "timeoutSec": 3]).obsoleteCount, 1)
    }

    func testActualBashPatchAndMCPPermissionFixturesRemainComplete() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["permission-bash", "permission-apply-patch", "permission-mcp"] {
            let data = try Data(contentsOf: repo.appendingPathComponent("docs/audit-support/2026-09-10/\(name).json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let permission = try XCTUnwrap(CodexPermissionRequest(payload: object))
            let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(permission.details.utf8)) as? NSDictionary)
            XCTAssertEqual(rendered, object as NSDictionary)
        }
    }

    func testPartialTrustNamesOnlyTheHooksThatNeedReview() throws {
        let hooks: [[String: Any]] = CodexHookEvent.Kind.allCases.map { kind in
            ["command": CodexHookSettingsEditor.command,
             "eventName": kind.rawValue.prefix(1).lowercased() + kind.rawValue.dropFirst(),
             "async": !CodexHookSettingsEditor.synchronousEvents.contains(kind),
             "timeoutSec": kind == .permissionRequest ? 600 : 3,
             "statusMessage": kind == .permissionRequest ? CodexHookSettingsEditor.permissionStatusMessage : "",
             "enabled": true,
             "trustStatus": [.subagentStart, .subagentStop].contains(kind) ? "untrusted" : "trusted"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [["hooks": hooks, "errors": []]]])
        let diagnostic = try XCTUnwrap(CodexHookDiagnostics(data: data))
        XCTAssertEqual(diagnostic.managedCount, 12)
        XCTAssertEqual(diagnostic.activeCount, 10)
        XCTAssertEqual(diagnostic.untrustedEventNames, ["SubagentStart", "SubagentStop"])
        XCTAssertEqual(diagnostic.summary, "10/12 hooks actifs. À approuver dans /hooks : SubagentStart, SubagentStop.")
    }
}
