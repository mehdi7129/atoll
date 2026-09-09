import XCTest
@testable import AtollCore

/// DÉFAUT TROUVÉ PAR CODEX le 2026-09-09, sur sa propre machine à états, et
/// introduit par le passage des hooks en `async` : `Stop` reste synchrone, ce
/// qui garantit sa LIVRAISON — pas qu'il arrive après les processus async déjà
/// lancés. Les deux premiers tests sont ceux qu'il a spécifiés.
final class CodexTurnClosureTests: XCTestCase {

    private func event(_ kind: String, turn: String?, session: String = "s1",
                       tool: String? = nil, prompt: String? = nil) -> CodexHookEvent {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": session,
                                      "cwd": "/tmp/projet"]
        if let turn { payload["turn_id"] = turn }
        if let tool { payload["tool_name"] = tool }
        if let prompt { payload["prompt"] = prompt }
        return CodexHookEvent(envelope: ["v": 1, "provider": "codex", "payload": payload])!
    }

    private func status(_ sessions: CodexSessions) -> AgentSession.Status? {
        sessions.sessions().first?.status
    }

    // MARK: - Les deux cas spécifiés par Codex

    /// « `Stop(t1)` puis `PreToolUse(t1)` » — un retardataire du MÊME tour
    /// passait le garde et remettait la session en activité, pour quinze
    /// minutes jusqu'à la péremption.
    func testALateEventOfAClosedTurnCannotReopenIt() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        sessions.apply(event("Stop", turn: "t1"))
        XCTAssertEqual(status(sessions), .awaitingInput)

        sessions.apply(event("PreToolUse", turn: "t1", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput, "un tour clos a été rouvert")

        // Les autres branches d'activité doivent être fermées de même.
        for kind in ["PostToolUse", "PreCompact", "PostCompact", "PermissionRequest"] {
            sessions.apply(event(kind, turn: "t1", tool: "Bash"))
            XCTAssertEqual(status(sessions), .awaitingInput, "rouvert par \(kind)")
        }
    }

    /// « `UserPromptSubmit(t2)` puis ancien `UserPromptSubmit(t1)` après clôture
    /// de `t1` » — LE CAS GRAVE : cette branche est exemptée du garde de tour,
    /// donc le retardataire replaçait `entry.turnID` sur le tour mort, et tous
    /// les événements du vrai tour étaient ensuite rejetés. Session figée.
    func testALateUserPromptOfAClosedTurnCannotHijackTheCurrentOne() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "premier"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "second"))
        XCTAssertEqual(sessions.sessions().first?.subtitle, "second")

        // Le retardataire de t1 ne doit ni reprendre le tour, ni changer le titre…
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "premier"))
        XCTAssertEqual(sessions.sessions().first?.subtitle, "second",
                       "un prompt d'un tour mort a repris la main")

        // …et surtout, le VRAI tour courant doit continuer d'être accepté.
        sessions.apply(event("PreToolUse", turn: "t2", tool: "Bash"))
        XCTAssertEqual(status(sessions), .working(tool: "Bash"),
                       "la session est figée : t2 n'est plus accepté")
    }

    // MARK: - Cas de bord

    /// Un retardataire SANS `turn_id` passe les deux gardes de tour : il faut
    /// que l'état terminal le retienne, sinon l'activité repart toute seule.
    func testAnEventWithoutTurnIdCannotReopenAClosedTurn() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("PostToolUse", turn: nil, tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
    }

    /// Une interruption clôt le tour aussi sûrement qu'un `Stop`.
    func testInterruptClosesTheTurnToo() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p"))
        sessions.apply(event("Interrupt", turn: "t1"))
        sessions.apply(event("PreToolUse", turn: "t1", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
    }

    /// La clôture ne doit pas GELER la session : un nouveau prompt rouvre.
    func testANewPromptReopensActivity() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p1"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "p2"))
        XCTAssertEqual(status(sessions), .working(tool: nil))
        sessions.apply(event("PreToolUse", turn: "t2", tool: "Grep"))
        XCTAssertEqual(status(sessions), .working(tool: "Grep"))
    }

    /// La mémoire des tours clos est BORNÉE : une session enchaîne des centaines
    /// de tours, elle ne doit pas croître avec eux.
    func testClosedTurnMemoryIsBounded() {
        var sessions = CodexSessions()
        for index in 0..<40 {
            sessions.apply(event("UserPromptSubmit", turn: "t\(index)", prompt: "p"))
            sessions.apply(event("Stop", turn: "t\(index)"))
        }
        // Le tour le plus récent reste protégé…
        sessions.apply(event("PreToolUse", turn: "t39", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
        // …et la session répond toujours normalement à un nouveau tour.
        sessions.apply(event("UserPromptSubmit", turn: "t40", prompt: "encore"))
        XCTAssertEqual(status(sessions), .working(tool: nil))
    }

    /// Deux sessions n'ont pas la même comptabilité de tours.
    func testTurnClosureIsPerSession() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", session: "a", prompt: "p"))
        sessions.apply(event("Stop", turn: "t1", session: "a"))
        sessions.apply(event("UserPromptSubmit", turn: "t1", session: "b", prompt: "p"))
        sessions.apply(event("PreToolUse", turn: "t1", session: "b", tool: "Bash"))
        let b = sessions.sessions().first { $0.id == "codex:b" }
        XCTAssertEqual(b?.status, .working(tool: "Bash"),
                       "la clôture d'une session a contaminé l'autre")
    }

    // MARK: - Le verdict rendu à l'appelant (2026-09-09, seconde revue de Codex)

    /// ⚠️ LE FILTRAGE PROTÉGEAIT L'ÉTAT DE SESSION, PAS L'INTERACTION.
    /// `apply` rendait `nil` pour « rejeté » comme pour « accepté, rien de
    /// terminé » : l'appelant ne pouvait pas les distinguer et enregistrait la
    /// carte d'autorisation dans les DEUX cas. Une permission retardataire d'un
    /// tour déjà clos créait donc une carte que plus personne n'attendait.
    func testARejectedEventSaysSoInsteadOfLookingLikeAnAcceptedOne() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        XCTAssertTrue(sessions.applyEvent(event("PreToolUse", turn: "t1", tool: "Bash")).accepted)

        sessions.apply(event("Stop", turn: "t1"))
        let late = sessions.applyEvent(event("PermissionRequest", turn: "t1", tool: "Bash"))
        XCTAssertFalse(late.accepted, "une permission d'un tour CLOS ne doit pas créer de carte")

        // Et l'autre garde : un événement d'un tour qui n'est pas le courant.
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "et ça"))
        let other = sessions.applyEvent(event("PermissionRequest", turn: "t1", tool: "Bash"))
        XCTAssertFalse(other.accepted, "une permission d'un AUTRE tour non plus")
    }

    /// `Stop` et `Interrupt` nomment le tour qu'ils viennent de clore :
    /// l'appelant retire les cartes de CE tour. `SessionEnd` avait son
    /// nettoyage, pas l'interruption — une carte y survivait jusqu'au reaper ou
    /// aux 600 s d'expiration du serveur.
    func testClosingAnEventNamesTheTurnWhoseCardsNobodyAwaitsAnymore() {
        for kind in ["Stop", "Interrupt"] {
            var sessions = CodexSessions()
            sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
            let applied = sessions.applyEvent(event(kind, turn: "t1"))
            XCTAssertTrue(applied.accepted, kind)
            XCTAssertEqual(applied.closure, .named("t1"), "\(kind) doit nommer le tour qu'il clôt")
        }
    }

    /// Un événement ORDINAIRE ne clôt rien : nommer un tour ici retirerait les
    /// cartes d'un tour bien vivant — l'inverse exact du défaut réparé.
    func testAnOrdinaryEventClosesNoTurn() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        for kind in ["PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact"] {
            XCTAssertEqual(sessions.applyEvent(event(kind, turn: "t1", tool: "Bash")).closure, .none, kind)
        }
    }

    /// La fin de session est ACCEPTÉE et porte les faits — c'est ce que
    /// l'appelant transmet au bilan.
    func testSessionEndIsAcceptedAndCarriesTheFacts() {
        var sessions = CodexSessions()
        sessions.apply(event("SessionStart", turn: nil))
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        let applied = sessions.applyEvent(event("SessionEnd", turn: nil))
        XCTAssertTrue(applied.accepted)
        // Le préfixe `codex:` est porté par l'événement lui-même : c'est ce qui
        // garde les deux espaces d'identifiants disjoints jusque dans l'index.
        XCTAssertEqual(applied.ended?.sessionID, "codex:s1")
    }

    // MARK: - Certitude contre doute (régression trouvée par Codex dans le correctif)

    /// ⚠️ LE SCÉNARIO EXACT DE LA RÉGRESSION. `UserPromptSubmit` est ASYNC :
    /// une `PermissionRequest(t2)` peut arriver AVANT le prompt qui ouvre `t2`.
    /// La projection la rejette — à raison, l'état de session ne doit pas
    /// bouger — mais la DEMANDE est vivante : la carte doit survivre, sinon
    /// plus rien ne la recrée quand le prompt arrive enfin.
    func testAPermissionOfAnUnopenedTurnKeepsItsCard() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        sessions.apply(event("Stop", turn: "t1"))

        let early = sessions.applyEvent(event("PermissionRequest", turn: "t2", tool: "Bash"))
        XCTAssertFalse(early.accepted, "l'état de session ne doit pas suivre un tour non ouvert")
        XCTAssertFalse(early.cardIsStale, "sa carte est VIVANTE : le prompt de t2 n'est pas encore arrivé")
    }

    /// L'autre moitié : un tour dont on SAIT qu'il est clos tue bien la carte.
    /// Sans elle, le correctif ne corrigerait plus rien.
    func testAPermissionOfAProvenClosedTurnLosesItsCard() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        sessions.apply(event("Stop", turn: "t1"))

        let late = sessions.applyEvent(event("PermissionRequest", turn: "t1", tool: "Bash"))
        XCTAssertFalse(late.accepted)
        XCTAssertTrue(late.cardIsStale, "t1 est mémorisé comme CLOS : la demande ne vaut plus rien")
    }

    /// Un événement sans `turn_id` arrivant après une clôture ne prouve rien :
    /// il peut appartenir au tour suivant. Doute ⇒ on ne détruit pas.
    func testAnUnnamedLateEventDoesNotKillACard() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        sessions.apply(event("Stop", turn: "t1"))

        let anonymous = sessions.applyEvent(event("PermissionRequest", turn: nil, tool: "Bash"))
        XCTAssertFalse(anonymous.accepted)
        XCTAssertFalse(anonymous.cardIsStale)
    }

    /// ⚠️ UNE CLÔTURE SANS `turn_id` N'EST PAS UNE ABSENCE DE CLÔTURE. Rendre
    /// `nil` pour les deux rendait le nettoyage inatteignable depuis le
    /// service : le `if let` sautait tout. La projection connaît le tour
    /// courant — c'est lui qu'elle nomme.
    func testAnUnnamedClosureFallsBackToTheCurrentTurn() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        XCTAssertEqual(sessions.applyEvent(event("Stop", turn: nil)).closure, .named("t1"))
    }

    /// Aucun tour connu du tout : la clôture est ANONYME, et l'appelant ne
    /// retire alors que les cartes qui ne nomment pas leur tour non plus.
    func testAClosureWithNoKnownTurnAtAllIsUnnamed() {
        var sessions = CodexSessions()
        sessions.apply(event("SessionStart", turn: nil))
        XCTAssertEqual(sessions.applyEvent(event("Stop", turn: nil)).closure, .unnamed)
    }

    /// Un événement ordinaire ne clôt toujours rien.
    func testAnOrdinaryEventStillClosesNothing() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        XCTAssertEqual(sessions.applyEvent(event("PreToolUse", turn: "t1", tool: "Bash")).closure, .none)
    }
}
