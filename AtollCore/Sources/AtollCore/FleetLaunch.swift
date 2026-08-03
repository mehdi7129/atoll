import Foundation

/// Ce qui reste du lancement de sessions d'arrière-plan (« cockpit ambiant »,
/// Phase 9) après son retrait le 2026-08-03 : l'échappement shell.
///
/// Il n'a plus rien à voir avec un lanceur — il sert à construire les commandes
/// que l'app confie à `zsh -l -c` pour le bilan de fin de session, l'inventaire
/// de plugins et le rangement des notes. Le reste (extraction de l'identifiant
/// sur la sortie de `claude --bg`, validation d'une tâche saisie) est parti avec
/// la fenêtre ⌘N, qui n'avait jamais servi et lançait sans isolation de worktree.
public enum FleetLaunch {

    /// Échappe un argument pour `/bin/zsh -c` (guillemets simples POSIX).
    ///
    /// À l'intérieur de guillemets simples, RIEN n'est échappé — pas même
    /// l'antislash : la seule façon d'insérer une apostrophe est de fermer,
    /// l'insérer échappée, puis rouvrir.
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
