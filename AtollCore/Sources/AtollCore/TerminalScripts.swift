import Foundation

/// Constructeurs d'AppleScript / arguments CLI pour focuser un terminal.
/// Fonctions pures (chaînes) → testables sans exécuter quoi que ce soit.
/// L'exécution appartient à l'app (attribution TCC correcte).
public enum TerminalScripts {

    /// Échappe une chaîne pour l'insérer entre guillemets AppleScript.
    static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `/dev/ttys012` normalisé à partir de « ttys012 » ou « /dev/ttys012 ».
    static func devTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// Terminal.app : sélectionne l'onglet dont le tty correspond, au premier plan.
    public static func terminalApp(tty: String) -> String {
        let target = escapeAppleScript(devTTY(tty))
        return """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t as text) is "\(target)" then
                set selected of t to true
                set frontmost of w to true
                return
              end if
            end repeat
          end repeat
        end tell
        """
    }

    /// iTerm2 : sélectionne la session (split pane) par tty, au premier plan.
    public static func iterm2(tty: String) -> String {
        let target = escapeAppleScript(devTTY(tty))
        return """
        tell application "iTerm"
          activate
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if (tty of aSession) is "\(target)" then
                  select aWindow
                  select aTab
                  select aSession
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }

    /// tmux : commandes pour sélectionner la fenêtre + le pane hébergeant le tty.
    /// (Le focus du terminal HÔTE est fait séparément par son propre adaptateur.)
    public static func tmuxSelect(pane: String) -> [[String]] {
        [
            ["select-pane", "-t", pane],
        ]
    }

    /// tmux : retrouve le pane par tty (quand TMUX_PANE n'est pas fiable).
    public static let tmuxListPanes = ["list-panes", "-a", "-F", "#{pane_id} #{pane_tty} #{session_name}:#{window_index}"]
}
