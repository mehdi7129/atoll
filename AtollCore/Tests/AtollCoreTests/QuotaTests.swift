import XCTest
@testable import AtollCore

final class QuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_400_000)

    func testParsesRealStatuslinePayload() throws {
        // Payload réel capturé sur cette machine (Claude Code 2.1.214).
        let json = """
        {
          "session_id": "abc-123",
          "model": { "id": "claude-opus-4-8", "display_name": "Opus 4.8" },
          "context_window": { "used_percentage": 45 },
          "cost": { "total_cost_usd": 278.51 },
          "rate_limits": {
            "five_hour": { "used_percentage": 54, "resets_at": 1784423400 },
            "seven_day": { "used_percentage": 31, "resets_at": 1784426400 }
          }
        }
        """
        let payload = try XCTUnwrap(StatusLinePayload(data: Data(json.utf8), now: now))
        XCTAssertEqual(payload.sessionID, "abc-123")
        XCTAssertEqual(payload.usage.modelDisplayName, "Opus 4.8")
        XCTAssertEqual(payload.usage.contextUsedFraction ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(payload.usage.costUSD ?? 0, 278.51, accuracy: 0.001)

        let quota = try XCTUnwrap(payload.quota)
        XCTAssertEqual(quota.fiveHour.usedFraction, 0.54, accuracy: 0.001)
        XCTAssertEqual(quota.sevenDay.usedFraction, 0.31, accuracy: 0.001)
        XCTAssertEqual(quota.fiveHour.resetsAt, Date(timeIntervalSince1970: 1784423400))
    }

    func testRejectsExpiredFiveHourWindow() throws {
        // Fenêtre 5h déjà réinitialisée (resets_at PASSÉ) : une session inactive
        // renvoie son cache d'avant reset — used% périmé à ignorer (sinon il
        // écrase la vraie valeur, bug « 5h 97% » figé).
        let past = now.timeIntervalSince1970 - 60
        let json = """
        { "session_id": "x", "rate_limits": {
            "five_hour": { "used_percentage": 97, "resets_at": \(Int(past)) },
            "seven_day": { "used_percentage": 27, "resets_at": \(Int(now.timeIntervalSince1970 + 400000)) }
        } }
        """
        let payload = try XCTUnwrap(StatusLinePayload(data: Data(json.utf8), now: now))
        XCTAssertNil(payload.quota, "un quota dont la fenêtre 5h est expirée est périmé")
    }

    func testAcceptsFreshWindowAfterReset() throws {
        // Après reset : nouvelle fenêtre, resets_at dans le FUTUR, used% bas.
        let future = Int(now.timeIntervalSince1970 + 17000)
        let json = """
        { "rate_limits": {
            "five_hour": { "used_percentage": 2, "resets_at": \(future) },
            "seven_day": { "used_percentage": 27, "resets_at": \(future) }
        } }
        """
        let payload = try XCTUnwrap(StatusLinePayload(data: Data(json.utf8), now: now))
        let quota = try XCTUnwrap(payload.quota)
        XCTAssertEqual(quota.fiveHour.usedFraction, 0.02, accuracy: 0.001)
    }

    func testMissingRateLimitsYieldsNilQuotaButKeepsUsage() throws {
        let json = """
        { "session_id": "x", "model": { "display_name": "Fable 5" }, "context_window": { "used_percentage": 12 } }
        """
        let payload = try XCTUnwrap(StatusLinePayload(data: Data(json.utf8), now: now))
        XCTAssertNil(payload.quota)
        XCTAssertEqual(payload.usage.modelDisplayName, "Fable 5")
        XCTAssertEqual(payload.usage.contextUsedFraction ?? 0, 0.12, accuracy: 0.001)
    }

    func testPartialRateLimitsIgnored() throws {
        // five_hour seul → pas de snapshot complet (on veut les deux fenêtres).
        let json = """
        { "session_id": "x", "rate_limits": { "five_hour": { "used_percentage": 20, "resets_at": 1784423400 } } }
        """
        let payload = try XCTUnwrap(StatusLinePayload(data: Data(json.utf8), now: now))
        XCTAssertNil(payload.quota)
    }

    func testRejectsGarbage() {
        XCTAssertNil(StatusLinePayload(data: Data("pas du json".utf8), now: now))
        XCTAssertNil(StatusLinePayload(data: Data("[1,2]".utf8), now: now))
    }

    func testFractionsClamped() {
        let rl = RateLimit(usedFraction: 1.8, resetsAt: nil)
        XCTAssertEqual(rl.usedFraction, 1.0)
        XCTAssertEqual(RateLimit(usedFraction: -0.5, resetsAt: nil).usedFraction, 0.0)
    }
}

final class StatusLineEditorTests: XCTestCase {
    private let wrapper = "\"$HOME/.atoll/bin/atoll-statusline\""

    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var userSettings: Data {
        Data("""
        {
          "model": "claude-fable-5",
          "statusLine": { "type": "command", "command": "bun /Users/x/.claude/scripts/statusline/src/index.ts", "padding": 0 },
          "language": "français"
        }
        """.utf8)
    }

