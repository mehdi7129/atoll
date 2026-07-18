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
        XCTAssertEqual(Set(hooks.keys), Set(HookSettingsEditor.managedEvents))

        // Chaque entrée gérée est async avec timeout court (fail-open).
        let stops = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(stops.first?["hooks"] as? [[String: Any]]).first!
        XCTAssertEqual(inner["command"] as? String, command)
        XCTAssertEqual(inner["async"] as? Bool, true)
        XCTAssertEqual(inner["timeout"] as? Int, 10)
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
            "PermissionRequest": [ { "hooks": [ { "type": "command", "command": "user-perm" } ] } ],
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
        XCTAssertNotNil(hooks["PermissionRequest"], "événement non géré préservé")
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
}
