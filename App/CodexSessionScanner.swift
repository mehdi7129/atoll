import Foundation
import AtollCore

enum CodexSessionScanner {
    static var registryURL: URL { BridgePaths.runDirectory.appendingPathComponent("codex-sessions.json") }

    /// Associations reçues par hooks, validées contre l'incarnation vivante.
    /// Un rollout ancien reste valide lors d'une reprise ; le cwd seul ne
    /// produit jamais une association, même avec un seul candidat.
    static func scan(known: Set<String>, home: URL,
                     registryURL: URL = registryURL) -> [CodexSessionDiscovery.Discovered] {
        CodexSessionRegistry.load(from: registryURL).compactMap { record in
            guard !known.contains(record.sessionID) else { return nil }
            return record.discovered(home: home) { pid in
                .init(isAlive: ProcessInspector.isAlive(pid), startTime: ProcessInspector.startTime(of: pid))
            }
        }
    }
}
