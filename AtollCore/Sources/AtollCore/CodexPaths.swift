import Foundation

public enum CodexPaths {
    /// Separate endpoint: an older Claude-only Atoll must never interpret a
    /// Codex permission as a Claude permission (or auto-approve it).
    public static var socketPath: String { "/tmp/atoll-codex-\(getuid()).sock" }
    public static var hooksURL: URL {
        let custom = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = custom.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? BridgePaths.homeDirectory.appendingPathComponent(".codex")
        return home.appendingPathComponent("hooks.json").resolvingSymlinksInPath()
    }
}
