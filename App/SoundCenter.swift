import AppKit
import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "sound")

/// Les sons d'Atoll : un pour « une décision t'attend », un autre pour « c'est
/// fini ». Chacun réglable (silencieux · 14 sons macOS · un fichier à toi) avec
/// son propre volume.
///
/// Ils remplacent les hooks `afplay` que l'utilisateur avait posés dans son
/// `settings.json` — sur son geste explicite, et de façon RÉVERSIBLE (voir
/// `parkUserSoundHooks` / `restoreUserSoundHooks`).
///
/// FAIL-OPEN : aucun de ces chemins n'est dans le chemin critique du CLI
/// `claude`. Tout se joue dans l'app ; un son introuvable ou illisible ne
/// produit rien d'autre qu'une ligne de log.
@MainActor
@Observable
final class SoundCenter {
    static let shared = SoundCenter()

    /// Sons personnalisés disponibles (contenu de `~/.atoll/sounds`).
    private(set) var customSounds: [String] = []
    /// Sons fournis par macOS.
    private(set) var systemSoundNames: [String] = []
    /// Hooks sonores repérés dans le settings.json de l'utilisateur.
    private(set) var detectedHooks: [SoundHookEditor.ParkedHook] = []
    /// Un parking est-il actif (les hooks de l'utilisateur sont chez nous) ?
    private(set) var isParked = false
    /// Le fichier de parking existe mais ne se lit pas : état à SIGNALER, jamais
    /// à confondre avec « rien de parqué » (on écraserait les hooks mis de côté).
    private(set) var isParkingUnreadable = false
    private(set) var lastError: String?

    enum SoundCenterError: LocalizedError {
        case parkingUnreadable

        var errorDescription: String? {
            switch self {
            case .parkingUnreadable:
                return "Le fichier ~/.atoll/parked-sound-hooks.json est illisible. "
                     + "Atoll refuse d'y toucher pour ne pas perdre tes hooks : "
                     + "ouvre-le ou supprime-le après en avoir recopié le contenu."
            }
        }
    }

    /// Instants de dernière lecture, par événement — anti-rafale.
    @ObservationIgnored private var lastPlayed: [SoundEvent: Date] = [:]
    /// `NSSound` déjà chargés, par valeur de réglage : éviter de relire le
    /// fichier à chaque lecture.
    @ObservationIgnored private var cache: [String: NSSound] = [:]

    // MARK: - Cycle de vie

    func start() {
        refreshLibraries()
        reconcile()
    }

    /// Relit les bibliothèques de sons et l'état du settings.json.
    func refreshLibraries() {
        systemSoundNames = SystemSounds.names(fromFileNames: SystemSounds.directories.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        })
        // Les sons personnalisés sont désignés par leur nom de FICHIER complet
        // (extension comprise) — contrairement aux sons système, nommés sans
        // extension par NSSound.
        customSounds = ((try? FileManager.default.contentsOfDirectory(
            atPath: BridgePaths.soundsDirectory.path)) ?? [])
            .filter { SoundImport.allowedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
        detectedHooks = SoundHookEditor.soundHooks(in: try? Data(contentsOf: BridgePaths.claudeSettingsURL))
        switch parkingState() {
        case .none: isParked = false; isParkingUnreadable = false
        case .parked: isParked = true; isParkingUnreadable = false
        case .unreadable: isParked = false; isParkingUnreadable = true
        }
    }

    /// Réconciliation au lancement — rattrapage de CRASH uniquement.
    ///
    /// Le fichier de parking est écrit AVANT la modification de settings.json.
    /// Si Atoll meurt entre les deux, on se retrouve avec un parking ET les
    /// hooks encore en place : l'utilisateur entendrait tout en double. On
    /// termine alors l'opération commencée.
    ///
    /// On ne restitue PAS automatiquement quand les sons d'Atoll sont coupés :
    /// couper le son n'est pas annuler la migration, et faire revenir ses
    /// `afplay` au redémarrage suivant serait incompréhensible. La restitution
    /// reste un geste explicite (bouton des réglages) — ou automatique à la
    /// désinstallation des hooks, là où elle a du sens.
    private func reconcile() {
        guard case .parked(let file) = parkingState(), !detectedHooks.isEmpty else { return }
        // Ne reprendre QUE si les hooks encore présents sont EXACTEMENT ceux
        // déjà inscrits dans le parking. Sinon on retirerait, sans le moindre
        // geste de l'utilisateur, un hook qu'il vient de remettre exprès (ou
        // que ses dotfiles ont restauré) — et on recommencerait à chaque
        // lancement. La règle du projet est explicite : rien d'automatique sur
        // des entrées qui ne sont pas les nôtres.
        let parkedKeys = Set(file.hooks.map { "\($0.event)\u{1}\($0.command)" })
        let presentKeys = Set(detectedHooks.map { "\($0.event)\u{1}\($0.command)" })
        guard presentKeys.isSubset(of: parkedKeys) else {
            log.info("hooks sonores non parqués détectés — aucune action automatique")
            return
        }
        log.info("parking interrompu (hooks encore présents) — reprise")
        try? parkUserSoundHooks()
    }

