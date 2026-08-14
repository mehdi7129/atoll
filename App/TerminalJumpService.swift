import AppKit
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "jump")

/// Fait remonter au premier plan le terminal exact qui héberge une session.
///
/// Règles (voir docs/research/…terminal-jump-back) :
/// - tout AppleScript est exécuté par l'app (attribution TCC correcte), JAMAIS
///   par le helper ;
/// - l'exécution (AppleScript, préflight TCC, spawn CLI) se fait HORS du thread
///   principal : un terminal figé ne doit jamais geler l'îlot (le `with timeout`
///   des scripts borne en plus l'Apple Event) ;
/// - la granularité dégrade en cascade : pane → onglet → fenêtre → app ;
/// - le repli `NSRunningApplication.activate()` ne demande AUCUNE permission.
enum TerminalJumpService {

    enum Result: Sendable {
        case focused(String, granularity: String) // nom du terminal
        case needsAutomationPermission(appName: String)
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "dev.mehdiguiard.atoll.jump", qos: .userInitiated)

    /// Lance le jump hors du thread principal et rappelle `completion` sur le main.
    @MainActor
    static func jump(to anchor: TerminalAnchor, completion: @escaping @MainActor (Result) -> Void) {
        let kind = TerminalResolver.resolve(anchor)
        queue.async {
            let result = perform(kind: kind, anchor: anchor)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Exécution (hors main thread)

    private static func perform(kind: TerminalKind, anchor: TerminalAnchor) -> Result {
        log.info("jump vers \(kind.displayName, privacy: .public) (tmux: \(anchor.isTmux))")
        switch kind {
        case .vscodeFamily(let cli):
            return focusIDE(cli: cli, kind: kind, anchor: anchor)
        case .terminalApp:
            return focusViaAppleScript(
                bundleID: "com.apple.Terminal", appName: "Terminal",
                script: anchor.tty.map { TerminalScripts.terminalApp(tty: $0) },
                kind: kind, granularity: "onglet"
            )
        case .iterm2:
            return focusViaAppleScript(
                bundleID: "com.googlecode.iterm2", appName: "iTerm2",
                script: anchor.tty.map { TerminalScripts.iterm2(tty: $0) },
                kind: kind, granularity: "pane"
            )
        default:
            return activateApp(bundleID: kind.fallbackBundleID, kind: kind)
        }
    }

    // MARK: - VS Code / Cursor (aucune permission requise)

    private static func focusIDE(cli: String, kind: TerminalKind, anchor: TerminalAnchor) -> Result {
        if let cwd = anchor.cwd,
           let cliPath = resolveIDECLI(cli: cli, bundleID: anchor.bundleID) {
            // Viser la RACINE du workspace (plus proche ancêtre avec .git), pas le
            // cwd brut : `-r` sur un sous-dossier détournerait une autre fenêtre.
            let root = WorkspaceRoot.resolve(cwd: cwd) { path in
                FileManager.default.fileExists(atPath: path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["-r", root]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                activateBundle(anchor.bundleID)
                return .focused(kind.displayName, granularity: "fenêtre")
            }
        }
        if activateBundle(anchor.bundleID) {
            return .focused(kind.displayName, granularity: "app")
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
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            return activateApp(bundleID: bundleID, kind: kind)
        }
        // Préflight TCC (hors main thread ici) : peut afficher le prompt système.
        switch AutomationPermission.check(bundleID: bundleID) {
        case .denied:
            // Le repli `activate` ne demande AUCUNE permission : la fenêtre
            // doit remonter même sans autorisation d'automatisation. On le
            // faisait pour toutes les autres erreurs, pas pour celle-ci — le
            // bouton principal du détail de session ne produisait donc rien
            // d'autre qu'un avertissement (audit du 2026-07-27).
            activateBundle(bundleID)
            return .needsAutomationPermission(appName: appName)
        case .granted, .undetermined:
            break
        }
        guard let script else {
            return activateApp(bundleID: bundleID, kind: kind)
        }

        var errorInfo: NSDictionary?
        let answer = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            log.warning("AppleScript \(appName, privacy: .public) erreur \(code)")
            if code == -1743 {
                // MÊME repli qu'au préflight `.denied` juste au-dessus : le
                // refus d'automatisation peut tomber ICI plutôt que là, selon
                // que TCC a déjà tranché ou non. Le correctif de l'audit du
                // 2026-07-27 n'avait été posé que sur l'une des deux sorties, et
                // sur celle-ci le bouton principal du détail de session ne
                // produisait toujours qu'un avertissement, sans remonter la
                // fenêtre. `activate` ne demande AUCUNE permission.
                activateBundle(bundleID)
                return .needsAutomationPermission(appName: appName)
            }
            return activateApp(bundleID: bundleID, kind: kind)
        }
        // Aucun onglet ne portait ce tty (onglet fermé, tty recyclé, pane
        // tmux) : le script se termine SANS erreur. Annoncer « focus (onglet) »
        // dans ce cas est un mensonge — seule l'app a été activée, sur un
        // onglet qui peut être une autre session.
        guard answer?.stringValue == TerminalScripts.hitMarker else {
            log.info("\(appName, privacy: .public) : tty introuvable — activation simple")
            return activateApp(bundleID: bundleID, kind: kind)
        }
        return .focused(kind.displayName, granularity: granularity)
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
            return .focused(kind.displayName, granularity: "app")
        }
        return .failed("\(kind.displayName) n'est pas lancé.")
    }
}
