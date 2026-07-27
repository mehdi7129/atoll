import XCTest
@testable import AtollCore

final class SkillCatalogTests: XCTestCase {
    private var root: URL!
    private var skillsRoot: URL!
    private var commandsRoot: URL!
    private var pluginsCacheRoot: URL!
    private var settingsURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("SkillCatalog-\(UUID().uuidString)")
        skillsRoot = root.appendingPathComponent("skills")
        commandsRoot = root.appendingPathComponent("commands")
        pluginsCacheRoot = root.appendingPathComponent("plugins/cache")
        settingsURL = root.appendingPathComponent("settings.json")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Aides

    private func makeCatalog() -> SkillCatalog {
        SkillCatalog(skillsRoot: skillsRoot, commandsRoot: commandsRoot,
                     pluginsCacheRoot: pluginsCacheRoot, settingsURL: settingsURL)
    }

    private func write(_ contents: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// `~/.claude/skills/<dossier>/SKILL.md`. `declaredName` est le champ
    /// `name:` du front-matter — volontairement dissociable du dossier.
    @discardableResult
    private func seedUserSkill(directory: String, declaredName: String? = nil,
                               description: String = "desc") throws -> URL {
        let url = skillsRoot.appendingPathComponent("\(directory)/SKILL.md")
        try write("""
        ---
        name: \(declaredName ?? directory)
        description: \(description)
        ---

        # corps
        """, to: url)
        return url
    }

    /// `~/.claude/commands/<chemin relatif>` (« gsd/plan-phase.md », « crawl.md »).
    @discardableResult
    private func seedCommand(_ relativePath: String, description: String = "desc") throws -> URL {
        let url = commandsRoot.appendingPathComponent(relativePath)
        try write("""
        ---
        description: \(description)
        ---

        # corps
        """, to: url)
        return url
    }

    /// `<cache>/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md`.
    @discardableResult
    private func seedPluginSkill(marketplace: String = "mk", plugin: String,
                                 version: String, skill: String,
                                 description: String = "desc") throws -> URL {
        let url = pluginsCacheRoot
            .appendingPathComponent("\(marketplace)/\(plugin)/\(version)/skills/\(skill)/SKILL.md")
        try write("""
        ---
        name: \(skill)
        description: \(description)
        ---

        # corps
        """, to: url)
        return url
    }

    private func seedSettings(_ json: String) throws {
        try write(json, to: settingsURL)
    }

    private func entry(_ id: String, in entries: [CatalogEntry]) throws -> CatalogEntry {
        try XCTUnwrap(entries.first { $0.id == id }, "entrée « \(id) » absente")
    }

    /// `contentsOfDirectory` rend des URL aux liens résolus (`/private/var`
    /// plutôt que `/var` sur macOS) : on compare les chemins canoniques.
    private func assertSamePath(_ lhs: URL, _ rhs: URL,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.resolvingSymlinksInPath().standardizedFileURL.path,
                       rhs.resolvingSymlinksInPath().standardizedFileURL.path,
                       file: file, line: line)
    }

    // MARK: - Robustesse : racines absentes

    func testMissingRootsYieldEmptyCatalog() {
        // Rien n'existe sur disque : aucune erreur, aucune entrée.
        let catalog = makeCatalog()
        XCTAssertTrue(catalog.entries().isEmpty)
        XCTAssertEqual(catalog.summaryForPrompt(), "")
        XCTAssertEqual(catalog.counts(), [.userSkill: 0, .command: 0, .pluginSkill: 0])
    }

    func testDirectoryWithoutSkillFileIsIgnored() throws {
        try fm.createDirectory(at: skillsRoot.appendingPathComponent("pas-un-skill"),
                               withIntermediateDirectories: true)
        try seedUserSkill(directory: "vrai")
        XCTAssertEqual(makeCatalog().entries().map(\.id), ["vrai"])
    }

    // MARK: - Skills utilisateur

