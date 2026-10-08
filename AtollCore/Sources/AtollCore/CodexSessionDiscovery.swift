import Foundation

/// Données de session confirmées par le registre et transmises au collecteur.
public enum CodexSessionDiscovery {
    /// Une session retrouvée, prête à être projetée dans l'îlot.
    public struct Discovered: Equatable, Sendable {
        public let sessionID: String        // déjà préfixé « codex: »
        public let cwd: String
        public let transcriptPath: String
        public let startedAt: Date
        public let process: ProcessIdentity?
        public let anchor: TerminalAnchor?

        public init(sessionID: String, cwd: String, transcriptPath: String, startedAt: Date,
                    process: ProcessIdentity? = nil, anchor: TerminalAnchor? = nil) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            self.startedAt = startedAt
            self.process = process
            self.anchor = anchor
        }
    }
}
