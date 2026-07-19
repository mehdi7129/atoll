import AppKit
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "jump")

/// Fait remonter au premier plan le terminal exact qui héberge une session.
///
/// Règles (voir docs/research/…terminal-jump-back) :
/// - tout AppleScript est exécuté par l'app (attribution TCC correcte), JAMAIS
///   par le helper ;
/// - la granularité dégrade en cascade : pane → onglet → fenêtre → app ;
/// - le repli `NSRunningApplication.activate()` ne demande AUCUNE permission.
@MainActor
enum TerminalJumpService {

    enum Result {
        case focused(TerminalKind, granularity: String)
        case needsAutomationPermission(appName: String)
        case failed(String)
    }

    static func jump(to anchor: TerminalAnchor) -> Result {
        let kind = TerminalResolver.resolve(anchor)
        log.info("jump vers \(kind.displayName, privacy: .public) (tmux: \(anchor.isTmux))")

        switch kind {
        case .vscodeFamily(let cli):
            return focusIDE(cli: cli, anchor: anchor)

        case .terminalApp:
            return focusViaAppleScript(
                bundleID: "com.apple.Terminal",
                appName: "Terminal",
                script: anchor.tty.map { TerminalScripts.terminalApp(tty: $0) },
                kind: kind, granularity: "onglet"
            )

        case .iterm2:
            return focusViaAppleScript(
                bundleID: "com.googlecode.iterm2",
                appName: "iTerm2",
                script: anchor.tty.map { TerminalScripts.iterm2(tty: $0) },
                kind: kind, granularity: "pane"
            )

        default:
            // Ghostty/WezTerm/kitty/Warp/Alacritty/inconnu : activation app.
            return activateApp(bundleID: kind.fallbackBundleID, kind: kind)
        }
    }

    // MARK: - VS Code / Cursor (aucune permission requise)

    private static func focusIDE(cli: String, anchor: TerminalAnchor) -> Result {
        let kind = TerminalKind.vscodeFamily(cli: cli)
        // 1. `<cli> -r <cwd>` : remonte la fenêtre du workspace (niveau fenêtre).
        if let cwd = anchor.cwd,
           let cliPath = resolveIDECLI(cli: cli, bundleID: anchor.bundleID) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["-r", cwd]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                // Ramener l'app au premier plan (la CLI ne le fait pas toujours).
                activateBundle(anchor.bundleID)
                return .focused(kind, granularity: "fenêtre")
            }
        }
        // 2. Repli : activation de l'app par bundle id.
        if activateBundle(anchor.bundleID) {
            return .focused(kind, granularity: "app")
        }
        return .failed("Impossible de focuser \(kind.displayName).")
    }

    private static func resolveIDECLI(cli: String, bundleID: String?) -> String? {
        let appPath = bundleID.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path
        }
        for candidate in IDECommandLine.candidates(cli: cli, appPath: appPath) {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - AppleScript (Terminal.app / iTerm2)

    private static func focusViaAppleScript(bundleID: String, appName: String,
                                            script: String?, kind: TerminalKind,
                                            granularity: String) -> Result {
        // Cible pas lancée → activation impossible, mais rien à focuser.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            return activateApp(bundleID: bundleID, kind: kind)
        }
        // Préflight TCC : si l'automatisation est refusée, le signaler à l'UI.
        switch AutomationPermission.check(bundleID: bundleID) {
        case .denied:
            return .needsAutomationPermission(appName: appName)
        case .granted, .undetermined:
            break
        }

        guard let script else {
            // Pas de tty → au moins activer l'app.
            return activateApp(bundleID: bundleID, kind: kind)
        }

        var errorInfo: NSDictionary?
        if let apple = NSAppleScript(source: script) {
            apple.executeAndReturnError(&errorInfo)
        }
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            log.warning("AppleScript \(appName, privacy: .public) erreur \(code)")
            if code == -1743 { return .needsAutomationPermission(appName: appName) }
            // L'onglet n'a pas été trouvé (session fermée ?) → activer l'app.
            return activateApp(bundleID: bundleID, kind: kind)
        }
        return .focused(kind, granularity: granularity)
    }

    // MARK: - Repli sans permission

    @discardableResult
    private static func activateBundle(_ bundleID: String?) -> Bool {
        guard let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        return app.activate(options: [])
    }

    private static func activateApp(bundleID: String?, kind: TerminalKind) -> Result {
        if activateBundle(bundleID) {
            return .focused(kind, granularity: "app")
        }
        return .failed("\(kind.displayName) n'est pas lancé.")
    }
}
