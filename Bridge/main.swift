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

/// Envoie l'enveloppe. Pour PermissionRequest (`awaitReply`), attend ensuite la
/// décision de l'app sur la même connexion (half-close côté écriture) — le CLI
/// borne l'attente via le timeout du hook, et l'app ferme la connexion sans
/// données pour « rendre la main au terminal ».
/// Ce qu'on sait après une tentative d'envoi.
///
/// `reached` répond à une question que le simple `Data?` ne pouvait pas
/// trancher : l'app a-t-elle VRAIMENT reçu l'enveloppe ? Sans réponse, on ne
/// pouvait pas savoir s'il fallait jouer le son de secours — `nil` signifiait
/// aussi bien « app absente » que « envoyé, rien à lire en retour ».
struct SocketOutcome {
    /// Connexion établie, pair authentifié comme NOUS, enveloppe écrite en entier.
    let reached: Bool
    /// Réponse de l'app, quand on l'attendait (PermissionRequest).
    let reply: Data?

    static let unreachable = SocketOutcome(reached: false, reply: nil)
}

func sendToSocket(_ data: Data, path: String, awaitReply: Bool = false) -> SocketOutcome {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .unreachable }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 0, tv_usec: 700_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    if !awaitReply {
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
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

    // À QUI parle-t-on ? `/private/tmp` est world-writable (sticky bit) : tant
    // qu'Atoll n'écoute pas, n'importe quel autre compte local peut créer
    // `/tmp/atoll-<uid>.sock`, recevoir tous les payloads de hooks ET répondre
    // `{"behavior":"allow"}` — réponse que le CLI honore telle quelle. On exige
    // donc que le pair soit NOUS. `LOCAL_PEERCRED` porte sur la connexion déjà
    // établie : aucune fenêtre de course, contrairement à un `stat` du chemin.
    // Le helper vérifie déjà le propriétaire de `proactive-recall.json` et de
    // `memory.db` ; c'est le même principe, sur le canal qui décide.
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
    // Half-close : signale « enveloppe complète » au serveur tout en gardant
    // la voie de retour ouverte pour la décision.
    shutdown(fd, SHUT_WR)

    // À partir d'ici l'app A REÇU l'enveloppe : c'est elle qui sonnera, pas nous.
    guard awaitReply else { return SocketOutcome(reached: true, reply: nil) }

    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            reply.append(contentsOf: chunk[0..<count])
            if reply.count > 1_048_576 { return SocketOutcome(reached: true, reply: nil) }
        } else if count == 0 {
            return SocketOutcome(reached: true, reply: reply.isEmpty ? nil : reply)
        } else {
            if errno == EINTR { continue }
            return SocketOutcome(reached: true, reply: nil)
        }
    }
}

// MARK: - Enrichissement + envoi

