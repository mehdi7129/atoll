import Foundation
import AtollCore
import Darwin

/// État du vrai service ; seuls les CLI et leurs collaborateurs sont factices.
@main struct CurationStateTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
    @MainActor static var root: URL { BridgePaths.root }
    @MainActor static var stateURL: URL { BridgePaths.learningDirectory.appendingPathComponent("curation.json") }
    @MainActor static var journalURL: URL { BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json") }
    @MainActor static var store: CurationCheckpointStore {
        .init(directory: BridgePaths.learningDirectory.appendingPathComponent("curation-pending"))
    }
    @MainActor static func launches() -> Int {
        ((try? String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }
    @MainActor static func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: "attente du harness expirée") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func finished() async throws {
        try await waitFor { NotesCurationService.shared.phase == .idle && AnalysisBudget.shared.active == nil }
    }
    @MainActor static func validState(fresh: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "lastRunAt": Date().addingTimeInterval(fresh ? 86400 : -8 * 86400).timeIntervalSinceReferenceDate,
            "lastOutcome": "ancien résultat conservé", "warnings": ["contradiction antérieure"]])
    }
    @MainActor static func seed() throws {
        try FileManager.default.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
        for name in ["one.md", "two.md"] {
            try String(repeating: "Connaissance vérifiée et utile au projet. ", count: 20)
                .write(to: BridgePaths.learningNotesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let notes = NotesCurationService.readNotes()
        let payload: [String: Any] = ["notes": notes.enumerated().map { index, note in
            ["title": "Fait vérifié \(index)", "content": note.content, "sources": [note.name]] as [String: Any]
        }, "contradictions": []]
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
    @MainActor static func run(_ scenario: String, provider: AgentProvider) async throws {
        let fm = FileManager.default
        try seed()
        LearningSettings.shared.isCurationScheduled = true
        LearningSettings.shared.maxPerWindow = 10
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["primary": ["usedPercent": 0,
            "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
        let previous = try validState()
        let corrupt = Data("{\"lastOutcome\":\"contradiction importante\",broken".utf8)
        let originalCorpus = CurationCorpusFingerprint(notes: NotesCurationService.readNotes())

        if scenario == "absent" || scenario == "absent-manual" || scenario == "repaired-absent" {
            if scenario == "repaired-absent" { try corrupt.write(to: stateURL) }
            let service = NotesCurationService.shared
            if scenario == "repaired-absent" {
                service.syncWithSettings()
                try await Task.sleep(for: .milliseconds(60))
                try fm.moveItem(at: stateURL, to: root.appendingPathComponent("preserved-invalid-state"))
                service.runIfDue()
                try await finished()
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                try check(state["lastRunAt"] is Double && launches() == 0 && !Resolver.entered,
                          "état retiré après erreur a lancé au lieu d'armer")
                service.curateNow()
                try await finished()
                try check(launches() == 1 && service.lastOutcome?.contains(" → ") == true,
                          "état retiré après erreur a bloqué le rangement manuel")
            } else if scenario == "absent" {
                service.syncWithSettings()
                try await Task.sleep(for: .milliseconds(60))
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                try check(state["lastRunAt"] is Double && launches() == 0 && !Resolver.entered,
                          "premier armement a lancé une analyse ou perdu son échéance")
            } else {
                service.curateNow()
                try await finished()
                try check(launches() == 1 && service.lastOutcome?.contains(" → ") == true,
                          "état absent a bloqué le rangement manuel")
            }
            return
        }
        if ["legacy", "fingerprint", "repaired-fresh"].contains(scenario) {
            var state = try JSONSerialization.jsonObject(with: validState(fresh: true)) as! [String: Any]
            if scenario == "fingerprint" { state["lastSuccessfulCorpus"] = ["hash": 17] }
            let bytes = try JSONSerialization.data(withJSONObject: state)
            if scenario == "repaired-fresh" {
                try corrupt.write(to: stateURL)
                NotesCurationService.shared.syncWithSettings()
                try await Task.sleep(for: .milliseconds(40))
            }
            try bytes.write(to: stateURL)
            let service = NotesCurationService.shared
            service.syncWithSettings()
            service.runIfDue()
            try await Task.sleep(for: .milliseconds(60))
            try check(launches() == 0 && !Resolver.entered, "réparation ou migration a ignoré la cadence restaurée")
            try check(try Data(contentsOf: stateURL) == bytes, "état valide ou empreinte optionnelle réécrit sans cycle")
            try check(service.lastOutcome == "ancien résultat conservé" && service.warnings == ["contradiction antérieure"],
                      "état valide réparé non rechargé")
            return
        }
        if ["during-prepare", "during-cancel", "during-model"].contains(scenario) {
            try previous.write(to: stateURL)
            let service = NotesCurationService.shared
            if scenario == "during-model" { try Data().write(to: root.appendingPathComponent("block")) }
            else { Resolver.blocked = true }
            service.curateNow()
            if scenario == "during-model" { try await waitFor { launches() == 1 } }
            else { try await waitFor { Resolver.entered } }
            try corrupt.write(to: stateURL)
            if scenario == "during-cancel" {
                service.cancel()
                try check(try Data(contentsOf: stateURL) == corrupt, "annulation a écrasé l'état devenu illisible")
                try check(service.warnings == ["contradiction antérieure"], "annulation a effacé les contradictions en mémoire")
            }
            Resolver.release()
            try Data().write(to: root.appendingPathComponent("release"))
            try await finished()
            try check(launches() == (scenario == "during-model" ? 1 : 0), "état devenu illisible avant spawn a déclenché une dépense")
            try check(try Data(contentsOf: stateURL) == corrupt, "cycle a écrasé l'état devenu illisible")
            try check(service.lastOutcome?.contains("illisible") == true, "retour du cycle a masqué l'état illisible")
            try check(CurationCorpusFingerprint(notes: NotesCurationService.readNotes()) == originalCorpus,
                      "état devenu illisible pendant le modèle a laissé appliquer les notes")
            if scenario == "during-model" {
                let pending = try store.load()
                try check(pending != nil, "résultat payé perdu avec l'état illisible")
                try previous.write(to: stateURL)
                service.curateNow()
                try await finished()
                try check(launches() == 1 && (try store.load()) == nil && service.lastOutcome?.contains(" → ") == true,
                          "réparation après résultat payé a relancé le modèle ou perdu la reprise")
            } else {
                let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
                let records = journal["records"] as! [[String: Any]]
                try check(records.count == 1 && records[0]["launchedAt"] == nil && records[0]["launchAttemptAt"] == nil,
                          "préparation bloquée comptée comme une dépense")
            }
            return
        }
        if scenario == "save-failure" {
            try check(geteuid() != 0, "fixture de permissions exige un compte non root")
            try previous.write(to: stateURL)
            try Data().write(to: root.appendingPathComponent("block"))
            let service = NotesCurationService.shared
            service.curateNow()
            try await waitFor { launches() == 1 }
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: BridgePaths.learningDirectory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: BridgePaths.learningDirectory.path) }
            try Data().write(to: root.appendingPathComponent("release"))
            try await finished()
            try check(try Data(contentsOf: stateURL) == previous, "fixture de sauvegarde refusée n'a pas échoué")
            let inMemory = service.lastRunAt
            try check(inMemory.map { Date().timeIntervalSince($0) < 30 } == true, "échéance en mémoire non avancée après dépense")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: BridgePaths.learningDirectory.path)
            service.runIfDue()
            try await finished()
            try check(launches() == 1 && service.lastRunAt == inMemory, "échec de sauvegarde a oublié la cadence en mémoire")
            return
        }

        let warm = scenario.hasPrefix("warm-")
        if warm {
            try previous.write(to: stateURL)
            _ = NotesCurationService.shared
        }
        let kind = warm ? String(scenario.dropFirst(5)) : scenario
        var bytes = corrupt
        switch kind {
        case "empty": bytes = Data()
        case "type": bytes = Data("{\"warnings\":17}".utf8)
        case "date": bytes = Data("{\"lastRunAt\":\"demain\"}".utf8)
        case "array": bytes = Data("[]".utf8)
        default: break
        }
        if kind == "directory" {
            try fm.createDirectory(at: stateURL, withIntermediateDirectories: true)
            try bytes.write(to: stateURL.appendingPathComponent("preserved"))
        } else if kind == "dangling" {
            try fm.createSymbolicLink(atPath: stateURL.path, withDestinationPath: "missing-state-target")
        } else {
            try bytes.write(to: stateURL)
        }
        let denied = kind == "unreadable" || kind == "parent-denied"
        let deniedURL = kind == "parent-denied" ? BridgePaths.learningDirectory : stateURL
        if denied {
            try check(geteuid() != 0, "fixture de permissions exige un compte non root")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deniedURL.path)
            try check((try? Data(contentsOf: stateURL)) == nil, "fixture d'accès refusé encore lisible")
        }
        defer { if denied { try? fm.setAttributes([.posixPermissions: kind == "parent-denied" ? 0o700 : 0o600], ofItemAtPath: deniedURL.path) } }
        let service = NotesCurationService.shared
        service.syncWithSettings()
        for _ in 0..<2 {
            service.runIfDue()
            service.curateNow()
            try await Task.sleep(for: .milliseconds(60))
        }
        try check(launches() == 0 && !Resolver.entered && service.phase == .idle && AnalysisBudget.shared.active == nil,
                  "état initial illisible a préparé ou lancé une analyse")
        try check(service.lastOutcome?.contains("illisible") == true, "état illisible non signalé")
        if warm {
            try check(service.warnings == ["contradiction antérieure"] && service.lastRunAt != nil,
                      "état mémoire valide perdu pendant une erreur de relecture")
        }
        if denied { try fm.setAttributes([.posixPermissions: kind == "parent-denied" ? 0o700 : 0o600], ofItemAtPath: deniedURL.path) }
        try check(!fm.fileExists(atPath: journalURL.path), "état initial illisible a réservé du budget")
        try check(CurationCorpusFingerprint(notes: NotesCurationService.readNotes()) == originalCorpus,
                  "état illisible a modifié le corpus")
        if kind == "directory" {
            try check(try Data(contentsOf: stateURL.appendingPathComponent("preserved")) == bytes, "dossier état illisible remplacé")
            try fm.moveItem(at: stateURL, to: root.appendingPathComponent("preserved-state-directory"))
        } else if kind == "dangling" {
            try check(try fm.destinationOfSymbolicLink(atPath: stateURL.path) == "missing-state-target", "lien état illisible remplacé")
            try fm.moveItem(at: stateURL, to: root.appendingPathComponent("preserved-state-link"))
        } else {
            try check(try Data(contentsOf: stateURL) == bytes, "octets de l'état illisible remplacés")
        }
        try previous.write(to: stateURL)
        service.curateNow()
        try await finished()
        try check(launches() == 1 && service.lastOutcome?.contains(" → ") == true,
                  "état réparé a bloqué la reprise manuelle")
    }
    @MainActor static func main() async {
        do {
            let scenario = CommandLine.arguments[1]
            let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
            try await run(scenario, provider: provider)
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["scenario": scenario,
                "provider": provider.rawValue, "fakeCLISpawns": launches(), "passed": true], options: [.sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
