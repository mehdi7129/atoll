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

    /// L'identifiant que `claude stop` sait résoudre — le PRÉFIXE DE 8 HEX, pas
    /// l'UUID complet.
    ///
    /// FAIT VÉRIFIÉ EMPIRIQUEMENT (CLI 2.1.220, 2026-08-03), et il invalidait
    /// silencieusement le bouton ARRÊTER depuis la Phase 9 : `claude stop` liste
    /// `~/.claude/jobs/`, ne garde que les entrées appariant `^[a-f0-9]{8}$`,
    /// puis retient celles dont le NOM commence par l'argument reçu. Un dossier
    /// de 8 caractères ne peut jamais commencer par une chaîne de 36 : Atoll
    /// passait `session.id` en entier, donc la commande rendait TOUJOURS
    /// « No job matching '…' » et sortait en 1. Mesuré sur le job mort
    /// `1b6e885d` : préfixe → « stopped 1b6e885d », EXIT=0 ; UUID complet →
    /// EXIT=1. Le kill-switch n'avait jamais abouti une seule fois.
    ///
    /// Renvoie `nil` si le préfixe n'est pas 8 hex minuscules : la CLI l'aurait
    /// de toute façon filtré, et mieux vaut un refus net qu'un argument inventé
    /// (`stop` agit sur la première correspondance — un préfixe tronqué ou
    /// normalisé pourrait désigner une AUTRE session que celle affichée).
    public static func jobIdentifier(for sessionID: String) -> String? {
        // Le jeu est celui de la CLI, écrit en toutes lettres : `Character.isHexDigit`
        // est plus large (majuscules, chiffres pleine chasse, chiffres arabes) et
        // laisserait passer des préfixes que `^[a-f0-9]{8}$` rejette.
        let allowed = Set("0123456789abcdef")
        let prefix = sessionID.prefix(8)
        guard prefix.count == 8, prefix.allSatisfy(allowed.contains) else { return nil }
        return String(prefix)
    }

    /// Échappe un argument pour `/bin/zsh -c` (guillemets simples POSIX).
    ///
    /// À l'intérieur de guillemets simples, RIEN n'est échappé — pas même
    /// l'antislash : la seule façon d'insérer une apostrophe est de fermer,
    /// l'insérer échappée, puis rouvrir.
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