    func testUserSkillNominal() throws {
        let path = try seedUserSkill(directory: "atoll-recall",
                                     description: "Recherche dans la mémoire longue durée")
        let found = try entry("atoll-recall", in: makeCatalog().entries())

        XCTAssertEqual(found.name, "atoll-recall")
        XCTAssertEqual(found.description, "Recherche dans la mémoire longue durée")
        XCTAssertEqual(found.kind, .userSkill)
        XCTAssertEqual(found.origin, SkillCatalog.userSkillOrigin)
        XCTAssertTrue(found.isAvailable)
        assertSamePath(found.path, path)
    }

    /// PIÈGE N° 1 — collision réelle : `workflow-apex-free/SKILL.md` déclare
    /// `name: apex` alors que le dossier `apex/` existe. Le DOSSIER fait
    /// autorité, les deux skills restent distincts.
    func testFolderNameWinsOverLyingFrontMatter() throws {
        try seedUserSkill(directory: "apex", description: "le vrai apex")
        try seedUserSkill(directory: "workflow-apex-free", declaredName: "apex",
                          description: "le clone")

        let entries = makeCatalog().entries()
        XCTAssertEqual(entries.map(\.id), ["apex", "workflow-apex-free"])
        XCTAssertEqual(try entry("apex", in: entries).description, "le vrai apex")
        XCTAssertEqual(try entry("workflow-apex-free", in: entries).description, "le clone")
        // Le champ `name:` est bien lu — il n'entre simplement pas dans l'identité.
        let front = try XCTUnwrap(SkillCatalog.frontMatter(
            of: skillsRoot.appendingPathComponent("workflow-apex-free/SKILL.md")))
        XCTAssertEqual(front.name, "apex")
    }

    // MARK: - Slash commands (piège n° 2 : ce ne sont PAS des skills)

    func testNamespacedCommandIdentifier() throws {
        let path = try seedCommand("gsd/plan-phase.md",
                                   description: "Create detailed phase plan")
        let found = try entry("gsd:plan-phase", in: makeCatalog().entries())

        XCTAssertEqual(found.name, "plan-phase")
        XCTAssertEqual(found.kind, .command)
        XCTAssertEqual(found.origin, SkillCatalog.commandOrigin)
        XCTAssertEqual(found.description, "Create detailed phase plan")
        XCTAssertTrue(found.isAvailable)
        assertSamePath(found.path, path)
    }

    func testRootCommandHasNoNamespace() throws {
        try seedCommand("crawl.md")
        try seedCommand("gsd/do.md")
        XCTAssertEqual(makeCatalog().entries().map(\.id), ["crawl", "gsd:do"])
    }

    func testDeeplyNamespacedCommandJoinsAllSegments() throws {
        try seedCommand("a/b/cmd.md")
        XCTAssertEqual(makeCatalog().entries().map(\.id), ["a:b:cmd"])
    }

    // MARK: - Skills de plugins

