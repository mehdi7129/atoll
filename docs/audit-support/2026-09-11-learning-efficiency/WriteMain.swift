import Foundation
import AtollCore

@main struct WriteAudit {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func main() async throws {
        let blocked = CommandLine.arguments[1] == "blocked"
        let fm = FileManager.default
        let root = BridgePaths.root
        try fm.createDirectory(at: BridgePaths.learningDirectory, withIntermediateDirectories: true)
        let marker = Data("fixture bloquant le dossier de destination".utf8)
        for directory in [BridgePaths.learningNotesDirectory, BridgePaths.learningProposedDirectory] {
            if blocked { try marker.write(to: directory) }
            else { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
        let transcript = root.appendingPathComponent("fixture.jsonl")
        let userLine = #"{"type":"user","uuid":"u","sessionId":"fixture","message":{"role":"user","content":"Vérifie le comportement d’écriture du faux CLI."}}"#
        let ignored = try JSONSerialization.data(withJSONObject: ["type": "progress", "padding": String(repeating: "x", count: 110_000)])
        try (userLine + "\n" + String(decoding: ignored, as: UTF8.self) + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let payload: [String: Any] = ["session_summary": "Vérification du contrat d’écriture.", "nothing_learned": false,
            "notes": [["slug": "verified-note", "content": "Une connaissance conservée et vérifiable.", "category": "pitfall", "confidence": "high"]],
            "skills": [["slug": "verified-procedure", "title": "Procédure vérifiée", "description": "Utiliser pour vérifier une collision de destination.", "skill_md": "Vérifier que la destination est un dossier avant de publier un artefact. Signaler tout refus d’écriture.", "rationale": "Le scénario synthétique reproduit une collision de destination.", "confidence": "high"]]]
        let envelope: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "structured_output": payload]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        let parsed = try RetrospectiveReport.parse(cliOutput: envelopeData).get()
        try check(parsed.notes.count == 1 && parsed.skills.count == 1, "fixture rejetée par le parseur")
        try envelopeData.write(to: root.appendingPathComponent("envelope.json"))
        let script = #"""
        #!/usr/bin/python3
        import pathlib
        root=pathlib.Path(__file__).parent
        with (root/'launches.txt').open('a') as stream: stream.write('spawn\n')
        print((root/'envelope.json').read_text())
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: .claude)
        LearningSettings.shared.maxPerWindow = 2
        var sinkCalls = 0
        RetrospectiveRunner.shared.noteSink = { _, _ in sinkCalls += 1 }
        var snapshot = SessionStore.Tracked(id: "fixture", cwd: root.path, transcriptPath: transcript.path, phase: .ended, isSynthetic: false,
            firstSeenAt: Date().addingTimeInterval(-3600), lastEventAt: Date())
        snapshot.userPromptCount = 3
        let job = RetrospectiveRunner.Job(snapshot: snapshot, endedAt: Date())
        await RetrospectiveRunner.shared.evaluateAndRun(job)
        let attempt = RetrospectiveRunner.shared.recentAttempts().first!
        let stateData = try Data(contentsOf: BridgePaths.learningStateURL)
        let state = try JSONSerialization.jsonObject(with: stateData) as! [String: Any]
        let processed = state["processed"] as? [[String: Any]] ?? []
        let noteFiles = (try? fm.contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path)) ?? []
        let proposals = (try? fm.contentsOfDirectory(atPath: BridgePaths.learningProposedDirectory.path)) ?? []
        if blocked {
            try check((try Data(contentsOf: BridgePaths.learningNotesDirectory)) == marker, "collision note écrasée")
            try check((try Data(contentsOf: BridgePaths.learningProposedDirectory)) == marker, "collision proposition écrasée")
        }
        await RetrospectiveRunner.shared.evaluateAndRun(job)
        let again = RetrospectiveRunner.shared.recentAttempts().first!
        let result: [String: Any] = ["scenario": blocked ? "blocked" : "nominal", "decision": attempt.decision,
            "outcome": attempt.outcome ?? "nil", "notesWrittenReported": attempt.notesWritten as Any? ?? NSNull(),
            "skillsProposedReported": attempt.skillsProposed as Any? ?? NSNull(), "actualNoteFiles": noteFiles.count,
            "actualProposalDirectories": proposals.count, "noteSinkCalls": sinkCalls, "processedSessions": processed.count,
            "sameTranscriptSecondDecision": again.decision,
            "fakeCLISpawns": try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8).split(separator: "\n").count]
        try check(attempt.outcome == "success(1n/1s)", "issue inattendue : \(String(describing: attempt.outcome))")
        try check(attempt.notesWritten == 1 && attempt.skillsProposed == 1 && processed.count == 1, "compteurs inattendus")
        try check(again.decision == "skip(alreadyProcessed)", "nouvelle tentative non dédupliquée")
        try check(noteFiles.count == (blocked ? 0 : 1) && proposals.count == (blocked ? 0 : 1), "artefacts réels inattendus")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
