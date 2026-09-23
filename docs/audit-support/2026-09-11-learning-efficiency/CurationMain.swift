import Foundation
import AtollCore
import CryptoKit

@main struct TriggerAudit {
    struct Failure: Error { let message: String }
    @MainActor static func waitFor(_ test: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !test() {
            guard Date() < deadline else { throw Failure(message: "timeout du harness") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func corpus() -> [String: String] {
        Dictionary(uniqueKeysWithValues: NotesCurationService.readNotes().map { name, content in
            (name, SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
        })
    }
    @MainActor static func launches() -> Int {
        ((try? String(contentsOf: BridgePaths.root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let fm = FileManager.default
        let root = BridgePaths.root
        let notesURL = BridgePaths.learningNotesDirectory
        try fm.createDirectory(at: notesURL, withIntermediateDirectories: true)
        if scenario != "unchanged" {
            let content = String(repeating: "Connaissance vérifiée et réutilisable dans le projet. ", count: 20)
            for name in ["one.md", "two.md"] {
                try content.write(to: notesURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        // État de fixture daté d'il y a huit jours, avant initialisation du singleton.
        // Aucun remplacement de Date(), aucune modification du service de production.
        let oldDate = Date().addingTimeInterval(-8 * 86400).timeIntervalSinceReferenceDate
        let state: [String: Any] = ["lastRunAt": oldDate, "lastOutcome": "fixture : dernier cycle terminé", "warnings": []]
        let stateURL = BridgePaths.learningDirectory.appendingPathComponent("curation.json")
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL)
        let stateBefore = try Data(contentsOf: stateURL)
        let hashesBefore = corpus()
        let notes = NotesCurationService.readNotes()
        let payload: [String: Any] = ["notes": notes.enumerated().map { index, note in
            ["title": "Connaissance \(index)", "content": note.content, "sources": [note.name]] as [String: Any]
        }, "contradictions": []]
        let envelope: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "structured_output": payload]
        try JSONSerialization.data(withJSONObject: envelope).write(to: root.appendingPathComponent("envelope.json"))
        let fake = #"""
        #!/usr/bin/python3
        import pathlib,time
        root=pathlib.Path(__file__).parent
        with (root/'launches.txt').open('a') as stream: stream.write('spawn\n')
        if (root/'block').exists():
            deadline=time.monotonic()+8
            while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.01)
        print((root/'envelope.json').read_text())
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try fake.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        LearningSettings.shared.isCurationScheduled = true
        LearningSettings.shared.maxPerWindow = 2
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: .claude)
        let service = NotesCurationService.shared
        let before = launches()
        var stateUnchangedAfterCancel: Bool?
        var corpusUnchangedAfterCancel: Bool?
        if scenario == "cancel" { try Data().write(to: root.appendingPathComponent("block")) }
        service.runIfDue()
        try await waitFor { launches() == before + 1 }
        if scenario == "cancel" {
            service.cancel()
            try Data().write(to: root.appendingPathComponent("release"))
            try await waitFor { service.phase == .idle && AnalysisBudget.shared.active == nil && service.lastOutcome == "analyse annulée" }
            let afterCancel = try Data(contentsOf: stateURL)
            stateUnchangedAfterCancel = afterCancel == stateBefore
            corpusUnchangedAfterCancel = corpus() == hashesBefore
            try check(afterCancel == stateBefore, "l'annulation a persisté la cadence, hypothèse réfutée")
            try check(corpus() == hashesBefore, "corpus changé après annulation")
            // Invoque directement le callback réel du prochain tick (pas le scheduler de 15 minutes).
            service.runIfDue()
            try await waitFor { launches() == before + 2 }
        }
        try await waitFor { service.phase == .idle && AnalysisBudget.shared.active == nil }
        let result: [String: Any] = ["scenario": scenario, "newSpawns": launches() - before,
            "totalSpawns": launches(), "stateUnchangedAfterCancel": stateUnchangedAfterCancel as Any? ?? NSNull(),
            "corpusUnchangedAfterCancel": corpusUnchangedAfterCancel as Any? ?? NSNull(), "hashesBefore": hashesBefore, "hashesAfter": corpus(),
            "outcome": service.lastOutcome ?? "nil", "stateDateBefore": oldDate,
            "retryAtAfter": service.retryAt?.timeIntervalSinceReferenceDate as Any? ?? NSNull(),
            "lastRunAtAfter": service.lastRunAt?.timeIntervalSinceReferenceDate as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result-\(scenario).json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
