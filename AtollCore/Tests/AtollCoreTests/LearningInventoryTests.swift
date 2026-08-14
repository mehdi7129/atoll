import XCTest
@testable import AtollCore

final class LearningInventoryTests: XCTestCase {
    private var notesRoot: URL!
    private var inventory: LearningInventory!
    private let fm = FileManager.default
    // Horloge fixe (seconde pleine : l'ISO-8601 d'Atoll est à la seconde, la
    // date relue doit être STRICTEMENT égale à celle écrite).
    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        notesRoot = fm.temporaryDirectory
            .appendingPathComponent("LearningInventory-\(UUID().uuidString)")
            .appendingPathComponent("notes")
        try fm.createDirectory(at: notesRoot, withIntermediateDirectories: true)
        inventory = LearningInventory(notesRoot: notesRoot)
    }

    override func tearDownWithError() throws {
        if let notesRoot { try? fm.removeItem(at: notesRoot.deletingLastPathComponent()) }
    }

    // MARK: - Aides

    /// Écrit un fichier tel quel dans le dossier des notes.
    private func write(_ contents: String, to fileName: String) throws {
        try Data(contents.utf8).write(to: notesRoot.appendingPathComponent(fileName))
    }

    /// Sème une note AU FORMAT RÉEL, via le rendu de production : le test casse
    /// si `LearningNoteFile.render` change de format — c'est voulu.
    @discardableResult
    private func seedRenderedNote(
        slug: String,
        category: String = "piege",
        content: String = "Contenu de la note.",
        project: String? = "/Users/moi/Projet",
        date: Date? = nil
    ) throws -> String {
        let rendered = LearningNoteFile.render(
            note: RetrospectiveReport.Note(
                slug: slug, category: category, content: content, confidence: "haute"),
            sessionID: "sess-1",
            project: project,
            date: date ?? fixedNow
        )
        try write(rendered.contents, to: rendered.filename)
        return rendered.filename
    }

    // MARK: - Robustesse

    func testDossierAbsentRendListeVide() throws {
        let absent = LearningInventory(
            notesRoot: notesRoot.appendingPathComponent("nexiste-pas", isDirectory: true))
        XCTAssertTrue(absent.notes().isEmpty)
        XCTAssertTrue(absent.projects().isEmpty)
    }

    func testFichierNonUTF8IgnoreSansPlanter() throws {
        try seedRenderedNote(slug: "valide")
        // Octets impossibles en UTF-8 : le fichier est ignoré, pas la liste.
        try Data([0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28])
            .write(to: notesRoot.appendingPathComponent("binaire.md"))
        XCTAssertEqual(inventory.notes().map(\.slug), ["valide"])
    }

    func testFichierNonMarkdownIgnore() throws {
        try seedRenderedNote(slug: "valide")
        try write("---\nslug: pas-une-note\n---\ncorps", to: "notes.json")
        try write("---\nslug: pas-une-note-non-plus\n---\ncorps", to: "README.txt")
        XCTAssertEqual(inventory.notes().map(\.slug), ["valide"])
    }

    // MARK: - Parsing du front-matter

    func testNoteCompleteRelue() throws {
        let fileName = try seedRenderedNote(
            slug: "git-hygiene",
            category: "convention",
            content: "Toujours rebaser avant de pousser.",
            project: "/Users/moi/Dynamic_Island"
        )
        let note = try XCTUnwrap(inventory.notes().first)

        XCTAssertEqual(note.fileName, fileName)
        XCTAssertEqual(note.id, fileName)
        XCTAssertEqual(note.slug, "git-hygiene")
        XCTAssertEqual(note.category, "convention")
        XCTAssertEqual(note.project, "/Users/moi/Dynamic_Island")
        XCTAssertEqual(note.createdAt, fixedNow)
        // `render` n'écrit pas de `title:` → repli sur le slug.
        XCTAssertEqual(note.title, "git-hygiene")
        // Le corps SEUL est compté (ni front-matter, ni ligne vide de séparation,
        // ni saut de ligne final).
        XCTAssertEqual(note.characterCount, "Toujours rebaser avant de pousser.".count)
    }

    func testTitreExpliciteGagneSurLeSlug() throws {
        try write("""
        ---
        title: Pièges de build
        slug: pieges-build
        ---

        Corps.
        """, to: "note.md")
        let note = try XCTUnwrap(inventory.notes().first)
        XCTAssertEqual(note.title, "Pièges de build")
        XCTAssertEqual(note.slug, "pieges-build")
    }

    func testNoteSansFrontMatter() throws {
        // Pas de `---` du tout : aucune métadonnée, titre = nom de fichier,
        // corps = fichier ENTIER (blancs de bord exclus du compte).
        let corps = "# Note brute\n\nÉcrite à la main.\n"
        try write(corps, to: "memo-perso.md")
        let note = try XCTUnwrap(inventory.notes().first)

        XCTAssertEqual(note.title, "memo-perso")
        XCTAssertNil(note.slug)
        XCTAssertNil(note.category)
        XCTAssertNil(note.project)
        XCTAssertNil(note.createdAt)
        XCTAssertEqual(note.characterCount, "# Note brute\n\nÉcrite à la main.".count)
    }

    func testFrontMatterOuvrantSansFermantNestPasUnFrontMatter() throws {
        // Un `---` sans fermeture est du markdown, pas des métadonnées.
        try write("---\nslug: piege\n\nPas de fin de bloc.", to: "tronquee.md")
        let note = try XCTUnwrap(inventory.notes().first)
        XCTAssertNil(note.slug)
        XCTAssertEqual(note.title, "tronquee")
    }

    func testValeursQuoteesDequotees() throws {
        // Chemin contenant `:` et `"` → `yamlScalar` le quote et l'échappe au
        // rendu ; l'inventaire doit rendre EXACTEMENT la valeur d'origine.
        let projet = #"/Users/moi/l'été: dossier "chaud" \ 2026"#
        try seedRenderedNote(slug: "quotee", project: projet)
        let note = try XCTUnwrap(inventory.notes().first)
        XCTAssertEqual(note.project, projet)

        // Et à la main, pour verrouiller l'échappement lu (`\"` et `\\`).
        try write("""
        ---
        title: "Titre: avec \\" et \\\\ dedans"
        ---
        corps
        """, to: "manuelle.md")
        let manuelle = try XCTUnwrap(inventory.notes().first { $0.fileName == "manuelle.md" })
        XCTAssertEqual(manuelle.title, #"Titre: avec " et \ dedans"#)
    }

    func testCuratedAtReconnuEtItemsDeListeIgnores() throws {
        // Format des notes CURÉES (NotesCurationPlanner) : `title`, `curated_at`
        // et une liste `sources:` dont les items sont indentés.
        try write("""
        ---
        title: Synthèse des pièges
        curated_at: 2026-07-20T12:00:00Z
        sources:
          - 2026-07-19-un.md
          - project: /faux/chemin
          - "titre: piégeux"
        ---

        Corps curé.
        """, to: "01-synthese.md")

        let note = try XCTUnwrap(inventory.notes().first)
        XCTAssertEqual(note.title, "Synthèse des pièges")
        XCTAssertEqual(note.createdAt, Date(timeIntervalSince1970: 1_784_548_800))
        // Un item de liste n'est JAMAIS pris pour une clé, même s'il en a la forme.
        XCTAssertNil(note.project)
        XCTAssertNil(note.slug)
        XCTAssertEqual(note.characterCount, "Corps curé.".count)
    }

    func testCreatedAtPrioritaireSurCuratedAt() throws {
        try write("""
        ---
        created_at: 2026-07-20T12:00:00Z
        curated_at: 2026-07-25T12:00:00Z
        ---
        corps
        """, to: "deux-dates.md")
        XCTAssertEqual(inventory.notes().first?.createdAt,
                       Date(timeIntervalSince1970: 1_784_548_800))
    }

    func testDateAvecFractionDeSecondeAcceptee() throws {
        try write("---\ncreated_at: 2026-07-20T12:00:00.500Z\n---\ncorps", to: "fraction.md")
        XCTAssertEqual(inventory.notes().first?.createdAt,
                       Date(timeIntervalSince1970: 1_784_548_800.5))
    }

    func testMetadonneesIllisiblesNeCassentRien() throws {
        // Date invalide, clés inconnues, valeur vide : tout est absorbé.
        try write("""
        ---
        slug:
        created_at: pas-une-date
        confidence: haute
        source_session: abc
        ---
        corps
        """, to: "abimee.md")
        let note = try XCTUnwrap(inventory.notes().first)
        XCTAssertNil(note.slug)
        XCTAssertNil(note.createdAt)
        XCTAssertEqual(note.title, "abimee") // repli ultime : le nom de fichier
    }

    // MARK: - Tri

    func testTriParDateDecroissantePuisNomDeFichier() throws {
        // Deux notes datées + deux sans date, dont deux à la MÊME date.
        try seedRenderedNote(slug: "ancienne", date: fixedNow.addingTimeInterval(-86_400))
        try seedRenderedNote(slug: "recente-b", date: fixedNow)
        try seedRenderedNote(slug: "recente-a", date: fixedNow)
        try write("# sans date b", to: "zz-sans-date.md")
        try write("# sans date a", to: "aa-sans-date.md")

        let noms = inventory.notes().map(\.fileName)
        // Les datées d'abord (récentes → anciennes), départage par nom ;
        // les non datées ferment la marche, entre elles triées par nom.
        XCTAssertEqual(noms, [
            "2026-02-02-recente-a.md",
            "2026-02-02-recente-b.md",
            "2026-02-01-ancienne.md",
            "aa-sans-date.md",
            "zz-sans-date.md",
        ])
        // Ordre déterministe : deux appels rendent la même liste.
        XCTAssertEqual(inventory.notes(), inventory.notes())
    }

    // MARK: - Regroupement par projet

    func testProjectsRegroupeEtTrie() throws {
        try seedRenderedNote(slug: "a", project: "/Users/moi/Atoll")
        try seedRenderedNote(slug: "b", project: "/Users/moi/Atoll")
        try seedRenderedNote(slug: "c", project: "/Users/moi/Atoll")
        try seedRenderedNote(slug: "d", project: "/Users/moi/Zenith")
        try seedRenderedNote(slug: "e", project: "/Users/moi/Alpha")
        // Sans projet (le rendu omet la clé quand il est vide) → clé "".
        try seedRenderedNote(slug: "f", project: nil)
        try seedRenderedNote(slug: "g", project: "")

        let groupes = inventory.projects()
        XCTAssertEqual(groupes.map(\.project),
                       ["/Users/moi/Atoll", "", "/Users/moi/Alpha", "/Users/moi/Zenith"])
        XCTAssertEqual(groupes.map(\.count), [3, 2, 1, 1])
    }
}
