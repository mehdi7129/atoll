import Foundation
import AtollCore

// Seuls les collaborateurs sont contrôlés ; les trois services sont compilés entiers.
enum CodexPreview { static let enabled = false }
enum CodexPaths {
    static var homeURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_PROCESS_ROOT"]!) }
    static var configurationError: String? { nil }
}
@MainActor final class SoundCenter {
    static let shared = SoundCenter()
    func restoreUserSoundHooks() throws {}
}
@MainActor final class SessionStore {
    static let shared = SessionStore()
    func applyFleetSnapshot(_ sessions: [AgentSessionInfo], available: Bool) {}
}
