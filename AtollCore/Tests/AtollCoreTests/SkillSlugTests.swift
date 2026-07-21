import XCTest
@testable import AtollCore

final class SkillSlugTests: XCTestCase {
    func testValidSlug() {
        XCTAssertEqual(SkillSlug.validate("git-hygiene"), "git-hygiene")
        XCTAssertEqual(SkillSlug.validate("a1"), "a1")
        XCTAssertEqual(SkillSlug.validate("verify-visual-notch"), "verify-visual-notch")
    }

    func testRejectsUppercaseAndSpaces() {
        XCTAssertNil(SkillSlug.validate("Git-Hygiene"))
        XCTAssertNil(SkillSlug.validate("git hygiene"))
        XCTAssertNil(SkillSlug.validate("git_hygiene")) // underscore hors alphabet
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(SkillSlug.validate("../secrets"))
        XCTAssertNil(SkillSlug.validate("a/b"))
        XCTAssertNil(SkillSlug.validate(".."))
    }

    func testRejectsTooShortTooLong() {
        XCTAssertNil(SkillSlug.validate("a"))                       // 1 caractère
        XCTAssertNil(SkillSlug.validate(String(repeating: "a", count: 41)))
        XCTAssertEqual(SkillSlug.validate("ab"), "ab")             // 2 = minimum
        let forty = String(repeating: "a", count: 40)
        XCTAssertEqual(SkillSlug.validate(forty), forty)          // 40 = maximum
    }

    func testRejectsReservedNames() {
        XCTAssertNil(SkillSlug.validate("recall"))
        XCTAssertNil(SkillSlug.validate("bridge"))
        XCTAssertNil(SkillSlug.validate("bin"))
    }

    func testRejectsAtollPrefixInInput() {
        // Le préfixe est ajouté par Atoll, jamais fourni par la rétrospective.
        XCTAssertNil(SkillSlug.validate("atoll-git"))
    }

    func testDirNamePrefixed() {
        XCTAssertEqual(SkillSlug.dirName(for: "git-hygiene"), "atoll-git-hygiene")
        XCTAssertEqual(SkillSlug.managedPrefix, "atoll-")
    }
}
