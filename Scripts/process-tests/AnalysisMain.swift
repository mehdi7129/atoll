import Foundation
import AtollCore

@main struct AnalysisProcessTests {
    @MainActor static func main() async throws {
        let service = CommandLine.arguments[1]
        let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
        let survivor = CommandLine.arguments.contains("survivor")
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
        with (root/'launches').open('a') as stream: stream.write('spawn\n')
        if (root/'survivor').exists():
            deadline=time.monotonic()+10
            while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.01)
            os._exit(0)
        if os.fork()==0:
            time.sleep(3)
            os._exit(0)
        (root/'parent-exit').write_text(str(time.time()))
        os._exit(0)
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        if survivor { try Data().write(to: root.appendingPathComponent("survivor")) }
        func launches() -> Int {
            ((try? String(contentsOf: root.appendingPathComponent("launches"))) ?? "").split(separator: "\n").count
        }
        func releaseChild() async throws {
            check(AnalysisBudget.shared.active != nil, "A09 live child lost analysis ownership")
            do {
                let context = try AnalysisExecution.capture(kind: .curation)
                _ = try AnalysisBudget.shared.begin(context, kind: .curation)
                check(false, "A09 another service acquired live child budget")
            } catch {}
            try Data().write(to: root.appendingPathComponent("release"))
            let limit = ContinuousClock.now.advanced(by: .seconds(3))
            while AnalysisBudget.shared.active != nil {
                check(ContinuousClock.now < limit, "A09 dead child ownership never released")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
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
            let job = RetrospectiveRunner.Job(snapshot: snapshot, endedAt: Date(), transcriptProvider: provider)
            let runner = RetrospectiveRunner.shared
            await runner.evaluateAndRun(job)
            check(runner.lastOutcome == "failed(timeout)", "A09 retrospective inherited pipe not reported")
            if survivor {
                check(launches() == 1, "A09 survivor fixture did not spawn")
                await runner.evaluateAndRun(job)
                check(launches() == 1, "A09 second retrospective overlapped live child")
                try await releaseChild()
                await runner.evaluateAndRun(job)
                check(launches() == 2, "A09 retrospective did not resume after child exit")
            }
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
            if survivor {
                check(launches() == 1, "A09 survivor fixture did not spawn")
                runner.curateNow()
                check(launches() == 1, "A09 second curation overlapped live child")
                try await releaseChild()
                runner.curateNow()
                while runner.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
                check(launches() == 2, "A09 curation did not resume after child exit")
            }
        }
        check(fm.fileExists(atPath: root.appendingPathComponent("launched").path), "A09 analysis fixture did not spawn")
        if survivor { print("PASS \(service)/\(provider.rawValue)/survivor"); return }
        let parentExit = Double(try String(contentsOf: root.appendingPathComponent("parent-exit")))!
        let drainSeconds = Date().timeIntervalSince1970 - parentExit
        check(drainSeconds < 2, "A09 analysis waited for inherited EOF: \(drainSeconds)s")
        print("PASS \(service)/\(provider.rawValue), parent-exit-to-result=\(drainSeconds)s")
    }
}
