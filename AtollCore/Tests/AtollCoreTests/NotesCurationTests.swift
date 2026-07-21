import XCTest
@testable import AtollCore

final class NotesCurationTests: XCTestCase {

    // MARK: - Fixtures

    /// Payload de curation réaliste : 2 notes consolidées (avec et sans
    /// sources) + 1 contradiction, plus un item invalide (sans title) qui
    /// doit être droppé en silence.
    private var curationPayload: String {
        #"""
        {
          "notes": [
            { "title": "Pièges CodeSign iCloud",
              "content": "DerivedData hors du Bureau : les xattrs du file provider iCloud cassent CodeSign.",
              "sources": ["2026-07-18-icloud-xattr.md", "2026-07-19-codesign.md"] },
            { "title": "Détection des processus claude",
              "content": "proc_name renvoie la version, pas « claude » : matcher par chemin d'exécutable.",
              "sources": [] },
            { "content": "item sans titre, à dropper" }
          ],
          "contradictions": [
            { "summary": "Deux notes divergent sur le seuil d'inactivité (15 s vs 30 s).",
              "files": ["2026-07-18-idle.md", "2026-07-20-idle.md"] }
          ]
        }
        """#
    }

    /// Enveloppe V0 réaliste de `claude -p --output-format json` (CLI 2.1.215) :
    /// structured_output = objet déjà « validé » côté CLI, result = le même en
    /// string, plus le bruit habituel (usage, durées, session_id…).
    private func envelope(structured: String?, result: String?,
                          subtype: String = "success", isError: Bool = false) throws -> Data {
        var root: [String: Any] = [
            "type": "result",
            "subtype": subtype,
            "is_error": isError,
            "duration_ms": 4210,
            "num_turns": 1,
            "session_id": "9c41d2ab-0000-4000-8000-6f2a8b3c7d10",
            "total_cost_usd": 0.0173,
            "usage": ["input_tokens": 1830, "output_tokens": 420],
        ]
        if let structured {
            root["structured_output"] = try JSONSerialization.jsonObject(with: Data(structured.utf8))
        }
        if let result {
            root["result"] = result
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Instant figé pour un rendu déterministe, indépendant du fuseau machine.
    private func fixedNow() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z"))
    }

    private func planSuccess(_ result: Result<NotesCurationPlanner.Plan, NotesCurationPlanner.CurationRefusal>,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> NotesCurationPlanner.Plan {
        switch result {
        case .success(let plan):
            return plan
        case .failure(let refusal):
            XCTFail("plan a refusé : \(refusal)", file: file, line: line)
            throw refusal
        }
    }

    // MARK: - Parsing

    func testParseCurationOutput() throws {
        let data = try envelope(structured: curationPayload, result: curationPayload)
        let output = try XCTUnwrap(NotesCurationOutput.parse(cliOutput: data))

        // L'item sans titre est droppé, les deux notes valides survivent.
        XCTAssertEqual(output.notes.count, 2)
        XCTAssertEqual(output.notes[0], NotesCurationOutput.Note(
            title: "Pièges CodeSign iCloud",
            content: "DerivedData hors du Bureau : les xattrs du file provider iCloud cassent CodeSign.",
            sources: ["2026-07-18-icloud-xattr.md", "2026-07-19-codesign.md"]
        ))
        XCTAssertEqual(output.notes[1].title, "Détection des processus claude")
        XCTAssertEqual(output.notes[1].sources, [])

        XCTAssertEqual(output.contradictions, [NotesCurationOutput.Contradiction(
            summary: "Deux notes divergent sur le seuil d'inactivité (15 s vs 30 s).",
            files: ["2026-07-18-idle.md", "2026-07-20-idle.md"]
        )])

        // Une sortie inexploitable rend nil, jamais d'exception.
        XCTAssertNil(NotesCurationOutput.parse(cliOutput: Data("pas du json".utf8)))
    }

    func testParseFallbackResultString() throws {
        // Sans structured_output, `result` (string JSON, fences strippées)
        // est la source.
        let fenced = "```json\n\(curationPayload)\n```"
        let data = try envelope(structured: nil, result: fenced)
        let output = try XCTUnwrap(NotesCurationOutput.parse(cliOutput: data))

        XCTAssertEqual(output.notes.count, 2)
        XCTAssertEqual(output.notes[0].title, "Pièges CodeSign iCloud")
        XCTAssertEqual(output.contradictions.count, 1)

        // Une enveloppe d'erreur du CLI est inexploitable → nil.
        XCTAssertNil(NotesCurationOutput.parse(cliOutput: try envelope(
            structured: nil, result: "boom", subtype: "error_during_execution", isError: true
        )))
    }

    // MARK: - Garde-fous du planificateur

    func testRefusesEmptyOutputWithNonEmptyInput() throws {
        let output = NotesCurationOutput(notes: [], contradictions: [])
        let result = NotesCurationPlanner.plan(
            existing: [(name: "2026-07-18-icloud-xattr.md", content: "contenu existant")],
            output: output,
            now: try fixedNow()
        )
        XCTAssertEqual(result, .failure(.emptyOutputFromNonEmptyInput))

        // Entrée vide + sortie vide : rien à curer, plan vide accepté.
        let emptyBoth = NotesCurationPlanner.plan(existing: [], output: output, now: try fixedNow())
        XCTAssertEqual(emptyBoth, .success(NotesCurationPlanner.Plan(newNotes: [], warnings: [])))
    }

    func testRefusesMassiveShrink() throws {
        let existing = [(name: "grosse-note.md", content: String(repeating: "x", count: 200))]
        let shrunk = NotesCurationOutput(
            notes: [.init(title: "Trop court", content: String(repeating: "y", count: 40), sources: [])],
            contradictions: []
        )

        guard case .failure(.excessiveShrink(let ratio)) = NotesCurationPlanner.plan(
            existing: existing, output: shrunk, now: try fixedNow()
        ) else {
            return XCTFail("le rétrécissement massif aurait dû être refusé")
        }
        XCTAssertEqual(ratio, 0.2, accuracy: 0.001)

        // À exactement 50 % on passe : le seuil est strict.
        let boundary = NotesCurationOutput(
            notes: [.init(title: "Pile au seuil", content: String(repeating: "y", count: 100), sources: [])],
            contradictions: []
        )
        _ = try planSuccess(NotesCurationPlanner.plan(existing: existing, output: boundary, now: try fixedNow()))
    }

    func testContradictionsAreSurfacedNotApplied() throws {
        let summary = "Deux notes divergent sur le seuil d'inactivité (15 s vs 30 s)."
        let output = NotesCurationOutput(
            notes: [.init(title: "Seuil d'inactivité", content: "Le minuteur d'inactivité est de 15 s.", sources: [])],
            contradictions: [.init(summary: summary, files: ["a.md", "b.md"])]
        )
        let plan = try planSuccess(NotesCurationPlanner.plan(
            existing: [], output: output, now: try fixedNow()
        ))

        // La contradiction est remontée en avertissement, format exact…
        XCTAssertEqual(plan.warnings, ["⚠ contradiction : \(summary)"])
        // …et n'est JAMAIS appliquée : une seule note rendue, sans trace de la
        // contradiction ni de ses fichiers.
        XCTAssertEqual(plan.newNotes.count, 1)
        XCTAssertFalse(plan.newNotes[0].content.contains(summary))
        XCTAssertFalse(plan.newNotes[0].fileName.contains("contradiction"))
    }

    // MARK: - Rendu

    func testPlanProducesRenderedNotes() throws {
        let output = NotesCurationOutput(
            notes: [
                .init(title: "Pièges CodeSign iCloud",
                      content: "Les xattrs iCloud cassent CodeSign.",
                      sources: ["2026-07-18-icloud-xattr.md"]),
                .init(title: "Détection des processus claude",
                      content: "Matcher par chemin d'exécutable.",
                      sources: []),
            ],
            contradictions: []
        )
        let now = try fixedNow()
        let plan = try planSuccess(NotesCurationPlanner.plan(existing: [], output: output, now: now))

        // Noms déterministes : index 1-based sur 2 chiffres + slug ASCII plié.
        XCTAssertEqual(plan.newNotes.map(\.fileName), [
            "01-pieges-codesign-icloud.md",
            "02-detection-des-processus-claude.md",
        ])

        // Front-matter minimal (title, curated_at UTC, sources si non vide)
        // puis le contenu, terminé par exactement un saut de ligne.
        XCTAssertEqual(plan.newNotes[0].content, """
        ---
        title: Pièges CodeSign iCloud
        curated_at: 2026-07-20T12:00:00Z
        sources:
          - 2026-07-18-icloud-xattr.md
        ---

        Les xattrs iCloud cassent CodeSign.

        """)
        // Sans sources, la clé est simplement omise.
        XCTAssertFalse(plan.newNotes[1].content.contains("sources:"))
        XCTAssertTrue(plan.newNotes[1].content.hasSuffix("Matcher par chemin d'exécutable.\n"))

        // Déterminisme : mêmes entrées + même `now` → même plan.
        XCTAssertEqual(plan, try planSuccess(NotesCurationPlanner.plan(existing: [], output: output, now: now)))
    }
}