    func testPluginSkillIdentifier() throws {
        let path = try seedPluginSkill(plugin: "superpowers", version: "6.2.0",
                                       skill: "brainstorming", description: "Explores intent")
        try seedSettings(#"{"enabledPlugins": {"superpowers@mk": true}}"#)

        let found = try entry("superpowers:brainstorming", in: makeCatalog().entries())
        XCTAssertEqual(found.name, "brainstorming")
        XCTAssertEqual(found.kind, .pluginSkill)
        XCTAssertEqual(found.origin, "superpowers")
        XCTAssertEqual(found.description, "Explores intent")
        XCTAssertTrue(found.isAvailable)
        assertSamePath(found.path, path)
    }

    /// PIÈGE N° 3 — deux versions installées côte à côte : une seule entrée,
    /// celle de la version la plus haute.
    func testHighestVersionWinsBetweenTwoInstalledVersions() throws {
        try seedPluginSkill(plugin: "superpowers", version: "6.1.1",
                            skill: "brainstorming", description: "vieux")
        try seedPluginSkill(plugin: "superpowers", version: "6.2.0",
                            skill: "brainstorming", description: "neuf")

        let entries = makeCatalog().entries()
        XCTAssertEqual(entries.count, 1)
        let found = try entry("superpowers:brainstorming", in: entries)
        XCTAssertEqual(found.description, "neuf")
        XCTAssertTrue(found.path.path.contains("/6.2.0/"))
    }

    /// `unknown` n'est pas une version : elle perd contre n'importe quelle autre.
    func testUnknownVersionAlwaysLoses() throws {
        try seedPluginSkill(plugin: "plug", version: SkillCatalog.unknownVersion,
                            skill: "a", description: "inconnue")
        try seedPluginSkill(plugin: "plug", version: "1.0.0", skill: "a",
                            description: "chiffrée")

        let found = try entry("plug:a", in: makeCatalog().entries())
        XCTAssertEqual(found.description, "chiffrée")
    }

    func testUnknownVersionAloneIsStillIndexed() throws {
        try seedPluginSkill(plugin: "plug", version: SkillCatalog.unknownVersion, skill: "a")
        XCTAssertEqual(makeCatalog().entries().map(\.id), ["plug:a"])
    }

    func testVersionComparisonRules() {
        // Numérique par composants dès que les deux versions le sont.
        XCTAssertTrue(SkillCatalog.isVersion("6.1.1", lowerThan: "6.2.0"))
        XCTAssertFalse(SkillCatalog.isVersion("6.2.0", lowerThan: "6.1.1"))
        XCTAssertTrue(SkillCatalog.isVersion("1.2", lowerThan: "1.2.1"))
        // 10 > 9 : c'est justement ce que le lexicographique raterait.
        XCTAssertTrue(SkillCatalog.isVersion("2.9.0", lowerThan: "2.10.0"))
        // `unknown` et la chaîne vide perdent toujours.
        XCTAssertTrue(SkillCatalog.isVersion("unknown", lowerThan: "0.0.1"))
        XCTAssertFalse(SkillCatalog.isVersion("0.0.1", lowerThan: "unknown"))
        XCTAssertFalse(SkillCatalog.isVersion("unknown", lowerThan: "unknown"))
        XCTAssertTrue(SkillCatalog.isVersion("", lowerThan: "b29e7cf65e5c"))
        // Non numérique (hachages du cache `anthropic-agent-skills`) →
        // lexicographique, jamais de crash.
        XCTAssertTrue(SkillCatalog.isVersion("1f630fdf9259", lowerThan: "9d2f1ae18723"))
        XCTAssertFalse(SkillCatalog.isVersion("b29e7cf65e5c", lowerThan: "9d2f1ae18723"))
        XCTAssertFalse(SkillCatalog.isVersion("1.0.0", lowerThan: "1.0.0"))
    }

    /// Seul le `skills/` du plugin est chargé par Claude Code : la charge utile
    /// de dépôt (`cli-tool/components/skills/…`) n'est pas de l'invocable et ne
    /// doit pas se faire passer pour tel.
    func testSkillFilesOutsideThePluginSkillsFolderAreIgnored() throws {
        try seedPluginSkill(plugin: "security-pro", version: "1.0.0", skill: "audit")
        try write("---\nname: theme-factory\n---\n", to: pluginsCacheRoot.appendingPathComponent(
            "mk/security-pro/1.0.0/cli-tool/components/skills/creative/theme-factory/SKILL.md"))

        XCTAssertEqual(makeCatalog().entries().map(\.id), ["security-pro:audit"])
    }

    // MARK: - Activation des plugins (piège n° 4)

    func testPluginAbsentFromEnabledPluginsIsUnavailable() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        try seedPluginSkill(plugin: "swift-lsp", version: "1.0.0", skill: "lsp")
        try seedSettings(#"{"enabledPlugins": {"swift-lsp@mk": true, "autre@mk": false}}"#)

        let entries = makeCatalog().entries()
        // Absent de la table → pas invocable, mais TOUJOURS listé : c'est une
        // antériorité (« ça existe, il suffit de l'activer »).
        XCTAssertFalse(try entry("hookify:writing-rules", in: entries).isAvailable)
        XCTAssertTrue(try entry("swift-lsp:lsp", in: entries).isAvailable)
    }

    func testPluginExplicitlyDisabledIsUnavailable() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        try seedSettings(#"{"enabledPlugins": {"hookify@mk": false}}"#)
        XCTAssertFalse(try entry("hookify:writing-rules", in: makeCatalog().entries()).isAvailable)
    }

    /// DÉGRADATION SÛRE : settings illisible → tout disponible. Masquer un
    /// skill par erreur ferait proposer un doublon ; l'inverse ne coûte rien.
    func testUnreadableSettingsMakesEverythingAvailable() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        try seedSettings("{ ceci n'est pas du JSON")
        XCTAssertTrue(try entry("hookify:writing-rules", in: makeCatalog().entries()).isAvailable)
    }

