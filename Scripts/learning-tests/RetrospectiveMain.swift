import Foundation
import AtollCore
import Observation

private final class RevisionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool { lock.withLock { value } }
    func signal() { lock.withLock { value = true } }
}

/// Vrai runner, vrais checkpoints/budgets, processus factice et homes privés.
@main struct RetrospectiveTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func waitFor(_ test: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !test() {
            guard Date() < deadline else { throw Failure(message: "deadline du scénario") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
        let root = BridgePaths.root, fm = FileManager.default
        let runner = RetrospectiveRunner.shared
        let journalProbe = RevisionProbe()
        withObservationTracking { _ = runner.journalRevision } onChange: { journalProbe.signal() }
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
        func noNotes() throws {
            if scenario == "note-context" {
                let contents = try String(contentsOf: BridgePaths.learningNotesDirectory.appendingPathComponent("legacy.md"), encoding: .utf8)
                try check(contents == "legacy-note-context-secret", "notes historiques modifiées")
            } else {
                try check(!fm.fileExists(atPath: BridgePaths.learningNotesDirectory.path), "le pipeline skills écrit des notes")
            }
        }
        if scenario.hasPrefix("legacy-") {
            let report = RetrospectiveReport(sessionSummary: "Ancienne sortie payée", nothingLearned: false,
                notes: [.init(slug: "legacy-note", category: "pitfall", content: "Ancienne note à conserver sans écriture.", confidence: "high")],
                skills: scenario == "legacy-notes" ? [] : [.init(slug: "verified-skill", title: "Procédure", description: "Procédure vérifiée.",
                    skillMD: "verify --verified", rationale: "preuve", confidence: "high")], costUSD: nil, flags: [:])
            var legacy = RetrospectiveDelivery(report: report, analysisID: UUID(), sessionID: "legacy", origin: provider,
                destination: provider, proposals: proposals, notesDirectory: BridgePaths.learningNotesDirectory,
                project: "/fixture", transcriptBytes: 120_000, materialFingerprint: "legacy", decidedAt: Date())
            legacy.notes[0].started = true
            try store.save(legacy)
            let original = try Data(contentsOf: store.directory.appendingPathComponent(legacy.id.uuidString + ".json"))
            LearningSettings.shared.isEnabled = false
            runner.settingsChanged()
            try check(try store.pending().count == 1, "OFF livre une sortie sauvegardée")
            LearningSettings.shared.codexModel = ""
            SessionStore.shared.realQuota?.fiveHour.usedFraction = 0.99
            LearningSettings.shared.isEnabled = true
            runner.settingsChanged()
            try check(try store.pending().isEmpty, "legacy notes hors périmètre bloquent la reprise")
            try check(launches() == 0 && !Resolver.entered, "reprise legacy capture ou paie un modèle")
            try check(try Data(contentsOf: store.directory.appendingPathComponent("legacy-notes/\(legacy.id.uuidString).json")) == original,
                      "original legacy non conservé")
            let attempt = try (state()["attempts"] as! [[String: Any]]).last!
            try check(attempt["notesWritten"] as? Int == 0 && attempt["skillsProposed"] as? Int == legacy.skills.count,
                      "legacy compte notes hors périmètre comme écrites")
            try noNotes()
            print("PASS \(provider.rawValue)/\(scenario)")
            return
        }
        if scenario == "recover" {
            try fm.removeItem(at: proposals)
            LearningSettings.shared.isEnabled = false
            runner.settingsChanged()
            try check(try store.pending().count == 1, "OFF reprend une livraison")
            LearningSettings.shared.codexModel = ""
            SessionStore.shared.realQuota?.fiveHour.usedFraction = 0.99
            LearningSettings.shared.isEnabled = true
            runner.settingsChanged()
            try check(try store.pending().isEmpty && counts() == (0, 1), "reprise locale ou compteurs incorrects")
            try check(launches() == 1 && !Resolver.entered, "reprise payée malgré modèle indisponible")
            try noNotes()
            print("PASS \(provider.rawValue)/recover")
            return
        }
        let transcript = root.appendingPathComponent("fixture.jsonl")
        func record(_ text: String) throws -> Data {
            let item: [String: Any] = provider == .codex
                ? ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": text]]]]
                : ["type": "user", "sessionId": "fixture", "message": ["role": "user", "content": text]]
            var data = try JSONSerialization.data(withJSONObject: item); data.append(10); return data
        }
        func noise() throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": provider == .codex ? "turn_context" : "progress",
                "padding": String(repeating: "x", count: 110_000)])
            data.append(10); return data
        }
        var input = try record("Vérifier la procédure et conserver les commandes dont l'issue est prouvée.")
        input.append(try noise())
        if scenario == "off-digest" || scenario == "migration-digest" {
            // Assez de matière pour laisser la MainActor traiter le changement
            // pendant le vrai lecteur détaché, sans remplacer le digest testé.
            let chunk = try record(String(repeating: "procédure et contrainte vérifiées ", count: 500))
            for _ in 0..<1_500 { input.append(chunk) }
        }
        try input.write(to: transcript)
        if scenario == "digest-reader" {
            let full = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider)
            let bytes = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider, byteCap: 1024)
            let lines = RetrospectiveRunner.digest(ofTranscriptAt: transcript.path, provider: provider, lineCap: 1)
            try check(full?.sourceReadStopped == false && bytes?.sourceReadStopped == true && lines?.sourceReadStopped == true,
                      "bornes du lecteur non signalées")
            print("PASS \(provider.rawValue)/digest-reader"); return
        }
        if scenario == "note-context" {
            try fm.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
            try "legacy-note-context-secret".write(to: BridgePaths.learningNotesDirectory.appendingPathComponent("legacy.md"), atomically: true, encoding: .utf8)
        }
        let payload: [String: Any] = ["nothing_learned": false,
            "notes": [["slug": "unexpected-note", "category": "pitfall", "content": "Ne jamais écrire cette note."]],
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
        if scenario == "off-before" || scenario == "migration-before" {
            if scenario == "off-before" { LearningSettings.shared.isEnabled = false }
            else { runner.generationAllowed = { false } }
            await runner.evaluateAndRun(job)
            try check(launches() == 0 && !CatalogProbe.entered && !Resolver.entered && AnalysisBudget.shared.active == nil,
                      "OFF ou migration prépare une analyse")
            try check(!fm.fileExists(atPath: BridgePaths.learningDirectory.path), "OFF ou migration réserve un bilan")
            print("PASS \(provider.rawValue)/\(scenario)"); return
        }
        if scenario == "off-wait" {
            runner.sessionEnded(snapshot, reason: .test)
            try check(runner.phase != .idle, "candidat non armé")
            LearningSettings.shared.isEnabled = false; runner.settingsChanged()
            LearningSettings.shared.isEnabled = true; runner.settingsChanged()
            try await Task.sleep(for: .milliseconds(20))
            try check(runner.phase == .idle && launches() == 0 && !Resolver.entered, "OFF/ON rattrape une file annulée")
            print("PASS \(provider.rawValue)/off-wait"); return
        }
        if scenario == "corrupt-state" {
            try fm.createDirectory(at: BridgePaths.learningDirectory, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: BridgePaths.learningStateURL)
            await runner.evaluateAndRun(job)
            try check(launches() == 0, "journal corrompu autorise une dépense")
            try check(try Data(contentsOf: BridgePaths.learningStateURL) == Data("{".utf8), "journal corrompu écrasé")
            try check(!journalProbe.changed, "échec de persistance notifié")
            print("PASS \(provider.rawValue)/corrupt-state"); return
        }
        CatalogProbe.blocked = ["off-catalog", "migration-catalog"].contains(scenario)
        Resolver.blocked = scenario == "off-cli"
        let run = Task { await runner.evaluateAndRun(job) }
        if scenario == "off-digest" || scenario == "migration-digest" {
            try await waitFor { runner.phase == .running(snapshot.id) }
            try check(!CatalogProbe.entered, "le scénario manque la préparation du digest")
            if scenario == "migration-digest" { runner.generationAllowed = { false } }
            else { LearningSettings.shared.isEnabled = false; runner.settingsChanged() }
            await run.value
            try check(launches() == 0 && !CatalogProbe.entered && AnalysisBudget.shared.active == nil,
                      "digest annulé lance le catalogue ou un modèle")
            try noNotes()
            print("PASS \(provider.rawValue)/\(scenario)"); return
        }
        if CatalogProbe.blocked || Resolver.blocked {
            if CatalogProbe.blocked { try await waitFor { CatalogProbe.continuation != nil } }
            else { try await waitFor { Resolver.continuation != nil } }
            if scenario == "migration-catalog" { runner.generationAllowed = { false } }
            else { LearningSettings.shared.isEnabled = false; runner.settingsChanged() }
            CatalogProbe.release(); Resolver.release(); await run.value
            try check(launches() == 0 && AnalysisBudget.shared.active == nil, "lancement tardif après OFF ou migration")
            try noNotes()
            print("PASS \(provider.rawValue)/\(scenario)"); return
        }
        try await waitFor { launches() == 1 }
        if ["off-running", "session-resumed", "on-while-stopping"].contains(scenario) {
            if scenario == "on-while-stopping" {
                let savedReport = try RetrospectiveReport.parse(codexOutput: JSONSerialization.data(withJSONObject: payload), includeNotes: false).get()
                let saved = RetrospectiveDelivery(report: savedReport, analysisID: UUID(), sessionID: "already-paid",
                    origin: provider, destination: provider, proposals: proposals, notesDirectory: BridgePaths.learningNotesDirectory,
                    project: "/fixture", transcriptBytes: 120_000, materialFingerprint: "saved", decidedAt: Date())
                try store.save(saved)
                LearningSettings.shared.isEnabled = false; runner.settingsChanged()
                LearningSettings.shared.isEnabled = true; runner.settingsChanged()
                try check(try store.pending().count == 1, "ON livre avant la sortie du processus annulé")
            } else if scenario == "off-running" { LearningSettings.shared.isEnabled = false; runner.settingsChanged() }
            else { runner.sessionResumed(snapshot.id) }
            try check(AnalysisBudget.shared.active != nil, "annulation libère le budget d'un processus encore vivant")
            try Data().write(to: root.appendingPathComponent("release")); await run.value
            try await waitFor { AnalysisBudget.shared.active == nil }
            try check(try store.pending().isEmpty, scenario == "on-while-stopping" ? "ON pendant arrêt ne reprend pas le résultat payé" : "sortie annulée livrée")
            if scenario == "on-while-stopping" {
                try check(try fm.contentsOfDirectory(atPath: proposals.path).count == 1 && launches() == 1,
                          "ON pendant arrêt ne reprend pas le résultat déjà payé")
            } else {
                try check(!fm.fileExists(atPath: proposals.path), "sortie annulée crée une proposition")
            }
            if scenario == "session-resumed" {
                await runner.evaluateAndRun(job)
                try check(launches() == 2 && counts() == (0, 1), "nouvelle fin après reprise n'est plus éligible")
            } else {
                LearningSettings.shared.isEnabled = true; runner.settingsChanged()
                try check(launches() == 1, "ON réanalyse une session annulée")
            }
            try noNotes()
            print("PASS \(provider.rawValue)/\(scenario)"); return
        }
        if scenario == "blocked" {
            try fm.createDirectory(at: proposals.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("obstacle propositions".utf8).write(to: proposals)
        } else if scenario == "checkpoint" {
            try fm.removeItem(at: store.directory)
            try Data("obstacle checkpoint".utf8).write(to: store.directory)
        }
        try Data().write(to: root.appendingPathComponent("release")); await run.value
        if scenario == "blocked" || scenario == "checkpoint" {
            try check(try counts() == (0, 0), "compteurs de succès inventés après échec")
            try check((try state()["processed"] as! [Any]).isEmpty, "résultat incomplet marqué traité")
            try check(runner.lastOutcome?.hasPrefix("failed(delivery)") == true, "échec local masqué")
            if scenario == "blocked" {
                try check(try store.pending().count == 1, "sortie payée non sauvegardée")
                await runner.evaluateAndRun(job)
                try check(launches() == 1, "nouvelle analyse malgré sortie récupérable")
            }
            try noNotes()
            print("PASS \(provider.rawValue)/\(scenario)"); return
        }
        try check(runner.journalRevision > 0 && journalProbe.changed, "journal non notifié")
        try check(try counts() == (0, 1), "nominal sans skills confirmés ou notes produites")
        try check(!CodexRun.lastPrompt.contains("legacy-note-context-secret"), "historique notes encore envoyé au modèle")
        struct Journal: Decodable { let records: [AnalysisBudget.Record] }
        let metrics = try JSONDecoder().decode(Journal.self, from: Data(contentsOf:
            BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json"))).records.last!
        try check(metrics.usage?.inputTokens == 100 && metrics.usage?.outputTokens == 30 && (metrics.promptCharacters ?? 0) > 0,
                  "usage du runner absent du journal")
        try check(metrics.digestSourceReadStopped == false && metrics.digestEntriesDropped == 0, "mesures du lecteur absentes du journal")
        if scenario == "unchanged" || scenario == "changed" {
            var appended = input; appended.append(try noise())
            if scenario == "changed" { appended.append(try record("Nouvelle contrainte vérifiée : utiliser --new-policy.")) }
            try appended.write(to: transcript); Resolver.entered = false
            let previousRevision = runner.journalRevision
            await runner.evaluateAndRun(job)
            try check(runner.journalRevision > previousRevision, "abstention non notifiée")
            if scenario == "unchanged" {
                try check(launches() == 1 && !Resolver.entered, "matière identique réanalysée")
            } else {
                try check(launches() == 2 && counts() == (0, 0), "doublons de sortie non filtrés")
            }
        }
        try noNotes()
        try check(try fm.contentsOfDirectory(atPath: proposals.path).count == 1, "propositions en double")
        print("PASS \(provider.rawValue)/\(scenario)")
    }
}
