import XCTest
@testable import AtollCore

final class TerminalTargetTests: XCTestCase {

    private func anchor(bundleID: String? = nil, termProgram: String? = nil,
                        env: [String: String] = [:], tty: String? = "ttys012",
                        cwd: String? = "/Users/me/proj") -> TerminalAnchor {
        TerminalAnchor(cwd: cwd, tty: tty, bundleID: bundleID, termProgram: termProgram,
                       entrypoint: env["CLAUDE_CODE_ENTRYPOINT"], env: env)
    }

    // MARK: - Résolution

    func testResolvesCursorFromBundleID() {
        // Le cas réel de Mehdi : sessions dans le terminal intégré de Cursor.
        let kind = TerminalResolver.resolve(anchor(bundleID: "com.todesktop.230313mzl4w4u92", termProgram: "vscode"))
        XCTAssertEqual(kind, .vscodeFamily(cli: "cursor"))
        XCTAssertEqual(kind.displayName, "Cursor")
    }

    func testResolvesVSCode() {
        XCTAssertEqual(TerminalResolver.resolve(anchor(bundleID: "com.microsoft.VSCode")), .vscodeFamily(cli: "code"))
    }

    func testResolvesTerminalAppAndIterm() {
        XCTAssertEqual(TerminalResolver.resolve(anchor(bundleID: "com.apple.Terminal")), .terminalApp)
        XCTAssertEqual(TerminalResolver.resolve(anchor(bundleID: "com.googlecode.iterm2")), .iterm2)
    }

    func testFallsBackToTermProgram() {
        XCTAssertEqual(TerminalResolver.resolve(anchor(termProgram: "Apple_Terminal")), .terminalApp)
        XCTAssertEqual(TerminalResolver.resolve(anchor(termProgram: "iTerm.app")), .iterm2)
        XCTAssertEqual(TerminalResolver.resolve(anchor(termProgram: "ghostty")), .ghostty)
    }

    func testUnknownTerminal() {
        let kind = TerminalResolver.resolve(anchor(bundleID: "com.example.weird"))
        XCTAssertEqual(kind, .unknown(bundleID: "com.example.weird"))
        XCTAssertEqual(kind.fallbackBundleID, "com.example.weird")
    }

    func testTmuxDetection() {
        XCTAssertTrue(anchor(env: ["TMUX": "/tmp/tmux-501/default,1234,0", "TMUX_PANE": "%3"]).isTmux)
        XCTAssertFalse(anchor().isTmux)
    }

    // MARK: - Scripts

    func testTerminalAppScriptEmbedsTTY() {
        let script = TerminalScripts.terminalApp(tty: "ttys004")
        XCTAssertTrue(script.contains("/dev/ttys004"))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("set frontmost of w to true"))
    }

    func testIterm2ScriptEmbedsTTY() {
        let script = TerminalScripts.iterm2(tty: "/dev/ttys009")
        XCTAssertTrue(script.contains("/dev/ttys009"))
        XCTAssertTrue(script.contains("tell application \"iTerm\""))
        XCTAssertTrue(script.contains("select aSession"))
    }

    func testDevTTYNormalisation() {
        XCTAssertTrue(TerminalScripts.terminalApp(tty: "ttys004").contains("\"/dev/ttys004\""))
        XCTAssertTrue(TerminalScripts.terminalApp(tty: "/dev/ttys004").contains("\"/dev/ttys004\""))
    }

    func testAppleScriptEscaping() {
        // Un tty ne contient jamais de guillemets, mais l'échappement doit être sûr.
        XCTAssertEqual(TerminalScripts.escapeAppleScript("a\"b\\c"), "a\\\"b\\\\c")
    }

    // MARK: - CLI IDE

    func testCursorCLICandidates() {
        let paths = IDECommandLine.candidates(cli: "cursor", appPath: "/Applications/Cursor.app")
        XCTAssertEqual(paths.first, "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/cursor"))
    }
}
