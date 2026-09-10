import Foundation
import Darwin

/// Explicit roots make filesystem behavior testable without touching a real
/// subscription, ~/.codex, ~/.claude or the recall measurement journal.
public enum CodexHookInstallation {
    public static func apply(settingsURL: URL, binDirectory: URL, helperURL: URL, install: Bool) throws {
        let fm = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        let current = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        if !install && current == nil { return }
        let edited = try CodexHookSettingsEditor.edit(current, install: install)
        if install {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = target.appendingPathExtension("atoll-backup")
            if let current, !fm.fileExists(atPath: backup.path) {
                let descriptor = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    try file.write(contentsOf: current)
                    try file.close()
                } catch {
                    try? file.close()
                    try? fm.removeItem(at: backup) // only our incomplete, newly created backup
                    throw error
                }
            }
            try writeWrapper(binDirectory: binDirectory, helperURL: helperURL)
        }
        // Best-effort concurrent-edit detection (not an atomic compare-and-swap).
        let latest = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        guard latest == current else { throw CocoaError(.fileWriteFileExists) }
        // Préserver aussi la mise en forme personnelle si les objets sont égaux.
        if let current, CodexHookSettingsEditor.sameJSON(current, edited) { return }
        try edited.write(to: target, options: .atomic)
        // Hook commands may contain personal paths or credentials. The backup
        // and settings are user-only; no widening of the existing access.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    // MARK: - Le lanceur des hooks

    /// LE SCRIPT, ÉCRIT UNE SEULE FOIS.
    ///
    /// ⚠️ IL A DÉJÀ EXISTÉ EN DEUX EXEMPLAIRES, et c'est précisément ce qui a
    /// produit le défaut que ce fichier corrige : le superviseur a été réparé
    /// dans le générateur pendant que le script RÉELLEMENT INSTALLÉ gardait son
    /// `exec`. Une correction qui n'atteint pas le disque n'existe pas.
    /// Le garder à un seul endroit est ce qui rend la migration ci-dessous
    /// capable de reconnaître un wrapper périmé.
    ///
    /// ⚠️ SUPERVISEUR, PAS `exec`. Avec `exec`, le worker REMPLACE le shell :
    /// un `SIGTERM` ou `SIGKILL` du worker devient la mort du hook, et Codex la
    /// voit comme un échec au lieu d'une abstention. Personne ne peut alors la
    /// convertir en « exit 0, stdout vide ».
    ///
    /// Ici le shell reste vivant, attend le worker, et sort 0 **quel que soit le
    /// sort du worker** : ce que celui-ci a écrit sur stdout est déjà parti vers
    /// Codex (allow/deny), et s'il est mort sans rien écrire, l'abstention est
    /// exactement ce qu'il faut. Constat de la revue de Codex du 2026-09-09 :
    /// « sans ce changement, l'architecture demandée est absente ».
    ///
    /// ⚠️ LA GARANTIE PORTE SUR LE WORKER, PAS SUR TOUT SIGNAL. Cette page a
    /// d'abord écrit « sort TOUJOURS 0 », et Codex l'a mesuré faux : un
    /// `SIGTERM` adressé au SUPERVISEUR lui-même rend **143** et laisse le
    /// worker vivant — le shell n'atteint jamais sa dernière ligne, `wait` n'a
    /// rien à convertir. La formulation exacte est donc : « le worker qui
    /// termine ou qui est tué devient une abstention ». Rendre aussi ce cas
    /// convertible demanderait un `trap` qui retransmet au worker puis attend à
    /// nouveau ; ce n'est PAS fait, et la documentation officielle des hooks ne
    /// dit pas à quel PID ou groupe Codex adresse ses annulations. On ne
    /// remplace pas une forme mesurée de bout en bout par une supposition.
    ///
    /// ⚠️ LES TROIS LIGNES DU MILIEU NE SONT PAS DÉCORATIVES, et la forme
    /// évidente (`"$BIN" codex-hook` en avant-plan) a été MESURÉE défaillante
    /// le 2026-09-09 :
    ///
    /// - **En avant-plan**, le shell annonce la mort du worker sur SON stderr —
    ///   « atoll-codex-bridge: line 4: 47645 Terminated: 15 ». Le contrat est
    ///   respecté (exit 0, stdout vide), mais le texte part vers Codex, et
    ///   Mehdi s'est plaint du bruit dans cette TUI. `wait $! 2>/dev/null`
    ///   étouffe ce SEUL message : il s'applique à `wait`, jamais au worker,
    ///   dont le stderr reste intact (mesuré).
    /// - **`&` SEUL CASSE LE CHEMIN NOMINAL** : un job d'arrière-plan reçoit
    ///   `/dev/null` sur stdin, donc le worker ne lisait PLUS LE PAYLOAD du
    ///   hook. Mesuré, et c'est exactement le piège du veilleur d'EOF de la
    ///   veille — réparer un cas de faute en cassant le cas nominal. D'où
    ///   `exec 3<&0` puis `<&3`, qui rendent explicitement stdin au worker.
    ///
    /// Les trois axes ont été mesurés sur cette forme : payload transmis,
    /// stdout et stderr du worker transmis, et worker tué ⇒ exit 0, stdout
    /// vide, stderr vide.
    ///
    /// Un `SIGKILL` du SUPERVISEUR lui-même reste non garantissable — aucun
    /// processus ne survit à SIGKILL — et c'est documenté comme tel.
    public static func wrapperScript(helperURL: URL) -> String {
        let escaped = helperURL.resolvingSymlinksInPath().path
            .replacingOccurrences(of: "'", with: "'\\''")
        return """
            #!/bin/sh
            BIN='\(escaped)'
            [ -x "$BIN" ] || exit 0
            exec 3<&0
            "$BIN" codex-hook <&3 &
            wait $! 2>/dev/null
            exit 0
            """ + "\n"
    }

