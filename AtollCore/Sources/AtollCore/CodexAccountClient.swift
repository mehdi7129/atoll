import Foundation
import Darwin

/// A short-lived, read-only app-server client. Never starts/resumes a thread or
/// generates tokens. Uses the CLI's own login; no auth.json/Keychain extraction.
public enum CodexAccountClient {
    public enum Outcome: Sendable {
        case available(CodexQuota)
        case unavailable(String)
    }

    /// Run on a worker, not the UI thread. All I/O and child lifetime are bounded.
    public static func read(executable: URL, timeout: TimeInterval = 20,
                            cancelled: @Sendable () -> Bool = { false }) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
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
        try? input.close()
        try? output.fileHandleForWriting.close()
        defer {
            shutdown(sockets[0], SHUT_WR)
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            process.waitUntilExit()
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
            "clientInfo": ["name": "atoll", "title": "Atoll quota reader", "version": "0.1.0"]
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
            guard totalBytes <= 2_097_152 else { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                else { continue }
                guard message["id"] as? Int == expectedID else { continue }
                guard message["error"] == nil, let result = message["result"] as? [String: Any]
                else { return .unavailable("quota indisponible — vérifier la connexion Codex") }
                switch expectedID {
                case 1:
                    guard send(["method": "initialized"]),
                          send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    else { return .unavailable("connexion Codex interrompue") }
                    expectedID = 2
                case 2:
                    guard let account = result["account"] as? [String: Any] else {
                        return .unavailable("connexion requise — lance codex login")
                    }
                    guard account["type"] as? String == "chatgpt" else {
                        return .unavailable("compte hors abonnement ChatGPT — quota non disponible")
                    }
                    guard send(["id": 3, "method": "account/rateLimits/read"]) else {
                        return .unavailable("connexion Codex interrompue")
                    }
                    expectedID = 3
                default:
                    guard let quota = CodexQuota(result: result) else {
                        return .unavailable("aucune fenêtre de quota fournie par Codex")
                    }
                    return .available(quota)
                }
            }
        }
        return .unavailable(cancelled() ? "lecture annulée" : "Codex ne répond pas — nouvel essai dans 2 min")
    }
}
