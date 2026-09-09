import Foundation
import AtollCore

enum CodexBridge {
    static var settingsURL: URL {
        CodexPaths.hooksURL
    }

    static func forward() {
        guard isatty(0) == 0 else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 8_388_608,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        // MÊME enrichissement que le chemin Claude, et pour la même raison :
        // sans lui, `terminalAnchor` ne connaît aucune session Codex et le
        // jump-back reste mort — alors que le mécanisme (`cursor -r <cwd>`) est
        // parfaitement agnostique au fournisseur. C'est ce qui rend le passage
        // de Claude Code à Codex transparent (demande de Mehdi, 2026-09-09).
        //
        // Toujours AUCUNE réponse, aucune décision : on enrichit ce qu'on
        // observe, on ne prend pas la main sur Codex.
        var enrich: [String: Any] = [:]
        if let tty = ProcessInspector.tty(of: getpid()) { enrich["tty"] = tty }
        let environment = ProcessInfo.processInfo.environment
        if let hint = environment["__CFBundleIdentifier"] ?? environment["TERM_PROGRAM"] {
            enrich["terminalHint"] = hint
        }
        let subset = TerminalAnchor.capture(from: environment)
        if !subset.isEmpty { enrich["env"] = subset }

        var envelope: [String: Any] = ["v": 1, "provider": "codex", "payload": payload]
        if !enrich.isEmpty { envelope["enrich"] = enrich }
        guard CodexHookEvent(envelope: envelope) != nil,
              let encoded = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        // Observation ONLY: no reply, no sounds/recall/Claude safety-rule edits.
        _ = sendToSocket(encoded, path: CodexPaths.socketPath)
    }

    static func configure(install: Bool) -> Int32 {
        do {
            try CodexHookInstallation.apply(settingsURL: settingsURL, binDirectory: BridgePaths.binDirectory,
                                            helperURL: URL(fileURLWithPath: CommandLine.arguments[0]), install: install)
            return 0
        } catch {
            let message = "Installation des hooks Codex échouée : \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            return 1
        }
    }
}
