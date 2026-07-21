import Foundation

/// Validation des slugs de skills appris (Phase 7c) et nom du dossier géré.
///
/// Un slug venu du modèle ou d'un `meta.json` ne devient JAMAIS un composant de
/// chemin sans passer par `validate` :
/// - kebab-case strict `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` ET 2–40 caractères
///   (le groupe optionnel de la regex accepterait un caractère seul — la borne
///   basse est donc vérifiée explicitement en plus) ;
/// - refus explicite de `/` et `..` AVANT la regex (défense en profondeur : la
///   regex les rejette déjà, mais une future retouche de la regex ne doit pas
///   pouvoir rouvrir une traversée de chemin) ;
/// - noms réservés refusés (`recall` = skill mémoire d'Atoll, `bridge`/`bin` =
///   infrastructure `~/.atoll`) ;
/// - un slug commençant déjà par `atoll-` est refusé : le préfixe est ajouté
///   par Atoll (`dirName(for:)`) — l'accepter en entrée créerait
///   `atoll-atoll-…` et laisserait surtout le modèle choisir lui-même un nom
///   de dossier géré.
///
/// Aucune normalisation : un slug « presque bon » est refusé, jamais corrigé
/// en silence.
public enum SkillSlug {

    /// Préfixe de TOUS les dossiers gérés par Atoll dans `~/.claude/skills` —
    /// les voisins sans ce préfixe sont des skills tiers, intouchables.
    public static let managedPrefix = "atoll-"

    /// Noms interdits même s'ils sont syntaxiquement valides.
    public static let reservedNames: Set<String> = ["recall", "bridge", "bin"]

    /// nil si invalide, sinon le slug tel quel.
    public static func validate(_ raw: String) -> String? {
        guard !raw.contains("/"), !raw.contains("..") else { return nil }
        guard raw.count >= 2, raw.count <= 40 else { return nil }
        guard raw.range(of: "\\A[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?\\z",
                        options: .regularExpression) != nil else { return nil }
        guard !reservedNames.contains(raw) else { return nil }
        guard !raw.hasPrefix(managedPrefix) else { return nil }
        return raw
    }

    /// Nom du dossier d'installation dans `~/.claude/skills` : `atoll-<slug>`.
    /// À n'appeler qu'avec un slug déjà validé.
    public static func dirName(for slug: String) -> String {
        managedPrefix + slug
    }
}
