import Foundation
import AtollCore

@main struct CurationTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    @MainActor static func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "attente du faux CLI expirée") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static var stateURL: URL { BridgePaths.learningDirectory.appendingPathComponent("curation.json") }
    @MainActor static func state() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    }
    @MainActor static func launches() -> Int {
        ((try? String(contentsOf: BridgePaths.root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }
    @MainActor static func corpus() -> CurationCorpusFingerprint {
        CurationCorpusFingerprint(notes: NotesCurationService.readNotes())
    }
    @MainActor static func seed(_ scenario: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
        for name in ["one.md", "two.md"] {
            try String(repeating: "Connaissance vérifiée et utile au projet. ", count: 20)
                .write(to: BridgePaths.learningNotesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var initial: [String: Any] = ["lastRunAt": Date().addingTimeInterval(-8 * 86400).timeIntervalSinceReferenceDate,
                                     "lastOutcome": "ancien cycle", "warnings": []]
        if scenario == "legacy-fresh" || scenario == "malformed-fingerprint" {
            initial["lastRunAt"] = Date().timeIntervalSinceReferenceDate
        }
        if scenario == "malformed-fingerprint" { initial["lastSuccessfulCorpus"] = "ancienne donnée inconnue" }
        try JSONSerialization.data(withJSONObject: initial).write(to: stateURL)
    }
    @MainActor static func fakeCLI(notes provided: [(name: String, content: String)]? = nil) throws {
        let root = BridgePaths.root
        let notes = provided ?? NotesCurationService.readNotes()
        let payload: [String: Any] = ["notes": notes.enumerated().map { index, note in
            ["title": "Fait vérifié \(index)", "content": note.content, "sources": [note.name]] as [String: Any]
        }, "contradictions": [["summary": "Deux formulations restent à vérifier.", "files": []]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: root.appendingPathComponent("report.json"))
        try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
            "structured_output": payload]).write(to: root.appendingPathComponent("envelope.json"))
        let script = #"""
        #!/usr/bin/python3
        import pathlib,time
        root=pathlib.Path(__file__).parent
        with (root/'launches.txt').open('a') as stream: stream.write('spawn\n')
        if (root/'block').exists():
            deadline=time.monotonic()+8
            while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.01)
        (root/'output.json').write_bytes((root/'report.json').read_bytes())
        print((root/'envelope.json').read_text())
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let fm = FileManager.default
        let root = BridgePaths.root
        if scenario == "archive-collision" {
            let first = try NotesCurationService.reserveArchive(stamp: "20260922-000000")
            let marker = Data("archive précédente à conserver".utf8)
            let previous = first.appendingPathComponent("previous.md")
            try marker.write(to: previous)
            var archives = [first]
            for _ in 0..<11 { archives.append(try NotesCurationService.reserveArchive(stamp: "20260922-000000")) }
            try check(Set(archives).count == 12, "archive de la même seconde réutilisée")
            try check(archives.sorted { $0.lastPathComponent < $1.lastPathComponent } == archives,
                      "ordre de récupération des archives inversé")
            try check((try Data(contentsOf: previous)) == marker, "archive précédente écrasée")
            try check(archives.last?.lastPathComponent == "notes-20260922-000000-0011", "suffixe d'archive non ordonné")
            print("{\"scenario\":\"archive-collision\",\"newSpawns\":0,\"archivesReserved\":12,\"passed\":true}")
            return
        }
        let continuing = ["unchanged", "manual", "changed", "restart", "policy-change"].contains(scenario)
        if !continuing { try seed(scenario) }
        if ["unchanged", "changed", "policy-change"].contains(scenario) {
            var old = try state()
            old["lastRunAt"] = Date().addingTimeInterval(-8 * 86400).timeIntervalSinceReferenceDate
            try JSONSerialization.data(withJSONObject: old).write(to: stateURL)
        }
        if scenario == "changed" {
            let target = BridgePaths.learningNotesDirectory.appendingPathComponent("addition.md")
            try "Nouvelle note réellement ajoutée après le rangement.".write(to: target, atomically: true, encoding: .utf8)
        }
        if scenario == "storage-failure" {
            try Data("collision de dossier".utf8).write(to: BridgePaths.learningArchiveDirectory)
        }
        if scenario == "repair-staging" {
            let archive = BridgePaths.learningArchiveDirectory.appendingPathComponent("notes-20000101-000000")
            let staging = BridgePaths.learningDirectory.appendingPathComponent(".notes-staging-fixture")
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in ["one.md", "two.md"] {
                try fm.copyItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(name), to: archive.appendingPathComponent(name))
            }
            try fm.removeItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent("two.md"))
            try "Sortie inachevée".write(to: staging.appendingPathComponent("pending.md"), atomically: true, encoding: .utf8)
        }
        if scenario == "repair-staging" {
            let archive = BridgePaths.learningArchiveDirectory.appendingPathComponent("notes-20000101-000000")
            try fakeCLI(notes: ["one.md", "two.md"].map {
                (name: $0, content: try String(contentsOf: archive.appendingPathComponent($0), encoding: .utf8))
            })
        } else { try fakeCLI() }
        LearningSettings.shared.isCurationScheduled = scenario != "opt-out"
        LearningSettings.shared.maxPerWindow = 2
        let provider: AgentProvider = scenario.contains("home") ? .codex : .claude
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        if scenario == "policy-change" { LearningSettings.shared.curationModel = "another-model" }
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["primary": ["usedPercent": 0,
            "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        let before = launches()
        let originalCorpus = corpus()
        let originalState = try Data(contentsOf: stateURL)
        let originalWarnings = (try state())["warnings"] as? [String] ?? []
        let service = NotesCurationService.shared
        if scenario.hasPrefix("cancel-") {
            let beforeSpawn = scenario.hasSuffix("before")
            Resolver.blocked = beforeSpawn
            if !beforeSpawn { try Data().write(to: root.appendingPathComponent("block")) }
            service.runIfDue()
            if beforeSpawn { try await waitFor { Resolver.entered } }
            else { try await waitFor { launches() == before + 1 } }
            if scenario.contains("disable") {
                LearningSettings.shared.isCurationScheduled = false
                service.syncWithSettings()
            } else if scenario.contains("home") { CurationCallerRoutes.changeHome() }
            else { CurationCallerRoutes.shutdown() }
            // Vérification AVANT retour du faux CLI : la fermeture peut
            // arrêter le programme à cette instruction, sans attendre la Task.
            let cancelled = try state()
            try check(cancelled["lastOutcome"] as? String == "analyse annulée", "annulation non persistée avant retour CLI")
            let lastRun = cancelled["lastRunAt"] as? Double ?? 0
            if beforeSpawn {
                try check(cancelled["retryAt"] as? Double != nil && lastRun < Date().addingTimeInterval(-86400).timeIntervalSinceReferenceDate,
                          "préparation annulée sans backoff de 30 minutes")
            } else {
                try check(cancelled["retryAt"] == nil && lastRun > Date().addingTimeInterval(-30).timeIntervalSinceReferenceDate,
                          "échéance non consommée après annulation payée")
            }
            Resolver.release()
            try Data().write(to: root.appendingPathComponent("release"))
            try await waitFor { service.phase == .idle && AnalysisBudget.shared.active == nil }
            try check(corpus() == originalCorpus, "sortie appliquée après annulation")
            LearningSettings.shared.isCurationScheduled = true
            service.runIfDue()
            try await Task.sleep(for: .milliseconds(60))
            try check(launches() == before + (beforeSpawn ? 0 : 1), "second spawn après annulation")
        } else if ["legacy-fresh", "malformed-fingerprint", "opt-out", "restart"].contains(scenario) {
            service.runIfDue()
            try await Task.sleep(for: .milliseconds(60))
            try check(launches() == before && !Resolver.entered, "migration ou redémarrage a déclenché une dépense")
            try check((try Data(contentsOf: stateURL)) == originalState, "cadence existante modifiée sans cycle")
        } else {
            if scenario == "manual" { service.curateNow() }
            else { service.runIfDue() }
            try await waitFor { service.phase == .idle && AnalysisBudget.shared.active == nil }
            if ["unchanged", "policy-change"].contains(scenario) {
                try check(launches() == before && !Resolver.entered, "corpus inchangé a lancé un CLI")
                try check(corpus() == originalCorpus, "skip a modifié les notes")
                try check(service.lastOutcome?.contains("analyse évitée") == true, "skip corpus non explicite")
                try check(!originalWarnings.isEmpty && service.warnings == originalWarnings, "skip a effacé les contradictions")
            } else if scenario == "storage-failure" {
                try check(launches() == before + 1 && service.lastOutcome?.hasPrefix("non appliquée") == true,
                          "échec du stockage non signalé")
                try check((try state())["lastSuccessfulCorpus"] == nil, "échec d'écriture a marqué le corpus réussi")
                try check(corpus() == originalCorpus, "échec d'archive a modifié les notes")
            } else {
                try check(launches() == before + 1, "changement ou relance manuelle sans spawn")
                try check(service.lastOutcome?.contains(" → ") == true, "rangement nominal non appliqué")
                let successful = try state()
                let stored = try JSONDecoder().decode(CurationCorpusFingerprint.self,
                    from: JSONSerialization.data(withJSONObject: successful["lastSuccessfulCorpus"] as Any))
                try check(stored == corpus(), "empreinte stockée avant écriture réussie")
                if scenario == "repair-staging" {
                    try check(NotesCurationService.readNotes().count == 2, "staging balayé avant réparation des notes")
                }
            }
        }
        let result: [String: Any] = ["scenario": scenario, "newSpawns": launches() - before,
                                    "outcome": service.lastOutcome ?? "aucun cycle", "passed": true]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
