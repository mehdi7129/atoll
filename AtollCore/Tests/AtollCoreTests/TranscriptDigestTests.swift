import XCTest
@testable import AtollCore

final class TranscriptDigestTests: XCTestCase {

    /// RÉGRESSION MESURÉE EN VRAI : sur un transcript de 45 Mo, les fragments
    /// `.assistant` mangeaient tout le budget et il ne restait **zéro**
    /// commande réussie — alors que le prompt promet au modèle « commands that
    /// succeeded » et que c'est la matière d'une procédure rejouable.
    func testToolInvocationsSurviveAFloodOfAssistantText() {
        var lines: [TranscriptLine] = []
        // 200 conclusions bavardes (2 000 caractères chacune après cap).
        for index in 0..<200 {
            lines.append(TranscriptLine(
                uuid: "a\(index)", sessionID: nil, timestamp: nil, cwd: nil, gitBranch: nil,
                fragments: [.init(role: .assistant, text: String(repeating: "bla ", count: 800))]
            ))
        }
        // 40 commandes qui ont MARCHÉ (invocation + résultat sans erreur).
        for index in 0..<40 {
            lines.append(TranscriptLine(
                uuid: "t\(index)", sessionID: nil, timestamp: nil, cwd: nil, gitBranch: nil,
                fragments: [.init(role: .tool, text: "Bash · commande-utile-\(index)")]
            ))
            lines.append(TranscriptLine(
                uuid: "r\(index)", sessionID: nil, timestamp: nil, cwd: nil, gitBranch: nil,
                fragments: [.init(role: .toolResult, text: "sortie normale \(index)")]
            ))
        }
        let result = TranscriptDigest.make(lines: lines)

        XCTAssertLessThanOrEqual(result.characterCount, TranscriptDigest.defaultCharacterBudget)
        let toolLines = result.text.components(separatedBy: "commande-utile-").count - 1
        XCTAssertGreaterThan(toolLines, 5,
                             "les commandes réussies doivent survivre au déluge de texte")
    }


    // MARK: - Fabriques

    /// Une ligne de transcript porteuse des fragments donnés. Le condensé travaille sur
    /// la sortie du parseur : on la fabrique directement, sans passer par du JSON.
    private func line(_ fragments: [(TranscriptLine.Role, String)],
                      at timestamp: Date? = nil) -> TranscriptLine {
        TranscriptLine(
            uuid: nil, sessionID: nil, timestamp: timestamp, cwd: nil, gitBranch: nil,
            fragments: fragments.map { TranscriptLine.Fragment(role: $0.0, text: $0.1) }
        )
    }

    /// Un texte de longueur EXACTE commençant par un jeton reconnaissable (pour vérifier
    /// qui a survécu à l'élagage). 2 000 par défaut = pile le cap, donc jamais tronqué.
    private func filler(_ token: String, length: Int = 2_000) -> String {
        token + String(repeating: "x", count: max(0, length - token.count))
    }

    // MARK: - Robustesse

