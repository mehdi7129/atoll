import Foundation

/// Les deux moments où Atoll peut se signaler à l'oreille.
///
/// Ils remplacent les deux hooks `afplay` que l'utilisateur avait posés
/// lui-même dans `settings.json` : mêmes instants, mais pilotés par ce qu'Atoll
/// SAIT de l'état réel des sessions, et réglables sans éditer un fichier.
public enum SoundEvent: String, Codable, CaseIterable, Sendable {
    /// Une carte attend une décision : permission, plan, question.
    case decisionNeeded
    /// Une session vient de finir son tour.
    case taskCompleted

    public var title: String {
        switch self {
        case .decisionNeeded: return "Décision attendue"
        case .taskCompleted: return "Tâche terminée"
        }
    }

    public var explanation: String {
        switch self {
        case .decisionNeeded:
            return "Une permission, un plan ou une question attend ta réponse."
        case .taskCompleted:
            return "Une session a fini de travailler."
        }
    }

    /// Clé de réglage (UserDefaults) du son choisi.
    public var choiceKey: String { "sound.\(rawValue).choice" }
    /// Clé de réglage du volume.
    public var volumeKey: String { "sound.\(rawValue).volume" }

    /// Volume par défaut : l'utilisateur jouait ses sons en `afplay -v 0.1`.
    /// On reprend SA valeur — il les veut discrets, pas absents.
    public static let defaultVolume: Double = 0.1
}

/// Ce qu'on joue pour un événement.
///
/// Sérialisé en une CHAÎNE (`silent`, `system:Glass`, `custom:finish.mp3`)
/// plutôt qu'en JSON d'enum à valeurs associées : la valeur vit dans
/// UserDefaults, doit rester lisible, et surtout se décoder DÉFENSIVEMENT —
/// une valeur inconnue ou trafiquée retombe sur « silencieux » au lieu de
/// planter ou, pire, de servir à construire un chemin de fichier arbitraire.
public enum SoundChoice: Equatable, Hashable, Sendable {
    case silent
    /// Un son fourni par macOS (`/System/Library/Sounds/<nom>.aiff`).
    case system(String)
    /// Un fichier importé par l'utilisateur, COPIÉ dans `~/.atoll/sounds/`.
    /// La valeur est un simple nom de fichier, jamais un chemin.
    case custom(String)

    public var storageValue: String {
        switch self {
        case .silent: return "silent"
        case .system(let name): return "system:\(name)"
        case .custom(let file): return "custom:\(file)"
        }
    }

    /// Décodage défensif. Tout ce qui n'est pas exactement reconnu — y compris
    /// un nom contenant un séparateur de chemin ou `..` — devient `.silent`.
    public static func decode(_ raw: String?) -> SoundChoice {
        guard let raw, !raw.isEmpty else { return .silent }
        if raw == "silent" { return .silent }
        if let name = raw.dropPrefixIfPresent("system:") {
            return isSafeComponent(name) ? .system(name) : .silent
        }
        if let file = raw.dropPrefixIfPresent("custom:") {
            return isSafeComponent(file) ? .custom(file) : .silent
        }
        return .silent
    }

    /// Un nom de fichier NU : pas de séparateur, pas de remontée de dossier,
    /// pas de nom caché. C'est ce qui empêche un réglage trafiqué de faire
    /// lire (et jouer) n'importe quel fichier de la machine.
    public static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        guard name != ".", name != "..", !name.hasPrefix(".") else { return false }
        return true
    }

    public var isSilent: Bool { self == .silent }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Règles d'import d'un son personnalisé.
public enum SoundImport {
    /// Formats que `NSSound` sait lire de façon fiable.
    public static let allowedExtensions: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]
    /// Un son d'alerte de plus de 10 Mo n'a pas de sens — et on le COPIE.
    public static let maxBytes = 10 * 1024 * 1024

    public enum ImportError: Error, Equatable {
        case unsupportedFormat(String)
        case tooLarge(Int)
        case unreadable
    }

    /// Valide un fichier candidat d'après son extension et sa taille.
    public static func validate(fileExtension: String, byteCount: Int) throws {
        let normalized = fileExtension.lowercased()
        guard allowedExtensions.contains(normalized) else {
            throw ImportError.unsupportedFormat(normalized)
        }
        guard byteCount > 0 else { throw ImportError.unreadable }
        guard byteCount <= maxBytes else { throw ImportError.tooLarge(byteCount) }
    }

    /// Nom sûr pour la copie dans `~/.atoll/sounds/`.
    ///
    /// On repart du nom d'origine (l'utilisateur doit reconnaître son fichier),
    /// mais réduit à des caractères inoffensifs : tout le reste devient `-`.
    /// nil si le nom ne donne rien d'exploitable.
    public static func destinationName(for originalName: String) -> String? {
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let base = url.deletingPathExtension().lastPathComponent
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        // Éviter `---------` et les noms vides ou cachés.
        let collapsed = base.replacingOccurrences(of: "-{2,}", with: "-",
                                                  options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !collapsed.isEmpty else { return nil }
        let name = "\(String(collapsed.prefix(60))).\(ext)"
        return SoundChoice.isSafeComponent(name) ? name : nil
    }
}

/// Anti-rafale : trois sessions qui finissent dans la même seconde ne doivent
/// pas empiler trois sons.
public enum SoundThrottle {
    public static let minimumInterval: TimeInterval = 2

    public static func shouldPlay(lastPlayedAt: Date?, now: Date,
                                  minimumInterval: TimeInterval = minimumInterval) -> Bool {
        guard let lastPlayedAt else { return true }
        // Horloge qui recule (changement d'heure, veille) : on autorise plutôt
        // que de rester muet indéfiniment.
        let elapsed = now.timeIntervalSince(lastPlayedAt)
        return elapsed < 0 || elapsed >= minimumInterval
    }
}

/// Sons fournis par macOS.
public enum SystemSounds {
    /// Emplacements standards, du plus spécifique au plus général.
    public static let directories = [
        "/System/Library/Sounds",
        "/Library/Sounds",
    ]

    /// Noms exploitables à partir d'un contenu de dossier brut : on ne garde
    /// que les fichiers audio, sans extension, triés et dédoublonnés.
    public static func names(fromFileNames fileNames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fileName in fileNames.sorted() {
            let url = URL(fileURLWithPath: fileName)
            guard SoundImport.allowedExtensions.contains(url.pathExtension.lowercased())
            else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard SoundChoice.isSafeComponent(name), seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }
}
