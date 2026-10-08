import Foundation

/// Service réel, racine privée : aucun CLI n'est nécessaire à cette reproduction.
@main struct CurationStateProbe {
    @MainActor static func main() throws {
        let directory = BridgePaths.learningDirectory
        let stateURL = directory.appendingPathComponent("curation.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{\"lastOutcome\":\"important contradiction\",broken".utf8)
        try original.write(to: stateURL)

        LearningSettings.shared.isCurationScheduled = true
        NotesCurationService.shared.syncWithSettings()

        let after = try Data(contentsOf: stateURL)
        let result: [String: Any] = [
            "corruptStatePreserved": after == original,
            "stateAfter": String(decoding: after, as: UTF8.self),
            "lastOutcome": NotesCurationService.shared.lastOutcome ?? "nil",
            "realCliLaunches": 0,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
