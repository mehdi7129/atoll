import AppKit
import Foundation
import AtollCore

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
    }
}
