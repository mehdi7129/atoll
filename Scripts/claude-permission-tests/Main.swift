import Foundation
import Darwin
import AtollCore

private enum ProbeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

@main private struct ClaudePermissionProbe {
    @MainActor static var passed: [String] = []
    @MainActor static var server: BridgeServer!
    @MainActor static var socketPath = ""
    @MainActor static var children: [Process] = []
    @MainActor static var expired: [String] = []
    @MainActor static let center = InteractionCenter.shared
    @MainActor static let store = SessionStore.shared

    struct Helper {
        let process: Process
        let output: Pipe
        let id: String
    }

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeFailure.failed(message) }
    }
    @MainActor static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            if Date() >= deadline { throw ProbeFailure.failed(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func mode(_ value: String) {
        UserDefaults.standard.setVolatileDomain([InteractionCenter.autonomyKey: value], forName: UserDefaults.argumentDomain)
    }
    static func envelope(_ kind: String, session: String, tool: String? = "Bash", label: String = "fixture") -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": session,
                                     "tool_input": ["command": label], "cwd": "/fixture/project"]
        if let tool { payload["tool_name"] = tool }
        return ["v": 1, "payload": payload]
    }
    @MainActor static func launch(_ data: [String: Any], wait: Bool = true) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--helper", socketPath, wait ? "wait" : "event"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: data))
        try input.fileHandleForWriting.close()
        return (process, output)
    }
    @MainActor static func permission(_ session: String, label: String) async throws -> Helper {
        let previous = Set(center.pending.map(\.id))
        let (process, output) = try launch(envelope("PermissionRequest", session: session, label: label))
        try await until("permission not registered") { center.pending.contains { !previous.contains($0.id) } }
        let id = center.pending.first { !previous.contains($0.id) }!.id
        return Helper(process: process, output: output, id: id)
    }
    @MainActor static func event(_ kind: String, session: String, tool: String? = "Bash") async throws {
        let count = store.eventCount
        let (process, _) = try launch(envelope(kind, session: session, tool: tool), wait: false)
        try await until("event not delivered: \(kind)") { store.eventCount > count && !process.isRunning }
        try check(process.terminationStatus == 0, "event helper did not fail open")
    }
    @MainActor static func waiting(_ session: String) -> Bool {
        guard let phase = store.sessions.first(where: { $0.id == session })?.phase else { return false }
        if case .waitingPermission = phase { return true }
        return false
    }
    @MainActor static func result(_ helper: Helper) async throws -> String {
        try await until("helper remained blocked after resolution") { !helper.process.isRunning }
        try check(helper.process.terminationStatus == 0, "helper resolution failed open")
        return String(decoding: helper.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @MainActor static func sameTool() async throws {
        let session = "same-tool"
        let a = try await permission(session, label: "command A")
        let b = try await permission(session, label: "command B")
        try await Task.sleep(for: .milliseconds(250))
        try check(center.pending.count == 2 && a.process.isRunning && b.process.isRunning, "half-close removed live request")
        passed.append("half-close preserves two live helpers")
        center.allow(a.id)
        let answer = try await result(a)
        try check(answer.contains("allow") && center.pending.map(\.id) == [b.id] && waiting(session), "allow A resolved B or its phase")
        passed.append("allow A keeps B and waiting phase")
        for kind in ["PostToolUse", "PreToolUse", "PostToolUseFailure", "PermissionDenied", "SubagentStart", "SubagentStop"] {
            for tool in ["Bash", "Edit", nil] as [String?] {
                try await event(kind, session: session, tool: tool)
                try check(center.pending.map(\.id) == [b.id], "tool event removed unrelated card")
                try check(waiting(session), "tool event erased waiting phase")
                try check(b.process.isRunning, "tool event unblocked unrelated helper")
                passed.append("\(kind) tool=\(tool ?? "nil") preserves B and phase")
            }
        }
        // L'expiration retardée de A ne doit plus toucher la demande B.
        center.pendingExpired(a.id)
        try check(center.pending.map(\.id) == [b.id] && waiting(session), "late expiry touched B")
        passed.append("late expiry of resolved A ignored")
        center.deny(b.id)
        let denied = try await result(b)
        try check(denied.contains("deny") && center.pending.isEmpty && !waiting(session), "deny B did not release phase")
        passed.append("deny B resolves only its helper and phase")
    }

    @MainActor static func helperExitAndTimeout() async throws {
        let session = "helper-exit"
        let a = try await permission(session, label: "helper A")
        let b = try await permission(session, label: "helper B")
        a.process.terminate() // Seulement notre helper de fixture.
        try await until("helper exit did not expire exact card") { !center.pending.contains { $0.id == a.id } }
        try check(center.pending.map(\.id) == [b.id] && waiting(session) && b.process.isRunning, "helper exit affected sibling card")
        try check(expired.contains(a.id), "process watcher did not notify expiry")
        passed.append("helper exit expires exact request and preserves sibling")
        server.expireForTesting(b.id)
        try await until("timeout did not remove exact card") { center.pending.isEmpty }
        let response = try await result(b)
        try check(response.isEmpty && !waiting(session), "timeout invented decision or kept stale phase")
        passed.append("timeout returns terminal without decision")
        // Processus déjà sorti lorsque l'enveloppe arrive : l'ordre des callbacks
        // doit empêcher la création d'une carte après son expiration.
        for number in 0..<5 {
            let count = store.eventCount
            // La connexion a déjà été fermée quand le serveur peut la lire :
            // la course devient déterministe au lieu de dépendre du scheduler.
            server.pauseForTesting()
            let process: Process
            let output: Pipe
            do {
                (process, output) = try launch(envelope("PermissionRequest", session: "instant-\(number)"), wait: false)
                try await until("fast helper did not exit") { !process.isRunning }
            } catch {
                server.resumeForTesting()
                throw error
            }
            server.resumeForTesting()
            do { try await until("fast helper exit left a ghost card") {
                store.eventCount > count && !process.isRunning && center.pending.isEmpty && !waiting("instant-\(number)")
            }
            } catch {
                throw ProbeFailure.failed("fast helper exit left a ghost card: number=\(number) running=\(process.isRunning) events=\(store.eventCount)/\(count) pending=\(center.pending.map { $0.sessionID }) waiting=\(waiting("instant-\(number)")) expired=\(expired.count)")
            }
            try check(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "fast helper fabricated output")
        }
        passed.append("five immediate helper exits leave no ghost card")
    }

    @MainActor static func sessionClosures() async throws {
        for kind in ["Stop", "SessionEnd", "UserPromptSubmit"] {
            let session = "global-\(kind)"
            let a = try await permission(session, label: "same command")
            let b = try await permission(session, label: "same command")
            try await event(kind, session: session)
            try check(center.pending.isEmpty && !waiting(session), "global event retained stale requests")
            let outputA = try await result(a), outputB = try await result(b)
            try check(outputA.isEmpty && outputB.isEmpty, "global event fabricated permission")
            passed.append("\(kind) releases all session requests without decision")
        }
    }

    @MainActor static func rockstar() async throws {
        mode("rockstar")
        let count = store.eventCount
        let (process, output) = try launch(envelope("PermissionRequest", session: "rockstar-new"))
        try await until("Rockstar no longer auto approves") { store.eventCount > count && !process.isRunning }
        try check(center.pending.isEmpty && !waiting("rockstar-new"), "Rockstar left stale phase")
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try check(response.contains("allow"), "Rockstar permission changed")
        passed.append("Rockstar new request auto-approved")
        mode("manual")
        let a = try await permission("rockstar-existing", label: "A")
        let b = try await permission("rockstar-existing", label: "B")
        mode("rockstar")
        center.resolvePendingAsRockstar()
        let answerA = try await result(a), answerB = try await result(b)
        try check(answerA.contains("allow") && answerB.contains("allow") && center.pending.isEmpty
                  && !waiting("rockstar-existing"), "Rockstar existing requests changed")
        passed.append("Rockstar resolves existing requests")
        mode("manual")
    }

    static func main() async {
        // Le transport est extrait du helper produit, sans modification. Seuls
        // l'enveloppe, le socket privé et le choix d'attente viennent du harness.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--helper" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let outcome = sendToSocket(data, path: CommandLine.arguments[2], awaitReply: CommandLine.arguments[3] == "wait")
            if let reply = outcome.reply { FileHandle.standardOutput.write(reply) }
            exit(0)
        }
        await run()
    }

    @MainActor static func run() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
            try check(BridgePaths.homeDirectory.resolvingSymlinksInPath() == root, "Foundation home not isolated")
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try check(support.path.hasPrefix(root.path + "/"), "Application Support not isolated")
            mode("manual")
            socketPath = root.appendingPathComponent("bridge.sock").path
            try check(socketPath.utf8.count < 104 && socketPath != BridgePaths.socketPath, "private socket invalid")
            server = BridgeServer(onEvent: { event, id in
                MainActor.assumeIsolated {
                    store.apply(event)
                    if let id { center.register(event: event, requestID: id) }
                }
            }, onStatusline: { _ in }, onStateChange: { _ in }, onPendingExpired: { id in
                MainActor.assumeIsolated { expired.append(id); center.pendingExpired(id) }
            }, socketPath: socketPath)
            center.server = server
            try server.start()
            try await sameTool()
            try await helperExitAndTimeout()
            try await sessionClosures()
            try await rockstar()
            server.stop()
            let report: [String: Any] = ["count": passed.count, "passed": passed]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            server?.stop()
            for child in children where child.isRunning { child.terminate() }
            exit(1)
        }
    }
}
