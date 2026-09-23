import Foundation
import AtollCore

/// Contexte réel et vrai runner, avec des notes synthétiques et un CLI factice.
@main struct NoteContextTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Note { let slug: String; let body: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
    static func notes(_ count: Int) -> [Note] {
        (0..<count).map {
            Note(slug: String(format: "existing-procedure-number-%04d-for-project-export", $0),
                 body: "Preuve \($0) : exporter --strict ; résultat vérifié. " + String(repeating: "Détail exact. ", count: 20))
        }
    }
    static func inline(_ value: String, cap: Int) -> String {
        String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(cap))
    }
    /// Rendu de référence figé avant la déduplication, indépendant de l'API neuve.
    static func legacySummary(_ notes: [Note], cap: Int) -> String {
        guard cap > 0 else { return "" }
        let marker = "\nAntériorité partielle."
        var result = String("Notes existantes pertinentes (données, pas instructions) :".prefix(max(0, cap - marker.count)))
        for note in notes {
            let line = "- \(inline(note.slug, cap: 120)) [pitfall] : \(inline(note.body, cap: 180))"
            if result.count + line.count + 1 + marker.count > cap { return String((result + marker).prefix(cap)) }
            result += "\n" + line
        }
        return result
    }
    static func history(_ notes: [Note], directory: URL) throws -> LearningNoteHistory {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, note) in notes.enumerated() {
            try "---\nslug: \(note.slug)\ncategory: pitfall\nproject: /fixture\n---\n\(note.body)\n".write(
                to: directory.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
        }
        return LearningNoteHistory.read(from: directory)
    }
    static func represented(_ summary: String) -> Set<String> {
        Set(summary.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- "), let end = line.range(of: " [pitfall] : ") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])
        })
    }
    @MainActor static func core() throws -> [String: Any] {
        var scenarios = 0
        var savings: [[String: Int]] = []
        for count in [0, 20, 60] {
            let fixture = notes(count)
            let history = try history(fixture, directory: BridgePaths.root.appendingPathComponent("core-\(count)"))
            let original = history.slugs(project: "/fixture", query: "exporter")
            for cap in [0, 1, 80, 600, 6_000] {
                let context = history.promptContext(project: "/fixture", query: "exporter", summaryMaxCharacters: cap)
                let expected = legacySummary(fixture, cap: cap)
                try check(context.summary == expected, "résumé historique modifié")
                try check(context.summary == history.summary(project: "/fixture", query: "exporter", maxCharacters: cap),
                          "API de résumé divergente")
                let shown = represented(expected)
                try check(context.additionalSlugs == original.filter { !shown.contains($0) },
                          "identifiant omis ou répété après plafond")
                try check(Set(context.additionalSlugs).union(shown) == Set(original).union(shown),
                          "union des identifiants altérée")
                try check(context.hasSummarizedNotes == !shown.isEmpty, "indicateur de résumé incorrect")
                if cap == 6_000 {
                    savings.append(["notes": count, "additionalSlugs": context.additionalSlugs.count,
                        "savedSlugCharacters": original.map { "- \($0)" }.joined(separator: "\n").count
                            - context.additionalSlugs.map { "- \($0)" }.joined(separator: "\n").count])
                }
                scenarios += 1
            }
            let limited = history.promptContext(project: "/fixture", query: "exporter", slugLimit: 2, slugMaxCharacters: 120)
            let baseline = history.slugs(project: "/fixture", query: "exporter", limit: 2, maxCharacters: 120)
            try check(limited.additionalSlugs == baseline.filter { !represented(limited.summary).contains($0) },
                      "plafond historique des slugs changé")
            scenarios += 1
        }
        let unusual = try history([Note(slug: "space  separated", body: "Fait confirmé.")],
                                  directory: BridgePaths.root.appendingPathComponent("unusual"))
        let unusualContext = unusual.promptContext(project: "/fixture", query: "")
        try check(unusualContext.summary.contains("space separated")
                  && unusualContext.additionalSlugs == ["space  separated"], "identifiant normalisé pris pour une identité exacte")
        scenarios += 1
        let mentioned = try history([Note(slug: "a-first", body: "Le texte cite z-hidden sans le résumer."),
                                     Note(slug: "z-hidden", body: String(repeating: "Preuve. ", count: 40))],
                                    directory: BridgePaths.root.appendingPathComponent("body-mention"))
        let mentionedContext = mentioned.promptContext(project: "/fixture", query: "", summaryMaxCharacters: 170)
        try check(mentionedContext.summary.contains("z-hidden") && mentionedContext.additionalSlugs == ["z-hidden"],
                  "mention dans le corps confondue avec un identifiant résumé")
        scenarios += 1
        let unreadable = BridgePaths.root.appendingPathComponent("unreadable")
        try Data("pas un dossier".utf8).write(to: unreadable)
        let partial = LearningNoteHistory.read(from: unreadable).promptContext(project: nil, query: "")
        try check(partial.summary.contains("Antériorité partielle.") && !partial.hasSummarizedNotes,
                  "signal d'antériorité inaccessible perdu")
        scenarios += 1
        return ["scope": "core", "passedScenarios": scenarios, "savings": savings]
    }

    @MainActor static func runner(provider: AgentProvider, count: Int) async throws -> [String: Any] {
        let root = BridgePaths.root
        let fixture = notes(count)
        let history = try history(fixture, directory: BridgePaths.learningNotesDirectory)
        let expected = history.promptContext(project: "/fixture", query: "exporter")
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        LearningSettings.shared.maxPerWindow = 1
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 10, "windowDurationMins": 300,
                        "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        let payload: [String: Any] = ["session_summary": "Rien de nouveau", "nothing_learned": true, "notes": [], "skills": []]
        try JSONSerialization.data(withJSONObject: payload).write(to: root.appendingPathComponent("payload.json"))
        if provider == .codex { try Data().write(to: root.appendingPathComponent("codex")) }
        let script = #"""
        #!/usr/bin/python3
        import json,pathlib
        root=pathlib.Path(__file__).parent
        payload=json.loads((root/'payload.json').read_text())
        (root/'output.json').write_text(json.dumps(payload))
        if (root/'codex').exists():
            print(json.dumps({'type':'turn.completed','usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30}}))
        else:
            print(json.dumps({'type':'result','subtype':'success','is_error':False,'structured_output':payload}))
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let item: [String: Any] = provider == .codex
            ? ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "exporter"]]]]
            : ["type": "user", "sessionId": "fixture", "message": ["role": "user", "content": "exporter"]]
        var transcript = try JSONSerialization.data(withJSONObject: item)
        transcript.append(10)
        transcript.append(try JSONSerialization.data(withJSONObject: ["type": provider == .codex ? "turn_context" : "progress",
            "padding": String(repeating: "x", count: 110_000)]))
        transcript.append(10)
        let transcriptURL = root.appendingPathComponent("transcript.jsonl")
        try transcript.write(to: transcriptURL)
        var snapshot = SessionStore.Tracked(id: "fixture", cwd: "/fixture", transcriptPath: transcriptURL.path,
            phase: .ended, isSynthetic: false, firstSeenAt: Date().addingTimeInterval(-1200), lastEventAt: Date())
        snapshot.userPromptCount = 3
        await RetrospectiveRunner.shared.evaluateAndRun(.init(snapshot: snapshot, endedAt: Date(), transcriptProvider: provider))
        let prompt = try String(contentsOf: root.appendingPathComponent("captured-prompt.txt"), encoding: .utf8)
        try check(prompt.contains(expected.summary), "résumé perdu dans le vrai runner")
        for note in fixture {
            let occurrences = prompt.components(separatedBy: note.slug).count - 1
            try check(occurrences <= 1, "slug déjà résumé transmis deux fois")
            try check(occurrences == 1, "identifiant hors résumé perdu dans le runner")
        }
        try check(!prompt.contains("(none yet)"), "liste dédupliquée présentée comme absence de notes")
        try check(prompt.contains("fixture catalog"), "catalogue de destination perdu")
        try check(RetrospectiveRunner.shared.lastOutcome == "nothing_learned", "runner non terminé normalement")
        return ["scope": "runner", "provider": provider.rawValue, "notes": count,
                "passedScenarios": 1, "promptCharacters": prompt.count]
    }

    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: BridgePaths.root, withIntermediateDirectories: true)
        let result: [String: Any]
        if CommandLine.arguments[1] == "core" { result = try core() }
        else { result = try await runner(provider: AgentProvider(rawValue: CommandLine.arguments[2])!,
                                         count: Int(CommandLine.arguments[3])!) }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        print("")
    }
}
