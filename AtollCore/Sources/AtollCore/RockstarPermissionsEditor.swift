import Foundation

/// Suspension chirurgicale des règles `permissions.deny` de `~/.claude/settings.json`
/// pendant le mode Rockstar, et restauration fidèle à la sortie.
///
/// Contexte (vérifié empiriquement, CLI 2.1.215) :
/// - les règles deny s'exécutent AVANT le hook PermissionRequest : une demande
///   refusée par une règle n'atteint jamais Atoll — l'îlot ne peut donc PAS les
///   outrepasser en répondant allow ;
/// - un hook ne peut pas non plus basculer la session en bypassPermissions
///   (`updatedPermissions setMode bypassPermissions` est ignoré par le CLI,
///   contrairement à `acceptEdits`).
/// Le SEUL moyen d'obtenir « aucune protection » est donc de retirer les règles
/// deny du fichier tant que Rockstar est actif. Elles sont conservées à part
/// (`~/.atoll/rockstar-parked-deny.json`) et réinsérées dès que l'utilisateur
/// quitte Rockstar — union sans doublons avec d'éventuelles règles ajoutées
/// entre-temps.
///
/// Mêmes règles absolues que HookSettingsEditor : fichier non-JSON → échec SANS
/// écriture ; tout le reste du fichier est préservé (structure).
public enum RockstarPermissionsEditor {

    public enum EditorError: Error, Equatable {
        /// settings.json existe mais n'est pas un objet JSON valide.
        case unparseableSettings
    }

    /// Retire toutes les règles `permissions.deny`. Renvoie nil si rien à faire
    /// (aucune règle) — aucune écriture dans ce cas. `permissions` ou `deny`
    /// d'un type inattendu → erreur SANS écriture (jamais d'écrasement aveugle).
    public static func park(in data: Data?) throws -> (updated: Data, parked: [String])? {
        var settings = try parse(data)
        guard var permissions = try strictPermissions(settings) else { return nil }
        guard let deny = try strictDeny(permissions), !deny.isEmpty else { return nil }
        permissions["deny"] = nil
        settings["permissions"] = permissions.isEmpty ? nil : permissions
        return (try serialize(settings), deny)
    }

    /// Réinsère des règles parquées : les règles d'origine d'abord (ordre
    /// conservé), puis celles ajoutées entre-temps par l'utilisateur.
    public static func restore(into data: Data?, parked: [String]) throws -> Data {
        var settings = try parse(data)
        var permissions = try strictPermissions(settings) ?? [:]
        let current = try strictDeny(permissions) ?? []
        let merged = mergeParked(previous: parked, new: current)
        permissions["deny"] = merged.isEmpty ? nil : merged
        settings["permissions"] = permissions.isEmpty ? nil : permissions
        return try serialize(settings)
    }

    /// Fusionne un parking précédent (crash / park répété) avec de nouvelles
    /// règles : les précédentes d'abord, sans doublon. Logique pure ici pour
    /// être testée (le helper ne fait que l'appeler).
    public static func mergeParked(previous: [String], new: [String]) -> [String] {
        previous + new.filter { !previous.contains($0) }
    }

    // MARK: - Fichier de parking

    /// Contenu du fichier `~/.atoll/rockstar-parked-deny.json`.
    public struct ParkedRules: Codable, Equatable {
        public let deny: [String]
        public let parkedAt: Date

        public init(deny: [String], parkedAt: Date) {
            self.deny = deny
            self.parkedAt = parkedAt
        }
    }

    public static func encodeParked(_ rules: ParkedRules) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rules)
    }

    public static func decodeParked(_ data: Data) -> ParkedRules? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ParkedRules.self, from: data)
    }

    // MARK: - Interne (mêmes conventions que HookSettingsEditor)

    /// nil = clé absente ; présente mais pas un objet → erreur, refus d'écrire.
    private static func strictPermissions(_ settings: [String: Any]) throws -> [String: Any]? {
        guard let value = settings["permissions"] else { return nil }
        guard let permissions = value as? [String: Any] else {
            throw EditorError.unparseableSettings
        }
        return permissions
    }

    /// nil = clé absente ; présente mais pas [String] → erreur, refus d'écrire.
    private static func strictDeny(_ permissions: [String: Any]) throws -> [String]? {
        guard let value = permissions["deny"] else { return nil }
        guard let deny = value as? [String] else {
            throw EditorError.unparseableSettings
        }
        return deny
    }

    /// nil = fichier ABSENT (création délibérée, machine neuve) ; fichier
    /// PRÉSENT mais vide ou réduit à des blancs = troncature → refus SANS
    /// écriture.
    ///
    /// Les deux tombaient dans la même branche (`guard let data, !data.isEmpty`),
    /// et `restore` reposait alors un fichier ne contenant QUE les règles deny :
    /// hooks tiers, statusLine, `permissions.allow`, `env` et `model` disparus.
    /// C'est le chemin le PLUS dangereux des cinq écrivains de ce fichier, parce
    /// que `performRockstarRestore` supprime le parking juste après avoir écrit —
    /// la trace s'en va avec la configuration. Même garde que
    /// `HookSettingsEditor` et `SoundHookEditor` (v0.16.1), qui l'avaient reçue
    /// sans que celui-ci ni `StatusLineEditor` ne l'obtiennent.
    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !HookSettingsEditor.isBlank(data) else { throw EditorError.unparseableSettings }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw EditorError.unparseableSettings
        }
        return dict
    }

    private static func serialize(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}
