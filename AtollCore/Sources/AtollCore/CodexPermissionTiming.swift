import Foundation

/// Délais de la carte d'autorisation Codex.
///
/// ⚠️ LES DEUX VALEURS NE SONT PAS LA MÊME, ET C'EST VOULU. Codex accorde 600 s
/// au hook (son défaut documenté) ; le helper s'arrête à 570 s. Les trente
/// secondes de marge existent pour que **Codex ne tue jamais le hook
/// lui-même** : s'il atteignait son propre plafond, il afficherait un échec de
/// timeout à l'utilisateur, là où une abstention silencieuse doit simplement
/// rendre la main à l'invite native. Spécifié par Codex le 2026-09-09.
public enum CodexPermissionTiming {
    /// Ce qu'on écrit dans `hooks.json`.
    public static let codexTimeoutSeconds: TimeInterval = 600
    /// Deadline MONOTONE du helper, toujours strictement inférieure.
    public static let helperDeadlineSeconds: TimeInterval = 570

    /// La marge doit rester réelle : un helper qui s'arrêterait après Codex
    /// ferait exactement ce que ce type existe pour empêcher.
    public static var marginSeconds: TimeInterval {
        codexTimeoutSeconds - helperDeadlineSeconds
    }
}
