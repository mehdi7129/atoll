import Foundation

public enum CodexProcessKind {
    /// Les auxiliaires (`codex-code-mode-host`, etc.) partagent le dossier du
    /// CLI, mais ni son rôle ni sa durée de vie. Seule l'image Codex compte.
    public static func isExecutable(path: String) -> Bool {
        (path as NSString).lastPathComponent == "codex"
    }

    /// Contrat CLI 0.154.0. Une option inconnue reste non attribuée.
    public static func isInteractive(arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        let valueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile",
                                          "-C", "--cd", "--add-dir", "--sandbox", "-s",
                                          "--ask-for-approval", "-a", "--image", "-i",
                                          "--enable", "--disable", "--local-provider"]
        let flags: Set<String> = ["--no-alt-screen", "--full-auto", "--search", "--oss",
                                  "--dangerously-bypass-approvals-and-sandbox", "--yolo",
                                  "--dangerously-bypass-hook-trust", "--approve-for-me",
                                  "--strict-config", "--worktree", "--ignore-user-config"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return true }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return false }
                index += 2; continue
            }
            if flags.contains(argument) || (argument.contains("=") && valueOptions.contains(String(argument.split(separator: "=", maxSplits: 1)[0]))) {
                index += 1; continue
            }
            if argument.hasPrefix("-") { return false }
            return !["exec", "e", "app-server", "login", "logout", "mcp", "mcp-server",
                     "debug", "sandbox", "completion", "apply", "review", "features",
                     "cloud", "help", "app", "update", "agents", "plugin", "remote-control",
                     "doctor", "queue", "archive", "delete", "migrate-rollouts", "unarchive",
                     "exec-server", "a"].contains(argument)
        }
        return true
    }
}
