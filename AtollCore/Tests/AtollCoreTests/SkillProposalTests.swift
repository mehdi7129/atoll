import XCTest
@testable import AtollCore

final class SkillProposalTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/proposed/git-hygiene")

    private func meta(status: String = "proposed",
                      slug: String = "git-hygiene",
                      omitTitle: Bool = false,
                      createdAt: String = "2026-07-20T18:00:00Z") -> Data {
        var fields = ["\"slug\": \"\(slug)\""]
        if !omitTitle { fields.append("\"title\": \"Hygiène git\"") }
        fields.append("\"description\": \"Vérifie la branche avant commit.\"")
        fields.append("\"rationale\": \"Erreur répétée.\"")
        fields.append("\"source_session\": \"abc-123\"")
        fields.append("\"project\": \"/Users/x/proj\"")
        fields.append("\"created_at\": \"\(createdAt)\"")
        fields.append("\"status\": \"\(status)\"")
        return Data("{ \(fields.joined(separator: ", ")) }".utf8)
    }

    func testDecodeMetaJSON() {
        let p = SkillProposal.decode(metaJSON: meta(), skillMD: "# corps", directoryURL: dir)
        let proposal = try? XCTUnwrap(p)
        XCTAssertEqual(proposal?.slug, "git-hygiene")
        XCTAssertEqual(proposal?.title, "Hygiène git")
        XCTAssertEqual(proposal?.status, .proposed)
        XCTAssertEqual(proposal?.sourceSession, "abc-123")
        XCTAssertEqual(proposal?.skillMD, "# corps")
        XCTAssertEqual(proposal?.id, "git-hygiene") // dernier composant du dossier
    }

    func testDecodeUnknownStatusIsIgnored() {
        // Un statut introduit par une version future → proposition ignorée.
        XCTAssertNil(SkillProposal.decode(metaJSON: meta(status: "quarantined"),
                                          skillMD: "x", directoryURL: dir))
    }

    func testDecodeMissingFieldsFailsSafe() {
        XCTAssertNil(SkillProposal.decode(metaJSON: meta(omitTitle: true),
                                          skillMD: "x", directoryURL: dir))
        XCTAssertNil(SkillProposal.decode(metaJSON: Data("pas du json".utf8),
                                          skillMD: "x", directoryURL: dir))
        XCTAssertNil(SkillProposal.decode(metaJSON: meta(createdAt: "hier"),
                                          skillMD: "x", directoryURL: dir))
    }

    func testTransitionProposedToApproved() {
        XCTAssertTrue(SkillProposal.canTransition(from: .proposed, to: .approved))
    }

    func testTransitionProposedToRejected() {
        XCTAssertTrue(SkillProposal.canTransition(from: .proposed, to: .rejected))
    }

    func testTransitionApprovedToArchived() {
        XCTAssertTrue(SkillProposal.canTransition(from: .approved, to: .archived))
    }

    func testForbiddenTransitions() {
        XCTAssertFalse(SkillProposal.canTransition(from: .rejected, to: .approved))
        XCTAssertFalse(SkillProposal.canTransition(from: .archived, to: .approved))
        XCTAssertFalse(SkillProposal.canTransition(from: .approved, to: .rejected))
        XCTAssertFalse(SkillProposal.canTransition(from: .proposed, to: .archived))
        XCTAssertFalse(SkillProposal.canTransition(from: .proposed, to: .proposed))
    }
}
