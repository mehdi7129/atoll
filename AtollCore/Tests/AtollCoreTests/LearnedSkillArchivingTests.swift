import XCTest
@testable import AtollCore

final class LearnedSkillArchivingTests: XCTestCase {
    private let fm = FileManager.default

    /// Les ressources ne sont présentes que dans le skill installé : la
    /// proposition d'origine ne permettrait pas de les récupérer après perte.
    private let files: [String: Data] = [
        "SKILL.md": Data("# Procédure éditée après installation\n".utf8),
        "references/nested/unique.bin": Data([0, 255, 17, 128, 10]),
        "scripts/run.sh": Data("#!/bin/sh\nprintf 'fixture\\n'\n".utf8)
    ]

    private struct Fixture {
        let store: LearnedSkillStore
        let installed: URL
        let archiveParent: URL
    }

    private func fixture(destination: AgentProvider) throws -> Fixture {
        let root = fm.temporaryDirectory.appendingPathComponent("SkillArchive-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let learning = root.appendingPathComponent("learning")
        let skills = root.appendingPathComponent("skills")
        let store = LearnedSkillStore(learningRoot: learning, skillsRoot: skills,
                                      destination: destination,
                                      now: { Date(timeIntervalSince1970: 1_770_000_000) })
        let installed = skills.appendingPathComponent("atoll-archive-me")
        for (relative, data) in files {
            let url = installed.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try fm.createDirectory(at: learning, withIntermediateDirectories: true)
        let entry = InstalledSkill(slug: "archive-me", dirName: "atoll-archive-me",
                                   installedAt: Date(timeIntervalSince1970: 1_770_000_000),
                                   skillSHA256: InstalledSkillsManifest.sha256("# Version initiale"),
                                   destination: destination)
        try InstalledSkillsManifest(v: 2, skills: [entry]).encoded().write(to: store.manifestURL)
        let archiveParent = store.proposedDirectory.deletingLastPathComponent()
            .appendingPathComponent("archive/uninstalled")
        try fm.createDirectory(at: archiveParent.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Fixture(store: store, installed: installed, archiveParent: archiveParent)
    }

    private func assertFiles(at directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        for (relative, expected) in files {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(relative)), expected,
                           relative, file: file, line: line)
        }
    }

    func testArchiveInstalledCopiesEveryResourceBeforeRemovingSource() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)

            try fixture.store.archiveInstalled(slug: "archive-me")

            let archives = try fm.contentsOfDirectory(at: fixture.archiveParent,
                                                       includingPropertiesForKeys: nil)
            XCTAssertEqual(archives.count, 1, destination.rawValue)
            try assertFiles(at: XCTUnwrap(archives.first))
            XCTAssertFalse(fm.fileExists(atPath: fixture.installed.path))
            XCTAssertTrue(fixture.store.installedSkills().isEmpty)
        }
    }

    func testArchiveInstalledPreservesSourceAndManifestWhenArchiveCannotBeCreated() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            let blocker = Data("Ce fichier n'est pas un dossier d'archive.".utf8)
            try blocker.write(to: fixture.archiveParent)
            let manifestBefore = try Data(contentsOf: fixture.store.manifestURL)

            XCTAssertThrowsError(try fixture.store.archiveInstalled(slug: "archive-me"),
                                 "L'échec d'archive doit remonter à l'appelant (\(destination.rawValue)).")

            XCTAssertEqual(try Data(contentsOf: fixture.store.manifestURL), manifestBefore)
            try assertFiles(at: fixture.installed)
            XCTAssertEqual(fixture.store.installedSkills().map(\.slug), ["archive-me"])
            XCTAssertEqual(try Data(contentsOf: fixture.archiveParent), blocker)
        }
    }

    func testArchiveInstalledCanBeRetriedAfterArchiveParentBecomesAvailable() throws {
        for destination in AgentProvider.allCases {
            let fixture = try fixture(destination: destination)
            try Data("Obstacle temporaire".utf8).write(to: fixture.archiveParent)
            XCTAssertThrowsError(try fixture.store.archiveInstalled(slug: "archive-me"))

            // Réparer uniquement le dossier d'archive, sans réinstaller le skill
            // ni reconstruire son manifeste : le même geste doit pouvoir aboutir.
            try fm.removeItem(at: fixture.archiveParent)
            try fixture.store.archiveInstalled(slug: "archive-me")

            let archives = try fm.contentsOfDirectory(at: fixture.archiveParent,
                                                       includingPropertiesForKeys: nil)
            XCTAssertEqual(archives.count, 1, destination.rawValue)
            try assertFiles(at: XCTUnwrap(archives.first))
            XCTAssertFalse(fm.fileExists(atPath: fixture.installed.path))
            XCTAssertTrue(fixture.store.installedSkills().isEmpty)
        }
    }
}
