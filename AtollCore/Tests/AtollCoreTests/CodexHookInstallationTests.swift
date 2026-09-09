import XCTest
@testable import AtollCore

final class CodexHookInstallationTests: XCTestCase {
    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atoll-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testFirstInstallReinstallBackupAndUninstall() throws {
        try inTemporaryDirectory { root in
            let settings = root.appendingPathComponent("hooks.json")
            let bin = root.appendingPathComponent("bin")
            let original = Data(#"{"description":"personal","hooks":{}}"#.utf8)
            try original.write(to: settings)
            for _ in 0..<2 {
                try CodexHookInstallation.apply(settingsURL: settings, binDirectory: bin,
                                                helperURL: root.appendingPathComponent("Atoll's test.app/helper"), install: true)
            }
            XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("atoll-backup")), original)
            XCTAssertTrue(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: settings)))
            let wrapper = bin.appendingPathComponent("atoll-codex-bridge")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
            XCTAssertTrue(try String(contentsOf: wrapper).contains("Atoll'\\''s test.app"))
            let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try CodexHookInstallation.apply(settingsURL: settings, binDirectory: bin, helperURL: root, install: false)
            XCTAssertFalse(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: settings)))
            XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("atoll-backup")), original)
            // Wrapper deliberately survives so already-running sessions fail open.
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        }
    }

    func testMalformedConfigDoesNotCreateWrapperOrBackup() throws {
        try inTemporaryDirectory { root in
            let settings = root.appendingPathComponent("hooks.json")
            let original = Data("broken json".utf8)
            try original.write(to: settings)
            XCTAssertThrowsError(try CodexHookInstallation.apply(settingsURL: settings,
                binDirectory: root.appendingPathComponent("bin"), helperURL: root, install: true))
            XCTAssertEqual(try Data(contentsOf: settings), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bin").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: settings.appendingPathExtension("atoll-backup").path))
        }
    }

    func testSymlinkIsPreservedAndMissingUninstallIsNoop() throws {
        try inTemporaryDirectory { root in
            let missing = root.appendingPathComponent("missing/hooks.json")
            try CodexHookInstallation.apply(settingsURL: missing, binDirectory: root, helperURL: root, install: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
            let target = root.appendingPathComponent("dotfiles.json")
            try Data("{}".utf8).write(to: target)
            let link = root.appendingPathComponent("hooks.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try CodexHookInstallation.apply(settingsURL: link, binDirectory: root.appendingPathComponent("bin"), helperURL: root, install: true)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            XCTAssertTrue(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: target)))
        }
    }
}

/// MESURÉ le 2026-09-09 : un hook synchrone est ANNONCÉ par Codex dans sa
/// sortie (« hook: PreToolUse » / « … Completed »). Dix événements synchrones
/// = dix lignes de bruit par tour, infligées en permanence — la règle n° 1 du
/// projet (rien de ce qu'Atoll installe ne doit gêner le CLI) tranche contre.
extension CodexHookInstallationTests {

    private func handlers(in data: Data) throws -> [String: [String: Any]] {
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var result: [String: [String: Any]] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]],
                  let handler = (groups.first?["hooks"] as? [[String: Any]])?.first else { continue }
            result[event] = handler
        }
        return result
    }

    func testObservationHooksAreAsync() throws {
        let data = try CodexHookSettingsEditor.edit(nil, install: true)
        let all = try handlers(in: data)
        for event in ["PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart",
                      "Interrupt", "PreCompact", "PostCompact"] {
            XCTAssertEqual(all[event]?["async"] as? Bool, true,
                           "\(event) synchrone : Codex l'annoncera dans sa sortie")
        }
    }

    /// `Stop` reste synchrone À DESSEIN : en async il est fire-and-forget et le
    /// process se termine avant que le hook n'ait écrit — MESURÉ, l'événement
    /// est perdu, et l'îlot laisserait la session « en cours » 15 minutes.
    func testStopStaysSynchronousSoTheEndOfTurnIsNeverLost() throws {
        let all = try handlers(in: try CodexHookSettingsEditor.edit(nil, install: true))
        XCTAssertNil(all["Stop"]?["async"], "Stop en async ⇒ fin de tour perdue")
        XCTAssertNil(all["SessionEnd"]?["async"])
    }

    /// ⚠️ UN HOOK `async` NE PEUT PAS DÉCIDER. En laisser un sur
    /// `PermissionRequest`, c'est faire afficher à Codex son invite native en
    /// même temps que la carte d'Atoll : deux interfaces concurrentes pour une
    /// seule décision, pire que de ne rien faire.
    func testPermissionRequestIsSynchronousAndCanWaitForAHuman() throws {
        let all = try handlers(in: try CodexHookSettingsEditor.edit(nil, install: true))
        let handler = try XCTUnwrap(all["PermissionRequest"])
        XCTAssertNil(handler["async"], "async ⇒ Codex n'attend pas et affiche sa propre invite")
        // 3 s suffisent à observer ; décider demande une présence humaine.
        XCTAssertEqual(handler["timeout"] as? Int, 600)
        XCTAssertEqual(handler["statusMessage"] as? String, "Waiting for approval in Atoll")
    }

    /// Le helper doit s'arrêter AVANT Codex, sinon Codex tue le hook et affiche
    /// un échec de timeout là où une abstention doit rendre la main en silence.
    func testHelperDeadlineLeavesARealMarginBeforeCodexKillsTheHook() {
        XCTAssertLessThan(CodexPermissionTiming.helperDeadlineSeconds,
                          CodexPermissionTiming.codexTimeoutSeconds)
        XCTAssertGreaterThanOrEqual(CodexPermissionTiming.marginSeconds, 20)
    }

    /// Les autres hooks gardent un timeout court : ils n'attendent personne.
    func testOnlyPermissionRequestGetsTheLongTimeout() throws {
        let all = try handlers(in: try CodexHookSettingsEditor.edit(nil, install: true))
        for (event, handler) in all where event != "PermissionRequest" {
            XCTAssertEqual(handler["timeout"] as? Int, 3, event)
            XCTAssertNil(handler["statusMessage"], event)
        }
    }

    func testEveryEventStillCarriesTheCommandAndTimeout() throws {
        let all = try handlers(in: try CodexHookSettingsEditor.edit(nil, install: true))
        XCTAssertEqual(all.count, CodexHookEvent.Kind.allCases.count)
        for (event, handler) in all {
            XCTAssertEqual(handler["command"] as? String, CodexHookSettingsEditor.command, event)
            XCTAssertNotNil(handler["timeout"] as? Int, event)
        }
    }

    /// Le retrait doit rester complet quelle que soit la forme du handler.
    func testUninstallRemovesAsyncHandlersToo() throws {
        let installed = try CodexHookSettingsEditor.edit(nil, install: true)
        XCTAssertTrue(CodexHookSettingsEditor.isInstalled(installed))
        let removed = try CodexHookSettingsEditor.edit(installed, install: false)
        XCTAssertFalse(CodexHookSettingsEditor.isInstalled(removed))
        XCTAssertFalse(String(decoding: removed, as: UTF8.self).contains("atoll-codex-bridge"))
    }
}
