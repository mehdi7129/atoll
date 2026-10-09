import Foundation
import AtollCore

// Les témoins sont alimentés uniquement dans la copie compilée du helper.
@MainActor enum HookFixtureProbe {
    static var calls: [String] = []
    static var barrierEntered = false
}

@main struct ProcessTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_PROCESS_ROOT"]!)
        let helper = root.appendingPathComponent("fake-helper")
        let scenario = CommandLine.arguments[1]
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func waitForFixture(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                check(ContinuousClock.now < deadline, "Fixture non établie : " + message)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func block(_ verb: String) throws {
            try Data().write(to: root.appendingPathComponent("block-" + verb))
        }
        func release(_ verb: String) throws {
            try Data().write(to: root.appendingPathComponent("release-" + verb))
        }
        func waitForHelper(_ verb: String) async throws {
            try await waitForFixture("helper prêt " + verb) {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-" + verb).path)
            }
        }
        switch scenario {
        case "fleet-ownership", "keychain-ownership":
            func probe() async -> Bool {
                if scenario == "fleet-ownership" {
                    return await FleetPoller.runAgentsJSON(claudePath: helper.path,
                        deadline: .now.advanced(by: .milliseconds(500))) != nil
                }
                return await ModelQuotaPoller.readAccessToken(executable: helper, timeout: 0.5) != nil
            }
            func launches() -> Int {
                ((try? String(contentsOf: root.appendingPathComponent("probe-launches"), encoding: .utf8)) ?? "").split(separator: "\n").count
            }
            let first = Task { await probe() }
            let fixtureDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while launches() == 0 {
                check(ContinuousClock.now < fixtureDeadline, "A09 probe fixture did not become ready")
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstSucceeded = await first.value
            check(!firstSucceeded && launches() == 1, "A09 probe fixture did not time out")
            let second = await probe()
            check(!second && launches() == 1, "A09 probe lost live child ownership")
            try Data().write(to: root.appendingPathComponent("probe-release"))
            try await Task.sleep(for: .milliseconds(300))
            let resumed = await probe()
            check(resumed && launches() == 2, "A09 probe did not resume after child exit")
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
            try block("first")
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await waitForHelper("first")
            let duplicate = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await waitForFixture("appel dupliqué") { HookFixtureProbe.calls.count == 2 }
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            try await waitForFixture("second appel enfilé") { HookFixtureProbe.calls.count == 3 }
            try release("first")
            try await first.value; try await duplicate.value; try await second.value
            let lines = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end"], "A10 helpers overlapped or duplicate spawned: \(lines)")
        case "writer-exclusion":
            try block("slow")
            let operation = Task { try await HookInstaller.runHelper("slow", executable: helper, timeout: 2) }
            try await waitForHelper("slow")
            do {
                try HookInstaller.requireNoActiveHelper()
                check(false, "A10 parallel settings writer allowed")
            } catch {}
            try release("slow")
            try await operation.value
            try HookInstaller.requireNoActiveHelper()
        case "alternating":
            try block("first")
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await waitForHelper("first")
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            try await waitForFixture("deuxième intention") { HookFixtureProbe.calls.count == 2 }
            let third = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await waitForFixture("troisième intention") { HookFixtureProbe.calls.count == 3 }
            try release("first")
            try await first.value; try await second.value; try await third.value
            let lines = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end", "first-start", "first-end"], "A10 last intent coalesced with old operation: \(lines)")
        case "queue-barrier":
            try block("first")
            let first = Task { try await HookInstaller.runHelper("first", executable: helper, timeout: 2) }
            try await waitForHelper("first")
            let barrier = Task { await HookInstaller.waitForPendingOperation() }
            try await waitForFixture("barrière sur le premier helper") { HookFixtureProbe.barrierEntered }
            let second = Task { try await HookInstaller.runHelper("second", executable: helper, timeout: 2) }
            try await waitForFixture("second appel enfilé") { HookFixtureProbe.calls.count == 2 }
            try release("first")
            await barrier.value
            let lines = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8).split(separator: "\n").map(String.init)
            check(lines == ["first-start", "first-end", "second-start", "second-end"], "A10 state reread before queued writer ended: \(lines)")
            try await first.value; try await second.value
        case "precondition-order":
            try await HookInstaller.runHelper("first", executable: helper, timeout: 2, before: {
                try HookInstaller.requireNoActiveHelper()
                try Data("restored-before-start\n".utf8).write(to: root.appendingPathComponent("order"))
            })
            let lines = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8).split(separator: "\n").map(String.init)
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
            let partial = try String(contentsOf: root.appendingPathComponent("partial-state"), encoding: .utf8)
            check(partial == "written", "A10 interrupted write fixture missing")
            check(HookInstaller.isInstalled, "A10 interrupted write state not reread")
            try await HookInstaller.runHelper("after", executable: helper, timeout: 2)
            let lines = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8).split(separator: "\n").map(String.init)
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
