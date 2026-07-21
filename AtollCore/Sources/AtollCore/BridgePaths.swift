import Foundation

/// Chemins partagés entre l'app, le helper `atoll-bridge` et l'installeur.
public enum BridgePaths {
    /// Socket Unix sur lequel l'app écoute les événements de hooks.
    public static var socketPath: String {
        "/tmp/atoll-\(getuid()).sock"
    }

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Répertoire du wrapper stable référencé par settings.json.
    public static var binDirectory: URL {
        homeDirectory.appendingPathComponent(".atoll/bin", isDirectory: true)
    }

    /// Wrapper shell stable : `~/.atoll/bin/atoll-bridge` (exec le binaire du bundle).
    public static var wrapperURL: URL {
        binDirectory.appendingPathComponent("atoll-bridge")
    }

    /// Wrapper statusline : met en cache les rate_limits puis exécute la
    /// statusline d'origine de l'utilisateur en passthrough.
    public static var statuslineWrapperURL: URL {
        binDirectory.appendingPathComponent("atoll-statusline")
    }

    /// Commande statusline d'origine de l'utilisateur, mémorisée pour restitution.
    public static var statuslineOriginalURL: URL {
        homeDirectory.appendingPathComponent(".atoll/statusline-original")
    }

    /// La commande inscrite dans settings.json. `$HOME` est développé par le shell
    /// qui exécute les hooks — le chemin reste valable si le home change de volume.
    public static let hookCommand = "\"$HOME/.atoll/bin/atoll-bridge\""
    public static let statuslineCommand = "\"$HOME/.atoll/bin/atoll-statusline\""

    public static var claudeSettingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    /// Règles `permissions.deny` suspendues pendant le mode Rockstar (et
    /// restaurées à la sortie). Présence du fichier = règles actuellement parquées.
    public static var rockstarParkedDenyURL: URL {
        homeDirectory.appendingPathComponent(".atoll/rockstar-parked-deny.json")
    }

    /// Backup unique, créé avant la toute première écriture, jamais écrasé.
    public static var settingsBackupURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json.atoll-backup")
    }

    // MARK: - Mémoire (Phase 7a)

    /// Index mémoire FTS5. Écrivain unique : l'app ; `atoll-bridge recall` ouvre
    /// en lecture seule (repli lecture-écriture SANS création : une base WAL
    /// jamais rouverte peut refuser un lecteur pur faute de fichier -shm).
    public static var memoryDatabaseURL: URL {
        homeDirectory.appendingPathComponent(".atoll/memory.db")
    }

    /// Racine des transcripts Claude Code (un dossier par cwd encodé).
    /// Format officiellement interne et instable → parsing défensif uniquement.
    public static var claudeProjectsURL: URL {
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Dossier du SEUL skill géré par Atoll dans ~/.claude/skills — ce répertoire
    /// contient des skills tiers : ne JAMAIS toucher les voisins.
    public static var recallSkillDirectory: URL {
        homeDirectory.appendingPathComponent(".claude/skills/atoll-recall", isDirectory: true)
    }

    public static var recallSkillURL: URL {
        recallSkillDirectory.appendingPathComponent("SKILL.md")
    }

    // MARK: - Apprentissage (Phase 7b)

    /// Racine des artefacts d'apprentissage. Créée à l'ACTIVATION du réglage
    /// (opt-in, OFF par défaut) — jamais au simple lancement.
    public static var learningDirectory: URL {
        homeDirectory.appendingPathComponent(".atoll/learning", isDirectory: true)
    }

    /// Notes mémoire durables écrites par Atoll après les rétrospectives
    /// (JAMAIS par le modèle : la session headless n'a aucun outil d'écriture).
    public static var learningNotesDirectory: URL {
        learningDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    /// QUARANTAINE : skills proposés, jamais actifs sans revue humaine (7c).
    public static var learningProposedDirectory: URL {
        learningDirectory.appendingPathComponent("proposed", isDirectory: true)
    }

    /// Archives (rien n'est jamais supprimé sans copie ici).
    public static var learningArchiveDirectory: URL {
        learningDirectory.appendingPathComponent("archive", isDirectory: true)
    }

    /// État du runner : sessions déjà traitées (dédup) + horodatages de
    /// tentatives (plafond par fenêtre de 5 h).
    public static var learningStateURL: URL {
        learningDirectory.appendingPathComponent("retrospectives.json")
    }

    // MARK: - Curation (Phase 7c)

    /// Dossier des skills Claude Code de l'utilisateur. Contient des skills
    /// TIERS : Atoll ne touche QUE les sous-dossiers préfixés `atoll-`.
    public static var claudeSkillsDirectory: URL {
        homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Manifeste des skills appris qu'Atoll a activés dans ~/.claude/skills
    /// (slug, hash SHA256, dates). Source de vérité de la désinstallation :
    /// manifeste illisible → FAIL-CLOSED, aucune suppression.
    public static var installedSkillsManifestURL: URL {
        learningDirectory.appendingPathComponent("installed.json")
    }
}
