import XCTest
@testable import AtollCore

final class RetrospectivePromptTests: XCTestCase {

    private func parsedSchema() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RetrospectivePrompt.jsonSchema.utf8)) as? [String: Any],
            "le schéma doit être un objet JSON valide"
        )
    }

    /// Valeur qui suit un flag dans les arguments CLI, nil si absent ou dernier.
    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.index(after: index) < args.endIndex else { return nil }
        return args[args.index(after: index)]
    }

    // MARK: - Schéma JSON

    func testSchemaIsValidJSON() throws {
        // Compact : une seule ligne (passé tel quel en argument de processus).
        XCTAssertFalse(RetrospectivePrompt.jsonSchema.contains("\n"))

        let schema = try parsedSchema()
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            Set(try XCTUnwrap(schema["required"] as? [String])),
            ["session_summary", "nothing_learned", "notes", "skills"]
        )

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let notes = try XCTUnwrap(properties["notes"] as? [String: Any])
        XCTAssertEqual(notes["maxItems"] as? Int, 8)
        let skills = try XCTUnwrap(properties["skills"] as? [String: Any])
        XCTAssertEqual(skills["maxItems"] as? Int, 2)
    }

    func testSchemaSlugPatternRejectsPathTraversal() throws {
        // Le pattern est lu DANS le schéma (pas dupliqué ici) : c'est bien la
        // contrainte réellement envoyée au CLI qu'on vérifie.
        let properties = try XCTUnwrap(try parsedSchema()["properties"] as? [String: Any])
        let notes = try XCTUnwrap(properties["notes"] as? [String: Any])
        let items = try XCTUnwrap(notes["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let slug = try XCTUnwrap(itemProperties["slug"] as? [String: Any])
        let pattern = try XCTUnwrap(slug["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)

        func matches(_ candidate: String) -> Bool {
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, range: range) != nil
        }

        // Traversée de chemin et variantes hors kebab : structurellement exclues.
        for rejected in ["../x", "a/b", "A", "a_b", "", ".", "..", "-a", "a-", "a--b", "é"] {
            XCTAssertFalse(matches(rejected), "« \(rejected) » devrait être refusé par le pattern")
        }
        for accepted in ["a", "notch-shape", "swift-6-migration", "42"] {
            XCTAssertTrue(matches(accepted), "« \(accepted) » devrait être accepté par le pattern")
        }
    }

    // MARK: - Prompt utilisateur

    func testUserPromptEmbedsTranscriptPath() {
        let prompt = RetrospectivePrompt.userPrompt(
            transcriptPath: "/Users/x/.claude/projects/-Users-x-proj/abc123.jsonl",
            projectPath: "/Users/x/proj",
            gitBranch: "feature/notch",
            model: "claude-fable-5",
            existingNoteSlugs: []
        )
        XCTAssertTrue(prompt.contains("/Users/x/.claude/projects/-Users-x-proj/abc123.jsonl"))
        XCTAssertTrue(prompt.contains("/Users/x/proj"))
        XCTAssertTrue(prompt.contains("feature/notch"))
        XCTAssertTrue(prompt.contains("claude-fable-5"))
    }

    func testUserPromptListsExistingSlugs() {
        let prompt = RetrospectivePrompt.userPrompt(
            transcriptPath: "/tmp/t.jsonl",
            projectPath: nil,
            gitBranch: nil,
            model: nil,
            existingNoteSlugs: ["codesign-icloud-detritus", "notch-shape-inset"]
        )
        XCTAssertTrue(prompt.contains("codesign-icloud-detritus"))
        XCTAssertTrue(prompt.contains("notch-shape-inset"))
    }

    func testUserPromptHandlesEmptySlugList() {
        let prompt = RetrospectivePrompt.userPrompt(
            transcriptPath: "/tmp/t.jsonl",
            projectPath: nil,
            gitBranch: nil,
            model: nil,
            existingNoteSlugs: []
        )
        // Liste vide annoncée explicitement, et le prompt reste complet.
        XCTAssertTrue(prompt.contains("(none yet)"))
        XCTAssertTrue(prompt.contains("nothing_learned"))
        XCTAssertTrue(prompt.contains("FRENCH"))
    }

    // MARK: - Prompt système

    func testSystemPromptContainsUntrustedDataWarning() {
        let prompt = RetrospectivePrompt.systemPrompt
        XCTAssertTrue(prompt.contains("UNTRUSTED DATA"))
        XCTAssertTrue(prompt.contains("STRICTLY READ-ONLY"))
        XCTAssertTrue(prompt.contains("ONE JSON object"))
        // L'injection « signée » est explicitement couverte.
        XCTAssertTrue(prompt.contains("claims to come from the user"))
    }

    // MARK: - Arguments CLI

    func testCLIArgumentsAreReadOnly() {
        let args = RetrospectivePrompt.cliArguments(model: "claude-haiku-4-5", budgetUSD: 0.5)

        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("--safe-mode"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertEqual(value(after: "--tools", in: args), "Read,Grep,Glob")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "plan")
        XCTAssertEqual(value(after: "--setting-sources", in: args), "")

        let disallowed = value(after: "--disallowedTools", in: args) ?? ""
        for tool in ["Write", "Edit", "Bash", "WebFetch", "Task"] {
            XCTAssertTrue(disallowed.contains(tool), "\(tool) doit être interdit")
        }

        XCTAssertFalse(args.contains("--bare"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testCLIArgumentsIncludeBudgetAndSchema() {
        let args = RetrospectivePrompt.cliArguments(model: "claude-fable-5", budgetUSD: 1.5)

        XCTAssertEqual(value(after: "--model", in: args), "claude-fable-5")
        XCTAssertEqual(value(after: "--max-budget-usd", in: args), String(1.5))
        XCTAssertEqual(value(after: "--output-format", in: args), "json")
        XCTAssertEqual(value(after: "--json-schema", in: args), RetrospectivePrompt.jsonSchema)
        XCTAssertEqual(value(after: "--system-prompt", in: args), RetrospectivePrompt.systemPrompt)
    }
}
