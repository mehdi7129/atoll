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
        // La marge doit rester RÉELLE : un helper qui s'arrêterait après Codex
        // ferait exactement ce que ces deux constantes existent pour empêcher.
        // (Elle se calcule ici plutôt que d'exister comme propriété du type :
        // celle-ci n'avait aucun appelant hors tests, et `check-docs` la
        // signalait comme morte.)
        XCTAssertGreaterThanOrEqual(
            CodexPermissionTiming.codexTimeoutSeconds - CodexPermissionTiming.helperDeadlineSeconds, 20)
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

/// LA MIGRATION DU LANCEUR. Deux pannes réelles, aucune visible :
/// un correctif du wrapper qui n'atteint jamais un poste déjà installé, et
/// une app déplacée qui laisse l'intégration morte en silence.
final class CodexWrapperRefreshTests: XCTestCase {

    private func withRoot(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atoll-wrapper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("hooks.json")
        let bin = root.appendingPathComponent("bin")
        let helper = root.appendingPathComponent("Helpers/atoll-bridge")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try body(settings, bin, helper)
    }

    private func install(_ settings: URL, _ bin: URL, _ helper: URL) throws {
        try CodexHookInstallation.apply(settingsURL: settings, binDirectory: bin,
                                        helperURL: helper, install: true)
    }

    private func wrapper(_ bin: URL) -> String? {
        try? String(contentsOf: CodexHookInstallation.wrapperURL(binDirectory: bin), encoding: .utf8)
    }

