import XCTest
@testable import AtollCore

final class LearningNoveltyTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("LearningNovelty-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func note(_ slug: String = "axis-check", body: String = "L'export emploie des mètres.", category: String = "project-fact") -> RetrospectiveReport.Note {
        .init(slug: slug, category: category, content: body, confidence: "high")
    }
    private func skill(_ slug: String = "axis-check", body: String = "Vérifier l'axe Z.\n\n    export --axis Z", description: String = "Vérifier un export de positions.") -> RetrospectiveReport.SkillProposal {
        .init(slug: slug, title: slug, description: description, skillMD: body, rationale: "Procédure éprouvée", confidence: "high")
    }
    private func seed(_ proposal: RetrospectiveReport.SkillProposal, store: LearnedSkillStore, name: String = UUID().uuidString) throws -> SkillProposal {
        let directory = store.proposedDirectory.appendingPathComponent(name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = LearningSkillProposalFile.renderMeta(proposal, sessionID: "fixture", project: nil,
            date: Date(timeIntervalSince1970: 1), flags: [], destination: store.destination)
        try meta.write(to: directory.appendingPathComponent("meta.json"))
        let body = LearningSkillProposalFile.renderSkillMD(proposal)
        try body.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(SkillProposal.decode(metaJSON: meta, skillMD: body, directoryURL: directory))
    }

    func testNoteIdentityIgnoresSlugButPreservesProjectCategoryAndCodeWhitespace() throws {
        let original = note()
        let rendered = LearningNoteFile.render(note: original, sessionID: "one", project: "/project-a", date: .distantPast)
        try rendered.contents.write(to: root.appendingPathComponent(rendered.filename), atomically: true, encoding: .utf8)
        var history = LearningNoteHistory.read(from: root)
        XCTAssertTrue(history.contains(note("renamed"), project: "/project-a"))
        XCTAssertFalse(history.contains(original, project: "/project-b"))
        XCTAssertFalse(history.contains(note(category: "decision"), project: "/project-a"))
        XCTAssertFalse(history.contains(note(body: "L'export  emploie des mètres."), project: "/project-a"))
        let changed = note(body: "L'export emploie des centimètres.")
        XCTAssertFalse(history.contains(changed, project: "/project-a"))
        history.record(changed, project: "/project-a")
        XCTAssertTrue(history.contains(changed, project: "/project-a"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(rendered.filename), encoding: .utf8), rendered.contents)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).count, 1, "La déduplication n'écrit ni ne supprime un souvenir.")
    }

    func testNoteSummaryAndSlugsAreBoundedAndPreferRelevantProject() {
        var history = LearningNoteHistory()
        for index in 0..<200 {
            history.record(note("noise-\(index)", body: "Texte ordinaire \(index)."), project: "/unrelated")
        }
        history.record(note("houdini-export", body: "Houdini exporte les axes en mètres."), project: "/houdini")
        let summary = history.summary(project: "/houdini", query: "export Houdini", maxCharacters: 300)
        XCTAssertLessThanOrEqual(summary.count, 300)
        XCTAssertTrue(summary.contains("houdini-export"))
        XCTAssertFalse(summary.contains("noise-"))
        let slugs = history.slugs(project: "/houdini", query: "export Houdini", limit: 1, maxCharacters: 30)
        XCTAssertEqual(slugs, ["houdini-export"])
        XCTAssertEqual(history.summary(project: nil, query: "", maxCharacters: 0), "")
        XCTAssertTrue(history.slugs(project: nil, query: "", limit: 0).isEmpty)
        XCTAssertTrue(history.slugs(project: nil, query: "", maxCharacters: 1).isEmpty)
    }

    func testPendingAndRejectedExactSkillsAreKnownButDifferentProcedureSurvives() throws {
        let store = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("skills"))
        let proposal = try seed(skill(), store: store)
        XCTAssertTrue(store.noveltyHistory().contains(skill("renamed")))
        XCTAssertTrue(store.noveltyHistory().summary(query: "axis export").contains("[proposed]"))
        try store.reject(proposal)
        let history = store.noveltyHistory()
        XCTAssertTrue(history.contains(skill("renamed")))
        XCTAssertTrue(history.summary(query: "axis export").contains("[rejected]"))
        XCTAssertFalse(history.contains(skill(body: "Vérifier l'axe Y.\n\n    export --axis Y")))
        XCTAssertFalse(history.contains(skill(body: "Vérifier l'axe Z.\n\nexport --axis Z")), "L'indentation du code est significative.")
        XCTAssertFalse(history.contains(skill(description: "Une autre condition de déclenchement.")))
    }

    func testSkillHistoriesAreIsolatedByProviderAndCodexHome() throws {
        let claude = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("claude/skills"))
        let codexA = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("codex-a/skills"), destination: .codex)
        let codexB = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("codex-b/skills"), destination: .codex)
        try seed(skill(), store: claude)
        XCTAssertTrue(claude.noveltyHistory().contains(skill()))
        XCTAssertFalse(codexA.noveltyHistory().contains(skill()))
        try seed(skill(), store: codexA)
        XCTAssertTrue(codexA.noveltyHistory().contains(skill()))
        XCTAssertFalse(codexB.noveltyHistory().contains(skill()))
    }

    func testSkillHistorySummaryIsBoundedWithoutDiscardingExactIdentity() {
        var history = LearningSkillHistory()
        for index in 0..<200 { history.record(skill("skill-\(index)", body: "Commande exacte \(index)"), status: .proposed) }
        let summary = history.summary(query: "Commande", maxCharacters: 300)
        XCTAssertLessThanOrEqual(summary.count, 300)
        XCTAssertTrue(summary.contains("Antériorité partielle."))
        XCTAssertTrue(history.contains(skill("renamed", body: "Commande exacte 0")))
        XCTAssertEqual(history.summary(query: "", maxCharacters: 0), "")
        XCTAssertLessThanOrEqual(history.summary(query: "", maxCharacters: 5).count, 5)
    }

    func testUnreadableArtifactDoesNotClaimCompleteHistory() throws {
        try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("broken.md"))
        let history = LearningNoteHistory.read(from: root)
        XCTAssertTrue(history.incomplete)
        XCTAssertTrue(history.summary(project: nil, query: "").contains("Antériorité partielle."))
    }

    func testUnavailableHistoryRootIsPartialButMissingRootIsNormal() throws {
        let notes = root.appendingPathComponent("notes")
        XCTAssertFalse(LearningNoteHistory.read(from: notes).incomplete)
        try Data("répertoire remplacé".utf8).write(to: notes)
        let history = LearningNoteHistory.read(from: notes)
        XCTAssertTrue(history.incomplete)
        XCTAssertTrue(history.summary(project: nil, query: "").contains("Antériorité partielle."))
        let store = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("skills"))
        XCTAssertFalse(store.noveltyHistory().incomplete)
        try Data("répertoire remplacé".utf8).write(to: store.proposedDirectory)
        XCTAssertTrue(store.noveltyHistory().incomplete)
        XCTAssertTrue(store.noveltyHistory().summary(query: "").contains("Antériorité partielle."))
    }
    func testFreshHistorySeesConcurrentInstallationWithoutAnArchive() throws {
        let skills = root.appendingPathComponent("skills")
        let store = LearnedSkillStore(learningRoot: root, skillsRoot: skills)
        let stale = store.noveltyHistory()
        XCTAssertFalse(stale.contains(skill()))
        let directory = skills.appendingPathComponent("installed-outside-atoll")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try LearningSkillProposalFile.renderSkillMD(skill("another-name"))
            .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.noveltyHistory().contains(skill()))
        XCTAssertFalse(stale.contains(skill()), "L'appelant doit rafraîchir juste avant application.")
    }

}
