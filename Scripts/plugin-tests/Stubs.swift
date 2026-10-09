import Foundation
import AtollCore

// Collaborateurs sans compte, préférences ou app. Les deux services testés
// restent les fichiers produit compilés, y compris leurs vrais sous-processus.
@MainActor final class SessionStore {
    static let shared = SessionStore()
    var internalPids: Set<Int32> = []
    func registerInternalPid(_ pid: Int32) { internalPids.insert(pid) }
    func unregisterInternalPid(_ pid: Int32) { internalPids.remove(pid) }
}
enum ProcessInspector {
    static var unverifiable = false
    static func launchOwned(_ process: Process) throws -> ProcessIdentity? {
        if unverifiable { try process.run(); return nil }
        return try ProcessIdentity.launch(process)
    }
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
    var active: UUID?
    func begin(_ execution: AnalysisExecution, kind: TestAnalysisKind, destination: AgentProvider) throws -> UUID {
        guard active == nil else { throw NSError(domain: "fixture.busy", code: 1) }
        let lease = UUID(); active = lease; return lease
    }
    func finish(_ lease: UUID, outcome: String) { if active == lease { active = nil } }
    func updateMetrics(_ lease: UUID, promptCharacters: Int) {}
    func mayLaunch(_ lease: UUID, context: AnalysisExecution) -> Bool { true }
    func prepareToLaunch(_ lease: UUID) throws {}
    func launched(_ lease: UUID) {}
    func recordUsage(_ lease: UUID, stdout: Data) {}
}
enum CodexRun {
    static var fixtureLaunch: Launch?
    static let lastFailure: String? = "Aucune génération dans cette recette."
    struct Launch {
        let shellCommand: String
        let outputFile: URL?
        let workspace: URL?
        func cleanUp() { if let workspace { try? Data().write(to: workspace.appendingPathComponent("cleaned")) } }
    }
    static func prepare(schema: String, prompt: String, label: String, home: URL,
                        model: String, executableOverride: String) async -> Launch? { nil }
    static func prepareClaude(arguments: [String], label: String) async -> Launch? { fixtureLaunch }
}
enum CodexExecutable {
    static let notFoundMessage = "Binaire de test absent."
    static func resolve(overridePath: String) async -> String? { overridePath }
}
