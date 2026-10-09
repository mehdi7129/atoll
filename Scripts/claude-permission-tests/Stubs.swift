import Foundation
import AtollCore

// Les trois composants du contrat (serveur, cartes et sessions) sont réels.
// Seuls les collaborateurs sans rôle dans la résolution sont neutralisés.
@MainActor final class SoundCenter {
    static let shared = SoundCenter()
    enum Event { case decisionNeeded, taskCompleted }
    func play(_ event: Event) {}
}
@MainActor final class MemoryIndexer {
    static let shared = MemoryIndexer()
    func nudge(transcriptPath: String) {}
}
@MainActor final class CodexService {
    static let shared = CodexService()
    var serverRunning = false
    func diagnosticSessions() -> [[String: Any]] { [] }
}
@MainActor final class CodexInteractionCenter {
    struct Request {
        struct Permission { let toolName: String }
        let id: String
        let sessionID: String
        let permission: Permission
        let agentID: String
        let turnID: String
    }
    static let shared = CodexInteractionCenter()
    let pending: [Request] = []
}
@MainActor final class ProviderPreferences {
    static let shared = ProviderPreferences()
    let selection = AgentProvider.claude
}