    // MARK: - Réglages

    /// Interrupteur général : Atoll joue-t-il des sons ? OFF par défaut —
    /// aucun son n'apparaît sans un geste de l'utilisateur.
    static let enabledKey = "soundsEnabled"

    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    var soundsEnabled: Bool {
        get { Self.soundsEnabled }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func choice(for event: SoundEvent) -> SoundChoice {
        SoundChoice.decode(UserDefaults.standard.string(forKey: event.choiceKey))
    }

    func setChoice(_ choice: SoundChoice, for event: SoundEvent) {
        UserDefaults.standard.set(choice.storageValue, forKey: event.choiceKey)
    }

    func volume(for event: SoundEvent) -> Double {
        let raw = UserDefaults.standard.object(forKey: event.volumeKey) as? Double
            ?? SoundEvent.defaultVolume
        return min(max(raw, 0), 1)
    }

    func setVolume(_ volume: Double, for event: SoundEvent) {
        UserDefaults.standard.set(min(max(volume, 0), 1), forKey: event.volumeKey)
    }

    // MARK: - Lecture

    /// Joue le son d'un événement, si les sons sont actifs et que l'anti-rafale
    /// le permet.
    func play(_ event: SoundEvent) {
        guard Self.soundsEnabled else { return }
        let now = Date()
        guard SoundThrottle.shouldPlay(lastPlayedAt: lastPlayed[event], now: now) else { return }
        lastPlayed[event] = now
        emit(event)
    }

    /// Écoute depuis les Réglages : ignore l'interrupteur général ET
    /// l'anti-rafale (on vient de cliquer sur ▶, il faut que ça sonne).
    func preview(_ event: SoundEvent) {
        emit(event)
    }

    private func emit(_ event: SoundEvent) {
        let choice = choice(for: event)
        guard !choice.isSilent, let sound = sound(for: choice, event: event) else { return }
        sound.volume = Float(volume(for: event))
        // Une même instance NSSound ne se superpose pas à elle-même : on la
        // rembobine plutôt que de laisser l'appel sans effet.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Une instance par (événement, son) et NON par son seul : les deux
    /// événements pointent souvent le MÊME fichier (la liste est courte). Avec
    /// une instance partagée, une carte de permission qui sonne serait coupée
    /// net par un `Stop` arrivant 300 ms plus tard, et rejouée au volume de
    /// l'autre événement.
    private func sound(for choice: SoundChoice, event: SoundEvent) -> NSSound? {
        let key = "\(event.rawValue)|\(choice.storageValue)"
        if let cached = cache[key] { return cached }
        let loaded: NSSound?
        switch choice {
        case .silent:
            loaded = nil
        case .system(let name):
            // `NSSound(named:)` résout les sons de /System/Library/Sounds et
            // ~/Library/Sounds. Le nom a été validé « composant nu » au décodage.
            loaded = NSSound(named: name)
        case .custom(let file):
            // `file` est validé nu par SoundChoice.decode : pas de remontée de
            // dossier possible ici.
            let url = BridgePaths.soundsDirectory.appendingPathComponent(file)
            loaded = NSSound(contentsOf: url, byReference: true)
        }
        guard let loaded else {
            log.error("son introuvable : \(choice.storageValue, privacy: .public)")
            return nil
        }
        cache[key] = loaded
        return loaded
    }

    // MARK: - Import d'un son personnalisé

    /// Copie un fichier audio dans `~/.atoll/sounds` et renvoie son nom.
    /// La COPIE est volontaire : si l'utilisateur déplace ou supprime
    /// l'original, Atoll continue de sonner.
    @discardableResult
    func importSound(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        try SoundImport.validate(fileExtension: url.pathExtension,
                                 byteCount: values.fileSize ?? 0)
        guard let baseName = SoundImport.destinationName(for: url.lastPathComponent) else {
            throw SoundImport.ImportError.unsupportedFormat(url.pathExtension)
        }
        let directory = BridgePaths.soundsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Deux fichiers d'origines différentes peuvent porter le même nom
        // (`ding.mp3`) : écraser changerait EN SILENCE le son déjà affecté à
        // l'autre événement. On désambiguïse — sauf si c'est le même fichier,
        // auquel cas réimporter doit rester idempotent.
        var name = baseName
        var destination = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            if let existing = try? Data(contentsOf: destination),
               let incoming = try? Data(contentsOf: url), existing == incoming {
                break // déjà importé à l'identique
            }
            let stem = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            name = "\(stem)-\(suffix).\(ext)"
            destination = directory.appendingPathComponent(name)
            suffix += 1
            guard suffix < 100 else { throw SoundImport.ImportError.unreadable }
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        refreshLibraries()
        log.info("son importé : \(name, privacy: .public)")
        return name
    }

    // MARK: - Migration des hooks de l'utilisateur

    /// Reprend les fichiers audio référencés par les hooks détectés comme sons
    /// Atoll, et les affecte à l'événement correspondant : jour 1 identique à
    /// l'oreille. Renvoie le nombre de sons repris.
    @discardableResult
    func adoptDetectedSounds() -> Int {
        var adopted = 0
        for hook in detectedHooks {
            guard let event = Self.event(forHookEvent: hook.event) else { continue }
            guard let path = SoundHookEditor.audioPaths(in: hook.command).first else { continue }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let name = try? importSound(from: url) else { continue }
            setChoice(.custom(name), for: event)
            adopted += 1
        }
        return adopted
    }

    /// Correspondance entre un événement de hook Claude Code et un événement
    /// sonore d'Atoll. `Notification` = « Claude a besoin de toi ».
    static func event(forHookEvent name: String) -> SoundEvent? {
        switch name {
        case "Notification", "PermissionRequest": return .decisionNeeded
        case "Stop", "SubagentStop": return .taskCompleted
        default: return nil
        }
    }

    /// Met de côté les hooks sonores de l'utilisateur. Le fichier de parking est
    /// écrit AVANT la modification de settings.json : si Atoll meurt entre les
    /// deux, la restitution reste possible.
    func parkUserSoundHooks() throws {
        // Un parking illisible : ÉCHOUER plutôt qu'écraser — l'écraser
        // détruirait définitivement les hooks déjà mis de côté (même règle que
        // le parking Rockstar).
        let state = parkingState()
        if case .unreadable = state { throw SoundCenterError.parkingUnreadable }

        let settingsURL = BridgePaths.claudeSettingsURL
        let data = try? Data(contentsOf: settingsURL)
        guard let result = try SoundHookEditor.park(in: data) else { return }
        try ensureSettingsBackup()

        let previous: [SoundHookEditor.ParkedHook]
        if case .parked(let file) = state { previous = file.hooks } else { previous = [] }
        let merged = SoundHookEditor.mergeParked(previous: previous, new: result.parked)
        let file = SoundHookEditor.ParkedSoundHooks(hooks: merged, parkedAt: Date())
        try FileManager.default.createDirectory(at: BridgePaths.parkedSoundHooksURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SoundHookEditor.encodeParked(file).write(to: BridgePaths.parkedSoundHooksURL, options: .atomic)
        try result.updated.write(to: settingsURL, options: .atomic)
        log.info("\(result.parked.count, privacy: .public) hook(s) sonore(s) parqué(s)")
        refreshLibraries()
    }

    /// Rend ses hooks sonores à l'utilisateur, puis efface le parking.
    func restoreUserSoundHooks() throws {
        switch parkingState() {
        case .none:
            return
        case .unreadable:
            // Ne pas rendre la main en silence : l'utilisateur croirait ses
            // hooks revenus alors qu'ils ne le sont pas.
            throw SoundCenterError.parkingUnreadable
        case .parked(let parked):
            try applyRestore(parked)
        }
    }

    private func applyRestore(_ parked: SoundHookEditor.ParkedSoundHooks) throws {
        let settingsURL = BridgePaths.claudeSettingsURL
        let data = try? Data(contentsOf: settingsURL)
        let restored = try SoundHookEditor.restore(into: data, parked: parked.hooks)
        try restored.write(to: settingsURL, options: .atomic)
        // Le parking ne disparaît QU'APRÈS une écriture réussie : sinon un
        // échec ici perdrait les hooks pour de bon.
        try? FileManager.default.removeItem(at: BridgePaths.parkedSoundHooksURL)
        log.info("\(parked.hooks.count, privacy: .public) hook(s) sonore(s) restitué(s)")
        refreshLibraries()
    }

    /// État du fichier de parking. On DISTINGUE « absent » d'« illisible » :
    /// confondre les deux faisait écraser un parking corrompu au prochain
    /// `park` (donc perdre les hooks pour de bon), et faisait disparaître le
    /// bouton de restitution — plus aucun chemin de récupération.
    enum ParkingState {
        case none
        case parked(SoundHookEditor.ParkedSoundHooks)
        case unreadable
    }

    func parkingState() -> ParkingState {
        guard FileManager.default.fileExists(atPath: BridgePaths.parkedSoundHooksURL.path)
        else { return .none }
        guard let data = try? Data(contentsOf: BridgePaths.parkedSoundHooksURL),
              let decoded = SoundHookEditor.decodeParked(data) else { return .unreadable }
        return .parked(decoded)
    }

    /// Sauvegarde « pré-Atoll » du settings.json, créée si elle n'existe pas
    /// encore. Le parking sonore est la SEULE écriture de ce fichier faite par
    /// l'app (le reste passe par le helper, qui sauvegarde lui-même) : sans
    /// ceci, migrer avant d'installer les hooks laissait Atoll copier plus tard
    /// un fichier DÉJÀ amputé comme « configuration d'origine ».
    private func ensureSettingsBackup() throws {
        let backup = BridgePaths.settingsBackupURL
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        let settings = BridgePaths.claudeSettingsURL
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: settings, to: backup)
        log.info("sauvegarde pré-Atoll du settings.json créée")
    }
}
