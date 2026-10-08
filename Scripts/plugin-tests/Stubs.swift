import Foundation
import AtollCore

// Collaborateurs sans compte, préférences ou app. Les deux services testés
// restent les fichiers produit compilés, y compris leurs vrais sous-processus.
@MainActor final class SessionStore {
    static let shared = SessionStore()
    func registerInternalPid(_ pid: Int32) {}
    func unregisterInternalPid(_ pid: Int32) {}
}
enum ProcessInspector {
    static func launchOwned(_ process: Process) throws -> ProcessIdentity? { try ProcessIdentity.launch(process) }
    static func identity(of pid: Int32) -> ProcessIdentity? { ProcessIdentity.current(of: pid) }
    @discardableResult static func signal(_ signal: Int32, to identity: ProcessIdentity) -> Bool { identity.send(signal) }
}
enum TestAnalysisKind { case pluginSearch }
struct AnalysisExecution {
    let provider = AgentProvider.claude
    let home = URL(fileURLWithPath: "/private/fixture")
    let model = "fixture"
    let executableOverride = ""
    static func capture(kind: TestAnalysisKind) throws -> Self { Self() }
}
@MainActor final class AnalysisBudget {
    static let shared = AnalysisBudget()
    func begin(_ execution: AnalysisExecution, kind: TestAnalysisKind, destination: AgentProvider) throws -> UUID { UUID() }
    func finish(_ lease: UUID, outcome: String) {}
    func updateMetrics(_ lease: UUID, promptCharacters: Int) {}
    func mayLaunch(_ lease: UUID, context: AnalysisExecution) -> Bool { true }
    func prepareToLaunch(_ lease: UUID) throws {}
    func launched(_ lease: UUID) {}
    func recordUsage(_ lease: UUID, stdout: Data) {}
}
enum CodexRun {
    static let lastFailure: String? = "Aucune génération dans cette recette."
    struct Launch {
        let shellCommand: String
        let outputFile: URL?
        let workspace: URL?
        func cleanUp() {}
    }
    static func prepare(schema: String, prompt: String, label: String, home: URL,
                        model: String, executableOverride: String) async -> Launch? { nil }
    static func prepareClaude(arguments: [String], label: String) async -> Launch? { nil }
}
enum CodexExecutable {
    static let notFoundMessage = "Binaire de test absent."
    static func resolve(overridePath: String) async -> String? { overridePath }
}
