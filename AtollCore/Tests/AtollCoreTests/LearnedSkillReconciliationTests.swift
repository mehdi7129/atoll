import XCTest
@testable import AtollCore

final class LearnedSkillReconciliationTests: XCTestCase {
    private let fm = FileManager.default
    private let files: [String: Data] = [
        "SKILL.md": Data("# Procédure installée\n".utf8),
        "references/nested/unique.bin": Data([0, 255, 17, 128, 10]),
        "scripts/run.sh": Data("#!/bin/sh\nprintf 'fixture\\n'\n".utf8)
    ]

    private struct Fixture {
        let store: LearnedSkillStore
        let installed: URL
        let manifest: Data
    }

    private func fixture(destination: AgentProvider, missingEntry: Bool = false) throws -> Fixture {
        let root = fm.temporaryDirectory.appendingPathComponent("SkillReconcile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let learning = root.appendingPathComponent("learning")
        let skills = root.appendingPathComponent("skills")
        let store = LearnedSkillStore(learningRoot: learning, skillsRoot: skills, destination: destination)
        let installed = skills.appendingPathComponent("atoll-durable")
        for (relative, data) in files {
            let url = installed.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let slugs = missingEntry ? ["disparu", "durable"] : ["durable"]
        let entries = slugs.map {
            InstalledSkill(slug: $0, dirName: "atoll-\($0)",
                           installedAt: Date(timeIntervalSince1970: 1_770_000_000),
                           skillSHA256: InstalledSkillsManifest.sha256(String(decoding: files["SKILL.md"]!, as: UTF8.self)),
                           destination: destination)
        }
        try fm.createDirectory(at: learning, withIntermediateDirectories: true)
        let manifest = try InstalledSkillsManifest(v: 2, skills: entries).encoded()
        try manifest.write(to: store.manifestURL)
        return Fixture(store: store, installed: installed, manifest: manifest)
    }

    private func assertPreserved(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), fixture.manifest, file: file, line: line)
        for (relative, expected) in files {
            XCTAssertEqual(try Data(contentsOf: fixture.installed.appendingPathComponent(relative)), expected,
                           relative, file: file, line: line)
        }
    }