func forwardHookEvent() {
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
    // Instantané d'environnement pour le jump-back (Phase 4).
    var subset: [String: String] = [:]
    for key in [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "TMUX", "TMUX_PANE",
        "KITTY_WINDOW_ID", "KITTY_LISTEN_ON", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR",
        "ALACRITTY_WINDOW_ID", "VSCODE_INJECTION", "CURSOR_TRACE_ID", "WARP_SESSION_ID",
        "__CFBundleIdentifier", "CLAUDE_CODE_ENTRYPOINT",
    ] {
        if let value = environment[key] { subset[key] = value }
    }
    if !subset.isEmpty { enrich["env"] = subset }

    let eventName = payload["hook_event_name"] as? String
    let isPermissionRequest = eventName == "PermissionRequest"

    // Recall proactif (opt-in) AVANT l'envoi à l'îlot (revue) : c'est LUI que
    // le CLI attend sur un hook bloquant, et il ne dépend pas de l'app (il lit
    // l'index en direct — il marche même Atoll fermé). L'affichage de l'îlot,
    // lui, tolère parfaitement 20 ms de retard. Fail-open : nil = rien n'est
    // écrit, le CLI poursuit comme si de rien n'était.
    if eventName == "UserPromptSubmit",
       let injection = ProactiveRecallHook.contextJSON(payload: payload) {
        _ = replyToStdout(injection.json)
        // L'îlot doit pouvoir DIRE qu'il a injecté quelque chose : sans ça,
        // l'injection est invisible pour l'utilisateur (le bloc part avec
        // `suppressOutput`, il n'apparaît que dans le transcript).
        enrich["recallInjected"] = injection.count
    }

    let envelope: [String: Any] = ["v": 1, "enrich": enrich, "payload": payload]
    guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }

    let outcome = sendToSocket(data, path: BridgePaths.socketPath, awaitReply: isPermissionRequest)
    _ = replyToStdout(outcome.reply)

    // FILET SONORE. L'app joue les sons quand elle tourne ; quand elle est
    // fermée, personne ne les jouait — et comme Atoll a PARQUÉ les hooks
    // `afplay` de l'utilisateur, il se retrouvait totalement muet (constaté :
    // deux jours sans le moindre signal). On ne joue donc QUE si l'enveloppe
    // n'a pas été remise : exactement un des deux sonne, jamais les deux.
    //
    // Placé APRÈS `replyToStdout` : la réponse au CLI ne doit rien attendre.
    if !outcome.reached, let eventName {
        SoundPlayer.play(hookEvent: eventName)
    }

    // FILET ROCKSTAR — même discriminant, même esprit que le filet sonore.
    //
    // Rockstar suspend les règles `permissions.deny` que l'utilisateur a écrites
    // lui-même, et TOUS les chemins de restitution supposaient qu'Atoll TOURNE
    // (sortie du mode, lancement de l'app, désinstallation). Ferme l'app en
    // Rockstar — ou laisse-la planter — et les règles restent suspendues sur
    // toute la machine, indéfiniment, sans îlot pour approuver quoi que ce soit :
    // le pire des deux états. C'est mot pour mot la faute déjà payée avec les
    // sons en v0.15.1 : prendre quelque chose à l'utilisateur et mourir avec.
    if outcome.reached {
        BridgeCLI.noteAppReachable()
    } else {
        BridgeCLI.restoreRockstarIfOrphaned()
    }
}

@discardableResult
func replyToStdout(_ reply: Data?) -> Bool {
    guard let reply, !reply.isEmpty else { return false }
    reply.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(1, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                break
            }
            if written == 0 { break }
            offset += written
        }
    }
    return true
}

