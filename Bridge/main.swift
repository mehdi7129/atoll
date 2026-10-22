import Foundation
import Darwin
import AtollCore

/// atoll-bridge — helper appelé par les hooks Claude Code.
///
/// Modes :
///   (sans argument)  lit le payload du hook sur stdin, l'enrichit (pid/tty/env)
///                    et l'envoie au socket de l'app. FAIL-OPEN ABSOLU : quoi
///                    qu'il arrive, exit 0 — un hook ne doit jamais gêner le CLI.
///   install          installe les hooks gérés dans ~/.claude/settings.json
///                    (backup unique, merge chirurgical) + wrapper ~/.atoll/bin
///   uninstall        retire nos hooks, préserve le reste
///   status           affiche l'état (JSON)

// MARK: - Client socket (BSD, timeouts courts)

/// Transport d'observation : aucune réponse de l'app n'est lue ou relayée.
/// Une ancienne session peut garder une déclaration synchrone : ce helper
/// rend la main dès l'enveloppe envoyée, indépendamment de l'app.
struct SocketOutcome {
    let reached: Bool
    static let unreachable = SocketOutcome(reached: false)
}

func sendToSocket(_ data: Data, path: String) -> SocketOutcome {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .unreachable }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 0, tv_usec: 700_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // L'app peut fermer pendant l'écriture : sans ceci, SIGPIPE tuerait le
    // helper (statut 141) — violation du fail-open.
    var noSigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return .unreachable }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count)))
        }
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, length)
        }
    }
    guard connected == 0 else { return .unreachable }

    // Les payloads restent privés : le socket doit appartenir au même uid.
    // L'identité est vérifiée sur la connexion établie, sans course avec stat.
    var credentials = xucred()
    var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
          credentials.cr_version == XUCRED_VERSION,
          credentials.cr_uid == getuid()
    else { return .unreachable }

    // DEADLINE GLOBALE (revue) : `SO_SNDTIMEO` borne chaque `write`, pas la
    // boucle — un lecteur lent qui accepte quelques octets à chaque tour la
    // faisait durer indéfiniment. Depuis que UserPromptSubmit peut être
    // BLOQUANT, ce temps se paie sur chaque message de l'utilisateur.
    let deadline = Date().addingTimeInterval(2.0)
    var offset = 0
    let total = data.count
    while offset < total {
        guard Date() < deadline else { return .unreachable }
        let written: Int = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress!.advanced(by: offset), min(total - offset, 65_536))
        }
        guard written > 0 else { return .unreachable }
        offset += written
    }
    // EOF explicite pour le serveur. Aucun read, aucune attente de décision.
    shutdown(fd, SHUT_WR)
    return SocketOutcome(reached: true)
}

// MARK: - Enrichissement + envoi

func forwardHookEvent(socketPath: String = BridgePaths.socketPath) {
    // Lancé à la main dans un terminal (stdin = tty) : ne pas bloquer sur la lecture.
    guard isatty(0) == 0 else { return }

    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty, input.count <= 8_388_608 else { return }
    guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }

    var enrich: [String: Any] = [:]
    // pid transmis SEULEMENT si un vrai processus claude est identifié dans la
    // chaîne d'ancêtres : un fallback aveugle sur getppid() attacherait la session
    // au shell éphémère du hook, que kqueue déclarerait mort aussitôt.
    if let claudePid = ProcessInspector.findClaudeAncestor(from: getppid()) {
        enrich["pid"] = Int(claudePid)
        if let startTime = ProcessInspector.startTime(of: claudePid) {
            enrich["startTime"] = startTime
        }
        if let tty = ProcessInspector.tty(of: claudePid) {
            enrich["tty"] = tty
        }
    } else if let tty = ProcessInspector.tty(of: getpid()) {
        enrich["tty"] = tty
    }

    let environment = ProcessInfo.processInfo.environment
    if let hint = environment["__CFBundleIdentifier"] ?? environment["TERM_PROGRAM"] {
        enrich["terminalHint"] = hint
    }
    if let entrypoint = environment["CLAUDE_CODE_ENTRYPOINT"] {
        enrich["entrypoint"] = entrypoint
    }
    // Instantané d'environnement pour le jump-back (Phase 4). La liste vit dans
    // `TerminalAnchor` : le helper Codex consomme la MÊME.
    let subset = TerminalAnchor.capture(from: environment)
    if !subset.isEmpty { enrich["env"] = subset }

    let envelope: [String: Any] = ["v": 1, "enrich": enrich, "payload": payload]
    guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
    // Ni recall, ni réponse, ni son, ni écriture de permissions dans un hook.
    _ = sendToSocket(data, path: socketPath)
}

