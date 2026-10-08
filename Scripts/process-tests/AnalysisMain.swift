import Foundation
import AtollCore

@main struct AnalysisProcessTests {
    @MainActor static func main() async throws {
        let service = CommandLine.arguments[1]
        let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
        let root = BridgePaths.root
        let fm = FileManager.default
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        try fm.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 10, "windowDurationMins": 300,
                        "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        let script = #"""
        #!/usr/bin/python3
        import os,pathlib,time
        root=pathlib.Path(__file__).parent
        (root/'launched').write_text('yes')
        if os.fork()==0:
            time.sleep(3)
            os._exit(0)
        (root/'parent-exit').write_text(str(time.time()))
        os._exit(0)
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let start = ContinuousClock.now
        if service == "retrospective" {
            let transcript = root.appendingPathComponent("fixture.jsonl")
            let text = "Conserver la procédure de stockage vérifiée et ses limites."
            let item: [String: Any] = provider == .codex
                ? ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": text]]]]
                : ["type": "user", "sessionId": "fixture", "message": ["role": "user", "content": text]]
            var data = try JSONSerialization.data(withJSONObject: item)
            data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: ["type": "progress", "padding": String(repeating: "x", count: 110_000)]))
            data.append(10)
            try data.write(to: transcript)
            var snapshot = SessionStore.Tracked(id: "fixture", cwd: "/fixture", transcriptPath: transcript.path,
                phase: .ended, isSynthetic: false, firstSeenAt: Date().addingTimeInterval(-1200), lastEventAt: Date())
            snapshot.userPromptCount = 3
            await RetrospectiveRunner.shared.evaluateAndRun(.init(snapshot: snapshot, endedAt: Date(), transcriptProvider: provider))
            check(RetrospectiveRunner.shared.lastOutcome == "failed(timeout)", "A09 retrospective inherited pipe not reported")
        } else {
            for name in ["one.md", "two.md"] {
                try String(repeating: "Connaissance vérifiée et utile au projet. ", count: 20)
                    .write(to: BridgePaths.learningNotesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let runner = NotesCurationService.shared
            runner.curateNow()
            while runner.phase != .idle {
                check(start.duration(to: .now) < .seconds(5), "A09 curation did not finish")
                try await Task.sleep(for: .milliseconds(10))
            }
            check(runner.lastOutcome?.contains("dépassé son délai") == true, "A09 curation inherited pipe not reported")
            check(NotesCurationService.readNotes().count == 2, "A09 curation changed notes on interrupted output")
        }
        check(fm.fileExists(atPath: root.appendingPathComponent("launched").path), "A09 analysis fixture did not spawn")
        let parentExit = Double(try String(contentsOf: root.appendingPathComponent("parent-exit")))!
        let drainSeconds = Date().timeIntervalSince1970 - parentExit
        check(drainSeconds < 2, "A09 analysis waited for inherited EOF: \(drainSeconds)s")
        print("PASS \(service)/\(provider.rawValue), parent-exit-to-result=\(drainSeconds)s")
    }
}
