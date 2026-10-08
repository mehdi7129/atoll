import Foundation
import AtollCore

@main struct ProcessTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_PROCESS_ROOT"]!)
        let helper = root.appendingPathComponent("fake-helper")
        let scenario = CommandLine.arguments[1]
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        switch scenario {
        case "resolve-claude", "resolve-codex", "resolve-claude-inherited", "resolve-codex-inherited":
            let cli = scenario.contains("claude") ? "claude" : "codex"
            let inherited = scenario.hasSuffix("inherited")
            check(("~" as NSString).expandingTildeInPath == root.path, "A09 resolver home escaped fixture")
            let start = ContinuousClock.now
            let path = cli == "claude" ? await ClaudeExecutable.resolve() : await CodexExecutable.resolve(overridePath: "")
            check(path == (inherited ? nil : root.appendingPathComponent("bin/" + cli).path), "A09 resolver result changed")
            check(start.duration(to: .now) < .seconds(2), "A09 resolver waited for inherited EOF")
        case "fleet":
            let start = ContinuousClock.now
            let result = await FleetPoller.runAgentsJSON(claudePath: helper.path,
                deadline: .now.advanced(by: .seconds(2)))
            check(result == nil, "A09 inherited pipe reported successful fleet")
            check(start.duration(to: .now) < .seconds(1), "A09 Fleet drain exceeded bound")
        case "keychain":
            let token = await ModelQuotaPoller.readAccessToken(executable: helper, timeout: 2)
            check(token == "fixture-token", "A11 token parsing changed")
        case "heartbeat":
            var heartbeat: ContinuousClock.Instant?
            let start = ContinuousClock.now
            let beat = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                heartbeat = .now
            }
            try await HookInstaller.runHelper("slow", executable: helper, timeout: 2)
            await beat.value
            check(heartbeat != nil && start.duration(to: heartbeat!) < .milliseconds(200), "A10 MainActor heartbeat delayed")
        case "large-stderr":
            try await HookInstaller.runHelper("large-stderr", executable: helper, timeout: 2)
        case "serial":
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            let duplicate = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            try await first.value; try await duplicate.value; try await second.value
            let lines = try String(contentsOf: root.appendingPathComponent("order")).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end"], "A10 helpers overlapped or duplicate spawned: \(lines)")
        case "writer-exclusion":
            let operation = Task { try await HookInstaller.runHelper("slow", executable: helper, timeout: 2) }
            try await Task.sleep(for: .milliseconds(50))
            do {
                try HookInstaller.requireNoActiveHelper()
                check(false, "A10 parallel settings writer allowed")
            } catch {}
            try await operation.value
            try HookInstaller.requireNoActiveHelper()
        case "alternating":
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            let third = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await first.value; try await second.value; try await third.value
            let lines = try String(contentsOf: root.appendingPathComponent("order")).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end", "first-start", "first-end"], "A10 last intent coalesced with old operation: \(lines)")
        case "queue-barrier":
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await Task.sleep(for: .milliseconds(40))
            let barrier = Task { await HookInstaller.waitForPendingOperation() }
            try await Task.sleep(for: .milliseconds(40))
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            await barrier.value
            let lines = try String(contentsOf: root.appendingPathComponent("order")).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end"], "A10 state reread before queued writer ended: \(lines)")
            try await first.value; try await second.value
        case "precondition-order":
            try await HookInstaller.runHelper("first", executable: helper, timeout: 2, before: {
                try HookInstaller.requireNoActiveHelper()
                try Data("restored-before-start\n".utf8).write(to: root.appendingPathComponent("order"))
            })
            let lines = try String(contentsOf: root.appendingPathComponent("order")).split(separator: "\n").map(String.init)
            check(lines == ["restored-before-start", "first-start", "first-end"], "A10 restitution order changed")
        case "interruption":
            check(BridgePaths.claudeSettingsURL.path.hasPrefix(root.path + "/"), "A10 settings escaped fixture")
            check(!HookInstaller.isInstalled, "A10 initial private state already installed")
            let installed = try HookSettingsEditor.install(into: nil, command: root.appendingPathComponent(".atoll/bin/atoll-bridge").path)
            try installed.write(to: root.appendingPathComponent("installed-fixture.json"))
            do {
                try await HookInstaller.runHelper("timeout", executable: helper, timeout: 1)
                check(false, "A10 timeout reported success")
            } catch {}
            let partial = try String(contentsOf: root.appendingPathComponent("partial-state"))
            check(partial == "written", "A10 interrupted write fixture missing")
            check(HookInstaller.isInstalled, "A10 interrupted write state not reread")
            try await HookInstaller.runHelper("after", executable: helper, timeout: 2)
            let lines = try String(contentsOf: root.appendingPathComponent("order")).split(separator: "\n").map(String.init)
            check(lines == ["after-start", "after-end"], "A10 interruption retried blindly")
        case "nonzero":
            do {
                try await HookInstaller.runHelper("failure", executable: helper, timeout: 2)
                check(false, "A10 nonzero status reported success")
            } catch { check(error.localizedDescription.contains("fixture-error"), "A10 stderr diagnostic lost") }
        default: fatalError("Unknown scenario")
        }
        print("PASS \(scenario)")
    }
}
