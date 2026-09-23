import Foundation
import AtollCore

@main struct RetrospectiveTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func waitFor(_ test: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !test() {
            guard Date() < deadline else { throw Failure(message: "deadline du scénario") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
        let root = BridgePaths.root
        let fm = FileManager.default
        let runner = RetrospectiveRunner.shared
        let store = RetrospectiveDelivery.Store(learningRoot: BridgePaths.learningDirectory)
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        LearningSettings.shared.maxPerWindow = 2
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 10, "windowDurationMins": 300,
                        "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        let proposals = try SkillDestination.capture(origin: provider).store.proposedDirectory
        func launches() -> Int {
            ((try? String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func state() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: BridgePaths.learningStateURL)) as! [String: Any]
        }
        func counts() throws -> (Int, Int) {
            let attempts = try state()["attempts"] as! [[String: Any]]
            let run = attempts.last { ($0["decision"] as? String) == "run" }!
            return (run["notesWritten"] as? Int ?? -1, run["skillsProposed"] as? Int ?? -1)
        }
        if scenario == "recover-partial" {
            try fm.removeItem(at: BridgePaths.learningNotesDirectory)
            runner.recoverPendingDeliveries()
            try check(try counts() == (1, 0), "compteurs de reprise partielle perdus")
            struct Journal: Decodable { let records: [AnalysisBudget.Record] }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf:
                BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json")))
            try check(journal.records.last?.notesWritten == 1 && journal.records.last?.skillsProposed == 0,
                      "métriques de reprise partielle perdues")
            try check(try store.pending().count == 1, "reprise partielle acquittée")
            try check((try state()["processed"] as! [Any]).isEmpty && launches() == 1,
                      "reprise partielle traitée ou repayée")
            print("PASS \(provider.rawValue)/recover-partial")
            return
        }
        if scenario == "recover-independent" {
            let blocked = try store.pending().first!
            try fm.removeItem(at: BridgePaths.learningNotesDirectory)
            try fm.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
            try Data("conflit étranger".utf8).write(to:
                BridgePaths.learningNotesDirectory.appendingPathComponent(blocked.notes[0].filename))
            let report = RetrospectiveReport(sessionSummary: "Indépendant", nothingLearned: false,
                notes: [.init(slug: "independent", category: "pitfall", content: "Autre résultat vérifié.", confidence: "high")],
                skills: [], costUSD: nil, flags: [:])
            let independent = RetrospectiveDelivery(report: report, analysisID: UUID(), sessionID: "independent",
                origin: provider, destination: provider, proposals: proposals,
                notesDirectory: BridgePaths.learningNotesDirectory, project: "/fixture", transcriptBytes: 1,
                materialFingerprint: "independent", decidedAt: Date(), now: blocked.createdAt.addingTimeInterval(1))
            try store.save(independent)
            runner.recoverPendingDeliveries()
            try check(try store.pending().map(\.id) == [blocked.id], "reprise indépendante bloquée par le premier reçu")
            let processed = try state()["processed"] as! [[String: Any]]
            try check(processed.count == 1 && processed[0]["sessionID"] as? String == "independent",
                      "reçu indépendant absent ou échec marqué traité")
            try check(launches() == 1 && runner.lastOutcome?.hasPrefix("failed(delivery)") == true,
                      "erreur partielle masquée ou nouvelle génération")
            print("PASS \(provider.rawValue)/recover-independent")
            return
        }
        if scenario == "recover" {
            // Le modèle et le quota empêcheraient un nouveau run, mais la
            // livraison du résultat déjà sauvegardé doit fonctionner.
            LearningSettings.shared.codexModel = ""
            SessionStore.shared.realQuota?.fiveHour.usedFraction = 0.99
            for path in [BridgePaths.learningNotesDirectory, proposals] {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    try fm.removeItem(at: path)
                }
            }
            runner.recoverPendingDeliveries()
            try check(try store.pending().isEmpty, "reprise locale incomplète")
            let result = try counts()
            try check(result == (1, 1), "compteurs après reprise incorrects")
            try check(launches() == 1, "nouvelle génération pendant la reprise")
            try check((try state()["processed"] as! [Any]).count == 1, "reçu de reprise absent")
            print("PASS \(provider.rawValue)/recover : reprise au redémarrage sans modèle")
            return
        }
        try fm.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: proposals, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("fixture.jsonl")
        func record(_ text: String) throws -> Data {
            let item: [String: Any] = provider == .codex
                ? ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": text]]]]
                : ["type": "user", "sessionId": "fixture", "message": ["role": "user", "content": text]]
            var data = try JSONSerialization.data(withJSONObject: item)
            data.append(10)
            return data
        }
        func noise() throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": provider == .codex ? "turn_context" : "progress",
                "padding": String(repeating: "x", count: 110_000)])
            data.append(10)
            return data
        }
        var input = try record("Vérifier la procédure de stockage et conserver le résultat.")
        input.append(try noise())
        try input.write(to: transcript)
        if scenario == "digest-reader" {
            let full = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider)
            let bytes = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider, byteCap: 1024)
            let lines = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider, lineCap: 1)
            try check(full?.sourceReadStopped == false && bytes?.sourceReadStopped == true
                      && lines?.sourceReadStopped == true, "bornes du lecteur non signalées")
            try check(launches() == 0, "le lecteur lance une analyse")
            print("PASS \(provider.rawValue)/digest-reader")
            return
        }
        let payload: [String: Any] = ["session_summary": "Procédure éprouvée", "nothing_learned": false,
            "notes": [["slug": "verified-note", "category": "pitfall", "content": "La procédure exige --verified.", "confidence": "high"]],
            "skills": [["slug": "verified-skill", "title": "Vérification", "description": "Utiliser cette procédure de vérification.",
                        "skill_md": "Exécuter verify --verified.", "rationale": "La session a vérifié ce drapeau.", "confidence": "high"]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: root.appendingPathComponent("payload.json"))
        if provider == .codex { try Data().write(to: root.appendingPathComponent("codex")) }
        let script = #"""
        #!/usr/bin/python3
        import json,pathlib,time
        root=pathlib.Path(__file__).parent
        with (root/'launches.txt').open('a') as stream: stream.write('spawn\n')
        deadline=time.monotonic()+8
        while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.01)
        payload=json.loads((root/'payload.json').read_text())
        (root/'output.json').write_text(json.dumps(payload))
        if (root/'codex').exists():
            print(json.dumps({'type':'turn.completed','usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30}}))
        else:
            print(json.dumps({'type':'result','subtype':'success','is_error':False,'structured_output':payload,
                              'usage':{'input_tokens':100,'cache_read_input_tokens':20,'output_tokens':30}}))
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var snapshot = SessionStore.Tracked(id: "fixture", cwd: "/fixture", transcriptPath: transcript.path,
            phase: .ended, isSynthetic: false, firstSeenAt: Date().addingTimeInterval(-1200), lastEventAt: Date())
        snapshot.userPromptCount = 3
        let job = RetrospectiveRunner.Job(snapshot: snapshot, endedAt: Date(), transcriptProvider: provider)
        if scenario == "corrupt-state" {
            try Data("{".utf8).write(to: BridgePaths.learningStateURL)
            await runner.evaluateAndRun(job)
            try check(launches() == 0, "journal corrompu autorise une dépense")
            try check(try Data(contentsOf: BridgePaths.learningStateURL) == Data("{".utf8), "journal corrompu écrasé")
            print("PASS \(provider.rawValue)/corrupt-state")
            return
        }
        let run = Task { await runner.evaluateAndRun(job) }
        try await waitFor { launches() == 1 }
        let blocked = ["blocked", "partial", "independent"].contains(scenario)
        if blocked {
            try fm.removeItem(at: BridgePaths.learningNotesDirectory)
            try Data("obstacle notes".utf8).write(to: BridgePaths.learningNotesDirectory)
            if scenario != "partial" {
                try fm.removeItem(at: proposals)
                try Data("obstacle propositions".utf8).write(to: proposals)
            }
        } else if scenario == "checkpoint" {
            try fm.removeItem(at: store.directory)
            try Data("obstacle checkpoint".utf8).write(to: store.directory)
        }
        try Data().write(to: root.appendingPathComponent("release"))
        await run.value
        if blocked || scenario == "checkpoint" {
            let c = try counts()
            try check(c == (0, scenario == "partial" ? 1 : 0), "compteurs de succès inventés après échec")
            try check((try state()["processed"] as! [Any]).isEmpty, "résultat incomplet marqué traité")
            try check(runner.lastOutcome?.hasPrefix("failed(delivery)") == true, "échec local masqué")
            if blocked {
                try check(try store.pending().count == 1, "sortie payée non sauvegardée")
                await runner.evaluateAndRun(job)
                try check(launches() == 1, "nouvelle analyse malgré une sortie récupérable")
            }
            print("PASS \(provider.rawValue)/\(scenario)")
            return
        }
        try check(try counts() == (1, 1), "nominal sans artefacts confirmés")
        struct Journal: Decodable { let records: [AnalysisBudget.Record] }
        let metrics = try JSONDecoder().decode(Journal.self, from: Data(contentsOf:
            BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json"))).records.last!
        try check(metrics.usage?.inputTokens == 100 && metrics.usage?.outputTokens == 30
                  && (metrics.promptCharacters ?? 0) > 0, "usage du runner absent du journal")
        try check(metrics.digestSourceReadStopped == false && metrics.digestEntriesDropped == 0,
                  "mesures du lecteur absentes du journal")
        if scenario == "unchanged" || scenario == "changed" {
            var appended = input
            appended.append(try noise())
            if scenario == "changed" { appended.append(try record("Nouveau fait validé : utiliser le mode --new-policy.")) }
            try appended.write(to: transcript)
            Resolver.entered = false
            await runner.evaluateAndRun(job)
            if scenario == "unchanged" {
                try check(launches() == 1 && !Resolver.entered, "matière identique réanalysée")
                try check(runner.recentAttempts().first?.decision == "skip(unchangedMaterial)", "skip non expliqué")
            } else {
                try check(launches() == 2, "matière nouvelle ignorée")
                try check(try counts() == (0, 0), "doublons de sortie non filtrés")
            }
        }
        try check(try fm.contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path).count == 1,
                  "notes en double")
        try check(try fm.contentsOfDirectory(atPath: proposals.path).count == 1, "propositions en double")
        print("PASS \(provider.rawValue)/\(scenario)")
    }
}
