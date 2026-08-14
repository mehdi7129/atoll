import XCTest
@testable import AtollCore

final class HookSettingsEditorTests: XCTestCase {

    private let command = "\"$HOME/.atoll/bin/atoll-bridge\""

    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Réplique fidèle de la structure du settings.json réel de l'utilisateur :
    /// hooks GSD + sons afplay + statusline + permissions. Rien ne doit être perdu.
    private var userSettings: Data {
        let json = """
        {
          "permissions": { "deny": ["Bash(rm -rf *)"], "defaultMode": "bypassPermissions" },
          "model": "claude-fable-5[1m]",
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "node \\"/Users/x/.claude/hooks/gsd-check-update.js\\"" } ] }
            ],
            "PostToolUse": [
              { "matcher": "Bash|Edit|Write|MultiEdit|Agent|Task",
                "hooks": [ { "type": "command", "command": "node \\"/Users/x/.claude/hooks/gsd-context-monitor.js\\"", "timeout": 10 } ] }
            ],
            "Stop": [
              { "matcher": "", "hooks": [ { "type": "command", "command": "afplay -v 0.1 '/Users/x/.claude/song/finish.mp3'" } ] }
            ]
          },
          "statusLine": { "type": "command", "command": "bun /Users/x/.claude/scripts/statusline/src/index.ts", "padding": 0 },
          "language": "français"
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Installation

    func testInstallIntoEmptyFile() throws {
        let result = try HookSettingsEditor.install(into: nil, command: command)
        XCTAssertTrue(HookSettingsEditor.isInstalled(in: result))

        let settings = try parse(result)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookSettingsEditor.managedEvents.map(\.name)))

        // Les événements d'état sont async avec timeout court (fail-open).
        let stops = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(stops.first?["hooks"] as? [[String: Any]]).first!
        XCTAssertEqual(inner["command"] as? String, command)
        XCTAssertEqual(inner["async"] as? Bool, true)
        XCTAssertEqual(inner["timeout"] as? Int, 10)

        // PermissionRequest est BLOQUANT : matcher *, timeout 24 h, pas d'async.
        let permissions = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permissions.first?["matcher"] as? String, "*")
        let permissionHook = try XCTUnwrap(permissions.first?["hooks"] as? [[String: Any]]).first!
        XCTAssertEqual(permissionHook["timeout"] as? Int, 86_400)
        XCTAssertNil(permissionHook["async"])
    }

    func testInstallPreservesUserHooksAndSettings() throws {
        let result = try HookSettingsEditor.install(into: userSettings, command: command)
        let settings = try parse(result)

        // Les clés hors hooks sont intactes.
        XCTAssertEqual(settings["model"] as? String, "claude-fable-5[1m]")
        XCTAssertEqual(settings["language"] as? String, "français")
        XCTAssertNotNil(settings["statusLine"])
        XCTAssertNotNil(settings["permissions"])

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])

        // Les hooks GSD/afplay de l'utilisateur sont toujours là…
        let stops = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let stopCommands = stops.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(stopCommands.contains { $0.contains("afplay") })
        // …et les nôtres ajoutés à côté.
        XCTAssertTrue(stopCommands.contains(command))

        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertTrue(postToolUse.contains { ($0["matcher"] as? String) == "Bash|Edit|Write|MultiEdit|Agent|Task" })
    }

    func testInstallIsIdempotent() throws {
        let once = try HookSettingsEditor.install(into: userSettings, command: command)
        let twice = try HookSettingsEditor.install(into: once, command: command)
        XCTAssertEqual(once, twice, "double installation = même fichier, pas de doublons")
    }

    // MARK: - Désinstallation

    func testUninstallRestoresUserSettingsExactly() throws {
        let installed = try HookSettingsEditor.install(into: userSettings, command: command)
        let uninstalled = try HookSettingsEditor.uninstall(from: installed)

        XCTAssertFalse(HookSettingsEditor.isInstalled(in: uninstalled))

        // install→uninstall doit être une identité parfaite sur le contenu :
        // on compare au fichier d'origine re-sérialisé par le même chemin.
        let roundTripped = try parse(uninstalled) as NSDictionary
        let original = try parse(try JSONSerialization.data(
            withJSONObject: try parse(userSettings),
            options: [.prettyPrinted, .sortedKeys]
        )) as NSDictionary
        XCTAssertEqual(roundTripped, original,
                       "uninstall doit restituer exactement la config d'origine")
    }

    func testUninstallLeavesMalformedAndUnmanagedEventsUntouched() throws {
        // Événements avec valeurs non conformes (dict au lieu de tableau, tableau
        // mixte) et un événement jamais géré par Atoll : uninstall ne doit PAS
        // y toucher, même pour retirer ses propres entrées ailleurs.
        let weird = """
        {
          "hooks": {
            "Stop": { "type": "command", "command": "afplay x.mp3" },
            "PreToolUse": [ { "hooks": [ { "type": "command", "command": "user-cmd" } ] }, "note" ],
            "Elicitation": [ { "hooks": [ { "type": "command", "command": "user-elicit" } ] } ],
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "\\"$HOME/.atoll/bin/atoll-bridge\\"" } ] }
            ]
          }
        }
        """
        let result = try HookSettingsEditor.uninstall(from: Data(weird.utf8))
        let hooks = try XCTUnwrap(try parse(result)["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"] as? [String: Any], "valeur dict préservée telle quelle")
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 2, "tableau mixte préservé")
        XCTAssertNotNil(hooks["Elicitation"], "événement non géré préservé")
        XCTAssertNil(hooks["SessionStart"], "notre entrée retirée, clé vide supprimée")
    }

    func testInstallRefusesMalformedManagedEvent() {
        let malformed = Data("""
        { "hooks": { "Stop": { "pas": "un tableau" } } }
        """.utf8)
        XCTAssertThrowsError(try HookSettingsEditor.install(into: malformed, command: command))
    }

    func testMarkerRequiresWrapperPath() throws {
        // Une commande utilisateur mentionnant « atoll-bridge » sans le chemin
        // du wrapper ne doit jamais être considérée comme gérée par Atoll.
        let tricky = """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo atoll-bridge est cool" } ] } ] } }
        """
        let result = try HookSettingsEditor.uninstall(from: Data(tricky.utf8))
        let hooks = try XCTUnwrap(try parse(result)["hooks"] as? [String: Any])
        let stops = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stops.count, 1, "le hook utilisateur doit survivre")
    }

    func testUninstallFromEmptyIsHarmless() throws {
        let result = try HookSettingsEditor.uninstall(from: nil)
        XCTAssertEqual(try parse(result).count, 0)
    }

    // MARK: - Sécurité anti-corruption

    func testRefusesUnparseableFile() {
        let jsonc = Data("{ // commentaire JSONC\n \"hooks\": {} }".utf8)
        XCTAssertThrowsError(try HookSettingsEditor.install(into: jsonc, command: command)) { error in
            XCTAssertEqual(error as? HookSettingsEditor.EditorError, .unparseableSettings)
        }
        XCTAssertThrowsError(try HookSettingsEditor.uninstall(from: jsonc))
        XCTAssertFalse(HookSettingsEditor.isInstalled(in: jsonc))
    }

    func testIsInstalledRequiresAllEvents() throws {
        // Installation partielle (simulée en retirant un événement) → pas "installé".
        let installed = try HookSettingsEditor.install(into: nil, command: command)
        var settings = try parse(installed)
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks["SessionEnd"] = nil
        settings["hooks"] = hooks
        let partial = try JSONSerialization.data(withJSONObject: settings)
        XCTAssertFalse(HookSettingsEditor.isInstalled(in: partial))
    }

    // MARK: - Recall proactif (UserPromptSubmit bloquant, opt-in)

    /// Le premier hook géré d'un événement, pour inspecter son mode.
    private func managedHook(_ data: Data, event: String) throws -> [String: Any] {
        let settings = try parse(data)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
        let inner = try XCTUnwrap(entries.compactMap { $0["hooks"] as? [[String: Any]] }.first)
        return try XCTUnwrap(inner.first)
    }

    func testProactiveRecallMakesUserPromptSubmitBlocking() throws {
        // OFF (défaut) : async, aucune latence ajoutée au CLI.
        let plain = try HookSettingsEditor.install(into: nil, command: command)
        let plainHook = try managedHook(plain, event: "UserPromptSubmit")
        XCTAssertEqual(plainHook["async"] as? Bool, true)
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: plain))

        // ON : bloquant (pas de clé async) et timeout court — sinon la sortie
        // du hook (additionalContext) ne serait jamais lue par le CLI.
        let proactive = try HookSettingsEditor.install(into: nil, command: command,
                                                      proactiveRecall: true)
        let hook = try managedHook(proactive, event: "UserPromptSubmit")
        XCTAssertNil(hook["async"])
        XCTAssertEqual(hook["timeout"] as? Int, 5)
        XCTAssertTrue(HookSettingsEditor.installedProactiveRecall(in: proactive))

        // Les autres événements d'état restent async dans les deux modes.
        XCTAssertEqual(try managedHook(proactive, event: "Stop")["async"] as? Bool, true)
        // Et PermissionRequest reste bloquant avec son timeout de 24 h.
        let permission = try managedHook(proactive, event: "PermissionRequest")
        XCTAssertNil(permission["async"])
        XCTAssertEqual(permission["timeout"] as? Int, 86_400)
    }

    func testProactiveRecallModeIsReversibleAndInstallStaysDetected() throws {
        let proactive = try HookSettingsEditor.install(into: nil, command: command,
                                                      proactiveRecall: true)
        // isInstalled est insensible au mode : les deux jeux couvrent les
        // mêmes événements (c'est `installedProactiveRecall` qui distingue).
        XCTAssertTrue(HookSettingsEditor.isInstalled(in: proactive))

        let back = try HookSettingsEditor.install(into: proactive, command: command)
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: back))
        XCTAssertEqual(try managedHook(back, event: "UserPromptSubmit")["async"] as? Bool, true)
        // Pas d'empilement : une seule entrée gérée après aller-retour.
        let settings = try parse(back)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["UserPromptSubmit"] as? [[String: Any]])?.count, 1)
    }

    func testInstalledProactiveRecallIsFalseWithoutHooks() {
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: nil))
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: Data("{}".utf8)))
        // Un hook UTILISATEUR bloquant sur UserPromptSubmit ne doit pas être
        // pris pour le nôtre (marquage par le chemin du wrapper).
        let foreign = Data("""
        {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"my-own-hook"}]}]}}
        """.utf8)
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: foreign))
    }
}