    /// chmod doit produire une vraie erreur noyau : root pourrait lire les
    /// fixtures malgré leurs modes et donnerait un faux succès au test.
    private func checkDeniedAccess(relativePath: String, mode: Int, missingEntry: Bool = false) throws {
        try XCTSkipIf(geteuid() == 0, "Les refus POSIX exigent un compte non root.")
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination, missingEntry: missingEntry)
            let restricted = relativePath.isEmpty ? fixture.store.skillsRoot
                : fixture.store.skillsRoot.appendingPathComponent(relativePath)
            let previous = try XCTUnwrap(fm.attributesOfItem(atPath: restricted.path)[.posixPermissions] as? NSNumber)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: restricted.path)
            defer { try? fm.setAttributes([.posixPermissions: previous], ofItemAtPath: restricted.path) }
            XCTAssertThrowsError(try Data(contentsOf: fixture.installed.appendingPathComponent("SKILL.md")),
                                 "Prérequis : le SKILL.md est effectivement inaccessible.")

            let report = fixture.store.reconcile()

            XCTAssertFalse(report.accessProblems.isEmpty, "Le refus doit remonter à l'appelant.")
            XCTAssertTrue(report.removedFromManifest.isEmpty, "Une passe incertaine ne valide aucun retrait.")
            XCTAssertTrue(report.userModified.isEmpty, "Un accès refusé ne prouve pas une édition.")
            XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), fixture.manifest,
                           "Le manifeste complet doit rester identique pendant l'erreur.")
            try fm.setAttributes([.posixPermissions: previous], ofItemAtPath: restricted.path)
            try assertPreserved(fixture)

            let resumed = fixture.store.reconcile()
            XCTAssertTrue(resumed.accessProblems.isEmpty)
            XCTAssertTrue(resumed.unmanaged.isEmpty, "L'accès rétabli retrouve l'autorité du manifeste.")
            XCTAssertTrue(resumed.userModified.isEmpty)
            XCTAssertEqual(resumed.removedFromManifest, missingEntry ? ["disparu"] : [])
            XCTAssertEqual(fixture.store.installedSkills().map(\.slug), ["durable"])
        }
    }

    func testReconcilePreservesManifestWhenRootCannotBeRead() throws {
        try checkDeniedAccess(relativePath: "", mode: 0o000)
    }

    func testReconcilePreservesManifestWhenRootCannotBeTraversed() throws {
        try checkDeniedAccess(relativePath: "", mode: 0o444)
    }

    func testReconcilePreservesManifestWhenSkillDirectoryCannotBeTraversed() throws {
        try checkDeniedAccess(relativePath: "atoll-durable", mode: 0o000)
    }

    func testReconcilePreservesManifestWhenSkillFileCannotBeRead() throws {
        try checkDeniedAccess(relativePath: "atoll-durable/SKILL.md", mode: 0o000)
    }

    func testReconcileDefersProvenDeletionWhenAnotherSkillIsInaccessible() throws {
        try checkDeniedAccess(relativePath: "atoll-durable", mode: 0o000, missingEntry: true)
    }

    func testReconcileRemovesOnlyProvenMissingChild() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination, missingEntry: true)
            let report = fixture.store.reconcile()
            XCTAssertEqual(report.removedFromManifest, ["disparu"], "L'absence prouvée doit être réconciliée.")
            XCTAssertTrue(report.accessProblems.isEmpty)
            XCTAssertTrue(report.unmanaged.isEmpty)
            XCTAssertTrue(report.userModified.isEmpty)
            XCTAssertEqual(fixture.store.installedSkills().map(\.slug), ["durable"])
            for (relative, expected) in files {
                XCTAssertEqual(try Data(contentsOf: fixture.installed.appendingPathComponent(relative)), expected)
            }
        }
    }

    func testReconcileKeepsManagedDirectoryAfterCaseOnlyRename() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            let renamed = fixture.store.skillsRoot.appendingPathComponent("ATOLL-DURABLE")
            try fm.moveItem(at: fixture.installed, to: renamed)
            try XCTSkipUnless(fm.fileExists(atPath: fixture.installed.path),
                              "Le test exige un volume insensible à la casse.")
            XCTAssertEqual(try Data(contentsOf: fixture.installed.appendingPathComponent("SKILL.md")), files["SKILL.md"])
            let report = fixture.store.reconcile()
            XCTAssertTrue(report.removedFromManifest.isEmpty, "Le chemin existant doit garder son autorité après renommage de casse.")
            XCTAssertTrue(report.accessProblems.isEmpty)
            XCTAssertTrue(report.unmanaged.isEmpty)
            XCTAssertTrue(report.userModified.isEmpty)
            XCTAssertEqual(fixture.store.installedSkills().map(\.slug), ["durable"])
            try assertPreserved(fixture)
        }
    }

    func testReconcilePreservesManifestWhenRootIsMissingOrDangling() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            let parked = fixture.store.skillsRoot.appendingPathExtension("parked")
            try fm.moveItem(at: fixture.store.skillsRoot, to: parked)
            for dangling in [false, true] {
                if dangling {
                    try fm.createSymbolicLink(at: fixture.store.skillsRoot,
                        withDestinationURL: fixture.store.skillsRoot.appendingPathExtension("missing"))
                }
                let report = fixture.store.reconcile()
                XCTAssertTrue(report.removedFromManifest.isEmpty)
                XCTAssertEqual(report.accessProblems.isEmpty, !dangling)
                XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), fixture.manifest)
            }
            try fm.removeItem(at: fixture.store.skillsRoot)
            try fm.moveItem(at: parked, to: fixture.store.skillsRoot)
            XCTAssertTrue(fixture.store.reconcile().unmanaged.isEmpty)
            try assertPreserved(fixture)
        }
    }

    func testReconcilePreservesManifestWhenRootIsReplacedByFile() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            let parked = fixture.store.skillsRoot.appendingPathExtension("parked")
            try fm.moveItem(at: fixture.store.skillsRoot, to: parked)
            let replacement = Data("Ce fichier ne constitue pas un inventaire.".utf8)
            try replacement.write(to: fixture.store.skillsRoot)
            let report = fixture.store.reconcile()
            XCTAssertTrue(report.removedFromManifest.isEmpty)
            XCTAssertFalse(report.accessProblems.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), fixture.manifest)
            XCTAssertEqual(try Data(contentsOf: fixture.store.skillsRoot), replacement)
            try fm.removeItem(at: fixture.store.skillsRoot)
            try fm.moveItem(at: parked, to: fixture.store.skillsRoot)
            try assertPreserved(fixture)
            XCTAssertTrue(fixture.store.reconcile().unmanaged.isEmpty)
        }
    }

    func testReconcileKeepsMissingOrInvalidSkillFileAsUserModified() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            let skill = fixture.installed.appendingPathComponent("SKILL.md")
            try fm.removeItem(at: skill)
            for invalidUTF8 in [false, true] {
                if invalidUTF8 { try Data([0xff, 0xfe, 0xff]).write(to: skill) }
                let report = fixture.store.reconcile()
                XCTAssertEqual(report.userModified, ["durable"])
                XCTAssertTrue(report.accessProblems.isEmpty)
                XCTAssertTrue(report.removedFromManifest.isEmpty)
                XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), fixture.manifest)
            }
        }
    }
}
