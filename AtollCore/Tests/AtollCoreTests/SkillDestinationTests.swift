import XCTest
@testable import AtollCore

final class SkillDestinationTests: XCTestCase {
    func testFinderMetadataDoesNotBlockApprovalButIsNeverInstalled() throws {
        let codex = store(.codex)
        let candidate = try proposal(codex)
        try Data("Finder metadata".utf8).write(to: candidate.directoryURL.appendingPathComponent(".DS_Store"))
        let installed = try codex.approve(candidate)
        let target = codex.skillsRoot.appendingPathComponent(installed.dirName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["SKILL.md"])
        for kind in ["directory", "symlink"] {
            let next = try proposal(codex, slug: "finder-\(kind)")
            let path = next.directoryURL.appendingPathComponent(".DS_Store")
            if kind == "directory" { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            else { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target.appendingPathComponent("SKILL.md")) }
            XCTAssertThrowsError(try codex.approve(next)) { XCTAssertEqual($0 as? LearnedSkillError, .unreviewedResources) }
        }
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(_ provider: AgentProvider, home: String = "default") -> LearnedSkillStore {
        LearnedSkillStore(learningRoot: root.appendingPathComponent("learning"),
            skillsRoot: root.appendingPathComponent("\(provider.rawValue)-\(home)/skills"), destination: provider)
    }
    private func proposal(_ store: LearnedSkillStore, content: String = "Version A", slug: String = "same-skill") throws -> SkillProposal {
        let dir = store.proposedDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["v": 2, "slug": slug, "title": "Titre", "description": "Description",
            "destination": store.destination.rawValue, "created_at": "2026-09-10T00:00:00Z", "status": "proposed"]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: dir.appendingPathComponent("meta.json"))
        try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(SkillProposal.decode(metaJSON: data, skillMD: content, directoryURL: dir))
    }
    private func legacy(_ skills: [InstalledSkill]) throws {
        let url = root.appendingPathComponent("learning/installed.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InstalledSkillsManifest(skills: skills).encoded().write(to: url, options: .atomic)
    }

    func testSameSlugCanBeInstalledForBothAgentsAndRemovedIndependently() throws {
        let claude = store(.claude), codex = store(.codex)
        let p1 = try proposal(claude), p2 = try proposal(codex)
        XCTAssertNotEqual(p1.id, p2.id)
        XCTAssertThrowsError(try claude.approve(p2))
        try claude.approve(p1)
        try codex.approve(p2)
        XCTAssertEqual(claude.installedSkills().first?.destination, .claude)
        XCTAssertEqual(codex.installedSkills().first?.destination, .codex)
        XCTAssertNotEqual(claude.manifestURL, codex.manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("learning/installed.json").path))
        try codex.uninstallAll()
        XCTAssertEqual(claude.installedSkills().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.skillsRoot.appendingPathComponent("atoll-same-skill/SKILL.md").path))
    }

    func testMigrationPreservesLegacyBytesAndMergesLaterOldAppChanges() throws {
        let claude = store(.claude), codex = store(.codex)
        let entry = InstalledSkill(slug: "old", dirName: "atoll-old", installedAt: Date(timeIntervalSince1970: 1), skillSHA256: "oldhash")
        try legacy([entry])
        let legacyURL = root.appendingPathComponent("learning/installed.json")
        let bytes = try Data(contentsOf: legacyURL)
        XCTAssertEqual(claude.installedSkills(), [entry])
        XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)
        try codex.approve(proposal(codex))
        let codexBytes = try Data(contentsOf: codex.manifestURL)
        let added = InstalledSkill(slug: "later", dirName: "atoll-later", installedAt: Date(timeIntervalSince1970: 2), skillSHA256: "laterhash")
        try legacy([entry, added])
        XCTAssertEqual(Set(claude.installedSkills().map(\.slug)), ["old", "later"])
        XCTAssertEqual(try Data(contentsOf: codex.manifestURL), codexBytes)
        try legacy([added])
        XCTAssertEqual(claude.installedSkills(), [added])
    }

    func testDivergentChangesFromOldAppDoNotOverwriteV2() throws {
        let claude = store(.claude)
        let original = try claude.approve(proposal(claude))
        try legacy([original])
        _ = claude.installedSkills() // establish legacy baseline
        try claude.approve(proposal(claude, content: "Version B"))
        let v2 = try Data(contentsOf: claude.manifestURL)
        let incoming = InstalledSkill(slug: original.slug, dirName: original.dirName, installedAt: original.installedAt, skillSHA256: "old-app-version-C")
        try legacy([incoming])
        XCTAssertThrowsError(try claude.archiveInstalled(slug: original.slug)) {
            XCTAssertEqual($0 as? LearnedSkillError, .legacyConflict(original.slug))
        }
        XCTAssertEqual(try Data(contentsOf: claude.manifestURL), v2)
        XCTAssertEqual(try String(contentsOf: claude.skillsRoot.appendingPathComponent(original.dirName + "/SKILL.md"), encoding: .utf8), "Version B")
    }

    func testChangingCodexHomeNeverAdoptsTheOtherHomeManifest() throws {
        let a = store(.codex, home: "a"), b = store(.codex, home: "b")
        try a.approve(proposal(a))
        XCTAssertTrue(b.installedSkills().isEmpty)
        XCTAssertNotEqual(a.proposedDirectory, b.proposedDirectory)
        try b.uninstallAll()
        XCTAssertEqual(a.installedSkills().count, 1)
    }

    func testUpdatingSkillPreservesResourcesAndRejectsStaleReview() throws {
        let codex = store(.codex)
        let first = try proposal(codex)
        let entry = try codex.approve(first)
        let resource = codex.skillsRoot.appendingPathComponent(entry.dirName + "/references/template.txt")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "resource".write(to: resource, atomically: true, encoding: .utf8)
        try codex.approve(proposal(codex, content: "Version B"))
        XCTAssertEqual(try String(contentsOf: resource, encoding: .utf8), "resource")
        let stale = try proposal(codex, content: "Version C")
        try "Changed after review".write(to: stale.directoryURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try codex.approve(stale))
        let annex = try proposal(codex, content: "Version D")
        try "unreviewed executable".write(to: annex.directoryURL.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try codex.approve(annex)) {
            XCTAssertEqual($0 as? LearnedSkillError, .unreviewedResources)
        }
        XCTAssertEqual(try String(contentsOf: resource, encoding: .utf8), "resource")
    }

    func testOfficialCatalogueKeepsScopeEnablementPluginAndErrors() throws {
        let entries: [[String: Any]] = [
            ["name": "same", "description": "User", "path": "/fixture/skills/same/SKILL.md", "scope": "user", "enabled": true],
            ["name": "same", "description": "Plugin", "path": "/fixture/plugin/same/SKILL.md", "scope": "repo", "enabled": false, "pluginId": "official-plugin"]]
        let data = try JSONSerialization.data(withJSONObject: ["data": [["cwd": "/fixture", "skills": entries, "errors": [["path": "/bad", "message": "invalid frontmatter"]]]]])
        let catalog = try XCTUnwrap(CodexSkillCatalog.parse(data, cwd: "/fixture"))
        XCTAssertEqual(catalog.entries.count, 2)
        XCTAssertEqual(catalog.entries.map(\.isAvailable), [true, false])
        XCTAssertTrue(catalog.entries[1].origin.contains("official-plugin"))
        XCTAssertFalse(catalog.errors.isEmpty)
        XCTAssertNil(CodexSkillCatalog.parse(data, cwd: "/different-project"))
    }

    func testInconsistentManifestCannotAuthorizeOverwriteOfAnotherDirectory() throws {
        for provider in AgentProvider.allCases {
            let target = store(provider)
            let next = try proposal(target)
            let folder = target.skillsRoot.appendingPathComponent("atoll-same-skill")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("foreign".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            let bogus = InstalledSkill(slug: next.slug, dirName: "atoll-somewhere-else", installedAt: Date(),
                skillSHA256: InstalledSkillsManifest.sha256("foreign"), destination: provider)
            try InstalledSkillsManifest(v: 2, skills: [bogus]).encoded().write(to: target.manifestURL)
            XCTAssertThrowsError(try target.approve(next, force: true))
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "foreign")
        }
    }

    func testProposalReplacedBySymlinkCannotMutateExternalMetadata() throws {
        let target = store(.codex), item = try proposal(store(.codex))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: item.directoryURL, to: outside)
        try FileManager.default.createSymbolicLink(at: item.directoryURL, withDestinationURL: outside)
        let before = try Data(contentsOf: outside.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try target.approve(item))
        XCTAssertThrowsError(try target.reject(item))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("meta.json")), before)
    }
}
