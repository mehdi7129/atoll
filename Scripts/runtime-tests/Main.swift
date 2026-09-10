import Foundation
import AtollCore

@main struct RuntimeTests {
    @MainActor static func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "deadline du harness") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    @MainActor static func checkLaunchIntent(_ name: String) throws {
        let data = try Data(contentsOf: BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json"))
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let records = state["records"] as! [[String: Any]]
        try check(records.last?["launchAttemptAt"] != nil, "intention de spawn non persistée : \(name)")
    }

    @MainActor static func fixture(_ name: String, curation: Bool, blockCLI: Bool, search: Bool = false) throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_RUNTIME_TEST_ROOT"]!)
        BridgePaths.root = base.appendingPathComponent(name)
        let fm = FileManager.default
        for directory in [BridgePaths.learningNotesDirectory, BridgePaths.learningProposedDirectory,
                          BridgePaths.claudeProjectsURL.appendingPathComponent("fixture")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let transcript = #"{"type":"user","uuid":"u","sessionId":"fixture","message":{"role":"user","content":"Vérifie le comportement du faux CLI."}}"# + "\n"
        try transcript.write(to: BridgePaths.claudeProjectsURL.appendingPathComponent("fixture/fixture.jsonl"), atomically: true, encoding: .utf8)
        let content = String(repeating: "Une connaissance conservée et vérifiable. ", count: 20)
        var payload: [String: Any]
        if search {
            payload = ["matches": [["plugin_id": "docs-writer@claude-plugins-official", "reason": "Test de contrat", "confidence": "high"]]]
        } else if curation {
            for name in ["one.md", "two.md"] {
                try content.write(to: BridgePaths.learningNotesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            payload = ["notes": [["title": "Consolidation", "content": content + content, "sources": ["one.md", "two.md"]]],
                       "contradictions": []]
        } else {
            payload = ["session_summary": "Test", "nothing_learned": false, "skills": [],
                       "notes": [["slug": "verified", "content": content, "category": "pitfall", "confidence": "high"]]]
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: BridgePaths.root.appendingPathComponent("report.json"))
        let envelope: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "structured_output": payload]
        try JSONSerialization.data(withJSONObject: envelope).write(to: BridgePaths.root.appendingPathComponent("envelope.json"))
        let script = """
        #!/usr/bin/python3
        import pathlib, time
        root = pathlib.Path(__file__).parent
        (root / "launched").write_text("yes")
        if \(blockCLI ? "True" : "False"):
            deadline = time.monotonic() + 8
            while not (root / "release").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
        (root / "output.json").write_bytes((root / "report.json").read_bytes())
        print((root / "envelope.json").read_text())
        """
        let cli = BridgePaths.root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        Resolver.entered = false
        Resolver.blocked = false
        Resolver.provider = nil
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var cases = 0
        let fm = FileManager.default
        for provider in AgentProvider.allCases {
            for cancellation in ["disable", "resume", "late-result", "nominal"] {
                let name = "retro-\(provider.rawValue)-\(cancellation)"
                print("RUN \(name)")
                try fixture(name, curation: false, blockCLI: cancellation == "late-result")
                Resolver.blocked = cancellation == "disable" || cancellation == "resume"
                RetrospectiveRunner.shared.debugRunOnLargestTranscript(projectDirectory: "fixture", provider: provider)
                try await waitFor { Resolver.entered }
                try check(Resolver.provider == provider, "\(name) : mauvais exécuteur")
                if cancellation == "disable" { RetrospectiveRunner.shared.disable(); Resolver.release() }
                if cancellation == "resume" { RetrospectiveRunner.shared.sessionResumed("fixture"); Resolver.release() }
                if cancellation == "late-result" {
                    try await waitFor { fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path) }
                    RetrospectiveRunner.shared.disable()
                    try Data().write(to: BridgePaths.root.appendingPathComponent("release"))
                }
                try await waitFor { RetrospectiveRunner.shared.phase == .idle && Resolver.continuation == nil }
                // disable rend phase idle avant la fin de sa tâche : attendre
                // son journal de clôture, pas ce seul indicateur d'interface.
                try await waitFor { RetrospectiveRunner.shared.lastOutcome != nil }
                let notes = try fm.contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path)
                try check(notes.count == (cancellation == "nominal" ? 1 : 0), "\(name) : note après annulation ou nominal muet")
                try check(RetrospectiveRunner.shared.lastOutcome == (cancellation == "nominal" ? "success(1n/0s)" : "failed(cancelled)"), "\(name) : issue incorrecte")
                if cancellation == "nominal" { try checkLaunchIntent(name) }
                if Resolver.blocked {
                    try check(!fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path), "\(name) : spawn après annulation")
                }
                print("PASS \(name)")
                cases += 1
            }
        }
        for provider in AgentProvider.allCases {
        SessionStore.shared.realQuota = provider == .codex ? nil : SessionStore.Quota()
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        for cancellation in ["preparation", "scheduled-off", "late-result", "nominal"] {
            let name = "curation-\(provider.rawValue)-\(cancellation)"
            print("RUN \(name)")
            try fixture(name, curation: true, blockCLI: cancellation == "late-result")
            Resolver.blocked = cancellation == "preparation" || cancellation == "scheduled-off"
            NotesCurationService.shared.curateNow(manual: cancellation != "scheduled-off")
            try await waitFor { Resolver.entered }
            try check(Resolver.provider == provider, "\(name) : mauvais exécuteur")
            if Resolver.blocked {
                if cancellation == "scheduled-off" {
                    LearningSettings.shared.isCurationScheduled = false
                    NotesCurationService.shared.syncWithSettings()
                } else { NotesCurationService.shared.cancel() }
                Resolver.release()
            }
            if cancellation == "late-result" {
                try await waitFor { fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path) }
                NotesCurationService.shared.cancel()
                try Data().write(to: BridgePaths.root.appendingPathComponent("release"))
            }
            try await waitFor { NotesCurationService.shared.phase == .idle }
            if cancellation != "nominal" {
                try await waitFor { NotesCurationService.shared.lastOutcome == "analyse annulée" }
            }
            let notes = try fm.contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path)
            try check(notes.count == (cancellation == "nominal" ? 1 : 2), "\(name) : corpus incorrect")
            if cancellation == "nominal" { try checkLaunchIntent(name) }
            if Resolver.blocked {
                try check(!fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path), "\(name) : spawn après annulation")
            }
            print("PASS \(name)")
            cases += 1
        }
        }
        for provider in AgentProvider.allCases {
            SessionStore.shared.realQuota = SessionStore.Quota()
            LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
            PluginInventory.shared.debugSeedSnapshot()
            for cancellation in ["preparation", "late-result", "nominal"] {
                let name = "search-\(provider.rawValue)-\(cancellation)"
                print("RUN \(name)")
                try fixture(name, curation: false, blockCLI: cancellation == "late-result", search: true)
                Resolver.blocked = cancellation == "preparation"
                let search = Task { await PluginInventory.shared.search(need: "relire code", useAI: true) }
                try await waitFor { Resolver.entered }
                try check(Resolver.provider == provider, "\(name) : mauvais exécuteur")
                if Resolver.blocked { PluginInventory.shared.cancel(); Resolver.release() }
                if cancellation == "late-result" {
                    try await waitFor { fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path) }
                    PluginInventory.shared.cancel()
                    try Data().write(to: BridgePaths.root.appendingPathComponent("release"))
                }
                let result = await search.value
                try check(PluginInventory.shared.searchMatches.count == (cancellation == "nominal" ? 1 : 0), "\(name) : résultat après annulation ou nominal muet (\(result ?? "nil"))")
                if cancellation == "nominal" { try checkLaunchIntent(name) }
                if Resolver.blocked {
                    try check(!fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path), "\(name) : spawn après annulation")
                }
                print("PASS \(name)")
                cases += 1
            }
        }
        let center = CodexInteractionCenter.shared
        let server = BridgeServer()
        center.server = server
        func permission(start: Double) -> CodexHookEvent {
            CodexHookEvent(envelope: ["provider": "codex", "payload": [
                "hook_event_name": "PermissionRequest", "session_id": "same",
                "cwd": "/fixture", "tool_name": "Bash", "tool_input": ["command": "echo fixture"]],
                "enrich": ["sessionPid": Int32(42), "sessionStartTime": start]])!
        }
        center.register(event: permission(start: 100), requestID: "old", helperPid: 501)
        center.register(event: permission(start: 100), requestID: "old", helperPid: 501)
        center.register(event: permission(start: 200), requestID: "new", helperPid: 502)
        try check(center.pending.count == 2 && SoundCenter.shared.played == 2, "dédup des cartes/sons")
        center.cancelAll(forSession: "codex:same", process: ProcessIdentity(pid: 42, startedAt: 100))
        try check(center.pending.map(\.id) == ["new"], "la fin ancienne a retiré la permission de reprise")
        ProcessInspector.dead.insert(502)
        center.decide("new", .allow)
        try check(server.replied.isEmpty && server.cancelled == ["old", "new"], "clic tardif vers helper mort")
        print("PASS cartes : incarnation, déduplication, sons et clic après mort du helper")
        cases += 4
        func child(_ kind: String, turn: String) -> CodexHookEvent {
            CodexHookEvent(envelope: ["provider": "codex", "payload": [
                "hook_event_name": kind, "session_id": "same", "agent_id": "child", "turn_id": turn,
                "cwd": "/fixture", "tool_name": "Bash", "tool_input": ["command": "echo fixture"]],
                "enrich": ["sessionPid": Int32(42), "sessionStartTime": 100.0] as [String: Any]])!
        }
        var children = CodexSessions()
        children.apply(permission(start: 100))
        children.apply(child("SubagentStart", turn: "t1"))
        center.register(event: child("PermissionRequest", turn: "t1"), requestID: "child-t1", helperPid: 503)
        let early = child("PermissionRequest", turn: "t2")
        try check(children.applyEvent(early).turn == .unknown, "tour enfant précoce présumé clos")
        center.register(event: early, requestID: "child-t2", helperPid: 504)
        let stopped = children.applyEvent(child("SubagentStop", turn: "t1"))
        try check(stopped.childClosed == "child" && stopped.childClosedTurn == "t1", "clôture enfant non corrélée")
        center.cancelAll(forAgent: "child", inSession: "codex:same", turn: stopped.childClosedTurn,
                         process: ProcessIdentity(pid: 42, startedAt: 100))
        try check(center.pending.map(\.id) == ["child-t2"], "fin enfant t1 a retiré la carte précoce t2")
        center.handBack("child-t2")
        print("PASS carte enfant t2 précoce conservée après clôture t1")
        cases += 1
        try fixture("budget", curation: false, blockCLI: false)
        let budget = AnalysisBudget()
        func context(_ provider: AgentProvider, known: Bool = false) -> AnalysisExecution {
            AnalysisExecution(provider: provider, reason: "test", model: "test-model", home: BridgePaths.root,
                executableOverride: "", quota: .init(usedFraction: known ? 0 : nil,
                    receivedAt: known ? Date() : nil, resetsAt: nil), threshold: 0.7, maximum: 2, allowUnknown: true)
        }
        let claudeUnknown = context(.claude)
        let staleHigh = AnalysisExecution(provider: .claude, reason: "test", model: "test-model",
            home: BridgePaths.root, executableOverride: "", quota: .init(usedFraction: 0.99,
                receivedAt: Date().addingTimeInterval(-700), resetsAt: Date().addingTimeInterval(1_000)),
            threshold: 0.7, maximum: 2, allowUnknown: true)
        try check(budget.refusalReason(for: staleHigh) == .quotaAboveThreshold,
                  "quota ancien déjà haut autorise curation/recherche")
        cases += 1
        do {
            let oldConfig = LearningSettings.shared.failoverConfig
            let oldQuota = CodexService.shared.quota
            defer {
                LearningSettings.shared.failoverConfig = oldConfig
                CodexService.shared.quota = oldQuota
            }
            LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: .codex)
            for partial in [false, true] {
                let stamp = Date()
                var bucket: [String: Any] = ["primary": ["usedPercent": 99,
                    "resetsAt": stamp.addingTimeInterval(partial ? -1 : 3600).timeIntervalSince1970]]
                if partial { bucket["secondary"] = ["usedPercent": 99, "resetsAt": stamp.addingTimeInterval(9000).timeIntervalSince1970] }
                CodexService.shared.quota = CodexQuota(result: ["rateLimits": bucket],
                    receivedAt: stamp.addingTimeInterval(partial ? -60 : -400))
                for kind in [AnalysisExecution.Kind.retrospective, .curation, .pluginSearch] {
                    let captured = try AnalysisExecution.capture(kind: kind)
                    try check(captured.quota.usedFraction == 0.99 && captured.quota.resetsAt != nil,
                              "capture a perdu le minorant Codex haut")
                    try check(captured.quota.usable(at: Date(), freshness: 300) == nil,
                              "quota Codex incomplet présenté comme disponible")
                    try check(budget.refusalReason(for: captured) == .quotaAboveThreshold,
                              "capture réelle laisse passer un quota Codex ancien/partiel haut")
                    do {
                        _ = try budget.begin(captured, kind: kind)
                        throw Failure(message: "quota Codex haut : une réservation a été autorisée")
                    } catch is AnalysisExecution.Failure {}
                    cases += 1
                }
            }
        }
        print("PASS quota Codex : capture → budget, ancien/partiel haut refusé pour les trois consommateurs")
        let preparing = try budget.begin(claudeUnknown, kind: .retrospective)
        do {
            _ = try budget.begin(claudeUnknown, kind: .curation)
            throw Failure(message: "deux analyses simultanées")
        } catch is AnalysisExecution.Failure {}
        budget.finish(preparing, outcome: "executableMissing")
        let first = try budget.begin(claudeUnknown, kind: .curation)
        budget.launched(first)
        budget.finish(first, outcome: "failed(exit)")
        try check(budget.refusal(for: claudeUnknown) != nil, "échec lancé non compté entre consommateurs")
        let codexUnknown = context(.codex)
        let codex = try budget.begin(codexUnknown, kind: .pluginSearch)
        budget.launched(codex)
        budget.finish(codex, outcome: "success")
        let second = try budget.begin(context(.claude, known: true), kind: .pluginSearch)
        budget.launched(second)
        budget.finish(second, outcome: "success")
        try check(budget.refusal(for: context(.claude, known: true)) != nil, "plafond commun ignoré")
        let reloaded = AnalysisBudget()
        do {
            _ = try reloaded.begin(codexUnknown, kind: .retrospective)
            throw Failure(message: "redémarrage a effacé les dépenses")
        } catch is AnalysisExecution.Failure {}
        print("PASS budget : verrou commun, pré-spawn remboursé, échec lancé compté, abonnement distinct, plafond et persistance")
        cases += 6
        for kind in [AnalysisExecution.Kind.retrospective, .curation, .pluginSearch] {
            for stage in ["preparing", "launching", "running", "spawnFailed"] {
                try fixture("restart-\(kind.rawValue)-\(stage)", curation: false, blockCLI: false)
                let original = AnalysisBudget()
                let lease = try original.begin(claudeUnknown, kind: kind)
                if stage != "preparing" { try original.prepareToLaunch(lease) }
                if stage == "running" { original.launched(lease) }
                if stage == "spawnFailed" { original.finish(lease, outcome: "spawnFailed") }
                let recovered = AnalysisBudget()
                let expected: LearningGate.Reason? = stage == "launching" || stage == "running" ? .windowCapReached : nil
                try check(recovered.refusalReason(for: claudeUnknown) == expected,
                          "reprise du budget incorrecte : \(kind.rawValue)/\(stage)")
                if expected == nil {
                    let next = try recovered.begin(claudeUnknown, kind: kind)
                    recovered.finish(next, outcome: "cancelled")
                }
                cases += 1
            }
        }
        print("PASS redémarrage : préparation libérée, spawn incertain ou confirmé compté, échec remboursé")
        for failure in ["modelMissing", "providerUnavailable", "homeInvalid"] {
            try fixture("capture-\(failure)", curation: false, blockCLI: false)
            let settings = LearningSettings.shared
            settings.failoverConfig = .init(enabled: failure == "providerUnavailable",
                                            preferred: failure == "providerUnavailable" ? .claude : .codex)
            SessionStore.shared.realQuota = .init()
            SessionStore.shared.realQuota?.fiveHour.usedFraction = 1
            SessionStore.shared.rawQuotaReceivedAt = Date()
            settings.codexModel = failure == "modelMissing" ? "" : "test-model"
            CodexPaths.invalidHome = failure == "homeInvalid"
            CodexService.shared.quota = failure == "providerUnavailable" ? nil : CodexQuota(result: [
                "rateLimits": ["primary": ["usedPercent": 0, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
            let snapshot = SessionStore.Tracked(id: "capture-\(failure)", cwd: nil, transcriptPath: nil,
                phase: .ended, isSynthetic: false, firstSeenAt: Date(), lastEventAt: Date())
            await RetrospectiveRunner.shared.evaluateAndRun(.init(snapshot: snapshot, endedAt: Date()))
            let attempts = RetrospectiveRunner.shared.recentAttempts()
            try check(attempts.count == 1 && attempts[0].decision == "skip(configuration)" && attempts[0].failureReason?.isEmpty == false,
                      "capture refusée sans trace persistée : \(failure)")
            try check(!fm.fileExists(atPath: BridgePaths.root.appendingPathComponent("launched").path), "capture refusée mais spawn effectué")
            cases += 1
        }
        CodexPaths.invalidHome = false
        print("PASS refus de capture journalisés : modèle absent, abonnement indisponible, home invalide")
        for refusal in ["empty", "oversize", "configuration"] {
            try fixture("curation-refusal-\(refusal)", curation: true, blockCLI: false)
            LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: .codex)
            LearningSettings.shared.codexModel = ""
            if refusal == "empty" {
                for name in ["one.md", "two.md"] { try fm.removeItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(name)) }
            } else if refusal == "oversize" {
                try String(repeating: "connaissance ", count: 100_000).write(to: BridgePaths.learningNotesDirectory.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
            }
            NotesCurationService.shared.curateNow(manual: true)
            try await waitFor { NotesCurationService.shared.phase == .idle }
            let data = try Data(contentsOf: BridgePaths.learningDirectory.appendingPathComponent("curation.json"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try check((state["lastOutcome"] as? String)?.isEmpty == false, "refus curation non persisté : \(refusal)")
            if refusal != "configuration" {
                try check(state["retryAt"] == nil && state["lastRunAt"] != nil, "curation sans travail relancée toutes les 30 minutes : \(refusal)")
            }
            try check(!Resolver.entered, "CLI résolu malgré un refus de curation")
            cases += 1
        }
        print("PASS curation : évaluation sans travail clôturée, refus de préparation persisté")
        print("\(cases) scénarios des runners et cartes de production vérifiés, aucun appel IA.")
    }
}
