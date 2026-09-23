import Foundation
import AtollCore

/// Service et journal réels, CLI Python local ; aucune app ni authentification.
@main struct CurationRecoveryTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
    @MainActor static var root: URL { BridgePaths.root }
    @MainActor static var stateURL: URL { BridgePaths.learningDirectory.appendingPathComponent("curation.json") }
    @MainActor static var store: CurationCheckpointStore {
        .init(directory: BridgePaths.learningDirectory.appendingPathComponent("curation-pending"))
    }
    @MainActor static func launches() -> Int {
        ((try? String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }
    @MainActor static func corpus() -> CurationCorpusFingerprint {
        CurationCorpusFingerprint(notes: NotesCurationService.readNotes())
    }
    @MainActor static func records() throws -> [AnalysisBudget.Record] {
        struct State: Decodable { let records: [AnalysisBudget.Record] }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: BridgePaths.learningDirectory
            .appendingPathComponent("analysis-jobs-v2.json"))).records
    }
    @MainActor static func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: "attente du faux CLI expirée") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func finished() async throws {
        try await waitFor { NotesCurationService.shared.phase == .idle && AnalysisBudget.shared.active == nil }
    }
    @MainActor static func seed() throws {
        try FileManager.default.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
        for (index, name) in ["one.md", "two.md"].enumerated() {
            let note = "---\ntitle: Connaissance \(index)\ncategory: technique\nproject: fixture\nsource_sessions: [\"session-\(index)\"]\n---\n\n"
                + String(repeating: "Connaissance vérifiée utile au projet \(index). ", count: 15)
            try note.write(to: BridgePaths.learningNotesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let state: [String: Any] = ["lastRunAt": Date().addingTimeInterval(-8 * 86400).timeIntervalSinceReferenceDate,
                                   "lastOutcome": "ancien cycle", "warnings": []]
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
    }
    @MainActor static func fakeCLI(_ kind: String = "valid") throws {
        let notes = NotesCurationService.readNotes()
        let items: [[String: Any]] = notes.enumerated().map { index, note in
            ["title": "Fait vérifié \(index)",
             "content": kind == "shrink" ? "Court." : note.content.components(separatedBy: "\n---\n").last!,
             "sources": kind == "provenance" ? ["invented.md"] : [note.name]]
        }
        let payload: [String: Any] = ["notes": items,
            "contradictions": [["summary": "Deux formulations à vérifier.", "files": ["one.md", "two.md"]]]]
        let report = kind == "invalid" ? Data("invalid json".utf8) : try JSONSerialization.data(withJSONObject: payload)
        let envelope = kind == "invalid" ? Data("invalid json".utf8) : try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false, "structured_output": payload,
            "usage": ["input_tokens": 100, "output_tokens": 20]])
        try report.write(to: root.appendingPathComponent("report.json"))
        try envelope.write(to: root.appendingPathComponent("envelope.json"))
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
        print('{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20}}') if (root/'codex').exists() else None
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }
    @MainActor static func configure(_ provider: AgentProvider, blocked: Bool = false) {
        LearningSettings.shared.isCurationScheduled = false
        LearningSettings.shared.maxPerWindow = blocked ? 0 : 10
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: provider)
        LearningSettings.shared.codexModel = blocked ? "" : "test-model"
        CodexPaths.invalidHome = blocked
        SessionStore.shared.realQuota?.fiveHour.usedFraction = blocked ? 1 : 0
        CodexService.shared.quota = CodexQuota(result: ["rateLimits": ["primary": [
            "usedPercent": blocked ? 100 : 0, "windowDurationMins": 300,
            "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
    }
    @MainActor static func mutate(_ action: String) throws {
        let directory = BridgePaths.learningNotesDirectory
        switch action {
        case "added":
            try "Nouvelle connaissance arrivée pendant l'analyse.".write(to: directory.appendingPathComponent("added.md"), atomically: true, encoding: .utf8)
        case "modified":
            try "Modification à conserver, sans restaurer l'ancien contenu.".write(to: directory.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        case "deleted": try FileManager.default.removeItem(at: directory.appendingPathComponent("one.md"))
        default: throw Failure(description: "mutation inconnue")
        }
    }
    @MainActor static func archiveFailure() async throws -> CurationCheckpoint {
        let initial = corpus()
        try Data("archive bloquée".utf8).write(to: BridgePaths.learningArchiveDirectory)
        NotesCurationService.shared.curateNow()
        try await finished()
        try check(corpus() == initial, "échec archive a modifié le corpus")
        try check(NotesCurationService.shared.lastOutcome?.hasPrefix("non appliquée") == true, "échec archive non signalé")
        guard let checkpoint = try store.load() else { throw Failure(description: "résultat payé perdu après échec archive") }
        try check(checkpoint.match(notes: NotesCurationService.readNotes()) == .source, "checkpoint ne correspond pas aux sources")
        try check(try records().count == 1 && records()[0].notesWritten == 0, "premier échec mal comptabilisé")
        return checkpoint
    }
    @MainActor static func stageCrash(_ boundary: String, checkpoint: CurationCheckpoint) throws {
        let fm = FileManager.default
        let notes = NotesCurationService.readNotes()
        let plan = try NotesCurationPlanner.plan(existing: notes, output: checkpoint.output!,
                                                now: checkpoint.createdAt).get()
        try check(CurationCorpusFingerprint(notes: plan.newNotes.map { ($0.fileName, $0.content) }) == checkpoint.targetFingerprint,
                  "fixture de crash ne reproduit pas la cible sauvegardée")
        try fm.removeItem(at: BridgePaths.learningArchiveDirectory)
        let archive = try NotesCurationService.reserveArchive(stamp: "20260923-000000")
        for note in notes {
            try fm.copyItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(note.name),
                            to: archive.appendingPathComponent(note.name))
        }
        let staging = BridgePaths.learningDirectory.appendingPathComponent(".notes-staging-recovery-test")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for note in plan.newNotes {
            try note.content.write(to: staging.appendingPathComponent(note.fileName), atomically: true, encoding: .utf8)
        }
        if boundary.hasPrefix("before-delete") {
            if boundary == "before-delete-external-deleted" || boundary == "before-delete-empty-staging" {
                try fm.removeItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(notes[0].name))
            }
            if boundary == "before-delete-empty-staging" {
                for note in plan.newNotes { try fm.removeItem(at: staging.appendingPathComponent(note.fileName)) }
            }
            return
        }
        try Data(checkpoint.id.uuidString.utf8).write(to: staging.appendingPathComponent(".swap-started"))
        let deletionCount = boundary == "delete-first" ? 1 : notes.count
        for note in notes.prefix(deletionCount) {
            try fm.removeItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(note.name))
        }
        if !["before-delete", "delete-first", "delete-all"].contains(boundary) {
            let first = plan.newNotes[0]
            let target = BridgePaths.learningNotesDirectory.appendingPathComponent(first.fileName)
            try fm.moveItem(at: staging.appendingPathComponent(first.fileName), to: target)
            if boundary == "external-modified" {
                try (first.content + "Modification externe à préserver.\n").write(to: target, atomically: true, encoding: .utf8)
            }
            if boundary == "external-added" {
                try "Nouvelle connaissance externe à préserver.".write(to: BridgePaths.learningNotesDirectory
                    .appendingPathComponent("external.md"), atomically: true, encoding: .utf8)
            }
            if boundary == "staging-modified" {
                try "Staging modifié à préserver.".write(to: staging.appendingPathComponent(plan.newNotes[1].fileName),
                                                       atomically: true, encoding: .utf8)
            }
            if boundary == "marker-absent" {
                try fm.removeItem(at: staging.appendingPathComponent(".swap-started"))
            }
            if boundary == "marker-invalid" {
                try Data(UUID().uuidString.utf8).write(to: staging.appendingPathComponent(".swap-started"))
            }
            if boundary == "archive-modified" {
                try "Archive modifiée à préserver.".write(to: archive.appendingPathComponent(notes[0].name),
                                                       atomically: true, encoding: .utf8)
            }
        }
    }
    @MainActor static func recoveryEvidence() throws -> [String: Data] {
        let fm = FileManager.default
        let roots = [BridgePaths.learningNotesDirectory, BridgePaths.learningArchiveDirectory, store.directory]
            + (try fm.contentsOfDirectory(at: BridgePaths.learningDirectory, includingPropertiesForKeys: nil))
                .filter { $0.lastPathComponent.hasPrefix(".notes-staging-") }
        var result: [String: Data] = [:]
        for directory in roots {
            let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[file.path] = try Data(contentsOf: file)
                }
            }
        }
        return result
    }
    @MainActor static func verifyCompleted(_ checkpoint: CurationCheckpoint, before: AnalysisBudget.Record) throws {
        try check(try store.load() == nil, "checkpoint non retiré après état confirmé")
        try check(corpus() == checkpoint.targetFingerprint, "reprise locale ne reproduit pas les octets prévus")
        try check(!NotesCurationService.shared.warnings.isEmpty, "contradictions perdues en reprise")
        struct State: Decodable { let lastSuccessfulCorpus: CurationCorpusFingerprint? }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        try check(state.lastSuccessfulCorpus == corpus(), "empreinte réussie non sauvegardée")
        let after = try records()
        try check(after.count == 1 && after[0].id == before.id && after[0].notesWritten == 2,
                  "reprise a créé un reçu ou perdu les écritures")
        try check(after[0].launchedAt == before.launchedAt && after[0].endedAt == before.endedAt
            && after[0].durationSeconds == before.durationSeconds && after[0].usage == before.usage,
                  "reprise a recompté une dépense ou altéré l'usage")
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let provider = AgentProvider(rawValue: CommandLine.arguments[2])!
        let fm = FileManager.default
        let cold = ["cold-resume", "cold-target", "cold-opt-out", "cold-added", "cold-modified", "cold-deleted", "crash-resume", "crash-refusal"].contains(scenario)
        if !cold { try seed() }
        if scenario == "crash-seed-same-names" {
            for (index, name) in ["one.md", "two.md"].enumerated() {
                try fm.moveItem(at: BridgePaths.learningNotesDirectory.appendingPathComponent(name),
                    to: BridgePaths.learningNotesDirectory.appendingPathComponent(String(format: "%02d-fait-verifie-%d.md", index + 1, index)))
            }
        }
        if provider == .codex { try Data().write(to: root.appendingPathComponent("codex")) }
        configure(provider)
        let cliKind = ["invalid", "shrink", "provenance"].contains(scenario) ? scenario : "valid"
        try fakeCLI(cliKind)
        let beforeSpawns = launches()
        let initial = corpus()
        let service = NotesCurationService.shared
        var observedSwapMarker = false
        if scenario == "target-seed" {
            service.onNotesReplaced = { _, _ in
                guard let checkpoint = try? store.load(),
                      let directories = try? fm.contentsOfDirectory(at: BridgePaths.learningDirectory,
                                                                    includingPropertiesForKeys: nil) else { return }
                observedSwapMarker = directories.filter { $0.lastPathComponent.hasPrefix(".notes-staging-") }.contains {
                    (try? Data(contentsOf: $0.appendingPathComponent(".swap-started"))) == Data(checkpoint.id.uuidString.utf8)
                }
            }
        }
        if scenario == "archive-seed" || scenario == "warm-resume" || scenario.hasPrefix("crash-seed-") {
            let checkpoint = try await archiveFailure()
            if scenario.hasPrefix("crash-seed-") {
                try stageCrash(String(scenario.dropFirst("crash-seed-".count)), checkpoint: checkpoint)
            }
            if scenario == "warm-resume" {
                let before = try records()[0]
                try fm.removeItem(at: BridgePaths.learningArchiveDirectory)
                configure(provider == .claude ? .codex : .claude, blocked: true)
                Resolver.entered = false
                service.curateNow()
                try await finished()
                try check(launches() == beforeSpawns + 1 && !Resolver.entered, "reprise chaude a relancé un CLI")
                try verifyCompleted(checkpoint, before: before)
            }
        } else if scenario == "crash-resume" || scenario == "crash-refusal" {
            guard let checkpoint = try store.load() else { throw Failure(description: "checkpoint de crash absent") }
            let before = try records()[0]
            let evidence = try recoveryEvidence()
            configure(provider == .claude ? .codex : .claude, blocked: true)
            service.curateNow()
            try await finished()
            try check(launches() == beforeSpawns && !Resolver.entered, "crash intermédiaire a relancé un CLI")
            if scenario == "crash-resume" {
                try check(corpus() == checkpoint.targetFingerprint, "crash intermédiaire a perdu la reprise locale")
                try verifyCompleted(checkpoint, before: before)
                let leftovers = try fm.contentsOfDirectory(atPath: BridgePaths.learningDirectory.path)
                    .filter { $0.hasPrefix(".notes-staging-") }
                try check(leftovers.isEmpty, "staging prouvé non nettoyé après reprise")
            } else {
                try check(try recoveryEvidence() == evidence, "reprise ambiguë a écrasé une modification externe")
                try check(service.lastOutcome?.contains("bascule interrompue ambiguë") == true,
                          "bascule ambiguë non refusée localement")
                try check(try records().count == 1 && records()[0].notesWritten == before.notesWritten,
                          "bascule ambiguë a altéré la dépense")
            }
        } else if scenario == "resume-shrink" || scenario == "resume-provenance" {
            _ = try await archiveFailure()
            let url = store.directory.appendingPathComponent("result.json")
            var checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: checkpoint["payload"] as! String)!) as! [String: Any]
            var notes = payload["notes"] as! [[String: Any]]
            for index in notes.indices {
                if scenario == "resume-shrink" { notes[index]["content"] = "Court." }
                else { notes[index]["sources"] = ["invented.md"] }
            }
            payload["notes"] = notes
            checkpoint["payload"] = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            try JSONSerialization.data(withJSONObject: checkpoint).write(to: url)
            try fm.removeItem(at: BridgePaths.learningArchiveDirectory)
            configure(provider == .claude ? .codex : .claude, blocked: true)
            Resolver.entered = false
            service.curateNow()
            try await finished()
            try check(corpus() == initial && launches() == beforeSpawns + 1 && !Resolver.entered,
                      "reprise locale a sauté les gardes du planificateur")
            let reason = scenario == "resume-shrink" ? "rétrécissement suspect" : "source de note absente ou inconnue"
            try check(service.lastOutcome?.contains(reason) == true, "refus du checkpoint non signalé")
            try check(try store.load() != nil, "résultat refusé perdu sans nouvelle analyse")
        } else if scenario == "cold-resume" || scenario == "cold-target" {
            guard let checkpoint = try store.load() else { throw Failure(description: "checkpoint froid absent") }
            let before = try records()[0]
            let expected: CurationCheckpoint.Match = scenario == "cold-target" ? .target : .source
            try check(checkpoint.match(notes: NotesCurationService.readNotes()) == expected, "fixture froide inattendue")
            if scenario == "cold-resume" { try fm.removeItem(at: BridgePaths.learningArchiveDirectory) }
            else { try fm.removeItem(at: stateURL) }
            let archivesBefore = (try? fm.contentsOfDirectory(atPath: BridgePaths.learningArchiveDirectory.path)) ?? []
            configure(provider == .claude ? .codex : .claude, blocked: true)
            var forgotten: [String] = []
            var indexed: [URL] = []
            service.onNotesReplaced = { forgotten = $0; indexed = $1 }
            service.curateNow()
            try await finished()
            try check(launches() == beforeSpawns && !Resolver.entered, "reprise froide a relancé un CLI")
            try verifyCompleted(checkpoint, before: before)
            if scenario == "cold-target" {
                try check(Set(forgotten) == Set(checkpoint.sourceNames.map { BridgePaths.learningNotesDirectory.appendingPathComponent($0).path })
                          && indexed.count == 2, "reprise cible a perdu la mise à jour de l'index")
                try check(corpus() == initial, "cible déjà appliquée réécrite")
                try check(try fm.contentsOfDirectory(atPath: BridgePaths.learningArchiveDirectory.path) == archivesBefore,
                          "cible déjà appliquée réarchivée")
            }
        } else if scenario == "cold-opt-out" {
            let checkpoint = try Data(contentsOf: store.directory.appendingPathComponent("result.json"))
            let state = try Data(contentsOf: stateURL)
            service.syncWithSettings()
            service.runIfDue()
            try await Task.sleep(for: .milliseconds(60))
            try check(launches() == beforeSpawns && !Resolver.entered && corpus() == initial, "reprise déclenchée sans opt-in")
            try check(try Data(contentsOf: stateURL) == state, "reprise sans opt-in a changé la cadence")
            try check(try Data(contentsOf: store.directory.appendingPathComponent("result.json")) == checkpoint, "reprise sans opt-in a consommé le résultat")
        } else if scenario.hasPrefix("cold-") {
            try mutate(String(scenario.dropFirst(5)))
            let changed = corpus()
            configure(.codex, blocked: true)
            service.curateNow()
            try await finished()
            try check(corpus() == changed && launches() == beforeSpawns, "ancien résultat appliqué sur corpus modifié")
            try check(try store.load() == nil, "ancien résultat non invalidé sur corpus modifié")
            try check(try records().count == 1, "corpus changé a réservé malgré configuration bloquée")
        } else if scenario.hasPrefix("during-") || scenario == "target-seed" || scenario == "checkpoint-write-failure" {
            try Data().write(to: root.appendingPathComponent("block"))
            service.curateNow()
            try await waitFor { launches() == beforeSpawns + 1 }
            if scenario.hasPrefix("during-") { try mutate(String(scenario.dropFirst(7))) }
            if scenario == "target-seed" {
                try fm.removeItem(at: stateURL)
                try fm.createDirectory(at: stateURL, withIntermediateDirectories: true)
            }
            if scenario == "checkpoint-write-failure" {
                try fm.createDirectory(at: store.directory.appendingPathComponent("result.json"), withIntermediateDirectories: true)
            }
            let changed = corpus()
            try Data().write(to: root.appendingPathComponent("release"))
            try await finished()
            if scenario == "target-seed" {
                try check(observedSwapMarker, "bascule appliquée sans marqueur de démarrage")
                guard let checkpoint = try store.load() else { throw Failure(description: "checkpoint retiré malgré état non sauvegardé") }
                try check(checkpoint.match(notes: NotesCurationService.readNotes()) == .target, "bascule non reconnue après échec état")
                try check(try records()[0].notesWritten == 2, "écritures avant échec état non mesurées")
            } else if scenario == "checkpoint-write-failure" {
                try check(corpus() == initial, "notes appliquées sans checkpoint sauvegardé")
                try check(service.lastOutcome?.contains("sauvegarde du résultat impossible") == true, "échec checkpoint non signalé")
                try check(!fm.fileExists(atPath: BridgePaths.learningArchiveDirectory.path), "archive touchée malgré checkpoint impossible")
            } else {
                try check(corpus() == changed, "modification concurrente écrasée après await modèle")
                try check(try store.load() == nil, "résultat périmé sauvegardé après modification concurrente")
                try check(service.lastOutcome?.contains("notes modifiées") == true, "modification concurrente non signalée")
            }
        } else if scenario == "corrupt-cache" {
            try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let bytes = Data("cache tronqué".utf8)
            let url = store.directory.appendingPathComponent("result.json")
            try bytes.write(to: url)
            service.curateNow()
            try await finished()
            try check(launches() == beforeSpawns && !Resolver.entered, "cache illisible a relancé un CLI")
            try check(corpus() == initial && (try Data(contentsOf: url)) == bytes, "cache illisible ou corpus écrasé")
            try check(service.lastOutcome?.contains("résultat sauvegardé illisible") == true, "cache illisible non signalé")
        } else {
            service.curateNow()
            try await finished()
            try check(corpus() == initial, "sortie invalide a modifié les notes")
            try check(try store.load() == nil, "sortie invalide sauvegardée dans le checkpoint")
            try check(launches() == beforeSpawns + 1, "fixture invalide non exécutée")
        }
        let result: [String: Any] = ["scenario": scenario, "provider": provider.rawValue,
            "newSpawns": launches() - beforeSpawns, "outcome": service.lastOutcome ?? "aucun cycle", "passed": true]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
