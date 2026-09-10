import Foundation
import Darwin

/// A short-lived, read-only app-server client. Never starts/resumes a thread or
/// generates tokens. Uses the CLI's own login; no auth.json/Keychain extraction.
public enum CodexReadClient {
    /// Allowlist : aucune méthode de création/reprise de thread, ni mutation.
    public enum Query: Sendable {
        case quota, hooks(cwd: String), models(cursor: String? = nil), skills(cwd: String), plugins(cwd: String)
        var requiresAccount: Bool { if case .quota = self { return true }; return false }
        var method: String {
            switch self {
            case .quota: return "account/rateLimits/read"
            case .hooks: return "hooks/list"
            case .models: return "model/list"
            case .skills: return "skills/list"
            case .plugins: return "plugin/list"
            }
        }
        var params: [String: Any] {
            switch self {
            case .quota: return [:]
            case .hooks(let cwd): return ["cwds": [cwd]]
            case .skills(let cwd): return ["cwds": [cwd], "forceReload": true]
            case .plugins(let cwd): return ["cwds": [cwd], "forceRefetch": false, "marketplaceKinds": ["local"]]
            case .models(let cursor):
                var value: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { value["cursor"] = cursor }
                return value
            }
        }
    }

    public enum Outcome: Sendable {
        case available(Data)
        case unavailable(String)
    }

    /// Run on a worker, not the UI thread. All I/O and child lifetime are bounded.
    public static func read(_ query: Query, executable: URL, home: URL = CodexPaths.homeURL, timeout: TimeInterval = 20,
                            cancelled: @Sendable () -> Bool = { false }) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["ATOLL_RETROSPECTIVE"] = "1"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: home.path)
            ? home : FileManager.default.temporaryDirectory
        // A socket instead of a pipe allows SO_NOSIGPIPE on writes: a dying
        // CLI must never terminate Atoll with SIGPIPE during the handshake.
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            return .unavailable("connexion locale impossible")
        }
        let input = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        let output = Pipe()
        var noSignal: Int32 = 1
        setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var writeTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sockets[0], SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        defer { close(sockets[0]); try? input.close() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // never log account/auth diagnostics
        do { try process.run() }
        catch { return .unavailable("codex ne peut pas démarrer") }
        let identity = ProcessIdentity.current(of: process.processIdentifier)
        try? input.close()
        try? output.fileHandleForWriting.close()
        defer {
            shutdown(sockets[0], SHUT_WR)
            if process.isRunning, let identity {
                identity.send(SIGTERM)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    identity.send(SIGKILL)
                }
            }
            // Sans identité lisible, l'EOF reste le seul geste autorisé ; ne
            // jamais attendre indéfiniment ni signaler un PID par supposition.
            if identity != nil || !process.isRunning { process.waitUntilExit() }
            try? output.fileHandleForReading.close()
        }

        func send(_ message: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return false }
            data.append(10)
            return data.withUnsafeBytes { bytes in
                Darwin.write(sockets[0], bytes.baseAddress!, bytes.count) == bytes.count
            }
        }
        guard send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "atoll", "title": "Atoll read-only client", "version": "0.1.0"]
        ]]) else { return .unavailable("connexion Codex interrompue") }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()
        var totalBytes = 0
        var expectedID = 1
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline, !cancelled() {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            totalBytes += count
            guard totalBytes <= 8_388_608 else { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                else { continue }
                guard message["id"] as? Int == expectedID else { continue }
                guard message["error"] == nil, let result = message["result"] as? [String: Any]
                else { return .unavailable("lecture Codex indisponible — vérifier la connexion et la version du CLI") }
                if expectedID == 1 {
                    guard send(["method": "initialized"]) else { return .unavailable("connexion Codex interrompue") }
                    expectedID = 2
                    let request: [String: Any] = query.requiresAccount
                        ? ["id": 2, "method": "account/read", "params": ["refreshToken": false]]
                        : ["id": 2, "method": query.method, "params": query.params]
                    guard send(request) else { return .unavailable("connexion Codex interrompue") }
                } else if expectedID == 2 && query.requiresAccount {
                    guard let account = result["account"] as? [String: Any] else {
                        return .unavailable("connexion requise — lance codex login")
                    }
                    guard account["type"] as? String == "chatgpt" else {
                        return .unavailable("compte hors abonnement ChatGPT — quota non disponible")
                    }
                    expectedID = 3
                    guard send(["id": 3, "method": query.method, "params": query.params]) else {
                        return .unavailable("connexion Codex interrompue")
                    }
                } else {
                    guard let data = try? JSONSerialization.data(withJSONObject: result) else {
                        return .unavailable("réponse Codex invalide")
                    }
                    return .available(data)
                }
            }
        }
        return .unavailable(cancelled() ? "lecture annulée" : "Codex ne répond pas — nouvel essai dans 2 min")
    }
}
