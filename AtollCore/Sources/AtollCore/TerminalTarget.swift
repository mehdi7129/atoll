import Foundation

/// Données d'ancrage capturées au moment du hook, permettant de retrouver le
/// terminal exact qui héberge une session (voir docs/research/…terminal-jump-back).
public struct TerminalAnchor: Equatable, Sendable {
    public let cwd: String?
    public let tty: String?               // « ttys012 »
    public let bundleID: String?          // __CFBundleIdentifier (autoritaire)
    public let termProgram: String?       // TERM_PROGRAM (repli)
    public let entrypoint: String?        // CLAUDE_CODE_ENTRYPOINT (cli | sdk-ts)
    public let env: [String: String]

    public init(cwd: String?, tty: String?, bundleID: String?, termProgram: String?,
                entrypoint: String?, env: [String: String]) {
        self.cwd = cwd
        self.tty = tty
        self.bundleID = bundleID
        self.termProgram = termProgram
        self.entrypoint = entrypoint
        self.env = env
    }

    public var itermSessionID: String? { env["ITERM_SESSION_ID"] }
    public var tmux: String? { env["TMUX"] }
    public var tmuxPane: String? { env["TMUX_PANE"] }

    /// La session tourne-t-elle sous tmux ? (le focus passe alors par le
    /// terminal hôte + une sélection de pane).
    public var isTmux: Bool { tmux != nil && !(tmux ?? "").isEmpty }
}

/// Terminal hôte identifié, avec la granularité de focus atteignable.
public enum TerminalKind: Equatable, Sendable {
    case terminalApp                 // com.apple.Terminal — pane (onglet) par tty
    case iterm2                      // com.googlecode.iterm2 — pane par tty/session id
    case ghostty                     // AppleScript par id (tty à partir de 1.4)
    case wezterm
    case kitty
    case warp                        // app seulement
    case alacritty                   // app seulement
    case vscodeFamily(cli: String)   // code / cursor / windsurf — fenêtre via `<cli> -r`
    case unknown(bundleID: String?)

    /// Bundle id pour l'activation de repli (NSRunningApplication / open -b).
    public var fallbackBundleID: String? {
        switch self {
        case .terminalApp: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .wezterm: return "com.github.wez.wezterm"
        case .kitty: return "net.kovidgoyal.kitty"
        case .warp: return "dev.warp.Warp-Stable"
        case .alacritty: return "org.alacritty"
        case .vscodeFamily: return nil // géré par la CLI / bundle id d'origine
        case .unknown(let id): return id
        }
    }

    public var displayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .warp: return "Warp"
        case .alacritty: return "Alacritty"
        case .vscodeFamily(let cli): return cli == "cursor" ? "Cursor" : (cli == "code" ? "VS Code" : "Windsurf")
        case .unknown: return "terminal"
        }
    }
}

public enum TerminalResolver {
    /// Map bundle id → CLI de la famille VS Code (leçon vérifiée : les sessions
    /// de Mehdi tournent dans le terminal intégré de Cursor).
    static let vscodeFamilyCLIs: [String: String] = [
        "com.microsoft.VSCode": "code",
        "com.microsoft.VSCodeInsiders": "code-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        // Zed n'utilise ni le flag `-r` ni le chemin de CLI VS Code → repli
        // sur activation app plutôt qu'un `zed -r` erroné.
    ]

    static let byBundleID: [String: TerminalKind] = [
        "com.apple.Terminal": .terminalApp,
        "com.googlecode.iterm2": .iterm2,
        "com.mitchellh.ghostty": .ghostty,
        "com.github.wez.wezterm": .wezterm,
        "net.kovidgoyal.kitty": .kitty,
        "dev.warp.Warp-Stable": .warp,
        "org.alacritty": .alacritty,
    ]

    public static func resolve(_ anchor: TerminalAnchor) -> TerminalKind {
        if let bundleID = anchor.bundleID {
            if let cli = vscodeFamilyCLIs[bundleID] { return .vscodeFamily(cli: cli) }
            if let kind = byBundleID[bundleID] { return kind }
        }
        // Repli sur TERM_PROGRAM.
        switch anchor.termProgram {
        case "Apple_Terminal": return .terminalApp
        case "iTerm.app": return .iterm2
        case "ghostty": return .ghostty
        case "WezTerm": return .wezterm
        case "vscode":
            // TERM_PROGRAM=vscode sans bundle id → on ne sait pas lequel : cursor par défaut.
            return .vscodeFamily(cli: "code")
        default:
            return .unknown(bundleID: anchor.bundleID)
        }
    }
}

/// Résolution de la racine de workspace pour un éditeur VS Code-family.
public enum WorkspaceRoot {
    /// Racine probable du workspace : le plus proche ancêtre de `cwd` contenant
    /// un `.git` (le cas quasi universel), sinon `cwd` lui-même. Passer la RACINE
    /// à `cursor -r` focalise la bonne fenêtre ; passer un sous-dossier
    /// détournerait une fenêtre existante (constat de revue).
    public static func resolve(cwd: String, gitExists: (String) -> Bool) -> String {
        var components = (cwd as NSString).pathComponents
        while components.count > 1 {
            let path = NSString.path(withComponents: components)
            if gitExists(path + "/.git") { return path }
            components.removeLast()
        }
        return cwd
    }
}

/// Chemins de la CLI d'un éditeur VS Code-family (embarquée dans le bundle).
public enum IDECommandLine {
    /// Chemins candidats de la CLI, du plus probable au moins probable.
    public static func candidates(cli: String, appPath: String?) -> [String] {
        var paths: [String] = []
        if let appPath {
            paths.append("\(appPath)/Contents/Resources/app/bin/\(cli)")
        }
        let apps: [String]
        switch cli {
        case "cursor": apps = ["/Applications/Cursor.app"]
        case "code": apps = ["/Applications/Visual Studio Code.app"]
        case "windsurf": apps = ["/Applications/Windsurf.app"]
        default: apps = []
        }
        for app in apps {
            paths.append("\(app)/Contents/Resources/app/bin/\(cli)")
        }
        // Symlinks usuels dans le PATH.
        paths.append("/usr/local/bin/\(cli)")
        paths.append("/opt/homebrew/bin/\(cli)")
        return paths
    }
}
