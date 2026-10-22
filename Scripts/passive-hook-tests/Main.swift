import Foundation
import Darwin
import AtollCore

@MainActor final class Observed {
    var claude = SessionPhase.starting
    var codex = CodexSessions()
    var count = 0
    var unexpectedRequest = false
}

@main struct PassiveServerProbe {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func legacyClient(_ path: String, _ payload: [String: Any], codex: Bool) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("legacy socket failed") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyMemory(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { fail("legacy connect failed") }
        var envelope: [String: Any] = ["payload": payload]
        if codex { envelope["provider"] = "codex" }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { fail("legacy incomplete write") }
        shutdown(fd, SHUT_WR)
        var byte: UInt8 = 0
        let received = read(fd, &byte, 1)
        guard received == 0 else { fail("legacy-permission-not-returned-empty") }
    }

    @MainActor static func main() async throws {
        let path = CommandLine.arguments[1]
        let observed = Observed()
        let server = BridgeServer(onEvent: { event, requestID in
            if requestID != nil { observed.unexpectedRequest = true }
            observed.claude = SessionReducer.reduce(observed.claude, event)
            observed.count += 1
        }, onStatusline: { _ in }, onStateChange: { _ in }, onCodexEvent: { event, requestID, helperPID in
            if requestID != nil || helperPID != 0 { observed.unexpectedRequest = true }
            observed.codex.applyEvent(event)
            observed.count += 1
        }, socketPath: path)
        try server.start()
        defer { server.stop() }
        var expected = 0
        for codex in [false, true] {
            for kind in ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"] {
                let payload: [String: Any] = ["hook_event_name": kind, "session_id": "passive-server",
                                             "turn_id": "turn", "tool_name": "Bash"]
                try await Task.detached { try legacyClient(path, payload, codex: codex) }.value
                expected += 1
                for _ in 0..<100 where observed.count < expected {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard observed.count == expected else { fail("passive-event-not-delivered") }
                if kind == "PermissionRequest" || kind == "PostToolUse" {
                    if codex {
                        guard case .awaitingPermission? = observed.codex.sessions().first?.status else { fail("codex-passive-wait-lost") }
                    } else {
                        guard case .waitingPermission = observed.claude else { fail("claude-passive-wait-lost") }
                    }
                }
            }
        }
        guard !observed.unexpectedRequest else { fail("decision-request-created") }
        guard observed.claude == .waitingInput,
              observed.codex.sessions().first?.status == .awaitingInput else { fail("native-stop-not-observed") }
        print("{\"legacy_permissions_closed_empty\":true,\"events\":8,\"passive_wait\":true}")
    }
}
