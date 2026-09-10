// Collaborateurs contrôlés du harness : les deux runners sont compilés verbatim.
import Foundation
import AtollCore
enum CodexPreview { static let enabled = false }
enum CodexPaths {
    static var invalidHome = false
    static var cliHomeURL: URL { BridgePaths.root }
    static var homeURL: URL { cliHomeURL }
    static func validatedHome() throws -> URL {
        if invalidHome { throw CocoaError(.fileReadCorruptFile) }
        return cliHomeURL
    }
}
struct SkillDestination {
    let provider: AgentProvider
    static func capture(origin: AgentProvider) throws -> Self { .init(provider: origin) }
    var store: LearnedSkillStore {
        .init(learningRoot: BridgePaths.learningDirectory,
              skillsRoot: BridgePaths.root.appendingPathComponent("skills/\(provider.rawValue)"), destination: provider)
    }
    func catalog(project: URL?) async throws -> [CatalogEntry] { [] }
    static func summary(_ entries: [CatalogEntry]) -> String { "fixture catalog" }
}

enum BridgePaths {
    static var root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_RUNTIME_TEST_ROOT"]!)
    static var learningDirectory: URL { root.appendingPathComponent("learning") }
    static var learningNotesDirectory: URL { learningDirectory.appendingPathComponent("notes") }
    static var learningProposedDirectory: URL { learningDirectory.appendingPathComponent("proposed") }
    static var learningArchiveDirectory: URL { learningDirectory.appendingPathComponent("archive") }
    static var learningStateURL: URL { learningDirectory.appendingPathComponent("retrospectives.json") }
    static var claudeProjectsURL: URL { root.appendingPathComponent("projects") }
    static var codexSessionsURL: URL { root.appendingPathComponent("sessions") }
}

@MainActor final class LearningSettings {
    static let shared = LearningSettings()
    static let budgetUSD = 1.50
    static let curationIntervalDays: TimeInterval = 7
    var isEnabled = true
    var isCurationScheduled = false
    var model = "test-model"
    var curationModel = "test-model"
    var searchModel = "test-model"
    var codexModel = "test-model"
    var maxPerWindow = 10
    var allowUnknownQuota = true
    var quotaThreshold = 0.70
    var failoverConfig = ProviderFailover.Config()
    var gateConfig = LearningGate.Config(enabled: true)
}

@MainActor final class SessionStore {
    static let shared = SessionStore()
    enum Phase {
        case ended, working
        var isAlive: Bool { self == .working }
    }
    enum SessionEndReason: String { case test }
    struct Tracked {
        let id: String
        var cwd: String?
        var transcriptPath: String?
        var phase: Phase
        var isSynthetic: Bool
        var firstSeenAt: Date
        var lastEventAt: Date
        var model: String?
        var gitBranch: String?
        var userPromptCount = 0
    }
    struct Window {
        var usedFraction = 0.0
        var resetsAt = Date().addingTimeInterval(3600)
    }
    struct Quota {
        var fiveHour = Window()
        var receivedAt = Date()
    }
    var realQuota: Quota? = Quota()
    var rawQuotaReceivedAt: Date? = Date()
    var sessions: [Tracked] = []
    func registerInternalPid(_ pid: Int32) {}
    func unregisterInternalPid(_ pid: Int32) {}
}

@MainActor final class CodexService {
    static let shared = CodexService()
    var quota: CodexQuota?
    func contains(_ id: String) -> Bool { false }
}

struct SkillCatalog {
    init(projectDirectory: URL?) {}
    func summaryForPrompt() -> String { "Catalogue de test vide." }
}
enum MemoryIndexer {
    static func noteSlug(for url: URL) -> String? { url.deletingPathExtension().lastPathComponent }
}

@MainActor enum Resolver {
    static var blocked = false
    static var entered = false
    static var continuation: CheckedContinuation<Void, Never>?
    static var provider: AgentProvider?
    static func resolve(_ engine: AgentProvider) async {
        provider = engine
        entered = true
        if blocked { await withCheckedContinuation { continuation = $0 } }
    }
    static func release() { continuation?.resume(); continuation = nil }
}

enum ClaudeExecutable {
    static let notFoundMessage = "faux CLI absent"
    @MainActor static func resolve() async -> String? {
        await Resolver.resolve(.claude)
        return BridgePaths.root.appendingPathComponent("fake-cli").path
    }
}

enum CodexExecutable {
    static let notFoundMessage = "faux CLI absent"
    static let overrideKey = "testCodexExecutable"
}
enum CodexRun {
    static let lastFailure: String? = nil
    struct Launch {
        let shellCommand: String
        let outputFile: URL?
        let workspace: URL?
        func cleanUp() {}
    }
    @MainActor static func prepare(schema: String, prompt: String, workingDirectory: String?, label: String,
                                  home: URL = CodexPaths.homeURL, model: String, executableOverride: String) async -> Launch? {
        await Resolver.resolve(.codex)
        return Launch(shellCommand: "exec " + FleetLaunch.shellQuote(BridgePaths.root.appendingPathComponent("fake-cli").path),
                      outputFile: BridgePaths.root.appendingPathComponent("output.json"), workspace: nil)
    }
    @MainActor static func prepareClaude(arguments: [String], label: String) async -> Launch? {
        guard let path = await ClaudeExecutable.resolve() else { return nil }
        return Launch(shellCommand: "exec " + FleetLaunch.shellQuote(path), outputFile: nil, workspace: nil)
    }
}

// Simulation du refus d'un signal : le faux CLI termine quand le test lui
// rend sa réponse. Cela force le cas important « annulé, puis exit 0 ».
enum ProcessInspector {
    static func identity(of pid: Int32) -> ProcessIdentity? { ProcessIdentity(pid: pid, startedAt: 123) }
    static func signal(_ signal: Int32, to identity: ProcessIdentity) {}
    static var dead: Set<Int32> = []
    static func isAlive(_ pid: Int32) -> Bool { !dead.contains(pid) }
    static func startTime(of pid: Int32) -> Double? { isAlive(pid) ? 123 : nil }
}

final class BridgeServer {
    var replied: [String] = []
    var cancelled: [String] = []
    func reply(_ id: String, decision: Data) { replied.append(id) }
    func cancelPending(_ id: String) { cancelled.append(id) }
}
@MainActor final class SoundCenter {
    static let shared = SoundCenter()
    enum Event { case decisionNeeded }
    var played = 0
    func play(_ event: Event) { played += 1 }
}
