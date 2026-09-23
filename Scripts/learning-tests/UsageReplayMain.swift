import Foundation
import AtollCore

/// Rejoue uniquement des compteurs capturés dans un journal privé. Aucun CLI.
@main struct UsageReplay {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Capture: Decodable {
        let usage: AnalysisUsage
        let model: String
        let promptCharacters: Int
        let durationSeconds: Double
    }
    struct State: Decodable { let records: [AnalysisBudget.Record] }
    struct Result: Encodable {
        let index: Int
        let passed: Bool
        let model: String
        let promptCharacters: Int
        let capturedCLIDurationSeconds: Double
        let replayJournalDurationSeconds: Double
        let usage: AnalysisUsage
        let coldReloadVerified: Bool
        let launchedRecords: Int
        let quotaCapVerified: Bool
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    @MainActor static func replay(_ object: [String: Any], index: Int, root: URL) throws -> Result {
        let capture = try JSONDecoder().decode(Capture.self, from: JSONSerialization.data(withJSONObject: object))
        guard let native = object["nativeUsage"] as? [String: Any], !native.isEmpty else {
            throw Failure(description: "capture \(index) : nativeUsage absent ou vide")
        }
        try check(capture.promptCharacters >= 0 && capture.durationSeconds.isFinite
                  && capture.durationSeconds >= 0 && !capture.model.isEmpty,
                  "capture \(index) : métadonnées invalides")
        // Les compteurs natifs restent inchangés ; aucun texte de réponse ou
        // prompt n'est nécessaire pour exercer le chemin réel d'enregistrement.
        let event = try JSONSerialization.data(withJSONObject: ["type": "turn.completed", "usage": native])
        try check(AnalysisUsage.parse(stdout: event, provider: .codex) == capture.usage,
                  "capture \(index) : usage capturé différent du snapshot natif rejoué")
        try check(capture.usage.source == .codexTurnCompleted && capture.usage.availability != .unknown,
                  "capture \(index) : aucun usage Codex exploitable")

        BridgePaths.root = root.appendingPathComponent("case-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: BridgePaths.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let journal = BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json")
        func records() throws -> [AnalysisBudget.Record] {
            try JSONDecoder().decode(State.self, from: Data(contentsOf: journal)).records
        }
        let execution = AnalysisExecution(provider: .codex, reason: "offline-usage-replay",
            model: capture.model, home: BridgePaths.root, executableOverride: "",
            quota: .init(usedFraction: 0, receivedAt: Date(), resetsAt: Date().addingTimeInterval(3600)),
            threshold: 0.7, maximum: 1, allowUnknown: false)
        let budget = AnalysisBudget()
        let id = try budget.begin(execution, kind: .retrospective, origin: .codex, destination: .codex)
        budget.updateMetrics(id, promptCharacters: capture.promptCharacters)
        try check(budget.refusalReason(for: execution) == nil, "réservation comptée comme dépense")
        try budget.prepareToLaunch(id)
        budget.launched(id)
        budget.recordUsage(id, stdout: event)
        budget.finish(id, outcome: "success")
        let finished = try records()
        try check(finished.count == 1, "nombre de reçus incorrect")
        let record = finished[0]
        try check(record.usage == capture.usage, "usage perdu ou modifié dans le journal")
        try check(record.promptCharacters == capture.promptCharacters && record.model == capture.model,
                  "prompt ou modèle perdu dans le journal")
        try check(record.launchedAt != nil && record.outcome == "success" && budget.active == nil,
                  "cycle de vie du reçu incorrect")
        guard let elapsed = record.durationSeconds, let end = record.endedAt else {
            throw Failure(description: "durée du replay absente")
        }
        try check(elapsed >= 0 && elapsed == end.timeIntervalSince(record.preparedAt),
                  "durée du replay incohérente")
        try check(budget.refusalReason(for: execution) == .windowCapReached, "dépense non comptée")

        // Une valeur locale distincte empêche qu'un no-op passe le test froid.
        // Ces valeurs transitoires ne sont jamais présentées comme usage capturé.
        budget.updateMetrics(id, promptCharacters: capture.promptCharacters == 0 ? 1 : 0)
        budget.recordUsage(id, stdout: Data())
        try check(try records()[0].usage == .unknown, "précondition du replay froid absente")
        // Deux instances sans lecture préalable reproduisent les entrées froides.
        let coldMetrics = AnalysisBudget()
        coldMetrics.updateMetrics(id, promptCharacters: capture.promptCharacters)
        try check(try records()[0].promptCharacters == capture.promptCharacters,
                  "métriques perdues sur instance froide")
        let coldUsage = AnalysisBudget()
        coldUsage.recordUsage(id, stdout: event)
        let reloaded = try records()
        try check(reloaded.count == 1 && reloaded[0].usage == capture.usage
                  && reloaded[0].promptCharacters == capture.promptCharacters
                  && reloaded[0].model == capture.model && reloaded[0].outcome == "success"
                  && reloaded[0].durationSeconds == elapsed && reloaded[0].endedAt == end,
                  "relecture froide a perdu ou altéré le reçu")
        try check(coldUsage.refusalReason(for: execution) == .windowCapReached && coldUsage.active == nil,
                  "relecture froide a perdu le plafond ou rouvert le reçu")
        let spends = reloaded.filter { $0.launchedAt != nil }.count
        try check(spends == 1, "compteurs natifs ont multiplié la dépense")
        return Result(index: index, passed: true, model: capture.model,
            promptCharacters: capture.promptCharacters, capturedCLIDurationSeconds: capture.durationSeconds,
            replayJournalDurationSeconds: elapsed, usage: record.usage!, coldReloadVerified: true,
            launchedRecords: spends, quotaCapVerified: true)
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3,
              let path = ProcessInfo.processInfo.environment["ATOLL_RUNTIME_TEST_ROOT"] else {
            throw Failure(description: "usage : usage-replay captures.json résultats.json ; racine privée obligatoire")
        }
        let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let captures = try JSONSerialization.jsonObject(with: input) as? [[String: Any]], !captures.isEmpty else {
            throw Failure(description: "tableau de captures attendu")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let results = try captures.enumerated().map { try replay($0.element, index: $0.offset, root: root) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("PASS \(results.count) replay(s) offline : usage exact, prompt, journal froid et dépense unique")
    }
}
