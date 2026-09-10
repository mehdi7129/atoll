import Foundation

public enum CodexPaths {
    public static var homeSelectionURL: URL { BridgePaths.homeDirectory.appendingPathComponent(".atoll/codex-home.json") }

    public static var configuredHome: String? {
        try? readSelection(at: homeSelectionURL)
    }

    public static func readSelection(at url: URL) throws -> String? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code)
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil { return nil }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard !data.isEmpty, data.count <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode([String: String].self, from: data)
        guard let path = value["home"], path.hasPrefix("/"), !path.contains("\0") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return path
    }

    public static var configurationError: String? {
        do { _ = try readSelection(at: homeSelectionURL); return nil }
        catch { return "Sélection CODEX_HOME illisible : choisis à nouveau le dossier dans Réglages → Codex." }
    }

    public static func resolveHome(configuredPath: String?, environment: [String: String],
                                   userHome: URL) -> URL {
        let path = [configuredPath, environment["CODEX_HOME"]].compactMap { $0 }
            .first { $0.hasPrefix("/") }
        return (path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    public static var homeURL: URL {
        // Aucun repli vers un autre compte si le choix enregistré est corrompu.
        (try? validatedHome()) ?? BridgePaths.homeDirectory.appendingPathComponent(".atoll/invalid-codex-home")
    }

    public static func validatedHome() throws -> URL {
        let path = try readSelection(at: homeSelectionURL)
        return resolveHome(configuredPath: path, environment: ProcessInfo.processInfo.environment,
                           userHome: BridgePaths.homeDirectory)
    }

    /// Le hook décrit le home de SON CLI, même si Atoll observe un autre home.
    public static var cliHomeURL: URL {
        resolveHome(configuredPath: nil, environment: ProcessInfo.processInfo.environment,
                    userHome: BridgePaths.homeDirectory)
    }

    public static func selectHome(_ path: String?, selectionURL: URL = homeSelectionURL) throws {
        guard let path, !path.isEmpty else {
            if FileManager.default.fileExists(atPath: selectionURL.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: selectionURL.path)) != nil {
                try FileManager.default.removeItem(at: selectionURL)
            }
            return
        }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        let data = try JSONEncoder().encode(["home": URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path])
        if (try? Data(contentsOf: selectionURL)) == data { return }
        try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: selectionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectionURL.path)
    }
    /// Separate endpoint: an older Claude-only Atoll must never interpret a
    /// Codex permission as a Claude permission (or auto-approve it).
    public static var socketPath: String { "/tmp/atoll-codex-\(getuid()).sock" }
    public static var hooksURL: URL {
        homeURL.appendingPathComponent("hooks.json").resolvingSymlinksInPath()
    }
}