/// Mode statusline : lit le payload statusline sur stdin, l'envoie à l'app (tee
/// non bloquant, fail-open) et ne produit RIEN sur stdout — le wrapper enchaîne
/// ensuite la statusline d'origine de l'utilisateur.
func forwardStatusline() {
    guard isatty(0) == 0 else { return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty, input.count <= 1_048_576 else { return }
    guard (try? JSONSerialization.jsonObject(with: input)) is [String: Any] else { return }
    var envelope = Data(#"{"v":1,"statusline":"#.utf8)
    envelope.append(input)
    envelope.append(Data("}".utf8))
    _ = sendToSocket(envelope, path: BridgePaths.socketPath)
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
        [ -x "$BIN" ] && exec "$BIN" "$@"
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

    /// Installe (ou met à jour) le skill « atoll-recall » dans ~/.claude/skills.
    /// Même pattern qu'`ensureWrapper` : idempotent (contenu identique → no-op),
    /// temporaire écrit dans le MÊME dossier puis rename atomique — le CLI ne
    /// peut jamais lire un SKILL.md partiellement écrit. Ne touche QUE notre
    /// dossier `atoll-recall` (le répertoire skills contient des skills tiers).
    static func ensureSkill() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: BridgePaths.recallSkillDirectory, withIntermediateDirectories: true)
        let content = RecallSkill.markdown
        if let existing = try? String(contentsOf: BridgePaths.recallSkillURL, encoding: .utf8),
           existing == content {
            return
        }
        let temporary = BridgePaths.recallSkillDirectory.appendingPathComponent(".SKILL.md.tmp")
        try content.write(to: temporary, atomically: true, encoding: .utf8)
        _ = try fileManager.replaceItemAt(BridgePaths.recallSkillURL, withItemAt: temporary)
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

            // Hooks : écriture seulement si pas déjà installés (évite de réécrire
            // à chaque lancement de l'app, fenêtre de course minimale avec le CLI)
            // OU si le mode de recall proactif du fichier installé ne correspond
            // plus au réglage (UserPromptSubmit bloquant ⟷ async).
            let wantsProactiveRecall = ProactiveRecallHook.loadConfig()?.enabled ?? false
            if !HookSettingsEditor.isInstalled(in: current)
                || HookSettingsEditor.installedProactiveRecall(in: current) != wantsProactiveRecall {
                try refreshBackup(currentData: current)
                let updated = try HookSettingsEditor.install(
                    into: current,
                    command: BridgePaths.hookCommand,
                    proactiveRecall: wantsProactiveRecall
                )
                try updated.write(to: settingsURL, options: .atomic)
                current = try readSettings()
            }

            // Statusline (vrais quotas) : idempotent, s'installe même si les hooks
            // l'étaient déjà — relu depuis le fichier à jour.
            try installStatusline(current: current)

            // Skill « atoll-recall » : NON-fatal — les hooks priment. Un échec
            // est signalé sur stderr sans changer le code de sortie.
            do {
                try ensureSkill()
            } catch {
                FileHandle.standardError.write(Data("avertissement : skill atoll-recall non installé : \(error)\n".utf8))
            }
            print("hooks + statusline OK (backup : \(BridgePaths.settingsBackupURL.path))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de l'installation : \(error)\n".utf8))
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
        // Skill « atoll-recall » : suppression de NOTRE dossier uniquement —
        // ~/.claude/skills contient des skills tiers, ne JAMAIS énumérer ni
        // toucher le parent. Avant les sorties anticipées : le skill doit
        // disparaître même si settings.json a été vidé entre-temps.
        try? FileManager.default.removeItem(at: BridgePaths.recallSkillDirectory)
        // Skills APPRIS (7c) : retrait piloté par le manifeste UNIQUEMENT
        // (préfixe atoll- + entrée listée), fail-closed si illisible. Les
        // DONNÉES d'apprentissage (~/.atoll/learning) sont conservées.
        if let report = try? LearnedSkillStore().uninstallAll(), !report.removed.isEmpty {
            print("skills appris retirés : \(report.removed.joined(separator: ", "))")
        }
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
    static func rockstarPark() -> Int32 {
        do {
            let current = try readSettings()
            guard let result = try RockstarPermissionsEditor.park(in: current) else {
                print("aucune règle deny — rien à suspendre")
                return 0
            }
            var allParked = result.parked
            if FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path) {
                let existing = try Data(contentsOf: BridgePaths.rockstarParkedDenyURL)
                guard let previous = RockstarPermissionsEditor.decodeParked(existing) else {
                    // Illisible : ÉCHOUER plutôt qu'écraser — l'écraser détruirait
                    // définitivement des règles parquées précédemment.
                    FileHandle.standardError.write(Data("fichier de parking illisible, suspension refusée : \(BridgePaths.rockstarParkedDenyURL.path)\n".utf8))
                    return 1
                }
                allParked = RockstarPermissionsEditor.mergeParked(previous: previous.deny, new: allParked)
            }
            try refreshBackup(currentData: current)
            try FileManager.default.createDirectory(
                at: BridgePaths.rockstarParkedDenyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let parkedData = try RockstarPermissionsEditor.encodeParked(
                .init(deny: allParked, parkedAt: Date()))
            try parkedData.write(to: BridgePaths.rockstarParkedDenyURL, options: .atomic)
            try result.updated.write(to: settingsURL, options: .atomic)
            print("règles deny suspendues (\(result.parked.count))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de la suspension des règles deny : \(error)\n".utf8))
            return 1
        }
    }

    /// Rend à `settings.json` les hooks sonores parqués. Même schéma que
    /// `rockstarRestore` : le fichier de parking n'est supprimé qu'APRÈS une
    /// écriture réussie, et un parking illisible est laissé en place (avec un
    /// message) plutôt que perdu. Renvoie `true` en cas d'échec.
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

    /// Délai de grâce avant qu'un parking Rockstar orphelin soit restitué par le
    /// helper lui-même.
    ///
    /// Le helper ne s'exécute qu'à l'occasion d'un hook : le scénario visé est
    /// donc « tu travailles avec Claude, et Atoll n'est pas là ». Le délai
    /// arbitre entre deux fautes symétriques :
    /// - trop court, une simple mise à jour Sparkle (moins d'une minute), un
    ///   redémarrage ou un plantage suivi d'une relance te sortiraient de
    ///   Rockstar en plein travail, sans que tu l'aies demandé ;
    /// - trop long, la machine reste désarmée une nuit entière de travail.
    /// Deux heures absorbent très largement toute interruption technique, et
    /// garantissent qu'une journée ne se passe pas sans garde-fou.
    static let rockstarOrphanGrace: TimeInterval = 2 * 60 * 60

    /// Témoin d'absence de l'app. Le helper est un processus NEUF à chaque hook :
    /// il n'a aucune mémoire, il lui faut donc un fichier — même dispositif que
    /// l'anti-rafale du son.
    static var appAbsentWitnessURL: URL {
        BridgePaths.runDirectory.appendingPathComponent("app-absent-since")
    }

    /// L'app a répondu : on efface le témoin. Le compte à rebours ne mesure que
    /// des absences CONTINUES.
    static func noteAppReachable() {
        try? FileManager.default.removeItem(at: appAbsentWitnessURL)
    }

    /// Restitue les règles `deny` parquées si Atoll est injoignable DEPUIS
    /// suffisamment longtemps. Silencieux et fail-open : c'est un chemin de
    /// hook, il ne doit ni écrire sur les flux standard, ni retarder le CLI, ni
    /// jamais faire échouer quoi que ce soit.
    ///
    /// Ce qui est mesuré est l'ABSENCE DE L'APP, pas l'ancienneté du parking.
    /// Se fier à `parkedAt` était faux : en Rockstar depuis trois jours, un
    /// hook tombant pendant les quelques secondes d'un redémarrage Sparkle
    /// aurait vu un parking « vieux de trois jours » et restitué aussitôt — soit
    /// exactement le faux positif que le délai de grâce doit empêcher.
    static func restoreRockstarIfOrphaned(now: Date = Date()) {
        // Rien de parqué : pas de témoin à tenir, pas de décision à prendre.
        guard FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path) else {
            noteAppReachable()
            return
        }
        let witness = appAbsentWitnessURL
        let since = (try? FileManager.default.attributesOfItem(atPath: witness.path)[.modificationDate]) as? Date
        guard let since else {
            // Première absence constatée : on pose le témoin et on ne décide
            // rien. Le compte à rebours démarre maintenant.
            try? FileManager.default.createDirectory(at: BridgePaths.runDirectory,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: witness.path, contents: Data())
            try? FileManager.default.setAttributes([.modificationDate: now],
                                                   ofItemAtPath: witness.path)
            return
        }
        // Témoin dans le FUTUR (horloge reculée) : on le repose à maintenant
        // plutôt que de conclure sur un âge négatif.
        guard now >= since else {
            try? FileManager.default.setAttributes([.modificationDate: now],
                                                   ofItemAtPath: witness.path)
            return
        }
        guard now.timeIntervalSince(since) >= rockstarOrphanGrace else { return }
        // Version SILENCIEUSE : ni stdout (canal de réponse du hook) ni stderr.
        if case .restored = performRockstarRestore() {
            try? FileManager.default.removeItem(at: witness)
        }
    }

    /// `atoll-bridge recall-stats [--json]` — l'état de la mémoire proactive.
    ///
    /// Sans journal : on le DIT, au lieu de rendre des zéros qui se liraient
    /// comme « la fonction ne sert à rien ». Absence de mesure et mesure nulle
    /// ne sont pas la même chose — c'est exactement l'erreur qui a fait juger le
    /// cockpit sur un fichier d'état né après lui.
    static func recallStats(arguments: [String]) -> Int32 {
        let url = ProactiveRecallHook.journalURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            print("Aucun journal (\(url.path)).")
            print("Soit le recall proactif est éteint, soit aucun prompt n'est encore passé")
            print("depuis l'installation de cette version. Vérifier :")
            print("  cat ~/.atoll/proactive-recall.json")
            return 0
        }
        let entries = RecallJournal.entries(in: data)
        guard !entries.isEmpty else {
            print("Journal présent mais illisible (\(data.count) octets) — aucune entrée décodée.")
            return 1
        }
        let summary = RecallJournal.summarize(entries)
        if arguments.contains("--json") {
            var counts: [String: Int] = [:]
            for (outcome, count) in summary.byOutcome { counts[outcome.rawValue] = count }
            var histogram: [String: Int] = [:]
            for (coverage, count) in summary.coverageHistogram { histogram[String(coverage)] = count }
            let object: [String: Any] = [
                "total": summary.total,
                "searched": summary.searched,
                "byOutcome": counts,
                "injectedSnippets": summary.injectedSnippets,
                "coverageHistogram": histogram,
                "totalBlockChars": summary.totalBlockChars,
                "medianElapsedMs": summary.medianElapsedMs,
                "maxElapsedMs": summary.maxElapsedMs,
                "injectionRate": summary.injectionRate,
                "thinMatchRate": summary.thinMatchRate,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) {
                print(String(decoding: json, as: UTF8.self))
            }
            return 0
        }
        print(RecallJournal.report(summary))
        return 0
    }

    static func status() -> Int32 {
        let settings = try? Data(contentsOf: BridgePaths.claudeSettingsURL)
        let state: [String: Any] = [
            "hooksInstalled": HookSettingsEditor.isInstalled(in: settings),
            "wrapperPresent": FileManager.default.isExecutableFile(atPath: BridgePaths.wrapperURL.path),
            "socketPresent": FileManager.default.fileExists(atPath: BridgePaths.socketPath),
            "denyParked": FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path),
            "skillInstalled": FileManager.default.fileExists(atPath: BridgePaths.recallSkillURL.path),
            "memoryIndexPresent": FileManager.default.fileExists(atPath: BridgePaths.memoryDatabaseURL.path),
            // Réglage demandé vs mode réellement installé : un écart signale
            // des hooks à réécrire (`atoll-bridge install` le fait).
            "proactiveRecallEnabled": ProactiveRecallHook.loadConfig()?.enabled ?? false,
            "proactiveRecallHookBlocking": HookSettingsEditor.installedProactiveRecall(in: settings),
            "learnedSkills": LearnedSkillStore().installedSkills().count,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return 0
    }
}

// MARK: - Entrée

signal(SIGPIPE, SIG_IGN)

switch CommandLine.arguments.dropFirst().first {
case "install":
    exit(BridgeCLI.install())
case "uninstall":
    exit(BridgeCLI.uninstall())
case "status":
    exit(BridgeCLI.status())
case "rockstar-park":
    exit(BridgeCLI.rockstarPark())
case "rockstar-restore":
    exit(BridgeCLI.rockstarRestore())
case "recall":
    // Recherche dans l'index mémoire (skill atoll-recall). Fail-open : exit 0.
    exit(RecallCLI.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
case "recall-stats":
    // Lit `~/.atoll/recall-journal.jsonl` et rend le résumé. C'est CE verbe qui
    // permettra, après un mois d'usage, de décider si le recall proactif mérite
    // d'exister — ou de rejoindre le cockpit et le niveau « Auto ».
    exit(BridgeCLI.recallStats(arguments: Array(CommandLine.arguments.dropFirst(2))))
case "statusline":
    // Tee des rate_limits vers l'app (fail-open, ne produit rien sur stdout).
    forwardStatusline()
    exit(0)
default:
    // Mode hook : tout échec est silencieux, exit 0 inconditionnel.
    forwardHookEvent()
    exit(0)
}
