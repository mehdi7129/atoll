import Foundation
import AtollCore

/// Journal réel, collaborateurs du harness runtime et racines temporaires.
/// Aucun runner, aucun CLI, aucune préférence utilisateur n'est exécuté.
@main struct MetricsTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    @MainActor static var journalURL: URL {
        BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json")
    }

    @MainActor static func fixture(_ name: String) throws {
        BridgePaths.root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_RUNTIME_TEST_ROOT"]!)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: BridgePaths.learningDirectory, withIntermediateDirectories: true)
    }

    @MainActor static func records() throws -> [AnalysisBudget.Record] {
        struct State: Decodable { let records: [AnalysisBudget.Record] }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: journalURL)).records
    }

    @MainActor static func context(_ provider: AgentProvider) -> AnalysisExecution {
        .init(provider: provider, reason: "test", model: "fixture-model", home: BridgePaths.root,
              executableOverride: "", quota: .init(usedFraction: 0, receivedAt: Date(),
                resetsAt: Date().addingTimeInterval(3600)), threshold: 0.7, maximum: 1, allowUnknown: true)
    }

    @MainActor static func lifecycle(_ provider: AgentProvider, kind: AnalysisExecution.Kind,
                                    outcome: String) throws {
        try fixture("\(provider.rawValue)-\(kind.rawValue)-\(outcome)")
        let budget = AnalysisBudget()
        let execution = context(provider)
        let lease = try budget.begin(execution, kind: kind)
        let initial = try records().last!
        try check(initial.usage == .unknown, "nouveau journal sans inconnue explicite")
        try check(initial.promptCharacters == nil && initial.notesWritten == nil && initial.skillsProposed == nil,
                  "mesures absentes converties en zéro")
        try check(initial.digestFragmentsShortened == nil && initial.digestEntriesDropped == nil
                  && initial.digestSourceReadStopped == nil, "digest absent converti en mesure complète")
        budget.updateMetrics(lease, promptCharacters: 340, notesWritten: 0, skillsProposed: 0)
        try budget.prepareToLaunch(lease)
        budget.launched(lease)
        budget.finish(lease, outcome: outcome)
        let finished = try records().last!
        try check(finished.endedAt != nil && finished.durationSeconds != nil, "durée terminée absente")
        try check(finished.durationSeconds == finished.endedAt!.timeIntervalSince(finished.preparedAt),
                  "durée différente de la réservation à la clôture")
        try check(budget.refusalReason(for: execution) == .windowCapReached, "dépense perdue après clôture")

        // Le retour stdout peut suivre une annulation qui a déjà clos le reçu.
        let output = provider == .codex
            ? #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":70,"output_tokens":11}}"#
            : #"{"type":"result","is_error":true,"result":"PRIVATE_RESULT","session_id":"PRIVATE_SESSION","usage":{"input_tokens":100,"cache_read_input_tokens":70,"cache_creation_input_tokens":20,"output_tokens":11}}"#
        budget.recordUsage(lease, stdout: Data(output.utf8))
        budget.updateMetrics(lease, notesWritten: 2, skillsProposed: 1,
                             digestFragmentsShortened: 3, digestEntriesDropped: 0, digestSourceReadStopped: false)
        let late = try records().last!
        try check(late.usage?.inputTokens == 100 && late.usage?.outputTokens == 11,
                  "usage tardif perdu après clôture")
        try check(late.usage?.cachedInputTokens == 70, "cache natif perdu au journal")
        try check(late.outcome == outcome && late.endedAt == finished.endedAt
                  && late.durationSeconds == finished.durationSeconds, "retour tardif a rouvert le reçu")
        try check(late.promptCharacters == 340 && late.notesWritten == 2 && late.skillsProposed == 1,
                  "compteurs d'écritures confirmées perdus")
        try check(late.digestFragmentsShortened == 3 && late.digestEntriesDropped == 0
                  && late.digestSourceReadStopped == false, "mesures du digest perdues")
        budget.updateMetrics(lease, promptCharacters: -1, notesWritten: -1, skillsProposed: -1)
        let unchanged = try records().last!
        try check(unchanged.promptCharacters == 340 && unchanged.notesWritten == 2 && unchanged.skillsProposed == 1,
                  "compteurs invalides ont remplacé une mesure")
        let unknownID = UUID()
        let before = try Data(contentsOf: journalURL)
        budget.recordUsage(unknownID, stdout: Data(output.utf8))
        budget.updateMetrics(unknownID, notesWritten: 999)
        budget.finish(unknownID, outcome: "foreign")
        try check(try Data(contentsOf: journalURL) == before, "identifiant étranger a modifié le journal")
        try check(!String(decoding: before, as: UTF8.self).contains("PRIVATE"), "texte privé copié dans les métriques")
        let reloaded = AnalysisBudget()
        try check(reloaded.refusalReason(for: execution) == .windowCapReached, "métriques ont effacé la dépense au redémarrage")
        try check(budget.active == nil && reloaded.active == nil, "lease rouverte par métriques")
        // Aucun begin/refusal avant ces entrées : c'est l'ordre réel au
        // démarrage, quand une livraison attend avant tout nouveau run.
        let coldMetrics = AnalysisBudget()
        coldMetrics.updateMetrics(lease, notesWritten: 3, skillsProposed: 2)
        let recoveredMetrics = try records().last!
        try check(recoveredMetrics.notesWritten == 3 && recoveredMetrics.skillsProposed == 2,
                  "métriques perdues sur instance froide")
        let coldUsage = AnalysisBudget()
        coldUsage.recordUsage(lease, stdout: Data(output.replacingOccurrences(of: "100", with: "101").utf8))
        let recoveredUsage = try records().last!
        try check(recoveredUsage.usage?.inputTokens == 101, "usage perdu sur instance froide")
        try check(recoveredUsage.notesWritten == 3 && recoveredUsage.outcome == outcome
                  && recoveredUsage.durationSeconds == finished.durationSeconds,
                  "instance froide a altéré le reçu de livraison")
    }

    @MainActor static func legacy(_ stage: String) throws {
        try fixture("legacy-\(stage)")
        let execution = context(.claude)
        let original = AnalysisBudget()
        let lease = try original.begin(execution, kind: .retrospective)
        if stage != "preparing" { try original.prepareToLaunch(lease) }
        if stage == "running" || stage == "success" { original.launched(lease) }
        if stage == "success" { original.finish(lease, outcome: "success") }
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
        var saved = root["records"] as! [[String: Any]]
        for key in ["endedAt", "durationSeconds", "promptCharacters", "usage", "notesWritten", "skillsProposed"] {
            saved[0].removeValue(forKey: key)
        }
        root["records"] = saved
        try JSONSerialization.data(withJSONObject: root).write(to: journalURL)
        let raw = try records().last!
        try check(raw.usage == nil && raw.durationSeconds == nil, "legacy a inventé des mesures")
        let recovered = AnalysisBudget()
        let expected: LearningGate.Reason? = stage == "preparing" ? nil : .windowCapReached
        try check(recovered.refusalReason(for: execution) == expected, "budget legacy changé : \(stage)")
        // Écrire le journal par une mesure n'ajoute pas de date de décès supposée.
        recovered.updateMetrics(lease, promptCharacters: 120)
        let record = try records().last!
        try check(record.durationSeconds == nil && record.endedAt == nil, "reprise a inventé la fin du processus")
        try check(record.outcome == (stage == "success" ? "success" : "interrupted"), "reprise legacy mal classée")
    }

    @MainActor static func main() throws {
        for provider in AgentProvider.allCases {
            for kind in [AnalysisExecution.Kind.retrospective, .curation, .pluginSearch] {
                for outcome in ["success", "cancelled", "failed(exit)"] {
                    try lifecycle(provider, kind: kind, outcome: outcome)
                }
            }
        }
        for stage in ["preparing", "launching", "running", "success"] { try legacy(stage) }
        try fixture("corrupt-cold-metrics")
        let corrupt = Data("journal interrompu".utf8)
        try corrupt.write(to: journalURL)
        let cold = AnalysisBudget()
        cold.updateMetrics(UUID(), notesWritten: 1)
        cold.recordUsage(UUID(), stdout: Data())
        try check(try Data(contentsOf: journalURL) == corrupt, "journal illisible écrasé par métriques froides")
        try check(cold.refusalReason(for: context(.claude)) == .analysisJournalUnreadable,
                  "journal illisible autorise une nouvelle dépense")
        print("PASS 23 parcours métriques : fin/échec/annulation, retours tardifs et froids, compteurs, confidentialité, quota et legacy")
    }
}
