import XCTest
@testable import AtollCore

/// Contrat vérifié par Codex dans la documentation officielle OpenAI, puis
/// spécifié par lui le 2026-09-09. L'enjeu n'est pas cosmétique : une réponse
/// mal formée ne « rate » pas, elle **refuse l'action de l'utilisateur**.
final class CodexPermissionDecisionTests: XCTestCase {

    private func json(_ decision: CodexPermissionDecision) throws -> [String: Any] {
        let data = try XCTUnwrap(decision.hookOutput())
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    // MARK: - Ce qu'on écrit à Codex

    func testAllowMatchesTheDocumentedContract() throws {
        let root = try json(.allow)
        let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(decision.count, 1, "aucune clé en plus sur un allow")
    }

    func testDenyCarriesItsMessage() throws {
        let decision = try XCTUnwrap(json(.deny(message: "trop risqué"))["hookSpecificOutput"]
            .flatMap { ($0 as? [String: Any])?["decision"] as? [String: Any] })
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "trop risqué")
    }

    /// ⚠️ LES TROIS CHAMPS RÉSERVÉS FONT REFUSER LA REQUÊTE. On ne les émet
    /// donc JAMAIS — c'est toute la raison d'être de l'allowlist.
    func testReservedFieldsAreNeverEmitted() throws {
        for decision in [CodexPermissionDecision.allow, .deny(message: "non")] {
            let text = String(decoding: try XCTUnwrap(decision.hookOutput()), as: UTF8.self)
            for reserved in ["updatedInput", "updatedPermissions", "interrupt"] {
                XCTAssertFalse(text.contains(reserved), "\(reserved) émis")
            }
        }
    }

    func testDenyMessageIsBounded() throws {
        let huge = String(repeating: "x", count: 5_000)
        let decision = try XCTUnwrap(json(.deny(message: huge))["hookSpecificOutput"]
            .flatMap { ($0 as? [String: Any])?["decision"] as? [String: Any] })
        XCTAssertEqual((decision["message"] as? String)?.count, CodexPermissionDecision.messageCap)
    }

    func testEmptyDenyMessageIsOmittedRatherThanSentEmpty() throws {
        let decision = try XCTUnwrap(json(.deny(message: ""))["hookSpecificOutput"]
            .flatMap { ($0 as? [String: Any])?["decision"] as? [String: Any] })
        XCTAssertNil(decision["message"])
    }

    // MARK: - Ce qu'on accepte de l'app

    func testBothEnvelopesAreAccepted() {
        let wrapped = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        XCTAssertEqual(CodexPermissionDecision.decode(Data(wrapped.utf8)), .allow)
        let bare = #"{"behavior":"deny","message":"non"}"#
        XCTAssertEqual(CodexPermissionDecision.decode(Data(bare.utf8)), .deny(message: "non"))
    }

    /// LE CŒUR DU LOT. Chacun de ces cas doit rendre `nil` — c'est-à-dire, côté
    /// helper, « exit 0, stdout vide », donc invite native. Relayer l'un d'eux
    /// REFUSERAIT l'action de Mehdi au lieu de lui rendre la main.
    func testEverythingUnexpectedAbstainsRatherThanDenying() {
        let cases = [
            "",                                             // vide
            "pas du json",
            "[]",
            "{}",
            #"{"behavior":"peut-être"}"#,                  // verbe inconnu
            #"{"behavior":"ALLOW"}"#,                      // casse différente
            #"{"decision":{"behavior":"allow"}}"#,         // enveloppe incomplète
            #"{"hookSpecificOutput":{"hookEventName":"Stop","decision":{"behavior":"allow"}}}"#,
            #"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#,
            // Les trois champs réservés, seuls ou accompagnés d'un verbe valide.
            #"{"behavior":"allow","updatedInput":{"command":"rm -rf /"}}"#,
            #"{"behavior":"allow","updatedPermissions":[{"mode":"bypass"}]}"#,
            #"{"behavior":"deny","interrupt":true}"#,
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{}}}}"#,

            // LES QUATRE CONTRE-EXEMPLES DE CODEX, revue du 2026-09-09. Aucun
            // ne relayait de clé dangereuse — le ré-encodage les retirait —
            // mais la règle est « forme inconnue = ABSTENTION », jamais
            // interprétation partielle. L'écart compte exactement au moment où
            // il est le plus dur à diagnostiquer : un décalage de versions
            // entre l'app et le helper.
            #"{"behavior":"allow","futureKey":true}"#,
            #"{"behavior":"allow","message":"un message n'a pas de sens sur allow"}"#,
            #"{"behavior":"deny","message":42}"#,
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","futureKey":1,"decision":{"behavior":"allow"}}}"#,
            // …et le champ réservé posé en FRÈRE de `decision`, que l'ancienne
            // boucle ne regardait pas.
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","interrupt":true,"decision":{"behavior":"allow"}}}"#,
            // Une clé inconnue à la racine, à côté de l'enveloppe.
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}},"extra":1}"#,
        ]
        for raw in cases {
            XCTAssertNil(CodexPermissionDecision.decode(Data(raw.utf8)),
                         "accepté à tort : \(raw.isEmpty ? "(vide)" : raw)")
        }
        XCTAssertNil(CodexPermissionDecision.decode(nil))
    }

    /// Une réponse énorme est un bug ou une version qu'on ne comprend pas.
    func testOversizedPayloadAbstains() {
        let huge = #"{"behavior":"allow","pad":""# + String(repeating: "x", count: 70_000) + #""}"#
        XCTAssertNil(CodexPermissionDecision.decode(Data(huge.utf8)))
    }

    func testDecodedDenyMessageIsBounded() {
        let raw = #"{"behavior":"deny","message":""# + String(repeating: "y", count: 5_000) + #""}"#
        guard case .deny(let message) = CodexPermissionDecision.decode(Data(raw.utf8)) else {
            return XCTFail("refus non décodé")
        }
        XCTAssertEqual(message?.count, CodexPermissionDecision.messageCap)
    }

    /// Un `deny` SANS message reste valide : c'est ce que rend un refus depuis
    /// l'îlot quand l'utilisateur n'écrit rien.
    func testDenyWithoutMessageIsStillAccepted() {
        XCTAssertEqual(CodexPermissionDecision.decode(Data(#"{"behavior":"deny"}"#.utf8)),
                       .deny(message: nil))
    }

    /// Aller-retour : ce qu'on émet doit être relu à l'identique. Sans quoi le
    /// helper ne pourrait pas valider sa propre sortie avant de l'écrire.
    func testRoundTrip() throws {
        for decision in [CodexPermissionDecision.allow, .deny(message: "non"), .deny(message: nil)] {
            let data = try XCTUnwrap(decision.hookOutput())
            XCTAssertEqual(CodexPermissionDecision.decode(data), decision)
        }
    }

    /// L'isolation demandée par Codex : une décision Claude ne doit pas se faire
    /// passer pour une décision Codex. Le format Claude (`{"behavior":"allow"}`
    /// sous `hookSpecificOutput` avec un autre `hookEventName`, ou la forme
    /// `permissionDecision`) n'est pas honoré.
    func testAClaudeShapedReplyIsNotHonouredAsCodex() {
        let claudeShaped = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#
        XCTAssertNil(CodexPermissionDecision.decode(Data(claudeShaped.utf8)))
    }
}