    func testEmptyLinesGivesEmptyDigest() {
        let result = TranscriptDigest.make(lines: [])
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.linesRead, 0)
        XCTAssertEqual(result.entriesKept, 0)
        XCTAssertEqual(result.characterCount, 0)
        XCTAssertFalse(result.truncated, "rien à élaguer n'est pas une troncature")
    }

    func testLinesWithoutKeepableFragmentsGivesEmptyDigest() {
        // Des lignes bien réelles, mais dont rien n'est retenu : pas une troncature.
        let result = TranscriptDigest.make(lines: [
            line([(.thinking, "je réfléchis")]),
            line([(.title, "Titre de session")]),
            line([]),
        ])
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.linesRead, 3, "linesRead compte les lignes REÇUES")
        XCTAssertEqual(result.entriesKept, 0)
        XCTAssertFalse(result.truncated)
    }

    func testNonPositiveBudget() {
        let lines = [line([(.user, "corrige le quota figé")])]
        for budget in [0, -1, Int.min] {
            let result = TranscriptDigest.make(lines: lines, budget: budget)
            XCTAssertEqual(result.text, "", "budget \(budget)")
            XCTAssertEqual(result.entriesKept, 0)
            XCTAssertEqual(result.characterCount, 0)
            XCTAssertTrue(result.truncated, "un budget inexploitable est signalé tronqué")
            XCTAssertEqual(result.linesRead, 1)
        }
    }

    // MARK: - Sélection des rôles

    func testKeepsUserSummaryAssistantAndDropsNoiseRoles() {
        let result = TranscriptDigest.make(lines: [
            line([(.user, "demande initiale")]),
            line([(.thinking, "raisonnement verbeux à jeter")]),
            line([(.assistant, "conclusion utile")]),
            line([(.summary, "résumé de compaction")]),
            line([(.title, "titre de session")]),
            line([(.note, "note écrite par Atoll")]),
        ])

        XCTAssertEqual(result.entriesKept, 3)
        XCTAssertTrue(result.text.contains("demande initiale"))
        XCTAssertTrue(result.text.contains("conclusion utile"))
        XCTAssertTrue(result.text.contains("résumé de compaction"))
        XCTAssertFalse(result.text.contains("raisonnement verbeux"), ".thinking est jeté")
        XCTAssertFalse(result.text.contains("titre de session"), ".title est jeté")
        XCTAssertFalse(result.text.contains("note écrite"), ".note est jetée")
        XCTAssertFalse(result.truncated)
    }

    func testKeepsFailingToolResultAndDropsPlainOne() {
        let result = TranscriptDigest.make(lines: [
            line([(.toolResult, "fatal: pathspec 'main' did not match — no such file")]),
            line([(.toolResult, "Command not found: xcodegen")]),
            line([(.toolResult, "ÉCHEC de la signature")]),
            line([(.toolResult, "42 fichiers listés, tout va bien")]),
        ])

        XCTAssertEqual(result.entriesKept, 3, "seuls les résultats porteurs d'échec restent")
        XCTAssertTrue(result.text.contains("no such file"))
        XCTAssertTrue(result.text.contains("Command not found"), "marqueur insensible à la casse")
        XCTAssertTrue(result.text.contains("ÉCHEC"), "« Échec » minusculisé matche « échec »")
        XCTAssertFalse(result.text.contains("tout va bien"), "un résultat banal ne vaut rien")
    }

    // MARK: - Paires outil → résultat

    func testKeepsToolFollowedBySuccessfulResult() {
        let result = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · xcodegen generate")]),
            line([(.toolResult, "Created Atoll.xcodeproj")]),
        ])

        // L'invocation (la procédure) est gardée, PAS sa sortie (aucune valeur durable).
        XCTAssertEqual(result.entriesKept, 1)
        XCTAssertTrue(result.text.contains("xcodegen generate"))
        XCTAssertFalse(result.text.contains("Created Atoll.xcodeproj"))
    }

    func testDropsToolFollowedByFailingResult() {
        let result = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · xattr -c Atoll.app")]),
            line([(.toolResult, "xattr: [Errno 2] No such file or directory")]),
        ])

        // Seule l'erreur reste : la commande a échoué, ce n'est pas une procédure.
        XCTAssertEqual(result.entriesKept, 1)
        XCTAssertFalse(result.text.contains("xattr -c"), "une commande ratée n'est pas gardée")
        XCTAssertTrue(result.text.contains("No such file"))
    }

    func testInterleavedToolsUseTheirOwnResult() {
        // tool A → erreur, tool B → succès. Naïvement (« un succès quelque part dans les
        // 3 suivantes »), A passerait pour réussi : c'est le PREMIER résultat qui décide.
        let result = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · commande-A")]),
            line([(.toolResult, "error: A a explosé")]),
            line([(.tool, "Bash · commande-B")]),
            line([(.toolResult, "B: 3 fichiers écrits")]),
        ])

        XCTAssertFalse(result.text.contains("commande-A"))
        XCTAssertTrue(result.text.contains("error: A a explosé"))
        XCTAssertTrue(result.text.contains("commande-B"))
        XCTAssertFalse(result.text.contains("3 fichiers écrits"))
        XCTAssertEqual(result.entriesKept, 2)
    }

    func testToolWithoutResultInWindowIsDropped() {
        // Le résultat arrive 4 entrées plus loin (hors fenêtre) : on ne peut rien
        // affirmer sur l'issue → pas de procédure.
        let result = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · commande-lointaine")]),
            line([(.assistant, "a")]),
            line([(.assistant, "b")]),
            line([(.assistant, "c")]),
            line([(.toolResult, "tout va bien")]),
        ])
        XCTAssertFalse(result.text.contains("commande-lointaine"))

        // Idem quand la session est coupée juste après l'invocation.
        let cut = TranscriptDigest.make(lines: [line([(.tool, "Bash · commande-orpheline")])])
        XCTAssertEqual(cut.entriesKept, 0)

        // Dans la fenêtre (2 entrées plus loin, appels parallèles) : gardé.
        let parallel = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · commande-1"), (.tool, "Bash · commande-2")]),
            line([(.toolResult, "ok 1"), (.toolResult, "ok 2")]),
        ])
        XCTAssertTrue(parallel.text.contains("commande-1"))
        XCTAssertTrue(parallel.text.contains("commande-2"))
    }

    // MARK: - Bornes

    func testEntryCappedAtTwoThousandCharacters() throws {
        // 400 Ko de sortie d'outil : le marqueur d'erreur est cherché sur le texte
        // ENTIER (donc l'entrée est bien retenue), la troncature n'arrive qu'après.
        let huge = filler("SORTIE-ENORME", length: 400_000) + " error"
        let entries = TranscriptDigest.entries(from: [line([(.toolResult, huge)])])
        XCTAssertEqual(entries.count, 1)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.text.count, 2_000, "cap par entrée, marqueur compris")
        XCTAssertTrue(entry.text.hasSuffix(" […]"))
        XCTAssertTrue(entry.text.hasPrefix("SORTIE-ENORME"))

        // Une entrée pile à 2 000 n'est pas touchée.
        let exact = TranscriptDigest.entries(from: [line([(.user, filler("PILE"))])])
        XCTAssertEqual(exact.first?.text.count, 2_000)
        XCTAssertEqual(exact.first?.text.hasSuffix(" […]"), false)
    }

    func testGlobalBudgetIsRespectedAndEveryUserSurvives() {
        // 500 entrées de 2 000 caractères ≈ 1 Mo de condensé brut, pour 150 000 de budget.
        var lines: [TranscriptLine] = []
        for index in 0..<20 {
            lines.append(line([(.user, filler(String(format: "USER-%02d", index)))]))
            for step in 0..<24 {
                lines.append(line([(.assistant, filler("ASSIST-\(index)-\(step)"))]))
            }
        }
        XCTAssertEqual(lines.count, 500)

        let budget = TranscriptDigest.defaultCharacterBudget
        let result = TranscriptDigest.make(lines: lines, budget: budget)

        XCTAssertLessThanOrEqual(result.characterCount, budget, "le budget est une borne DURE")
        XCTAssertEqual(result.characterCount, result.text.count)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.entriesKept, 500)
        XCTAssertGreaterThan(result.entriesKept, 20, "il reste de la place après les user")
        XCTAssertEqual(result.linesRead, 500)

        for index in 0..<20 {
            let token = String(format: "USER-%02d", index)
            XCTAssertTrue(result.text.contains(token),
                          "\(token) doit survivre : les .user sont sacrifiés en dernier")
        }
    }

    func testPruningEatsTheMiddleAndKeepsBothEnds() {
        // 20 prompts utilisateur pour un budget qui n'en laisse passer qu'une poignée :
        // l'élagage doit manger le MILIEU, pas la fin.
        let lines = (0..<20).map { index in
            line([(.user, filler(String(format: "U%02d", index), length: 1_000))])
        }
        let result = TranscriptDigest.make(lines: lines, budget: 10_000)

        XCTAssertLessThanOrEqual(result.characterCount, 10_000)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.text.contains("U00"), "le début pose le contexte")
        XCTAssertTrue(result.text.contains("U19"), "la fin conclut — jamais tronquée à l'aveugle")
        XCTAssertFalse(result.text.contains("U09"), "le milieu est sacrifié d'abord")
        XCTAssertFalse(result.text.contains("U10"))

        // Les survivants restent dans l'ORDRE du transcript.
        let positions = (0..<20).compactMap { index -> Int? in
            result.text.range(of: String(format: "U%02d", index))
                .map { result.text.distance(from: result.text.startIndex, to: $0.lowerBound) }
        }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testCategoriesAreSacrificedInOrder() {
        // Un budget qui ne peut tenir qu'une entrée sur quatre : c'est le .user qui reste.
        let result = TranscriptDigest.make(lines: [
            line([(.tool, "Bash · commande-reussie")]),
            line([(.toolResult, "ok, rien à signaler")]),
            line([(.assistant, "conclusion")]),
            line([(.toolResult, "error: ça a cassé")]),
            line([(.user, "intention")]),
        ], budget: 40)

        XCTAssertTrue(result.text.contains("intention"))
        XCTAssertFalse(result.text.contains("commande-reussie"), ".tool part en premier")
        XCTAssertFalse(result.text.contains("conclusion"))
        XCTAssertFalse(result.text.contains("ça a cassé"))
        XCTAssertLessThanOrEqual(result.characterCount, 40)
    }

    func testTruncatedIsFalseWhenEverythingFits() {
        let result = TranscriptDigest.make(lines: [
            line([(.user, "petite demande")]),
            line([(.assistant, "petite réponse")]),
        ])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.entriesKept, 2)
        XCTAssertEqual(result.characterCount, result.text.count)
    }

    // MARK: - Rendu

    func testRenderedFormatWithAndWithoutTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let dated = TranscriptDigest.make(lines: [line([(.user, "bonjour")], at: date)])
        // Heure LOCALE → on vérifie la forme, pas une valeur (le fuseau de la machine
        // de test ne doit pas décider du verdict).
        XCTAssertNotNil(dated.text.range(of: #"^\[user \d{2}:\d{2}\] bonjour$"#,
                                         options: .regularExpression),
                        "format attendu « [user 14:32] texte », obtenu : \(dated.text)")

        let undated = TranscriptDigest.make(lines: [line([(.assistant, "salut")])])
        XCTAssertEqual(undated.text, "[assistant] salut", "heure inconnue → préfixe sans heure")

        // Un bloc par entrée, séparés par une ligne vide ; graphie des rôles = celle de
        // TranscriptLine.Role (tool_result et non toolResult).
        let blocks = TranscriptDigest.make(lines: [
            line([(.user, "a")]),
            line([(.toolResult, "error: b")]),
        ])
        XCTAssertEqual(blocks.text, "[user] a\n\n[tool_result] error: b")
    }

    // MARK: - Déterminisme

    func testDeterministicOutput() {
        var lines: [TranscriptLine] = []
        for index in 0..<40 {
            lines.append(line([(.user, filler("U\(index)", length: 600))]))
            lines.append(line([(.assistant, filler("A\(index)", length: 900))]))
            lines.append(line([(.tool, "Bash · cmd-\(index)")]))
            lines.append(line([(.toolResult, index.isMultiple(of: 3) ? "error: boum" : "ok")]))
            lines.append(line([(.thinking, filler("T\(index)", length: 300))]))
        }

        let first = TranscriptDigest.make(lines: lines, budget: 20_000)
        let second = TranscriptDigest.make(lines: lines, budget: 20_000)
        XCTAssertEqual(first, second, "deux appels identiques → même Result")
        XCTAssertEqual(first.text, second.text)
        XCTAssertTrue(first.truncated)
        XCTAssertLessThanOrEqual(first.characterCount, 20_000)
    }

    // MARK: - Outils PARALLÈLES (audit du 2026-07-27)

    /// Un message assistant qui émet quatre outils d'un coup : les résultats
    /// arrivent groupés ensuite. L'appariement par POSITION jugeait t1..t3 sur
    /// le résultat de t0 — et écartait t0 lui-même. Résultat concret : une
    /// commande qui a ÉCHOUÉ était présentée au modèle comme ayant réussi.
    func testParallelToolCallsArePairedByIdentifier() {
        func tool(_ id: String, _ name: String) -> TranscriptLine.Fragment {
            TranscriptLine.Fragment(role: .tool, text: name, toolUseID: id)
        }
        func result(_ id: String, failed: Bool) -> TranscriptLine.Fragment {
            TranscriptLine.Fragment(role: .toolResult, text: failed ? "boom" : "ok",
                                    isError: failed, toolUseID: id)
        }
        let lines = [
            TranscriptLine(uuid: "a", sessionID: "s", timestamp: nil, cwd: nil, gitBranch: nil,
                           fragments: [tool("t0", "swift build"), tool("t1", "xcodebuild"),
                                       tool("t2", "git status"), tool("t3", "ls")]),
            TranscriptLine(uuid: "b", sessionID: "s", timestamp: nil, cwd: nil, gitBranch: nil,
                           fragments: [result("t0", failed: false), result("t1", failed: true),
                                       result("t2", failed: false), result("t3", failed: false)]),
        ]
        let outils = TranscriptDigest.entries(from: lines)
            .filter { $0.role == .tool }
            .map(\.text)
        XCTAssertEqual(outils, ["swift build", "git status", "ls"],
                       "le seul outil ÉCHOUÉ (xcodebuild) doit être écarté, les trois autres gardés")
    }

    /// Un transcript sans identifiant (format ancien ou inattendu) doit
    /// continuer de fonctionner par position — parsing défensif.
    func testToolsWithoutIdentifierFallBackToPosition() {
        let lines = [
            TranscriptLine(uuid: "a", sessionID: "s", timestamp: nil, cwd: nil, gitBranch: nil,
                           fragments: [TranscriptLine.Fragment(role: .tool, text: "swift build")]),
            TranscriptLine(uuid: "b", sessionID: "s", timestamp: nil, cwd: nil, gitBranch: nil,
                           fragments: [TranscriptLine.Fragment(role: .toolResult, text: "ok",
                                                               isError: false)]),
        ]
        let outils = TranscriptDigest.entries(from: lines).filter { $0.role == .tool }
        XCTAssertEqual(outils.map(\.text), ["swift build"])
    }
}
