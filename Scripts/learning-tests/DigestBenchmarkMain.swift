import Foundation

/// Corpus synthétique annoté : il mesure la préservation des extraits attendus,
/// jamais la qualité d'un modèle, l'utilité future d'un skill ou le temps humain.
@main struct DigestBenchmark {
    struct Fixture {
        let name: String
        let annotation: String
        let lines: [TranscriptLine]
        let expectedProofs: [String]
        var budget = TranscriptDigest.defaultCharacterBudget
        var fullCommand: String? = nil
        var expectedShortened: Int = 0
        var expectedDropped: Int = 0
        var readStopped = false
    }
    struct Row: Codable {
        let name: String
        let annotation: String
        let characters: Int
        let expectedProofs: Int
        let preservedProofs: Int
        let fragmentsShortened: Int
        let entriesDropped: Int
        let sourceReadStopped: Bool?
        let fullCommandPreserved: Bool?
        let incompleteCommandMarked: Bool?
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
    static func line(_ role: TranscriptLine.Role, _ text: String,
                     outcome: TranscriptLine.ToolOutcome? = nil) -> TranscriptLine {
        .init(uuid: nil, sessionID: nil, timestamp: nil, cwd: nil, gitBranch: nil,
              fragments: [.init(role: role, text: text, toolOutcome: outcome)])
    }
    static var fixtures: [Fixture] {
        let verbose = String(repeating: "Explication provisoire à examiner. ", count: 100)
        let command = "Bash · run-check --payload '" + String(repeating: "long-param=12345;", count: 160) + "' --final-flag"
        return [
            .init(name: "routine", annotation: "Aucun skill attendu : lecture et opération ordinaires.",
                  lines: [line(.user, "Vérifie le statut du dépôt."), line(.assistant, "git status ne montre aucun changement.")],
                  expectedProofs: ["aucun changement"]),
            .init(name: "already-covered", annotation: "Aucun skill attendu : procédure déjà présente au catalogue annoté.",
                  lines: [line(.user, "Utilise le skill release-pipeline existant."), line(.assistant, "La procédure release-pipeline existante convient.")],
                  expectedProofs: ["release-pipeline existant"]),
            .init(name: "verified-pitfall", annotation: "Candidat possible : échec, correction puis contrôle concret.",
                  lines: [line(.toolResult, "resource fork not allowed", outcome: .failure),
                          line(.assistant, "La copie ditto hors iCloud passe codesign --verify --deep.")],
                  expectedProofs: ["resource fork not allowed", "codesign --verify --deep"]),
            .init(name: "final-correction", annotation: "Candidat possible seulement si la correction finale reste visible.",
                  lines: [line(.assistant, "Hypothèse initiale invalidée. " + verbose + "\nPREUVE FINALE : la copie ditto passe codesign.")],
                  expectedProofs: ["Hypothèse initiale", "PREUVE FINALE : la copie ditto passe codesign."], expectedShortened: 1),
            .init(name: "compaction-summary", annotation: "La synthèse doit conserver sa conclusion, sans créer de nouveau fait.",
                  lines: [line(.summary, "État avant compaction. " + verbose + "\nRÉSULTAT CONSERVÉ : le contrôle a réussi.")],
                  expectedProofs: ["État avant compaction", "RÉSULTAT CONSERVÉ : le contrôle a réussi."], expectedShortened: 1),
            .init(name: "long-command", annotation: "Ne pas proposer de commande rejouable à partir d'un extrait incomplet.",
                  lines: [line(.tool, command), line(.toolResult, "ok", outcome: .success)],
                  expectedProofs: [], fullCommand: command, expectedShortened: 1),
            .init(name: "resumed-session", annotation: "Antériorité de reprise distincte de la nouvelle demande.",
                  lines: [line(.summary, "La session précédente a validé le backup."), line(.user, "Reprends sans refaire le backup."),
                          line(.assistant, "Le backup précédent reste valide ; contrôle SHA256 inchangé.")],
                  expectedProofs: ["sans refaire le backup", "SHA256 inchangé"]),
            .init(name: "unknown-success", annotation: "Aucun succès établi malgré la prose ; aucun skill de procédure validée attendu.",
                  lines: [line(.tool, "Bash · check-result", outcome: .unknown), line(.toolResult, "exit code 0, semble fonctionner", outcome: .unknown)],
                  expectedProofs: ["outcome=unknown"]),
            .init(name: "pruned-and-read-limited", annotation: "Les fragments perdus ne gonflent pas le compteur des fragments raccourcis gardés.",
                  lines: [line(.assistant, verbose), line(.assistant, verbose), line(.user, "Demande conservée.")],
                  expectedProofs: ["Demande conservée."], budget: 100, expectedDropped: 2, readStopped: true),
        ]
    }

    static func main() throws {
        let baseline = CommandLine.arguments.contains("--baseline")
        var rows: [Row] = []
        for fixture in fixtures {
            let result = TranscriptDigest.make(lines: fixture.lines, budget: fixture.budget,
                                               sourceReadStopped: fixture.readStopped)
            let proofs = fixture.expectedProofs.filter { result.text.contains($0) }.count
            let exactCommand = fixture.fullCommand.map { result.text.contains($0) }
            let incompleteMarked = fixture.fullCommand.map { _ in result.text.contains("command=incomplete") }
            try check(result.characterCount <= fixture.budget, "budget dépassé : \(fixture.name)")
            try check(result == TranscriptDigest.make(lines: fixture.lines, budget: fixture.budget,
                                                     sourceReadStopped: fixture.readStopped), "rendu instable : \(fixture.name)")
            if !baseline {
                try check(proofs == fixture.expectedProofs.count, "preuve finale perdue : \(fixture.name)")
                try check(result.fragmentsShortened == fixture.expectedShortened, "compteur raccourcis incorrect : \(fixture.name)")
                try check(result.entriesDropped == fixture.expectedDropped, "compteur élagués incorrect : \(fixture.name)")
                try check(result.sourceReadStopped == fixture.readStopped, "limite lecture perdue : \(fixture.name)")
                if fixture.fullCommand != nil {
                    try check(exactCommand == false && incompleteMarked == true, "commande incomplète non signalée")
                    try check(!result.text.contains("--final-flag"), "commande recomposée depuis sa fin")
                }
            }
            rows.append(Row(name: fixture.name, annotation: fixture.annotation, characters: result.characterCount,
                expectedProofs: fixture.expectedProofs.count, preservedProofs: proofs,
                fragmentsShortened: result.fragmentsShortened, entriesDropped: result.entriesDropped,
                sourceReadStopped: result.sourceReadStopped, fullCommandPreserved: exactCommand,
                incompleteCommandMarked: incompleteMarked))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(rows), as: UTF8.self))
    }
}
