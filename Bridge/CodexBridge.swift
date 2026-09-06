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
        let envelope: [String: Any] = ["v": 1, "provider": "codex", "payload": payload]
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
