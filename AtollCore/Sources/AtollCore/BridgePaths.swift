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

    /// Config du recall proactif (Milestone B) : ÉCRITE par l'app quand
    /// l'utilisateur bascule le réglage, LUE par le helper à chaque
    /// UserPromptSubmit et à l'installation des hooks (elle décide si ce hook
    /// est bloquant). Fichier absent = fonction désactivée — l'opt-in ne
    /// dépend d'aucun état d'application.
    public static var proactiveRecallConfigURL: URL {
        homeDirectory.appendingPathComponent(".atoll/proactive-recall.json")
    }

    /// Journal des tâches lancées depuis le notch (`claude --bg`). Persisté :
    /// une tâche de fond survit à un redémarrage d'Atoll, et sans ce fichier on
    /// perdrait le lien avec elle — donc l'annonce de sa fin.
    public static var launchedTasksURL: URL {
        homeDirectory.appendingPathComponent(".atoll/launched-tasks.json")
    }

    /// Sons personnalisés importés par l'utilisateur. Les fichiers sont COPIÉS
    /// ici : déplacer ou supprimer l'original ne doit pas rendre Atoll muet.
    public static var soundsDirectory: URL {
        homeDirectory.appendingPathComponent(".atoll/sounds", isDirectory: true)
    }

    /// Hooks sonores de l'utilisateur mis de côté pendant qu'Atoll joue les
    /// sons. Écrit AVANT toute modification de settings.json (crash-safe),
    /// exactement comme le parking Rockstar.
    public static var parkedSoundHooksURL: URL {
        homeDirectory.appendingPathComponent(".atoll/parked-sound-hooks.json")
    }

    /// Réglages sonores, ÉCRITS par l'app et LUS PAR LE HELPER — même dispositif
    /// que `proactive-recall.json`. C'est ce qui permet au son de sonner quand
    /// Atoll est fermée : le helper, lui, tourne à chaque hook. Voir
    /// `SoundFallback`.
    public static var soundSettingsURL: URL {
        homeDirectory.appendingPathComponent(".atoll/sound-settings.json")
    }

    /// État éphémère du helper (témoins d'anti-rafale). Séparé des réglages :
    /// ce dossier peut être vidé à tout moment sans rien perdre.
    public static var runDirectory: URL {
        homeDirectory.appendingPathComponent(".atoll/run", isDirectory: true)
    }

    // MARK: - Apprentissage (Phase 7b)

    /// Dernier quota serveur connu, mis en cache pour survivre à un
    /// redémarrage d'Atoll (le gate d'apprentissage en dépend).
    public static var quotaCacheURL: URL {
        homeDirectory.appendingPathComponent(".atoll/quota-cache.json")
    }

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

}