    /// ⚠️ LE POINT LE PLUS IMPORTANT : ne rien poser chez quelqu'un qui n'a
    /// jamais demandé l'intégration Codex.
    func testNothingIsWrittenWhenHooksAreNotInstalled() throws {
        try withRoot { settings, bin, helper in
            XCTAssertEqual(try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: helper), .notInstalled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bin.path))
        }
    }

    /// Idempotence : le second lancement de l'app n'écrit RIEN.
    func testASecondPassWritesNothing() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            XCTAssertEqual(try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: helper), .upToDate)
        }
    }

    /// PANNE N° 1 — un wrapper d'une version précédente (avec `exec`) est
    /// remplacé. Sans cette migration, la correction du superviseur n'aurait
    /// jamais atteint un poste déjà installé.
    func testAnOutdatedWrapperIsRewritten() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            let url = CodexHookInstallation.wrapperURL(binDirectory: bin)
            let legacy = "#!/bin/sh\nBIN='\(helper.path)'\n[ -x \"$BIN\" ] && exec \"$BIN\" codex-hook\nexit 0\n"
            try legacy.write(to: url, atomically: true, encoding: .utf8)

            let result = try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: helper)
            XCTAssertEqual(result, .rewritten(previous: legacy))
            // Le superviseur est bien là : le worker n'est PAS `exec`uté.
            // ⚠️ ON TESTE `exec "$BIN"`, PAS `exec` : le script contient
            // légitimement `exec 3<&0` (la duplication de stdin). Chercher la
            // sous-chaîne large faisait rougir ce test pour la bonne propriété
            // — mais sur le mauvais motif.
            let now = try XCTUnwrap(wrapper(bin))
            XCTAssertFalse(now.contains("exec \"$BIN\""), "le worker remplace encore le shell")
            XCTAssertTrue(now.contains("\"$BIN\" codex-hook"))
        }
    }

    /// PANNE N° 2 — l'app a été déplacée. Le wrapper pointait vers un binaire
    /// disparu : sa garde `[ -x "$BIN" ] || exit 0` faisait exactement son
    /// travail, et l'intégration était morte SANS UN MESSAGE.
    func testAMovedAppRepointsTheWrapper() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            let moved = helper.deletingLastPathComponent()
                .appendingPathComponent("../Applications/atoll-bridge")
            let result = try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: moved)
            guard case .rewritten = result else { return XCTFail("chemin non corrigé : \(result)") }
            let now = try XCTUnwrap(wrapper(bin))
            XCTAssertTrue(now.contains(moved.resolvingSymlinksInPath().path))
            XCTAssertFalse(now.contains("Helpers/atoll-bridge"), "ancien chemin conservé")
        }
    }

    /// Un wrapper au bon contenu mais qui a PERDU son bit exécutable est
    /// inerte : Codex ne peut pas le lancer. La comparaison d'octets seule ne
    /// le verrait pas.
    func testANonExecutableWrapperIsRepaired() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            let url = CodexHookInstallation.wrapperURL(binDirectory: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            guard case .rewritten = try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: helper) else {
                return XCTFail("wrapper non exécutable laissé en place")
            }
            let mode = try XCTUnwrap((try FileManager.default
                .attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)
            XCTAssertNotEqual(mode.int16Value & 0o111, 0)
        }
    }

    /// Un wrapper carrément ABSENT (nettoyage de `~/.atoll`, restauration
    /// partielle) est reposé, pas ignoré.
    func testAMissingWrapperIsRecreated() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            try FileManager.default.removeItem(at: CodexHookInstallation.wrapperURL(binDirectory: bin))
            XCTAssertEqual(try CodexHookInstallation.refreshWrapper(
                settingsURL: settings, binDirectory: bin, helperURL: helper), .rewritten(previous: nil))
            XCTAssertNotNil(wrapper(bin))
        }
    }

    /// Ce que la migration écrit doit être EXACTEMENT ce que l'installation
    /// écrit — sinon la première passe après chaque installation réécrirait le
    /// fichier, et l'idempotence serait un mensonge.
    func testInstallAndRefreshAgreeToTheByte() throws {
        try withRoot { settings, bin, helper in
            try install(settings, bin, helper)
            XCTAssertEqual(wrapper(bin), CodexHookInstallation.wrapperScript(helperURL: helper))
        }
    }

    /// LES TROIS PROPRIÉTÉS DU SUPERVISEUR, mesurées sur pièces le 2026-09-09
    /// puis figées ici. Chacune correspond à un essai qui a ÉCHOUÉ en mesure :
    /// l'avant-plan (le shell annonce la mort du worker sur stderr) et le `&`
    /// nu (le worker perd stdin et ne lit plus le payload du hook).
    func testTheSupervisorShapeIsTheOneThatWasMeasured() {
        let script = CodexHookInstallation.wrapperScript(
            helperURL: URL(fileURLWithPath: "/opt/atoll/atoll-bridge"))
        // 1. Le worker n'est jamais `exec`uté : le shell doit survivre pour
        //    convertir sa mort en abstention.
        XCTAssertFalse(script.contains("exec \"$BIN\""))
        // 2. Stdin lui est rendu EXPLICITEMENT — sans quoi un job d'arrière-plan
        //    lit /dev/null, et le hook n'a plus de payload.
        XCTAssertTrue(script.contains("exec 3<&0"))
        XCTAssertTrue(script.contains("<&3 &"))
        // 3. Seul le rapport de terminaison du shell est étouffé, jamais le
        //    stderr du worker : la redirection porte sur `wait`.
        XCTAssertTrue(script.contains("wait $! 2>/dev/null"))
        // 4. Et la sortie est TOUJOURS 0 : c'est ce qui fait l'abstention.
        XCTAssertTrue(script.hasSuffix("exit 0\n"))
    }

    /// Une apostrophe dans le chemin du bundle ne doit pas casser le script —
    /// ni, pire, y injecter une commande.
    func testAQuoteInThePathIsEscaped() {
        let script = CodexHookInstallation.wrapperScript(
            helperURL: URL(fileURLWithPath: "/tmp/l'app; touch /tmp/pwned/atoll-bridge"))
        XCTAssertFalse(script.contains("BIN='/tmp/l'app"), "apostrophe non échappée")
        XCTAssertTrue(script.contains("'\\''"))
    }
}
