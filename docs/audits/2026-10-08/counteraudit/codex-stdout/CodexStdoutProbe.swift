import Foundation
import Darwin
import AtollCore
struct SocketOutcome { let reached: Bool; let reply: Data? }
func sendToSocket(_ data: Data, path: String, awaitReply: Bool = false, replyDeadline: TimeInterval? = nil) -> SocketOutcome {
    SocketOutcome(reached: true, reply: CodexPermissionDecision.allow.hookOutput())
}
enum ProcessInspector {
    static func findCodexTUIAncestor(from pid: pid_t) -> ProcessIdentity? { nil }
    static func tty(of pid: pid_t) -> String? { nil }
    static func executablePath(of pid: pid_t) -> String? { nil }
}
enum SoundPlayer { static func play(hookEvent: String, provider: AgentProvider) {} }
@main struct Main {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        CodexBridge.forward()
        exit(0)
    }
}