    func testInstallChainsAndReportsOriginal() throws {
        let result = try StatusLineEditor.install(into: userSettings, wrapperCommand: wrapper)
        XCTAssertEqual(result.originalCommand, "bun /Users/x/.claude/scripts/statusline/src/index.ts")
        XCTAssertTrue(StatusLineEditor.isInstalled(in: result.settings))

        let settings = try parse(result.settings)
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, wrapper)
        XCTAssertEqual(statusLine["padding"] as? Int, 0, "les autres champs sont préservés")
        XCTAssertEqual(settings["model"] as? String, "claude-fable-5")
    }

    func testUninstallRestoresOriginal() throws {
        let installed = try StatusLineEditor.install(into: userSettings, wrapperCommand: wrapper)
        let restored = try StatusLineEditor.uninstall(from: installed.settings, originalCommand: installed.originalCommand)
        XCTAssertFalse(StatusLineEditor.isInstalled(in: restored))
        let statusLine = try XCTUnwrap(try parse(restored)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "bun /Users/x/.claude/scripts/statusline/src/index.ts")
        XCTAssertEqual(statusLine["padding"] as? Int, 0)
    }

    func testInstallIntoEmptyThenUninstallRemovesStatusLine() throws {
        let result = try StatusLineEditor.install(into: nil, wrapperCommand: wrapper)
        XCTAssertNil(result.originalCommand)
        let restored = try StatusLineEditor.uninstall(from: result.settings, originalCommand: nil)
        XCTAssertNil(try parse(restored)["statusLine"])
    }

    func testReinstallDoesNotStompStoredOriginal() throws {
        // Déjà installé : install ne doit pas prendre notre propre wrapper pour l'original.
        let once = try StatusLineEditor.install(into: userSettings, wrapperCommand: wrapper)
        let twice = try StatusLineEditor.install(into: once.settings, wrapperCommand: wrapper)
        XCTAssertNil(twice.originalCommand, "ne pas mémoriser notre wrapper comme 'original'")
    }

    func testInstallAddsRefreshIntervalWhenAbsent() throws {
        let result = try StatusLineEditor.install(into: userSettings, wrapperCommand: wrapper)
        let statusLine = try XCTUnwrap(try parse(result.settings)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, StatusLineEditor.managedRefreshInterval,
                       "sans lui, le quota gèle pendant l'inactivité")
    }

    func testInstallRespectsUserRefreshInterval() throws {
        let custom = Data("""
        { "statusLine": { "type": "command", "command": "bun /Users/x/s.ts", "refreshInterval": 5 } }
        """.utf8)
        let result = try StatusLineEditor.install(into: custom, wrapperCommand: wrapper)
        let statusLine = try XCTUnwrap(try parse(result.settings)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 5, "valeur utilisateur conservée")
    }

    func testUninstallRemovesOnlyOurRefreshInterval() throws {
        // Le nôtre (sentinelle) est retiré à la restitution…
        let installed = try StatusLineEditor.install(into: userSettings, wrapperCommand: wrapper)
        let restored = try StatusLineEditor.uninstall(from: installed.settings, originalCommand: installed.originalCommand)
        let statusLine = try XCTUnwrap(try parse(restored)["statusLine"] as? [String: Any])
        XCTAssertNil(statusLine["refreshInterval"])

        // …mais une valeur modifiée par l'utilisateur entre-temps est conservée.
        var settings = try parse(installed.settings)
        var block = settings["statusLine"] as? [String: Any] ?? [:]
        block["refreshInterval"] = 120
        settings["statusLine"] = block
        let data = try JSONSerialization.data(withJSONObject: settings)
        let restored2 = try StatusLineEditor.uninstall(from: data, originalCommand: "bun /Users/x/s.ts")
        let statusLine2 = try XCTUnwrap(try parse(restored2)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine2["refreshInterval"] as? Int, 120)
    }

    func testAddRefreshIntervalMigratesOnlyOurChainedInstall() throws {
        // Chaînée sans refreshInterval → ajouté.
        let installed = Data("""
        { "statusLine": { "type": "command", "command": "\\"$HOME/.atoll/bin/atoll-statusline\\"" } }
        """.utf8)
        let migrated = try XCTUnwrap(StatusLineEditor.addRefreshIntervalIfMissing(into: installed))
        let statusLine = try XCTUnwrap(try parse(migrated)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, StatusLineEditor.managedRefreshInterval)

        // Déjà présent → nil (aucune écriture) ; statusline étrangère → nil.
        XCTAssertNil(try StatusLineEditor.addRefreshIntervalIfMissing(into: migrated))
        let foreign = Data("""
        { "statusLine": { "type": "command", "command": "bun /autre/s.ts" } }
        """.utf8)
        XCTAssertNil(try StatusLineEditor.addRefreshIntervalIfMissing(into: foreign))
    }

    func testUninstallLeavesForeignStatusLineUntouched() throws {
        let foreign = Data("""
        { "statusLine": { "type": "command", "command": "bun /autre/statusline.ts" } }
        """.utf8)
        let result = try StatusLineEditor.uninstall(from: foreign, originalCommand: nil)
        let statusLine = try XCTUnwrap(try parse(result)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "bun /autre/statusline.ts")
    }
}
