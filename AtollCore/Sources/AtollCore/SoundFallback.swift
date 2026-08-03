import Foundation

/// Ce qu'il faut pour qu'un son sonne **sans l'app**.
///
/// POURQUOI CE FICHIER EXISTE (2026-08-03, constaté sur la machine de Mehdi).
/// Atoll a repris ses deux hooks `afplay` le 27 juillet — donc `settings.json`
/// n'en contenait plus aucune trace — puis l'app est restée fermée deux jours.
/// Résultat : quand Claude Code avait besoin de lui, **rien ne sonnait**. Ni ses
/// hooks (parqués), ni les sons d'Atoll (l'app était morte). Or il a mis ces
/// sons précisément pour être APPELÉ plutôt que surveiller un écran.
///
/// C'est une violation de l'esprit de la règle n° 1 du projet : ce qu'Atoll
/// installe ne doit jamais dégrader l'usage du CLI. Prendre quelque chose à
/// l'utilisateur et mourir avec, c'est exactement ça.
///
/// Le helper `atoll-bridge`, lui, tourne à chaque hook, que l'app soit là ou
/// non — c'est vérifié : `memory.db` est écrit alors qu'Atoll est fermée. Il
/// devient donc le filet : **si l'app n'a pas été jointe, c'est lui qui joue.**
/// Exactement un des deux sonne, jamais les deux.
public enum SoundFallback {

    // MARK: - Réglages partagés app → helper

    /// Réglages sonores écrits par l'app et LUS PAR LE HELPER.
    ///
    /// Même dispositif que `proactive-recall.json` : la source de vérité est un
    /// fichier, pas l'état d'un processus. Les `UserDefaults` de l'app ne
    /// conviennent pas — le helper est un autre binaire, avec son propre
    /// domaine, et `cfprefsd` met en cache.
    public struct Settings: Codable, Equatable, Sendable {
        /// Interrupteur général d'Atoll. Faux = le helper ne joue rien non plus.
        public var enabled: Bool
        /// Valeur de réglage par événement (`silent`, `system:Glass`, `custom:x.mp3`).
        public var choices: [String: String]
        /// Volume par événement, 0…1.
        public var volumes: [String: Double]

        public init(enabled: Bool, choices: [String: String], volumes: [String: Double]) {
            self.enabled = enabled
            self.choices = choices
            self.volumes = volumes
        }

        public func choice(for event: SoundEvent) -> SoundChoice {
            SoundChoice.decode(choices[event.rawValue])
        }

        public func volume(for event: SoundEvent) -> Double {
            min(max(volumes[event.rawValue] ?? SoundEvent.defaultVolume, 0), 1)
        }
    }

    public static func encode(_ settings: Settings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// Décodage DÉFENSIF : un fichier absent, tronqué ou trafiqué rend `nil`, et
    /// le helper reste muet. Il ne doit jamais rien casser, surtout pas un hook.
    public static func decode(_ data: Data?) -> Settings? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    // MARK: - Quel hook déclenche quel son

    /// Correspondance utilisée par le HELPER — volontairement plus étroite que
    /// `SoundCenter.event(forHookEvent:)`.
    ///
    /// Celle de l'app sert à REPRENDRE les hooks de l'utilisateur, donc elle
    /// reconnaît aussi `PermissionRequest` et `SubagentStop`. Ici on JOUE : si
    /// on acceptait `PermissionRequest` **et** `Notification`, une même demande
    /// sonnerait deux fois ; `SubagentStop` ferait tinter chaque sous-agent.
    ///
    /// Les deux événements retenus sont exactement ceux sur lesquels Mehdi avait
    /// posé ses propres `afplay` — c'est la définition honnête de « réparer ».
    public static func event(forHookEvent name: String) -> SoundEvent? {
        switch name {
        case "Notification": return .decisionNeeded
        case "Stop": return .taskCompleted
        default: return nil
        }
    }

    // MARK: - Résolution du fichier à jouer

    /// Chemin réel du son, ou `nil` s'il n'y a rien à jouer.
    ///
    /// `SoundChoice.decode` a déjà garanti que le nom est un composant NU (ni
    /// séparateur, ni `..`, ni nom caché) : aucun réglage trafiqué ne peut faire
    /// lire un fichier arbitraire. On revérifie tout de même l'existence, pour
    /// ne pas lancer `afplay` sur du vide.
    public static func fileURL(for choice: SoundChoice,
                               soundsDirectory: URL,
                               systemDirectories: [String] = SystemSounds.directories,
                               userSoundsDirectory: URL? = nil,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        switch choice {
        case .silent:
            return nil
        case .custom(let file):
            let url = soundsDirectory.appendingPathComponent(file)
            return fileExists(url.path) ? url : nil
        case .system(let name):
            // `NSSound(named:)` n'existe pas côté helper (pas d'AppKit) : on
            // reconstruit le chemin comme le fait macOS, du plus spécifique au
            // plus général, en essayant les extensions connues.
            var roots = systemDirectories
            if let userSoundsDirectory { roots.insert(userSoundsDirectory.path, at: 0) }
            for root in roots {
                for ext in SoundImport.allowedExtensions.sorted() {
                    let path = URL(fileURLWithPath: root)
                        .appendingPathComponent("\(name).\(ext)").path
                    if fileExists(path) { return URL(fileURLWithPath: path) }
                }
            }
            return nil
        }
    }

    // MARK: - Anti-rafale entre processus

    /// Le helper est un processus NEUF à chaque hook : il n'a aucune mémoire.
    /// L'anti-rafale passe donc par la date de modification d'un fichier témoin,
    /// un par événement.
    public static func stampURL(for event: SoundEvent, in directory: URL) -> URL {
        directory.appendingPathComponent("sound-\(event.rawValue).stamp")
    }

    /// Décide s'il faut jouer, d'après la date du témoin. Même fenêtre que
    /// l'app (`SoundThrottle.minimumInterval`), pour que le comportement ne
    /// change pas selon qui joue.
    public static func shouldPlay(stampDate: Date?, now: Date) -> Bool {
        SoundThrottle.shouldPlay(lastPlayedAt: stampDate, now: now)
    }
}
