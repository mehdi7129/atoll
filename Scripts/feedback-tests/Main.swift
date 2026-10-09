import AppKit
import Foundation
import AtollCore

/// Collaborateurs injectés dans une copie privée de `perform` : aucun IDE réel.
final class FeedbackJumpFixture: @unchecked Sendable {
    static let shared = FeedbackJumpFixture()
    let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("jump-cli").path
    private let lock = NSLock()
    private var activations: [String] = []
    func activate(_ bundleID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        activations.append(bundleID ?? "absent")
        return true
    }
    var activated: [String] {
        lock.lock(); defer { lock.unlock() }
        return activations
    }
}

@main struct FeedbackTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
        try check(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == root.resolvingSymlinksInPath(), "home non isolé")
        let center = SoundCenter.shared
        let first = center.fixtureSound(.system("Glass"), .decisionNeeded)!
        let second = center.fixtureSound(.system("Glass"), .taskCompleted)!
        try check(first !== second, "A15 instances partagées")
        first.volume = 0.2; second.volume = 0.8
        try check(abs(first.volume - 0.2) < 0.001 && abs(second.volume - 0.8) < 0.001, "A15 volumes partagés")
        try check(center.fixtureSound(.system("Glass"), .decisionNeeded) === first, "cache du même événement perdu")
        try check(center.fixtureSound(.silent, .decisionNeeded) == nil, "silence perdu")
        try check(center.fixtureSound(.system("atoll-fixture-inexistant"), .decisionNeeded) == nil, "son absent inventé")
        try FileManager.default.createDirectory(at: BridgePaths.soundsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: BridgePaths.soundsDirectory.appendingPathComponent("fixture.aiff"))
        let custom = center.fixtureSound(.custom("fixture.aiff"), .decisionNeeded)!
        try check(custom !== center.fixtureSound(.custom("fixture.aiff"), .taskCompleted)!, "instances fichier partagées")
        try check(custom === center.fixtureSound(.custom("fixture.aiff"), .decisionNeeded), "cache fichier perdu")
        print("PASS A15 : 7 assertions AppKit, aucune lecture sonore")

        let workspace = root.appendingPathComponent("workspace")
        let nested = workspace.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let anchor = TerminalAnchor(cwd: nested.path, tty: nil, bundleID: "fixture", termProgram: nil, entrypoint: nil, env: [:])
        let marker = root.appendingPathComponent("finished")
        let cli = root.appendingPathComponent("fixture-cli")
        for (name, script, activation, expectedFocus) in [
            ("success", "sleep 0.15; printf '%s' \"$2\" > \"$CFFIXED_USER_HOME/finished\"; exit 0", true, true),
            ("exit42", "exit 42", false, false),
            ("fallback", "exit 42", true, true),
            ("activate-failed", "exit 0", false, false),
            ("timeout", "exec /bin/sleep 30", false, false),
            ("spawn-failed", "", false, false),
            ("missing-cli", "", true, true)
        ] {
            try ("#!/bin/sh\n" + script + "\n").write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let start = ContinuousClock.now
            let result = await TerminalJumpService.focusIDE(cli: "cursor", kind: .vscodeFamily(cli: "cursor"), anchor: anchor,
                resolveCLI: { _, _ in name == "missing-cli" ? nil : (name == "spawn-failed" ? cli.path + "-absent" : cli.path) },
                activate: { _ in activation }, timeout: 0.5)
            switch result {
            case .focused(_, let granularity):
                try check(expectedFocus && granularity == "app", "A17 succès ou granularité inventé")
            case .failed: try check(!expectedFocus, "A17 repli perdu")
            default: throw Failure(message: "TCC invoqué pour IDE")
            }
            if name == "success" {
                try check((try? String(contentsOf: marker, encoding: .utf8)) == workspace.path, "A17 fin CLI non attendue")
            }
            try check(start.duration(to: .now) < .seconds(2), "A17 deadline dépassée")
            print("PASS A17 \(name)")
        }

        let jumpCLI = URL(fileURLWithPath: FeedbackJumpFixture.shared.cli)
        try """
        #!/bin/sh
        name=${2##*/}
        printf 'start-%s\\n' "$name" >> "$CFFIXED_USER_HOME/jump-events"
        if [ "$name" = slow ]; then
            while [ ! -f "$CFFIXED_USER_HOME/jump-release" ]; do /bin/sleep 0.01; done
        fi
        printf 'end-%s\\n' "$name" >> "$CFFIXED_USER_HOME/jump-events"
        """.write(to: jumpCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jumpCLI.path)
        var callbacks: [String] = []
        var callbacksOnMain = true
        let targets = [("slow", "com.todesktop.230313mzl4w4u92"), ("fast", "com.microsoft.VSCode")]
        for (name, bundleID) in targets {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = TerminalAnchor(cwd: folder.path, tty: nil, bundleID: bundleID, termProgram: nil, entrypoint: nil, env: [:])
            TerminalJumpService.jump(to: target) { _ in
                callbacksOnMain = callbacksOnMain && Thread.isMainThread
                callbacks.append(name)
            }
        }
        // Le CLI attend une écriture effectuée ici sur MainActor : s'il était
        // bloqué, le watchdog couperait le CLI sans son marqueur de fin.
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (try? String(contentsOf: root.appendingPathComponent("jump-events"), encoding: .utf8))?
            .contains("start-slow") != true && ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        try Data().write(to: root.appendingPathComponent("jump-release"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while callbacks.count < targets.count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(callbacks == ["slow", "fast"] && callbacksOnMain, "A17 ordre des jumps perdu")
        let events = try String(contentsOf: root.appendingPathComponent("jump-events"), encoding: .utf8)
        try check(events.split(separator: "\n") == ["start-slow", "end-slow", "start-fast", "end-fast"],
                  "A17 ordre des jumps perdu : CLI concurrents")
        try check(FeedbackJumpFixture.shared.activated == targets.map(\.1), "A17 ordre des activations perdu")
        print("PASS A17 jumps successifs : CLI, activations et callbacks ordonnés ; MainActor disponible")
    }
}