    func testMissingSettingsFileMakesEverythingAvailable() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        // Aucun settings.json écrit du tout.
        XCTAssertTrue(try entry("hookify:writing-rules", in: makeCatalog().entries()).isAvailable)
    }

    func testSettingsWithoutEnabledPluginsKeyMakesEverythingAvailable() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        try seedSettings(#"{"model": "opus"}"#)
        XCTAssertTrue(try entry("hookify:writing-rules", in: makeCatalog().entries()).isAvailable)
    }

    func testEmptyEnabledPluginsMeansNothingIsEnabled() throws {
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules")
        // Table présente mais vide : ce n'est pas de l'ignorance, c'est une réponse.
        try seedSettings(#"{"enabledPlugins": {}}"#)
        XCTAssertFalse(try entry("hookify:writing-rules", in: makeCatalog().entries()).isAvailable)
    }

    /// Le même plugin dans deux marketplaces : la version la plus haute fixe le
    /// contenu, mais l'entrée est invocable dès qu'UNE copie est activée.
    func testAvailabilityIsTrueIfAnyInstalledCopyIsEnabled() throws {
        try seedPluginSkill(marketplace: "officiel", plugin: "security-guidance",
                            version: "2.0.6", skill: "audit", description: "récent")
        try seedPluginSkill(marketplace: "communaute", plugin: "security-guidance",
                            version: "2.0.0", skill: "audit", description: "ancien")
        try seedSettings("""
        {"enabledPlugins": {"security-guidance@officiel": false,
                            "security-guidance@communaute": true}}
        """)

        let entries = makeCatalog().entries()
        XCTAssertEqual(entries.count, 1)
        let found = try entry("security-guidance:audit", in: entries)
        XCTAssertEqual(found.description, "récent")
        XCTAssertTrue(found.isAvailable)
    }

    // MARK: - Tri, déduplication, comptes

    func testSortedByKindThenIdentifier() throws {
        try seedPluginSkill(plugin: "plug", version: "1.0.0", skill: "zeta")
        try seedCommand("b.md")
        try seedCommand("a.md")
        try seedUserSkill(directory: "zzz")
        try seedUserSkill(directory: "aaa")

        XCTAssertEqual(makeCatalog().entries().map(\.id),
                       ["aaa", "zzz", "a", "b", "plug:zeta"])
    }

    /// Collision d'identifiant entre sources : le plus proche de l'utilisateur
    /// gagne (utilisateur > command > plugin).
    func testDuplicateIdentifierKeepsHighestPrioritySource() throws {
        try seedUserSkill(directory: "commit", description: "skill utilisateur")
        try seedCommand("commit.md", description: "slash command")

        let entries = makeCatalog().entries()
        XCTAssertEqual(entries.count, 1)
        let found = try entry("commit", in: entries)
        XCTAssertEqual(found.kind, .userSkill)
        XCTAssertEqual(found.description, "skill utilisateur")
    }

    func testCounts() throws {
        try seedUserSkill(directory: "a")
        try seedUserSkill(directory: "b")
        try seedCommand("gsd/x.md")
        try seedPluginSkill(plugin: "p", version: "1.0.0", skill: "s1")
        try seedPluginSkill(plugin: "p", version: "1.0.0", skill: "s2")
        try seedPluginSkill(plugin: "p", version: "1.0.0", skill: "s3")

        XCTAssertEqual(makeCatalog().counts(),
                       [.userSkill: 2, .command: 1, .pluginSkill: 3])
    }

    func testEntriesAreDeterministic() throws {
        try seedUserSkill(directory: "a")
        try seedCommand("gsd/x.md")
        try seedPluginSkill(plugin: "p", version: "1.0.0", skill: "s")
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.entries(), catalog.entries())
    }

    // MARK: - Rendu pour prompt

    func testSummaryFormat() throws {
        try seedUserSkill(directory: "atoll-recall", description: "Recherche mémoire")
        try seedCommand("gsd/plan-phase.md", description: "Plan de phase")
        try seedPluginSkill(plugin: "hookify", version: "1.0.0", skill: "writing-rules",
                            description: "Règles")
        try seedSettings(#"{"enabledPlugins": {"autre@mk": true}}"#)

        XCTAssertEqual(makeCatalog().summaryForPrompt(), """
        - atoll-recall (utilisateur) : Recherche mémoire
        - gsd:plan-phase (command) : Plan de phase
        - hookify:writing-rules (hookify) [désactivé] : Règles
        """)
    }

    func testSummaryMarksMissingDescription() throws {
        try write("# pas de front-matter", to: skillsRoot.appendingPathComponent("nu/SKILL.md"))
        XCTAssertEqual(makeCatalog().summaryForPrompt(), "- nu (utilisateur) : (sans description)")
    }

    func testSummaryIsDeterministic() throws {
        for index in 0..<12 { try seedUserSkill(directory: "skill-\(index)") }
        try seedCommand("gsd/plan-phase.md")
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.summaryForPrompt(), catalog.summaryForPrompt())
    }

    /// Cap par NOMBRE d'entrées : la coupe est annoncée, sinon le modèle
    /// conclurait « rien d'équivalent » à partir d'une liste partielle.
    func testSummaryCapsByEntryCountAndAnnouncesTruncation() throws {
        for index in 0..<10 { try seedUserSkill(directory: "skill-\(index)") }

        let lines = makeCatalog().summaryForPrompt(limit: 3).split(separator: "\n")
        XCTAssertEqual(lines.count, 4) // 3 entrées + le marqueur
        XCTAssertTrue(lines[0].hasPrefix("- skill-0 (utilisateur)"))
        XCTAssertEqual(String(lines[3]), SkillCatalog.truncationMarker(7))
    }

    func testSummaryWithZeroLimitStillAnnouncesEverything() throws {
        try seedUserSkill(directory: "a")
        try seedUserSkill(directory: "b")
        XCTAssertEqual(makeCatalog().summaryForPrompt(limit: 0),
                       SkillCatalog.truncationMarker(2))
    }

    /// Cap par CARACTÈRES : même avec une limite d'entrées large, le rendu ne
    /// dépasse jamais `maxSummaryCharacters`.
    func testSummaryCapsByCharacterBudget() throws {
        let long = String(repeating: "z", count: 320)
        for index in 0..<200 {
            try seedUserSkill(directory: String(format: "skill-%03d", index), description: long)
        }

        let summary = makeCatalog().summaryForPrompt(limit: 400)
        XCTAssertLessThanOrEqual(summary.count, SkillCatalog.maxSummaryCharacters)
        let lines = summary.split(separator: "\n")
        XCTAssertLessThan(lines.count, 200) // la coupe a bien eu lieu
        XCTAssertTrue(lines.last!.hasPrefix("… "), "la troncature doit être annoncée")
    }

    // MARK: - Descriptions (aplatissement, cap, formes YAML)

    func testMultilineBlockDescriptionIsFlattened() throws {
        try write("""
        ---
        name: claude-api
        description: |-
          Reference   for the Claude API
          TRIGGER — ne doit PAS apparaître dans le résumé.
        license: LICENSE.txt
        ---

        # corps
        """, to: skillsRoot.appendingPathComponent("claude-api/SKILL.md"))

        let found = try entry("claude-api", in: makeCatalog().entries())
        XCTAssertEqual(found.description, "Reference for the Claude API")
    }

    func testFoldedAndQuotedDescriptions() {
        XCTAssertEqual(
            SkillCatalog.parseFrontMatter("---\ndescription: >-\n  plié\n---\n").description,
            "plié")
        XCTAssertEqual(
            SkillCatalog.parseFrontMatter("---\ndescription: \"guillemets \\\"internes\\\"\"\n---\n")
                .description,
            "guillemets \"internes\"")
        XCTAssertEqual(
            SkillCatalog.parseFrontMatter("---\ndescription: 'simples'\n---\n").description,
            "simples")
    }

    func testDescriptionIsCappedAtThreeHundredCharacters() throws {
        try seedUserSkill(directory: "bavard", description: String(repeating: "x", count: 900))
        let found = try entry("bavard", in: makeCatalog().entries())
        XCTAssertEqual(found.description.count, 300)
        XCTAssertTrue(found.description.hasSuffix("…"))
    }

    func testFlattenedCollapsesWhitespaceAndDropsControlCharacters() {
        XCTAssertEqual(SkillCatalog.flattened("  a\t\tb\n\n c  "), "a b c")
        XCTAssertEqual(SkillCatalog.flattened("a\u{0007}b"), "ab")
        XCTAssertEqual(SkillCatalog.flattened(""), "")
    }

    func testFrontMatterRequiresBothFences() {
        // `---` ouvrant sans fermant : ce n'est pas un front-matter.
        let orphan = SkillCatalog.parseFrontMatter("---\ndescription: rien\n\n# corps")
        XCTAssertNil(orphan.name)
        XCTAssertEqual(orphan.description, "")
        // Lignes vides de tête tolérées, fins de ligne Windows aussi.
        let tolerated = SkillCatalog.parseFrontMatter("\n\n---\r\ndescription: ok\r\n---\r\n")
        XCTAssertEqual(tolerated.description, "ok")
    }

    func testFrontMatterIgnoresIndentedAndListLines() {
        // Une ligne indentée n'est jamais une clé, même si elle contient un `:`.
        let parsed = SkillCatalog.parseFrontMatter("""
        ---
        allowed-tools:
          - Bash: ls
        description: la bonne
        ---
        """)
        XCTAssertEqual(parsed.description, "la bonne")
    }

    func testUnreadableSkillFileIsNotAnEntry() throws {
        // Dossier nommé `SKILL.md` : impossible à ouvrir comme fichier.
        try fm.createDirectory(at: skillsRoot.appendingPathComponent("piege/SKILL.md"),
                               withIntermediateDirectories: true)
        try seedUserSkill(directory: "bon")
        XCTAssertEqual(makeCatalog().entries().map(\.id), ["bon"])
    }

    func testBinarySkillFileYieldsEntryWithoutDescription() throws {
        let url = skillsRoot.appendingPathComponent("binaire/SKILL.md")
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x01, 0xC3]).write(to: url)

        // Le dossier a bien un SKILL.md : c'est un skill, simplement muet.
        let found = try entry("binaire", in: makeCatalog().entries())
        XCTAssertEqual(found.description, "")
    }

    // MARK: - Aucune écriture

    func testCatalogNeverWritesAnything() throws {
        try seedUserSkill(directory: "a")
        let before = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        let catalog = makeCatalog()
        _ = catalog.entries()
        _ = catalog.counts()
        _ = catalog.summaryForPrompt()
        let after = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(before, after)
    }


    // MARK: - Détection locale d'antériorité (jalon 12b)

    /// Un skill proposé qui refait un skill existant doit être repéré SANS
    /// modèle : la garantie « aucune proposition ne duplique l'existant » ne
    /// peut pas dépendre du bon vouloir d'une analyse.
    func testClosestMatchFindsAnObviousDuplicate() throws {
        try seedUserSkill(directory: "commit",
                          description: "Quick commit and push with minimal, clean messages")
        let catalog = makeCatalog()

        let match = catalog.closestMatch(
            slug: "quick-commit-push",
            title: "Commit and push quickly",
            description: "Quick commit and push with clean messages"
        )
        XCTAssertEqual(match?.id, "commit")
    }

    /// Un sujet réellement différent ne doit RIEN signaler : un avertissement
    /// systématique s'apprend à ignorer.
    func testClosestMatchStaysSilentOnUnrelatedSkill() throws {
        try seedUserSkill(directory: "commit",
                          description: "Quick commit and push with minimal, clean messages")
        let catalog = makeCatalog()

        XCTAssertNil(catalog.closestMatch(
            slug: "notarisation-dmg",
            title: "Notariser un DMG signé Developer ID",
            description: "Build Release, notarytool, staple et vérification Gatekeeper"
        ))
    }

    /// Trop peu de matière pour juger → nil (pas de faux positif sur un titre
    /// réduit à des mots vides).
    func testClosestMatchNeedsEnoughSignal() throws {
        try seedUserSkill(directory: "commit", description: "Quick commit and push")
        let catalog = makeCatalog()
        XCTAssertNil(catalog.closestMatch(slug: "x", title: "Use", description: ""))
    }

    /// Les mots trop courants (« skill », « claude », « session »…) ne créent
    /// pas de ressemblance.
    func testGenericWordsAreIgnored() {
        let words = SkillCatalog.significantWords(from: "Un skill Claude pour la session projet")
        XCTAssertFalse(words.contains("skill"))
        XCTAssertFalse(words.contains("claude"))
        XCTAssertFalse(words.contains("session"))
    }

    /// RÉGRESSION MESURÉE : la rétrospective rédige en FRANÇAIS, 89 des 119
    /// descriptions du catalogue sont en ANGLAIS — la comparaison par le texte
    /// ratait 5 des 6 vrais doublons de la machine. Les IDENTIFIANTS, eux,
    /// restent en anglais des deux côtés : c'est le filet qui compte.
    func testClosestMatchCrossesTheLanguageBarrierViaIdentifiers() throws {
        try seedUserSkill(directory: "fix-pr-comments",
                          description: "Fetch PR review comments and implement all requested changes")
        try seedUserSkill(directory: "create-pr",
                          description: "Create and push PR with auto-generated title and description")
        let catalog = makeCatalog()

        // Titre et description en français, slug en anglais (le cas réel).
        let match = catalog.closestMatch(
            slug: "fix-pr-comments-workflow",
            title: "Traiter les commentaires de revue d'une pull request",
            description: "Récupérer les commentaires et appliquer les corrections demandées"
        )
        XCTAssertEqual(match?.id, "fix-pr-comments")
    }

    /// Une mise à jour d'un skill déjà appris ne doit pas se signaler comme son
    /// propre doublon (`atoll-<slug>` est SON installation précédente).
    func testClosestMatchCanExcludeTheProposalTwin() throws {
        try seedUserSkill(directory: "atoll-release-pipeline",
                          description: "Publier une release Atoll avec appcast Sparkle correct")
        let catalog = makeCatalog()

        XCTAssertEqual(
            catalog.closestMatch(slug: "release-pipeline",
                                 title: "Publier une release Atoll",
                                 description: "Build, notarisation, DMG, appcast")?.id,
            "atoll-release-pipeline",
            "sans exclusion, le jumeau est bien trouvé"
        )
        XCTAssertNil(
            catalog.closestMatch(slug: "release-pipeline",
                                 title: "Publier une release Atoll",
                                 description: "Build, notarisation, DMG, appcast",
                                 excluding: ["atoll-release-pipeline"]),
            "exclu : une mise à jour n'est pas un doublon d'elle-même"
        )
    }
}
