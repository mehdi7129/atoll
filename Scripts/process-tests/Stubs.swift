import Foundation
import AtollCore

// Seuls les collaborateurs sont contrôlés ; les trois services sont compilés entiers.
enum CodexPreview { static let enabled = false }
enum CodexPaths {
    static var selectedHome: URL?
    static var selectionError: String?
    static var homeURL: URL { selectedHome ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_PROCESS_ROOT"]!) }
    static var hooksURL: URL { homeURL.appendingPathComponent("hooks.json") }
    static var configurationError: String? { selectionError }
    static func validatedHome() throws -> URL {
        if selectionError != nil { throw CocoaError(.fileReadCorruptFile) }
        return homeURL
    }
}
final class EssentialFixtureDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
@MainActor final class SessionStore {
    static let shared = SessionStore()
    func applyFleetSnapshot(_ sessions: [AgentSessionInfo], available: Bool) {}
}
