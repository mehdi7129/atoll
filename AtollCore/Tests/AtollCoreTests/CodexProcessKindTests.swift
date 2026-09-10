import XCTest
@testable import AtollCore

final class CodexProcessKindTests: XCTestCase {
    func testYoloAliasAndCurrentInteractiveFlagsPreserveSessionDetection() {
        for flag in ["--yolo", "--dangerously-bypass-approvals-and-sandbox",
                     "--dangerously-bypass-hook-trust", "--approve-for-me", "--worktree", "--strict-config"] {
            XCTAssertTrue(CodexProcessKind.isInteractive(arguments: ["codex", flag]), flag)
            XCTAssertTrue(CodexProcessKind.isInteractive(arguments: ["codex", flag, "resume", "--last"]), flag)
            XCTAssertFalse(CodexProcessKind.isInteractive(arguments: ["codex", flag, "exec", "fixture"]), flag)
            XCTAssertFalse(CodexProcessKind.isInteractive(arguments: ["codex", flag, "app-server"]), flag)
        }
    }

    func testHelpersInsideTheCodexPackageAreNotSessionProcesses() {
        let bin = "/fixture/.codex/packages/standalone/releases/0.154.0/bin/"
        XCTAssertTrue(CodexProcessKind.isExecutable(path: bin + "codex"))
        XCTAssertTrue(CodexProcessKind.isExecutable(path: "/Applications/ChatGPT.app/Contents/Resources/codex"))
        for helper in ["codex-code-mode-host", "codex-exec-server", "rg", "node"] {
            XCTAssertFalse(CodexProcessKind.isExecutable(path: bin + helper), helper)
        }
    }

    func testUnknownOptionsIncompleteArgumentsAndHeadlessCommandsStayExcluded() {
        for args in [["codex", "--new-unverified-option"], ["codex", "--model"],
                     ["codex", "--yolo", "--config"], ["codex", "--remote", "unix://"],
                     ["codex", "--yolo", "review"], ["codex", "--yolo", "--version"]] {
            XCTAssertFalse(CodexProcessKind.isInteractive(arguments: args), "\(args)")
        }
        XCTAssertTrue(CodexProcessKind.isInteractive(arguments: ["codex", "--local-provider", "ollama", "--oss"]))
    }
}
