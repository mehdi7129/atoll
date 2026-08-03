import Foundation
import AtollCore

/// Le FILET sonore du helper : si l'app n'a pas été jointe, c'est lui qui sonne.
///
/// Atoll a repris les hooks `afplay` de l'utilisateur, puis est restée fermée
/// deux jours : plus rien ne sonnait. Le helper, lui, s'exécute à chaque hook —
/// il est le seul endroit où un son peut être garanti.
///
/// FAIL-OPEN, sans exception. Ce code est dans le chemin d'un hook :
/// - il n'écrit JAMAIS sur stdout ni stderr (ce sont les canaux du protocole de
///   hook — un octet de trop et le CLI lit une réponse invalide) ;
/// - il n'attend PAS la fin de la lecture ;
/// - la moindre erreur est avalée en silence.
enum SoundPlayer {

    /// Joue le son associé à un événement de hook, si tout s'y prête.
    /// Ne fait rien — jamais d'erreur remontée — dans tous les autres cas.
    static func play(hookEvent: String, now: Date = Date()) {
        guard let event = SoundFallback.event(forHookEvent: hookEvent) else { return }
        guard let settings = SoundFallback.decode(try? Data(contentsOf: BridgePaths.soundSettingsURL)),
              settings.enabled
        else { return }

        let choice = settings.choice(for: event)
        guard !choice.isSilent,
              let url = SoundFallback.fileURL(for: choice,
                                              soundsDirectory: BridgePaths.soundsDirectory,
                                              userSoundsDirectory: BridgePaths.homeDirectory
                                                  .appendingPathComponent("Library/Sounds", isDirectory: true))
        else { return }

        guard claimThrottle(for: event, now: now) else { return }
        spawnDetached(volume: settings.volume(for: event), file: url.path)
    }

    // MARK: - Anti-rafale

    /// Le helper n'a aucune mémoire d'un hook à l'autre : l'anti-rafale passe
    /// par la date de modification d'un fichier témoin. On l'écrit AVANT de
    /// jouer — deux hooks quasi simultanés (`Stop` de deux sessions) ne doivent
    /// pas sonner deux fois.
    private static func claimThrottle(for event: SoundEvent, now: Date) -> Bool {
        let stamp = SoundFallback.stampURL(for: event, in: BridgePaths.runDirectory)
        let existing = (try? FileManager.default.attributesOfItem(atPath: stamp.path)[.modificationDate]) as? Date
        guard SoundFallback.shouldPlay(stampDate: existing, now: now) else { return false }
        try? FileManager.default.createDirectory(at: BridgePaths.runDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Le contenu n'a aucune importance : seule la date compte.
        FileManager.default.createFile(atPath: stamp.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
        return true
    }

    // MARK: - Lancement détaché

    /// Lance `afplay` dans SA PROPRE session, les trois descripteurs sur
    /// `/dev/null`, et rend la main immédiatement.
    ///
    /// `POSIX_SPAWN_SETSID` n'est pas un détail : sans nouvelle session, le
    /// lecteur reste dans le groupe de processus du hook et peut être emporté
    /// quand le CLI fait le ménage — le son serait coupé au bout de quelques
    /// dizaines de millisecondes, ou pas joué du tout.
    ///
    /// Les descripteurs sur `/dev/null` ne sont pas un détail non plus : stdout
    /// est le canal par lequel un hook répond au CLI.
    private static func spawnDetached(volume: Double, file: String) {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in Int32(0)...Int32(2) {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let clamped = min(max(volume, 0), 1)
        let arguments = ["afplay", "-v", String(format: "%.3f", clamped), file]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        // On n'attend pas : `afplay` vit sa vie, le hook rend la main aussitôt.
        _ = posix_spawn(&pid, "/usr/bin/afplay", &actions, &attributes, argv, environ)
    }
}
