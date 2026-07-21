import XCTest
@testable import AtollCore

final class LearnedSkillStoreTests: XCTestCase {
    private var root: URL!
    private var learningRoot: URL!
    private var skillsRoot: URL!
    private var store: LearnedSkillStore!
    private let fm = FileManager.default
    // Horloge fixe : les noms de dossiers d'archive sont déterministes.
    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("LearnedSkill-\(UUID().uuidString)")
        learningRoot = root.appendingPathComponent("learning")
        skillsRoot = root.appendingPathComponent("skills")
        try fm.createDirectory(at: learningRoot.appendingPathComponent("proposed"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        store = LearnedSkillStore(learningRoot: learningRoot, skillsRoot: skillsRoot,
                                  now: { self.fixedNow })
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Aides

    @discardableResult
    private func seedProposal(slug: String, status: String = "proposed",
                              skillMD: String = "---\nname: atoll-x\n---\n# corps") throws -> URL {
        let dir = learningRoot.appendingPathComponent("proposed/\(slug)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = """
        { "v": 1, "slug": "\(slug)", "title": "Titre \(slug)",
          "description": "desc", "rationale": "r", "source_session": "s",
          "project": "/p", "created_at": "2026-07-20T18:00:00Z",
          "status": "\(status)", "flags": [] }
        """
        try Data(meta.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data(skillMD.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        return dir
    }

    private func plantForeignSkill(_ name: String) throws {
        let dir = skillsRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("# skill tiers".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
    }

    private func exists(_ relativePath: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    // MARK: - Découverte

    func testDiscoverProposals() throws {
        try seedProposal(slug: "beta")
        try seedProposal(slug: "alpha")
        let found = store.discoverProposals()
        XCTAssertEqual(found.count, 2)
        // Même date de création → départage par id (nom de dossier).
        XCTAssertEqual(found.map(\.slug), ["alpha", "beta"])
    }

    func testDiscoverIgnoresMalformedMeta() throws {
        try seedProposal(slug: "bon")
        let mauvais = learningRoot.appendingPathComponent("proposed/mauvais", isDirectory: true)
        try fm.createDirectory(at: mauvais, withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: mauvais.appendingPathComponent("meta.json"))
        // Un dossier proposé de statut ≠ proposed n'apparaît pas non plus.
        try seedProposal(slug: "decidee", status: "approved")
        XCTAssertEqual(store.discoverProposals().map(\.slug), ["bon"])
    }

    // MARK: - Approbation

    func testApproveInstallsSkillAndManifest() throws {
        try seedProposal(slug: "git-hygiene", skillMD: "# contenu final")
        let proposal = try XCTUnwrap(store.discoverProposals().first)
        let entry = try store.approve(proposal)

        XCTAssertEqual(entry.dirName, "atoll-git-hygiene")
        XCTAssertTrue(exists("skills/atoll-git-hygiene/SKILL.md"))
        XCTAssertEqual(try String(contentsOf: skillsRoot.appendingPathComponent("atoll-git-hygiene/SKILL.md"), encoding: .utf8),
                       "# contenu final")
        XCTAssertEqual(store.installedSkills().map(\.slug), ["git-hygiene"])
        // La proposition a quitté la file d'attente vers l'archive approved/.
        XCTAssertFalse(exists("learning/proposed/git-hygiene"))
        XCTAssertTrue(store.discoverProposals().isEmpty)
    }

    func testApproveIsAtomicOnDisk() throws {
        try seedProposal(slug: "atomique")
        let proposal = try XCTUnwrap(store.discoverProposals().first)
        try store.approve(proposal)
        // Aucun dossier de staging temporaire résiduel dans skillsRoot.
        let leftovers = try fm.contentsOfDirectory(atPath: skillsRoot.path)
            .filter { $0.hasPrefix(".atoll-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testApproveRefusesUnmanagedCollision() throws {
        // Un dossier atoll-collision existe HORS manifeste (perso de l'utilisateur).
        try plantForeignSkill("atoll-collision")
        try seedProposal(slug: "collision")
        let proposal = try XCTUnwrap(store.discoverProposals().first)
        XCTAssertThrowsError(try store.approve(proposal)) { error in
            XCTAssertEqual(error as? LearnedSkillError,
                           .collisionWithUnmanagedDirectory("atoll-collision"))
        }
        // Le dossier étranger est intact, rien n'a été installé.
        XCTAssertEqual(try String(contentsOf: skillsRoot.appendingPathComponent("atoll-collision/SKILL.md"), encoding: .utf8),
                       "# skill tiers")
    }

    func testApproveUpdatesManagedSkillWithBackup() throws {
        try seedProposal(slug: "maj", skillMD: "# v1")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        // Nouvelle proposition, même slug, contenu différent.
        try seedProposal(slug: "maj", skillMD: "# v2")
        let v2 = try XCTUnwrap(store.discoverProposals().first)
        try store.approve(v2)

        XCTAssertEqual(try String(contentsOf: skillsRoot.appendingPathComponent("atoll-maj/SKILL.md"), encoding: .utf8),
                       "# v2")
        // updatedAt renseigné à la mise à jour.
        XCTAssertNotNil(store.installedSkills().first { $0.slug == "maj" }?.updatedAt)
    }

    func testApproveRefusesUserModifiedWithoutForce() throws {
        try seedProposal(slug: "modif", skillMD: "# officiel")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        // L'utilisateur édite le skill installé à la main.
        try Data("# édité à la main".utf8)
            .write(to: skillsRoot.appendingPathComponent("atoll-modif/SKILL.md"))
        try seedProposal(slug: "modif", skillMD: "# nouvelle version")
        let update = try XCTUnwrap(store.discoverProposals().first)

        XCTAssertThrowsError(try store.approve(update)) { error in
            XCTAssertEqual(error as? LearnedSkillError, .userModifiedWithoutForce("modif"))
        }
        // force: true accepte (et archive l'édition manuelle d'abord).
        XCTAssertNoThrow(try store.approve(update, force: true))
        XCTAssertEqual(try String(contentsOf: skillsRoot.appendingPathComponent("atoll-modif/SKILL.md"), encoding: .utf8),
                       "# nouvelle version")
    }

    // MARK: - Rejet / archivage

    func testRejectMovesToArchiveNothingDeleted() throws {
        try seedProposal(slug: "rejetee")
        let proposal = try XCTUnwrap(store.discoverProposals().first)
        try store.reject(proposal)
        XCTAssertFalse(exists("learning/proposed/rejetee"))
        let archived = try fm.contentsOfDirectory(atPath: learningRoot.appendingPathComponent("archive/rejected").path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived[0].hasPrefix("rejetee-"))
    }

    func testArchiveInstalledBacksUpThenRemoves() throws {
        try seedProposal(slug: "installe")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        try store.archiveInstalled(slug: "installe")
        XCTAssertFalse(exists("skills/atoll-installe"))
        XCTAssertTrue(store.installedSkills().isEmpty)
        // Copie de sauvegarde présente.
        XCTAssertTrue(exists("learning/archive/uninstalled"))
    }

    // MARK: - Désinstallation intégrale (le cœur de la sûreté)

    func testUninstallAllRemovesOnlyManifestEntries() throws {
        try seedProposal(slug: "un")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        try seedProposal(slug: "deux")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))

        let report = try store.uninstallAll()
        XCTAssertEqual(Set(report.removed), ["un", "deux"])
        XCTAssertFalse(exists("skills/atoll-un"))
        XCTAssertFalse(exists("skills/atoll-deux"))
        XCTAssertTrue(store.installedSkills().isEmpty)
    }

    func testUninstallAllNeverTouchesForeignDirs() throws {
        // Deux skills TIERS + un skill perso préfixé atoll- mais HORS manifeste.
        try plantForeignSkill("gsd-foo")
        try plantForeignSkill("apex")
        try plantForeignSkill("atoll-perso-non-gere")
        try seedProposal(slug: "gere")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))

        _ = try store.uninstallAll()
        // Le skill géré part…
        XCTAssertFalse(exists("skills/atoll-gere"))
        // …mais AUCUN dossier étranger n'est touché, pas même l'atoll-* non géré.
        XCTAssertTrue(exists("skills/gsd-foo/SKILL.md"))
        XCTAssertTrue(exists("skills/apex/SKILL.md"))
        XCTAssertTrue(exists("skills/atoll-perso-non-gere/SKILL.md"))
    }

    func testUninstallAllFailClosedOnCorruptManifest() throws {
        try seedProposal(slug: "gere")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        // Manifeste corrompu → aucune suppression, throw.
        try Data("{ corrompu".utf8).write(to: learningRoot.appendingPathComponent("installed.json"))
        XCTAssertThrowsError(try store.uninstallAll()) { error in
            XCTAssertEqual(error as? LearnedSkillError, .manifestUnreadable)
        }
        XCTAssertTrue(exists("skills/atoll-gere"), "fail-closed : le skill reste en place")
    }

    // MARK: - Réconciliation

    func testReconcileDropsMissingDirs() throws {
        try seedProposal(slug: "gere")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        // Suppression manuelle du dossier.
        try fm.removeItem(at: skillsRoot.appendingPathComponent("atoll-gere"))
        let report = store.reconcile()
        XCTAssertEqual(report.removedFromManifest, ["gere"])
        XCTAssertTrue(store.installedSkills().isEmpty)
    }

    func testReconcileFlagsUnmanaged() throws {
        try plantForeignSkill("atoll-orphelin")
        let report = store.reconcile()
        XCTAssertEqual(report.unmanaged, ["atoll-orphelin"])
        // Toujours présent, jamais touché.
        XCTAssertTrue(exists("skills/atoll-orphelin/SKILL.md"))
    }

    func testReconcileIgnoresInfrastructureSkill() throws {
        // atoll-recall (skill d'infra posé par le bridge) n'est jamais « non géré ».
        try plantForeignSkill("atoll-recall")
        XCTAssertTrue(store.reconcile().unmanaged.isEmpty)
        XCTAssertTrue(exists("skills/atoll-recall/SKILL.md"))
    }

    func testReconcileFlagsUserModified() throws {
        try seedProposal(slug: "modif", skillMD: "# officiel")
        try store.approve(try XCTUnwrap(store.discoverProposals().first))
        try Data("# édité à la main".utf8)
            .write(to: skillsRoot.appendingPathComponent("atoll-modif/SKILL.md"))
        XCTAssertEqual(store.reconcile().userModified, ["modif"])
    }

    func testReconcileFinishesInterruptedMove() throws {
        // Déplacement inachevé (crash entre meta et move) : proposed/<slug> avec
        // un statut déjà décidé → reconcile le pousse en archive.
        try seedProposal(slug: "inachevee", status: "rejected")
        _ = store.reconcile()
        XCTAssertFalse(exists("learning/proposed/inachevee"))
        let archived = try fm.contentsOfDirectory(atPath: learningRoot.appendingPathComponent("archive/rejected").path)
        XCTAssertTrue(archived.contains { $0.hasPrefix("inachevee-") })
    }

    func testApproveRecoversHalfFinishedInstall() throws {
        // Simule un crash entre le move du skill (c) et le manifeste (d) :
        // dossier atoll-<slug> présent, ABSENT du manifeste, proposition intacte.
        try seedProposal(slug: "reprise", skillMD: "# contenu")
        try fm.createDirectory(at: skillsRoot.appendingPathComponent("atoll-reprise"),
                               withIntermediateDirectories: true)
        try Data("# contenu".utf8)
            .write(to: skillsRoot.appendingPathComponent("atoll-reprise/SKILL.md"))
        // Re-approuver ne doit PAS lever collision : contenu identique → reprise.
        let proposal = try XCTUnwrap(store.discoverProposals().first)
        XCTAssertNoThrow(try store.approve(proposal))
        XCTAssertEqual(store.installedSkills().map(\.slug), ["reprise"])
        XCTAssertFalse(exists("learning/proposed/reprise")) // proposition consommée
    }

    func testReconcileSweepsStagingLeaks() throws {
        // Un staging orphelin (crash pendant approve) est balayé, jamais laissé.
        let leak = skillsRoot.appendingPathComponent(".atoll-x.tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: leak, withIntermediateDirectories: true)
        _ = store.reconcile()
        XCTAssertFalse(fm.fileExists(atPath: leak.path))
    }

    func testArchiveInstalledFailClosedOnCorruptManifest() throws {
        try Data("{ corrompu".utf8).write(to: learningRoot.appendingPathComponent("installed.json"))
        XCTAssertThrowsError(try store.archiveInstalled(slug: "quelconque")) { error in
            XCTAssertEqual(error as? LearnedSkillError, .manifestUnreadable)
        }
    }
}
