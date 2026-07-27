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

    /// Réponse d'un script de focus : l'onglet cherché a-t-il été TROUVÉ ?
    ///
    /// Sans elle, un tty introuvable (onglet fermé, tty recyclé, pane tmux)
    /// terminait les boucles sans erreur — et l'îlot annonçait « focus (onglet) »
    /// alors que seul l'`activate` global avait eu lieu, sur un onglet qui
    /// pouvait être une AUTRE session (audit du 2026-07-27).
    public static let hitMarker = "atoll-hit"
    public static let missMarker = "atoll-miss"

    /// Terminal.app : sélectionne l'onglet dont le tty correspond, au premier plan.
    /// `with timeout` borne l'Apple Event : un terminal figé dégrade au lieu de
    /// bloquer l'appelant indéfiniment.
    public static func terminalApp(tty: String, timeoutSeconds: Int = 5) -> String {
        let target = escapeAppleScript(devTTY(tty))
        return """
        with timeout of \(timeoutSeconds) seconds
          tell application "Terminal"
            activate
            repeat with w in windows
              repeat with t in tabs of w
                if (tty of t as text) is "\(target)" then
                  set selected of t to true
                  set frontmost of w to true
                  return "\(hitMarker)"
                end if
              end repeat
            end repeat
            return "\(missMarker)"
          end tell
        end timeout
        """
    }

    /// iTerm2 : sélectionne la session (split pane) par tty, au premier plan.
    public static func iterm2(tty: String, timeoutSeconds: Int = 5) -> String {
        let target = escapeAppleScript(devTTY(tty))
        return """
        with timeout of \(timeoutSeconds) seconds
          tell application "iTerm"
            activate
            repeat with aWindow in windows
              repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                  if (tty of aSession) is "\(target)" then
                    select aWindow
                    select aTab
                    select aSession
                    return "\(hitMarker)"
                  end if
                end repeat
              end repeat
            end repeat
            return "\(missMarker)"
          end tell
        end timeout
        """
    }

}
