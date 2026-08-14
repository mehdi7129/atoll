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

    // MARK: - Héritage des métadonnées

    /// Une note consolidée HÉRITE du projet, de la catégorie et de la date de
    /// naissance de ses sources. Sans cela, la première curation effaçait
    /// `project`/`category` et le regroupement par projet du tableau de bord
    /// disparaissait pour toujours (revue).
    func testCuratedNoteInheritsSourceMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = [
            (name: "a.md", content: """
            ---
            slug: piege-un
            category: pitfall
            project: /Users/x/Dynamic_Island
            created_at: 2026-07-18T08:00:00Z
            ---

            Premier piège.
            """),
            (name: "b.md", content: """
            ---
            slug: piege-deux
            category: pitfall
            project: /Users/x/Dynamic_Island
            created_at: 2026-07-20T08:00:00Z
            ---

            Second piège.
            """),
        ]
        // Contenu consolidé assez fourni pour passer le garde-fou de volume
        // (le refus pour rétrécissement a ses propres tests).
        let output = NotesCurationOutput(
            notes: [.init(title: "Pièges de build",
                          content: String(repeating: "Les deux pièges réunis. ", count: 20),
                          sources: ["a.md", "b.md"])],
            contradictions: []
        )
        let plan = try planSuccess(NotesCurationPlanner.plan(existing: existing, output: output, now: now))
        let content = try XCTUnwrap(plan.newNotes.first?.content)

        XCTAssertTrue(content.contains("category: pitfall"), content)
        XCTAssertTrue(content.contains("project: /Users/x/Dynamic_Island"), content)
        // La date de naissance la plus ANCIENNE (l'âge de la connaissance),
        // et la date de curation en plus, jamais à la place. La valeur passe
        // par l'échappement YAML (elle contient des `:`) — donc entre
        // guillemets, ce que l'inventaire déquote (vérifié plus bas).
        XCTAssertTrue(content.contains("created_at: \"2026-07-18T08:00:00Z\""), content)
        XCTAssertTrue(content.contains("curated_at: "), content)

        // Et l'inventaire relit bien tout ça (contrat verrouillé des deux côtés).
        let summary = LearningInventory.parse(
            fileName: plan.newNotes[0].fileName, contents: content)
        XCTAssertEqual(summary.project, "/Users/x/Dynamic_Island")
        XCTAssertEqual(summary.category, "pitfall")
        XCTAssertEqual(summary.title, "Pièges de build")
    }

    /// Sources sans métadonnées (ou inconnues) : aucune clé inventée.
    func testCuratedNoteOmitsUnknownMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let output = NotesCurationOutput(
            notes: [.init(title: "Sans héritage",
                          content: String(repeating: "Corps. ", count: 10),
                          sources: ["absent.md"])],
            contradictions: []
        )
        let plan = try planSuccess(NotesCurationPlanner.plan(
            existing: [(name: "autre.md", content: "pas de front-matter")],
            output: output, now: now))
        let content = try XCTUnwrap(plan.newNotes.first?.content)
        XCTAssertFalse(content.contains("project:"), content)
        XCTAssertFalse(content.contains("category:"), content)
        XCTAssertFalse(content.contains("created_at:"), content)
        XCTAssertTrue(content.contains("curated_at:"), content)
    }

    /// Une SECONDE curation qui rend les notes à l'identique doit passer.
    ///
    /// Comparer « fichier entier » (front-matter compris) à « corps nu » la
    /// faisait refuser en boucle : la curation hebdomadaire ne repassait plus
    /// jamais (audit du 2026-07-27). Une consolidation fusionne beaucoup de
    /// notes, donc son `sources:` est long — le front-matter pèse alors autant
    /// que le corps.
    func testIdenticalRecurationIsNotSeenAsShrink() throws {
        let corps = String(repeating: "contenu consolidé. ", count: 20)   // 380 car.
        let sources = (0..<12).map { "  - 2026-07-\(10 + $0)-note-source-longue.md" }
            .joined(separator: "\n")
        let fichier = """
        ---
        title: Pièges de build
        category: gotcha
        project: /Users/m/Desktop/Dynamic_Island
        created_at: 2026-07-20T10:00:00Z
        curated_at: 2026-07-26T00:22:12Z
        sources:
        \(sources)
        ---

        \(corps)
        """
        let existing = (0..<3).map { (name: "0\($0)-note.md", content: fichier) }
        let output = NotesCurationOutput(
            notes: (0..<3).map { NotesCurationOutput.Note(title: "Pièges de build \($0)",
                                                          content: corps, sources: []) },
            contradictions: [])

        // L'ANCIENNE mesure (fichier entier vs corps nu) aurait refusé : on le
        // vérifie pour que ce test ne devienne pas vert par accident.
        let volumeFichiers = existing.reduce(0) { $0 + $1.content.count }
        let volumeCorps = output.notes.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThan(Double(volumeCorps) / Double(volumeFichiers), 0.5,
                          "le jeu de test doit bien piéger l'ancienne mesure")

        let plan = NotesCurationPlanner.plan(existing: existing, output: output,
                                             now: try fixedNow())
        guard case .success = plan else {
            return XCTFail("re-curation à l'identique refusée : \(plan)")
        }
    }

    // MARK: - Les bornes du schéma sont REVALIDÉES (2026-08-14)

    /// Un schéma est une DEMANDE, pas une garantie : le parseur doit borner
    /// lui-même, comme le fait `RetrospectiveReport` depuis toujours.
    func testLeParsingBorneCeQueLeSchemaDemande() throws {
        let titre = String(repeating: "T", count: 300)
        let contenu = String(repeating: "C", count: 5000)
        let source = String(repeating: "s", count: 400)
        let sources = Array(repeating: "\"" + source + "\"", count: 30).joined(separator: ",")
        let une = "{\"title\":\"" + titre + "\",\"content\":\"" + contenu + "\",\"sources\":[" + sources + "]}"
        let toutes = Array(repeating: une, count: 45).joined(separator: ",")
        let json = "{\"structured_output\":{\"notes\":[" + toutes + "],\"contradictions\":[]}}"
        let out = try XCTUnwrap(NotesCurationOutput.parse(cliOutput: Data(json.utf8)))

        XCTAssertEqual(out.notes.count, NotesCurationPrompt.maxNotes, "45 notes proposées, 40 retenues")
        for n in out.notes {
            XCTAssertLessThanOrEqual(n.title.count, 100)
            XCTAssertLessThanOrEqual(n.content.count, NotesCurationPrompt.maxNoteCharacters)
            XCTAssertLessThanOrEqual(n.sources.count, 20)
            for s in n.sources { XCTAssertLessThanOrEqual(s.count, 120) }
        }
    }

    /// Idem pour les contradictions.
    func testLesContradictionsSontBorneesAussi() throws {
        let resume = String(repeating: "S", count: 900)
        let fichier = String(repeating: "f", count: 400)
        let fichiers = Array(repeating: "\"" + fichier + "\"", count: 15).joined(separator: ",")
        let une = "{\"summary\":\"" + resume + "\",\"files\":[" + fichiers + "]}"
        let toutes = Array(repeating: une, count: 25).joined(separator: ",")
        let json = "{\"structured_output\":{\"notes\":[],\"contradictions\":[" + toutes + "]}}"
        let out = try XCTUnwrap(NotesCurationOutput.parse(cliOutput: Data(json.utf8)))
        XCTAssertEqual(out.contradictions.count, 20)
        for k in out.contradictions {
            XCTAssertLessThanOrEqual(k.summary.count, 300)
            XCTAssertLessThanOrEqual(k.files.count, 10)
            for f in k.files { XCTAssertLessThanOrEqual(f.count, 120) }
        }
    }

    /// Une coupe ne doit jamais scinder un caractère composé.
    func testLaCoupeNeScindePasUnCaractere() throws {
        let emoji = String(repeating: "🇫🇷", count: 200)
        let json = "{\"structured_output\":{\"notes\":[{\"title\":\"" + emoji
            + "\",\"content\":\"c\",\"sources\":[]}],\"contradictions\":[]}}"
        let out = try XCTUnwrap(NotesCurationOutput.parse(cliOutput: Data(json.utf8)))
        let titre = try XCTUnwrap(out.notes.first?.title)
        XCTAssertEqual(titre.count, 100)
        XCTAssertTrue(titre.hasSuffix("🇫🇷"), "le drapeau n'est pas coupé en deux")
    }
}