    public static func wrapperURL(binDirectory: URL) -> URL {
        binDirectory.appendingPathComponent("atoll-codex-bridge")
    }

    private static func writeWrapper(binDirectory: URL, helperURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let url = wrapperURL(binDirectory: binDirectory)
        if (try? String(contentsOf: url, encoding: .utf8)) == wrapperScript(helperURL: helperURL),
           fm.isExecutableFile(atPath: url.path) { return }
        let temporary = binDirectory.appendingPathComponent(".codex-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try wrapperScript(helperURL: helperURL).write(to: temporary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Ce qu'une passe de migration a fait — journalisable, et testable.
    public enum WrapperRefresh: Equatable, Sendable {
        /// Les hooks Codex ne sont pas installés : on ne pose rien.
        case notInstalled
        /// Le wrapper sur disque est déjà le bon, à l'octet près.
        case upToDate
        /// Il a été réécrit ; l'ancien contenu est rendu pour le journal.
        case rewritten(previous: String?)
    }

    /// Remet le lanceur installé en accord avec CETTE version d'Atoll.
    ///
    /// DEUX PANNES RÉELLES, ET AUCUNE NE SE VOIT :
    /// 1. **Une correction du wrapper n'atteignait jamais un poste déjà
    ///    installé.** Le fichier est écrit à l'installation et plus jamais
    ///    relu : le superviseur corrigé le 2026-09-09 serait resté un `exec`
    ///    chez tous ceux qui avaient installé les hooks avant.
    /// 2. **L'app déplacée laissait l'intégration morte EN SILENCE.** Le
    ///    wrapper garde le chemin absolu du helper ; le bundle déplacé, sa
    ///    garde `[ -x "$BIN" ] || exit 0` fait exactement ce qu'on lui demande —
    ///    sortir proprement — donc Codex ne se plaint de rien et Atoll ne voit
    ///    plus un seul événement. Le panneau des réglages demandait à
    ///    l'utilisateur de « retirer puis réinstaller les hooks » : une charge
    ///    qui n'a jamais eu de raison d'être la sienne.
    ///
    /// IDEMPOTENT PAR COMPARAISON D'OCTETS : au lancement suivant, rien n'est
    /// écrit. On ne touche au disque que pour une vraie différence — un `rename`
    /// à chaque démarrage serait un risque gratuit sur un fichier que Codex
    /// exécute.
    ///
    /// ⚠️ NE POSE JAMAIS LE WRAPPER SI LES HOOKS NE SONT PAS INSTALLÉS. Sans
    /// cette garde, Atoll créerait un lanceur dans `~/.atoll/bin` chez un
    /// utilisateur qui n'a jamais demandé l'intégration Codex.
    @discardableResult
    public static func refreshWrapper(settingsURL: URL,
                                      binDirectory: URL,
                                      helperURL: URL) throws -> WrapperRefresh {
        let fm = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        let settings = fm.fileExists(atPath: target.path) ? try? Data(contentsOf: target) : nil
        guard CodexHookSettingsEditor.hasManagedHooks(settings) else { return .notInstalled }

        let url = wrapperURL(binDirectory: binDirectory)
        let wanted = wrapperScript(helperURL: helperURL)
        let previous = try? String(contentsOf: url, encoding: .utf8)
        // Exécutable ET identique : la seule combinaison qui n'a rien à corriger.
        if previous == wanted,
           let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
           mode.int16Value & 0o111 != 0 {
            return .upToDate
        }
        try writeWrapper(binDirectory: binDirectory, helperURL: helperURL)
        return .rewritten(previous: previous)
    }

    /// Migre les anciennes définitions encore présentes. Un retrait ou une
    /// personnalisation reste choisi par l'utilisateur ; seul « Réparer »
    /// explicitement demandé réinstalle la liste complète.
    @discardableResult
    public static func migrateIfInstalled(settingsURL: URL, binDirectory: URL,
                                          helperURL: URL) throws -> Bool {
        let target = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        let data = try Data(contentsOf: target)
        // Valider avant toute écriture ; un JSON invalide n'est pas « absent ».
        _ = try CodexHookSettingsEditor.edit(data, install: false)
        guard CodexHookSettingsEditor.hasManagedHooks(data) else { return false }
        let edited = try CodexHookSettingsEditor.migrate(data)
        let changed = !CodexHookSettingsEditor.sameJSON(data, edited)
        if changed {
            // Chaque vraie migration conserve SA copie, y compris après une
            // personnalisation. La sauvegarde de première installation reste.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = target.appendingPathExtension("atoll-migration-\(stamp)-\(UUID().uuidString).json")
            let fd = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try file.write(contentsOf: data); try file.close() }
            catch { try? file.close(); try? FileManager.default.removeItem(at: backup); throw error }
            guard try Data(contentsOf: target) == data else { throw CocoaError(.fileWriteFileExists) }
            try edited.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        _ = try refreshWrapper(settingsURL: target, binDirectory: binDirectory, helperURL: helperURL)
        return changed
    }
}
