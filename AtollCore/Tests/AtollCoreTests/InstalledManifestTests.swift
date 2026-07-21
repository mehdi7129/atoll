import XCTest
@testable import AtollCore

final class InstalledManifestTests: XCTestCase {
    func testRoundTrip() throws {
        let manifest = InstalledSkillsManifest(v: 1, skills: [
            InstalledSkill(slug: "git-hygiene", dirName: "atoll-git-hygiene",
                           installedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           updatedAt: nil,
                           skillSHA256: InstalledSkillsManifest.sha256("# corps"),
                           sourceArchivePath: "/a/b"),
        ])
        let data = try manifest.encoded()
        let decoded = try XCTUnwrap(InstalledSkillsManifest.decode(data))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.skills.first?.dirName, "atoll-git-hygiene")
    }

    func testCorruptManifestDecodesNil() {
        XCTAssertNil(InstalledSkillsManifest.decode(Data("{ pas du json".utf8)))
        XCTAssertNil(InstalledSkillsManifest.decode(Data("{ \"v\": 1 }".utf8))) // skills manquant
    }

    func testSHA256Deterministic() {
        let a = InstalledSkillsManifest.sha256("bonjour")
        let b = InstalledSkillsManifest.sha256("bonjour")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, InstalledSkillsManifest.sha256("bonjou"))
    }
}
