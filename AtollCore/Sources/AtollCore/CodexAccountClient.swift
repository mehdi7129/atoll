import Foundation

/// Le quota est une lecture typée du même transport borné que les catalogues.
public enum CodexAccountClient {
    public enum Outcome: Sendable {
        case available(CodexQuota)
        case unavailable(String)
    }

    public static func read(executable: URL, home: URL = CodexPaths.homeURL, timeout: TimeInterval = 20,
                            cancelled: @Sendable () -> Bool = { false }) -> Outcome {
        switch CodexReadClient.read(.quota, executable: executable, home: home,
                                   timeout: timeout, cancelled: cancelled) {
        case .available(let data):
            guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let quota = CodexQuota(result: result) else {
                return .unavailable("aucune fenêtre de quota fournie par Codex")
            }
            return .available(quota)
        case .unavailable(let reason): return .unavailable(reason)
        }
    }
}
