import CryptoKit
import Foundation

// Deux types publics co-localisés, délibérément (même pattern que
// `LearningArtifacts`) : `InstalledSkill` n'existe que comme entrée de
// `InstalledSkillsManifest` — les séparer éparpillerait un seul format de
// fichier (`~/.atoll/learning/installed.json`) sur deux fichiers source.

/// Une entrée du manifeste : un skill appris qu'Atoll a activé dans
/// `~/.claude/skills/<dirName>/`.
public struct InstalledSkill: Codable, Equatable, Sendable {
    public let slug: String
    /// Nom du dossier installé (`atoll-<slug>`) — TOUJOURS préfixé `atoll-` ;
    /// la désinstallation revérifie ce préfixe avant toute suppression.
    public let dirName: String
    public let installedAt: Date
    /// Date de la dernière mise à jour (approbation d'une nouvelle version) ;
    /// nil si jamais mis à jour depuis l'installation.
    public let updatedAt: Date?
    /// SHA-256 hex du `SKILL.md` installé : toute divergence sur disque
    /// signifie une modification manuelle de l'utilisateur (à préserver).
    public let skillSHA256: String
    /// Dossier d'archive de la proposition d'origine (informatif, best-effort).
    public let sourceArchivePath: String?

    public init(
        slug: String,
        dirName: String,
        installedAt: Date,
        updatedAt: Date? = nil,
        skillSHA256: String,
        sourceArchivePath: String? = nil
    ) {
        self.slug = slug
        self.dirName = dirName
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.skillSHA256 = skillSHA256
        self.sourceArchivePath = sourceArchivePath
    }
}

/// Manifeste des skills appris installés (`~/.atoll/learning/installed.json`).
///
/// SOURCE DE VÉRITÉ de la désinstallation : seuls les dossiers listés ici
/// (et préfixés `atoll-`) peuvent être supprimés de `~/.claude/skills`, qui
/// contient par ailleurs des skills tiers intouchables.
///
/// Invariants :
/// - `decode` renvoie nil si le fichier est illisible ou incomplet — l'appelant
///   doit alors FAIL-CLOSED (aucune suppression, cf. `LearnedSkillStore`) ;
/// - `encoded()` produit des octets déterministes (sortedKeys, dates ISO-8601
///   UTC) : deux manifestes égaux donnent les mêmes octets, comparables.
public struct InstalledSkillsManifest: Codable, Equatable, Sendable {
    /// Version du format — incrémentée si le schéma change.
    public var v: Int
    public var skills: [InstalledSkill]

    public init(v: Int = 1, skills: [InstalledSkill] = []) {
        self.v = v
        self.skills = skills
    }

    /// nil si illisible (JSON invalide, champ manquant, type ou date
    /// inattendus) → l'appelant FAIL-CLOSED, jamais de manifeste « deviné ».
    public static func decode(_ data: Data) -> InstalledSkillsManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledSkillsManifest.self, from: data)
    }

    /// Octets prêts à écrire, déterministes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// SHA-256 hex (minuscules, 64 caractères) du texte UTF-8 — l'empreinte
    /// des `SKILL.md` stockée dans `skillSHA256`.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
