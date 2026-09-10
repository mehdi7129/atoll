import Foundation
import Observation
import AtollCore

/// La vue choisie n'est jamais une autorisation de changer le moteur des jobs.
@MainActor
@Observable
final class ProviderPreferences {
    static let shared = ProviderPreferences()
    static let selectedKey = "selectedAgentProvider"
    static let codexPaletteKey = "codexPaletteID"
    static var selected: AgentProvider { shared.selection }
    var selection: AgentProvider {
        didSet {
            guard !CodexPreview.enabled else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.selectedKey)
        }
    }

    private init() {
        selection = AgentProvider(rawValue: UserDefaults.standard.string(forKey: Self.selectedKey) ?? "") ?? .claude
    }
}