/// Mode statusline : lit le payload statusline sur stdin, l'envoie à l'app (tee
/// non bloquant, fail-open) et ne produit RIEN sur stdout — le wrapper enchaîne
/// ensuite la statusline d'origine de l'utilisateur.
func forwardStatusline(socketPath: String = BridgePaths.socketPath) {
    guard isatty(0) == 0 else { return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty, input.count <= 1_048_576 else { return }
    guard (try? JSONSerialization.jsonObject(with: input)) is [String: Any] else { return }
    var envelope = Data(#"{"v":1,"statusline":"#.utf8)
    envelope.append(input)
    envelope.append(Data("}".utf8))
    _ = sendToSocket(envelope, path: socketPath)
}

// MARK: - Installation (partagée CLI / app)

enum BridgeCLI {
    /// Chemin réel du settings.json : résout un éventuel symlink (dotfiles
    /// stow/chezmoi) pour que l'écriture atomique remplace la CIBLE et ne
    /// détruise pas le lien.
    static var settingsURL: URL {
        BridgePaths.claudeSettingsURL.resolvingSymlinksInPath()
    }

    /// nil = fichier absent. Fichier présent mais illisible (droits, I/O) →
    /// l'erreur se propage et AUCUNE écriture n'a lieu : jamais confondre
    /// « absent » et « illisible » (sinon on remplacerait la config par du vide).
    static func readSettings() throws -> Data? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        return try Data(contentsOf: settingsURL)
    }

    static func ensureWrapper() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: BridgePaths.binDirectory, withIntermediateDirectories: true)
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        // Échappement sh en simples quotes (gère espaces, $, `, ") :  ' → '\''
        let escaped = selfPath.replacingOccurrences(of: "'", with: "'\\''")
        let content = """
        #!/bin/sh
        # Généré par Atoll — pointeur stable vers le helper du bundle. Fail-open.
        BIN='\(escaped)'
        # Les commandes administratives doivent conserver leur statut d'erreur.
        # Seul le chemin d'observation est supervisé et rendu fail-open.
        case "${1-}" in
          install|uninstall|repair-passive|install-codex|uninstall-codex|status|rockstar-restore|rockstar-park|recall|recall-stats)
            [ -x "$BIN" ] || exit 1
            exec "$BIN" "$@"
            ;;
        esac
        [ -x "$BIN" ] || exit 0
        exec 3<&0
        "$BIN" "$@" <&3 &
        wait $! 2>/dev/null
        exit 0
        """
        // Idempotent, et jamais de fenêtre « écrit mais pas exécutable » :
        // temporaire + chmod PUIS rename atomique.
        if let existing = try? String(contentsOf: BridgePaths.wrapperURL, encoding: .utf8),
           existing == content,
           fileManager.isExecutableFile(atPath: BridgePaths.wrapperURL.path) {
            return
        }
        let temporary = BridgePaths.binDirectory.appendingPathComponent(".atoll-bridge.tmp")
        try content.write(to: temporary, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try fileManager.replaceItemAt(BridgePaths.wrapperURL, withItemAt: temporary)
    }

    /// Génère le wrapper statusline : tee non bloquant des rate_limits vers l'app,
    /// puis exécution de la statusline d'origine (lue à l'exécution depuis un
    /// fichier — survit à un déplacement de l'app). Fail-open intégral.
    static func ensureStatuslineWrapper() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: BridgePaths.binDirectory, withIntermediateDirectories: true)
        let helperPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let escaped = helperPath.replacingOccurrences(of: "'", with: "'\\''")
        let originalFile = BridgePaths.statuslineOriginalURL.path
            .replacingOccurrences(of: "'", with: "'\\''")
        let content = """
        #!/bin/sh
        # Généré par Atoll — met en cache les rate_limits puis enchaîne la
        # statusline d'origine. Fail-open : ne bloque ni ne casse jamais le CLI.
        BIN='\(escaped)'
        INPUT=$(cat)
        # Tee détaché : stdout/stderr redirigés pour ne PAS garder ouverts les
        # pipes de la statusline du CLI. ATTENTION : jamais de `</dev/null` sur
        # "$BIN" — il écraserait le pipe de printf et le bridge lirait une
        # entrée VIDE (bug réel : quota jamais alimenté). Le stdin du job est le
        # pipe, refermé dès la fin de printf — rien ne bloque le CLI.
        if [ -x "$BIN" ]; then
          { printf '%s' "$INPUT" | "$BIN" statusline >/dev/null 2>&1 & } >/dev/null 2>&1
        fi
        ORIG='\(originalFile)'
        if [ -s "$ORIG" ]; then
          printf '%s' "$INPUT" | sh -c "$(cat "$ORIG")"
        fi
        exit 0
        """
        if let existing = try? String(contentsOf: BridgePaths.statuslineWrapperURL, encoding: .utf8),
           existing == content,
           fileManager.isExecutableFile(atPath: BridgePaths.statuslineWrapperURL.path) {
            return
        }
        let temporary = BridgePaths.binDirectory.appendingPathComponent(".atoll-statusline.tmp")
        try content.write(to: temporary, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try fileManager.replaceItemAt(BridgePaths.statuslineWrapperURL, withItemAt: temporary)
    }

    /// Commande statusline d'origine mémorisée par Atoll, avec repli sur le
    /// backup pré-Atoll si le fichier a disparu (ex. `rm -rf ~/.atoll`). Chaîne
    /// vide = « l'utilisateur n'avait pas de statusline » (distinct de nil/absent).
    static func storedOriginalStatusline() -> String? {
        if let stored = try? String(contentsOf: BridgePaths.statuslineOriginalURL, encoding: .utf8) {
            return stored // peut être "" (marqueur « aucune »)
        }
        // Fichier disparu : récupérer depuis le backup pré-Atoll.
        if let backup = try? Data(contentsOf: BridgePaths.settingsBackupURL) {
            return StatusLineEditor.currentCommand(in: backup) ?? ""
        }
        return nil
    }

    /// Installe le chaînage statusline en mémorisant la commande d'origine.
    static func installStatusline(current: Data?) throws {
        try ensureStatuslineWrapper()

        // Déjà chaîné → ne pas réécrire les settings, mais AUTO-RÉPARER le
        // fichier d'original s'il a disparu (sinon la désinstallation supprimerait
        // la statusline de l'utilisateur au lieu de la restituer).
        if StatusLineEditor.isInstalled(in: current) {
            if (try? String(contentsOf: BridgePaths.statuslineOriginalURL, encoding: .utf8)) == nil,
               let recovered = storedOriginalStatusline() {
                try recovered.write(to: BridgePaths.statuslineOriginalURL, atomically: true, encoding: .utf8)
            }
            // Migration douce des installations existantes : refreshInterval
            // s'il manque (quota pendant l'inactivité) — seule clé touchée.
            if let migrated = try StatusLineEditor.addRefreshIntervalIfMissing(into: current) {
                try migrated.write(to: settingsURL, options: .atomic)
            }
            return
        }

        let result = try StatusLineEditor.install(into: current, wrapperCommand: BridgePaths.statuslineCommand)
        // Mémoriser l'original (ou le marqueur vide « aucune ») AVANT d'écrire
        // les settings — toujours réécrit pour refléter l'état courant, jamais
        // conditionné à l'absence du fichier (évite de ressusciter un ancien).
        try (result.originalCommand ?? "").write(to: BridgePaths.statuslineOriginalURL, atomically: true, encoding: .utf8)
        try result.settings.write(to: settingsURL, options: .atomic)
    }

    static func uninstallStatusline(current: Data) throws {
        guard StatusLineEditor.isInstalled(in: current) else { return }
        // "" = l'utilisateur n'avait pas de statusline (on la retire) ;
        // nil ne devrait pas arriver (storedOriginalStatusline replie sur "").
        let original = storedOriginalStatusline()
        let restored = try StatusLineEditor.uninstall(
            from: current,
            originalCommand: (original?.isEmpty ?? true) ? nil : original
        )
        try restored.write(to: settingsURL, options: .atomic)
        try? FileManager.default.removeItem(at: BridgePaths.statuslineWrapperURL)
        // Ne pas laisser traîner l'original : une réinstallation future ne doit
        // pas ressusciter une statusline que l'utilisateur a depuis retirée.
        try? FileManager.default.removeItem(at: BridgePaths.statuslineOriginalURL)
    }

    /// Backup : créé avant la première écriture ; rafraîchi quand le fichier
    /// courant ne contient aucun hook Atoll (réinstallation propre) pour ne pas
    /// laisser traîner un backup vieux de plusieurs mois.
    static func refreshBackup(currentData: Data?) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        // Fichier PRÉSENT mais vide (0 octet, ou uniquement du blanc) : c'est une
        // troncature, pas une configuration. Sans cette garde, la toute première
        // installation — celle où AUCUN backup n'existe encore — tombait
        // directement sur le `copyItem` final et gravait le fichier vide comme
        // « sauvegarde pré-Atoll », définitivement (le backup n'est jamais
        // écrasé ensuite). Les gardes plus bas ne couvrent QUE le cas d'un
        // backup déjà présent.
        if let currentData, HookSettingsEditor.isBlank(currentData) { return }
        let backupPath = BridgePaths.settingsBackupURL.path
        if fileManager.fileExists(atPath: backupPath) {
            guard !HookSettingsEditor.isInstalled(in: currentData) else { return }
            // `isInstalled` exige TOUS les événements gérés : retirer un seul
            // hook à la main le fait passer à false alors que le fichier
            // contient encore la statusline d'Atoll. On rafraîchissait alors le
            // backup « pré-Atoll » AVEC notre propre wrapper dedans, et la
            // statusline d'origine de l'utilisateur n'existait plus nulle part
            // (audit du 2026-07-27). Même test qu'à la désinstallation : AUCUNE
            // trace d'Atoll dans le fichier, ou on ne touche pas au backup.
            if let currentData,
               String(decoding: currentData, as: UTF8.self).contains("atoll-") {
                return
            }
            // Fichier courant ILLISIBLE (JSONC, corrompu) : `isInstalled` rend
            // false, et sans cette garde on remplaçait le backup sain par la
            // version corrompue (revue) — juste avant que l'installation
            // échoue de toute façon. Le backup ne se rafraîchit que depuis un
            // JSON valide.
            guard let currentData,
                  (try? JSONSerialization.jsonObject(with: currentData)) is [String: Any]
            else { return }
            try fileManager.removeItem(atPath: backupPath)
        }
        try fileManager.copyItem(at: settingsURL, to: BridgePaths.settingsBackupURL)
    }

    static func install() -> Int32 {
        do {
            try ensureWrapper()
            var current = try readSettings()

            if !HookSettingsEditor.isInstalled(in: current)
                || HookSettingsEditor.hasDuplicateManagedHooks(in: current) {
                try refreshBackup(currentData: current)
                let updated = try HookSettingsEditor.install(into: current, command: BridgePaths.hookCommand)
                try updated.write(to: settingsURL, options: .atomic)
            } else if let original = current {
                let updated = try HookSettingsEditor.migratePassive(original)
                if updated != original {
                    try refreshBackup(currentData: original)
                    try updated.write(to: settingsURL, options: .atomic)
                }
            }
            current = try readSettings()
            try installStatusline(current: current)

            print("hooks + statusline OK (backup : \(BridgePaths.settingsBackupURL.path))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de l'installation : \(error)\n".utf8))
            return 1
        }
    }

    /// Actualise une intégration existante sans recréer les événements retirés.
    /// Les wrappers ne sont posés que si leurs définitions sont encore présentes.
    static func repairPassive() -> Int32 {
        do {
            guard let current = try readSettings() else { return 0 }
            let updated = try HookSettingsEditor.migratePassive(current)
            if updated != current {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = settingsURL.appendingPathExtension("atoll-passive-\(stamp)-\(UUID().uuidString).json")
                let fd = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do { try file.write(contentsOf: current); try file.close() }
                catch { try? file.close(); throw error }
                guard try readSettings() == current else { throw CocoaError(.fileWriteFileExists) }
                try updated.write(to: settingsURL, options: .atomic)
            }
            if HookSettingsEditor.hasManagedHooks(in: updated) { try ensureWrapper() }
            // La branche déjà installée répare aussi l'original perdu depuis
            // le backup et le refreshInterval absent. Une statusline retirée
            // par l'utilisateur ne doit jamais être réinstallée au démarrage.
            if StatusLineEditor.isInstalled(in: updated) { try installStatusline(current: updated) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de l'actualisation passive : \(error)\n".utf8))
            return 1
        }
    }

    static func uninstall() -> Int32 {
        // Restaurer les règles deny parquées (rockstar) AVANT TOUT — y compris
        // les sorties anticipées ci-dessous : la désinstallation ne doit JAMAIS
        // laisser les règles de l'utilisateur suspendues, même si settings.json
        // a disparu ou ne contient plus de marqueur Atoll. Un échec est signalé
        // (exit 1) mais n'empêche pas de retirer les hooks.
        var denyRestoreFailed = false
        if FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path) {
            denyRestoreFailed = rockstarRestore() != 0
        }
        // Hooks SONORES parqués : même régime, et pour la même raison. La
        // restitution n'existait que dans la façade app ; désinstaller depuis
        // le terminal — le seul chemin possible si l'app a été supprimée —
        // laissait les `afplay` de l'utilisateur dans le fichier de parking.
        // Silence total, puis perte définitive au premier `rm -rf ~/.atoll`.
        let soundRestoreFailed = restoreParkedSoundHooks()
        do {
            guard let current = try readSettings() else {
                print("aucun settings.json — rien à désinstaller")
                return (denyRestoreFailed || soundRestoreFailed) ? 1 : 0
            }
            guard HookSettingsEditor.isInstalled(in: current) ||
                  StatusLineEditor.isInstalled(in: current) ||
                  String(decoding: current, as: UTF8.self).contains("/.atoll/bin/") else {
                print("hooks non installés — rien à faire")
                return (denyRestoreFailed || soundRestoreFailed) ? 1 : 0
            }
            // Restaurer la statusline d'origine AVANT de retirer les hooks : la
            // désinstallation doit rendre le settings.json tel qu'il était.
            try uninstallStatusline(current: current)
            let afterStatusline = try readSettings() ?? current
            let updated = try HookSettingsEditor.uninstall(from: afterStatusline)
            try updated.write(to: settingsURL, options: .atomic)
            // Les wrappers restent en place : les sessions Claude déjà ouvertes les
            // référencent encore, et ils sont fail-open (exit 0 sans binaire).
            print("hooks + statusline désinstallés")
            return (denyRestoreFailed || soundRestoreFailed) ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data("échec de la désinstallation : \(error)\n".utf8))
            return 1
        }
    }

    /// Rockstar : suspend les règles `permissions.deny` (conservées dans
    /// ~/.atoll/rockstar-parked-deny.json). Crash-safe : le fichier de parking
    /// est écrit AVANT de toucher settings.json — à aucun moment les règles
    /// n'existent nulle part. Idempotent : un parking précédent est fusionné.
    /// Restitution legacy, jamais appelée depuis le chemin d'un hook.
    static func restoreParkedSoundHooks() -> Bool {
        let parkedURL = BridgePaths.parkedSoundHooksURL
        guard FileManager.default.fileExists(atPath: parkedURL.path) else { return false }
        do {
            let data = try Data(contentsOf: parkedURL)
            guard let parked = SoundHookEditor.decodeParked(data) else {
                FileHandle.standardError.write(Data(
                    "parking sonore illisible : \(parkedURL.path) — hooks NON restitués\n".utf8))
                return true
            }
            let current = try readSettings()
            let updated = try SoundHookEditor.restore(into: current, parked: parked.hooks)
            try updated.write(to: settingsURL, options: .atomic)
            try FileManager.default.removeItem(at: parkedURL)
            print("hooks sonores restitués (\(parked.hooks.count))")
            return false
        } catch {
            FileHandle.standardError.write(Data(
                "échec de la restitution des hooks sonores : \(error)\n".utf8))
            return true
        }
    }

    /// Rockstar terminé : réinsère les règles parquées (union avec celles
    /// ajoutées entre-temps). Le fichier de parking ne disparaît QU'APRÈS
    /// l'écriture réussie de settings.json.
    /// Issue d'une restitution, sans le moindre effet de bord sur les flux : le
    /// chemin de hook ne peut RIEN écrire (stdout y est le canal de réponse du
    /// hook, stderr est avalé) ; seule la commande CLI parle.
    enum RockstarRestoreOutcome {
        case nothingParked
        case restored(count: Int)
        case unreadableParking
        case failed(Error)
    }

    /// Cœur SILENCIEUX de la restitution. Appelé par la commande CLI (qui
    /// imprime) et par le filet de hook (qui se tait).
    static func performRockstarRestore() -> RockstarRestoreOutcome {
        do {
            guard FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path) else {
                return .nothingParked
            }
            let parkedData = try Data(contentsOf: BridgePaths.rockstarParkedDenyURL)
            guard let parked = RockstarPermissionsEditor.decodeParked(parkedData) else {
                // Corrompu : on le laisse en place pour diagnostic, on signale.
                return .unreadableParking
            }
            let current = try readSettings()
            let updated = try RockstarPermissionsEditor.restore(into: current, parked: parked.deny)
            try updated.write(to: settingsURL, options: .atomic)
            try FileManager.default.removeItem(at: BridgePaths.rockstarParkedDenyURL)
            return .restored(count: parked.deny.count)
        } catch {
            return .failed(error)
        }
    }

    static func rockstarRestore() -> Int32 {
        switch performRockstarRestore() {
        case .nothingParked:
            print("aucune règle parquée — rien à restaurer")
            return 0
        case .restored(let count):
            print("règles deny restaurées (\(count))")
            return 0
        case .unreadableParking:
            FileHandle.standardError.write(Data("fichier de parking illisible : \(BridgePaths.rockstarParkedDenyURL.path)\n".utf8))
            return 1
        case .failed(let error):
            FileHandle.standardError.write(Data("échec de la restauration des règles deny : \(error)\n".utf8))
            return 1
        }
    }

    static func status() -> Int32 {
        let settings = try? Data(contentsOf: BridgePaths.claudeSettingsURL)
        var state: [String: Any] = [
            "hooksInstalled": HookSettingsEditor.isInstalled(in: settings),
            "wrapperPresent": FileManager.default.isExecutableFile(atPath: BridgePaths.wrapperURL.path),
            "socketPresent": FileManager.default.fileExists(atPath: BridgePaths.socketPath),
            "denyParked": FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path),
            "skillInstalled": FileManager.default.fileExists(atPath: BridgePaths.recallSkillURL.path),
            "memoryIndexPresent": FileManager.default.fileExists(atPath: BridgePaths.memoryDatabaseURL.path),
            "memoryIndexPath": BridgePaths.memoryDatabaseURL.path,
            // Réglage demandé vs mode réellement installé : un écart signale
            // des hooks à réécrire (`atoll-bridge install` le fait).
            "proactiveRecallEnabled": false,
            "proactiveRecallHookBlocking": HookSettingsEditor.installedProactiveRecall(in: settings),
            "learnedSkills": LearnedSkillStore().installedSkills().count,
        ]
        state["provider"] = "claude" // anciens champs conservés pour les consommateurs existants
        state["codex"] = [
            "home": CodexPaths.homeURL.path,
            "configurationError": CodexPaths.configurationError as Any? ?? NSNull(),
            "hooksInstalled": CodexHookSettingsEditor.isInstalled(try? Data(contentsOf: CodexPaths.hooksURL)),
            "nativeTrust": "non vérifié — /hooks ou diagnostic natif dans Atoll",
            "socketPresent": FileManager.default.fileExists(atPath: CodexPaths.socketPath),
            "recallFilePresent": FileManager.default.fileExists(atPath: CodexRecallSkill.directory(home: CodexPaths.homeURL).appendingPathComponent("SKILL.md").path),
            "proactiveRecallEnabled": false,
            "learnedSkills": LearnedSkillStore(destination: .codex).installedSkills().count,
            "skillManifestProblem": LearnedSkillStore(destination: .codex).manifestProblem() as Any? ?? NSNull(),
        ] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return 0
    }
}

// MARK: - Entrée

signal(SIGPIPE, SIG_IGN)

switch CommandLine.arguments.dropFirst().first {
case "codex-hook":
    CodexBridge.forward()
    exit(0)
case "install-codex":
    exit(CodexBridge.configure(install: true))
case "uninstall-codex":
    exit(CodexBridge.configure(install: false))
case "install":
    exit(BridgeCLI.install())
case "repair-passive":
    exit(BridgeCLI.repairPassive())
case "uninstall":
    exit(BridgeCLI.uninstall())
case "status":
    exit(BridgeCLI.status())
case "rockstar-park":
    // Ancien appel conservé sans action : Atoll ne suspend plus de permissions.
    exit(0)
case "rockstar-restore":
    exit(BridgeCLI.rockstarRestore())
case "recall", "recall-stats":
    // Compatibilité des anciens skills/wrappers : aucune recherche/injection.
    exit(0)
case "statusline":
    // Tee des rate_limits vers l'app (fail-open, ne produit rien sur stdout).
    forwardStatusline()
    exit(0)
default:
    // Mode hook : tout échec est silencieux, exit 0 inconditionnel.
    forwardHookEvent()
    exit(0)
}
