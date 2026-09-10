import Foundation

/// Associations attestées par les hooks, conservées pour un redémarrage d'Atoll.
/// Jamais de recherche de rollout par cwd ou date de dossier.
public struct CodexSessionRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let process: ProcessIdentity
    public let home: String
    public let cwd: String
    public let transcriptPath: String
    public let anchor: TerminalAnchor?

    public init?(event: CodexHookEvent, home: URL, previousAnchor: TerminalAnchor? = nil) {
        guard event.agentID == nil, let process = event.process, let cwd = event.cwd,
              let path = event.transcriptPath, path.hasPrefix("/"), cwd.hasPrefix("/") else { return nil }
        sessionID = event.sessionID
        self.process = process
        self.home = home.standardizedFileURL.resolvingSymlinksInPath().path
        self.cwd = cwd
        transcriptPath = path
        anchor = event.anchor ?? previousAnchor
    }

    public func discovered(home: URL, probe: (Int32) -> CodexCardReaper.Probe) -> CodexSessionDiscovery.Discovered? {
        guard self.home == home.standardizedFileURL.resolvingSymlinksInPath().path,
              sessionID.hasPrefix("codex:"), cwd.hasPrefix("/"), transcriptPath.hasPrefix("/") else { return nil }
        let seen = probe(process.pid)
        guard seen.isAlive, process.matches(pid: process.pid, startedAt: seen.startTime) else { return nil }
        return .init(sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath,
                     startedAt: Date(timeIntervalSince1970: process.startedAt), process: process, anchor: anchor)
    }
}

public enum CodexSessionRegistry {
    /// L'app est l'unique écrivain ; les helpers transmettent leurs observations.
    public static func load(from url: URL) -> [CodexSessionRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 512 * 1024 + 1), bytes.count <= 512 * 1024,
              let records = try? JSONDecoder().decode([CodexSessionRecord].self, from: bytes) else { return [] }
        return Array(records.suffix(256))
    }

    public static func save(_ records: [CodexSessionRecord], to url: URL) throws {
        let data = try JSONEncoder().encode(Array(records.suffix(256)))
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
