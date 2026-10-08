import Foundation
import AtollCore

/// Service réel, horloge réelle, rapport Claude factice dans une racine privée.
@main struct CurationCollisionProbe {
    enum Failure: Error { case timeout }

    @MainActor static func seedNotes() throws {
        let directory = BridgePaths.learningNotesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in ["one.md", "two.md"].enumerated() {
            let note = "---\ntitle: Connaissance \(index)\ncategory: technique\nproject: fixture\nsource_sessions: [\"session-\(index)\"]\n---\n\n"
                + String(repeating: "Connaissance vérifiée utile au projet \(index). ", count: 15)
            try note.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    @MainActor static func prepareFakeCLI() throws {
        let root = BridgePaths.root
        let items: [[String: Any]] = NotesCurationService.readNotes().enumerated().map { index, note in
            ["title": "Fait vérifié \(index)",
             "content": note.content.components(separatedBy: "\n---\n").last!,
             "sources": [note.name]]
        }
        let payload: [String: Any] = ["notes": items,
            "contradictions": [["summary": "Deux formulations à vérifier.", "files": ["one.md", "two.md"]]]]
        let envelope = try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false, "structured_output": payload,
            "usage": ["input_tokens": 100, "output_tokens": 20]])
        try envelope.write(to: root.appendingPathComponent("envelope.json"))
        let script = #"""
        #!/usr/bin/python3
        import pathlib
        root = pathlib.Path(__file__).parent
        with (root / 'launches.txt').open('a') as stream: stream.write('spawn\n')
        print((root / 'envelope.json').read_text())
        """#
        let cli = root.appendingPathComponent("fake-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    @MainActor static func archiveContains(_ bytes: Data) -> Bool {
        guard let files = FileManager.default.enumerator(at: BridgePaths.learningArchiveDirectory,
            includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files where (try? Data(contentsOf: file)) == bytes { return true }
        return false
    }

    @MainActor static func main() async throws {
        try seedNotes()
        LearningSettings.shared.isCurationScheduled = false
        LearningSettings.shared.maxPerWindow = 10
        LearningSettings.shared.failoverConfig = .init(enabled: false, preferred: .claude)

        let directory = BridgePaths.learningNotesDirectory
        let original = Data([0xff, 0xfe, 0xfd, 0x80])
        let collision = directory.appendingPathComponent("01-fait-verifie-0.md")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let orphan = directory.appendingPathComponent("01-fait-verifie-0.md.orphan-" + formatter.string(from: now))
        // Occuper le secours sans modifier l'horloge ni le service testé.
        for offset in -2...30 {
            let stamp = formatter.string(from: now.addingTimeInterval(Double(offset)))
            let url = directory.appendingPathComponent("01-fait-verifie-0.md.orphan-" + stamp)
            try Data("existing orphan must survive".utf8).write(to: url)
        }
        try original.write(to: collision)
        try prepareFakeCLI()
        NotesCurationService.shared.curateNow()
        let deadline = Date().addingTimeInterval(10)
        while NotesCurationService.shared.phase != .idle || AnalysisBudget.shared.active != nil {
            guard Date() < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }

        let launches = try String(contentsOf: BridgePaths.root.appendingPathComponent("launches.txt"), encoding: .utf8)
        let result: [String: Any] = [
            "outcome": NotesCurationService.shared.lastOutcome ?? "nil",
            "originalBytesPreserved": (try? Data(contentsOf: collision)) == original,
            "originalBytesInArchive": archiveContains(original),
            "orphanStillPresent": FileManager.default.fileExists(atPath: orphan.path),
            "fakeCliLaunches": launches.split(separator: "\n").count,
            "realCliLaunches": 0,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
