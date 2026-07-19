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
func sendToSocket(_ data: Data, path: String, awaitReply: Bool = false) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
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
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
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
    guard connected == 0 else { return nil }

    var offset = 0
    let total = data.count
    while offset < total {
        let written: Int = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress!.advanced(by: offset), min(total - offset, 65_536))
        }
        guard written > 0 else { return nil }
        offset += written
    }
    // Half-close : signale « enveloppe complète » au serveur tout en gardant
    // la voie de retour ouverte pour la décision.
    shutdown(fd, SHUT_WR)

    guard awaitReply else { return nil }

    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            reply.append(contentsOf: chunk[0..<count])
            if reply.count > 1_048_576 { return nil }
        } else if count == 0 {
            return reply.isEmpty ? nil : reply
        } else {
            if errno == EINTR { continue }
            return nil
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

    let envelope: [String: Any] = ["v": 1, "enrich": enrich, "payload": payload]
    guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }

    let isPermissionRequest = (payload["hook_event_name"] as? String) == "PermissionRequest"
    let reply = sendToSocket(data, path: BridgePaths.socketPath, awaitReply: isPermissionRequest)
    _ = replyToStdout(reply)
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
        let backupPath = BridgePaths.settingsBackupURL.path
        if fileManager.fileExists(atPath: backupPath) {
            guard !HookSettingsEditor.isInstalled(in: currentData) else { return }
            try fileManager.removeItem(atPath: backupPath)
        }
        try fileManager.copyItem(at: settingsURL, to: BridgePaths.settingsBackupURL)
    }

    static func install() -> Int32 {
        do {
            try ensureWrapper()
            var current = try readSettings()

            // Hooks : écriture seulement si pas déjà installés (évite de réécrire
            // à chaque lancement de l'app, fenêtre de course minimale avec le CLI).
            if !HookSettingsEditor.isInstalled(in: current) {
                try refreshBackup(currentData: current)
                let updated = try HookSettingsEditor.install(into: current, command: BridgePaths.hookCommand)
                try updated.write(to: settingsURL, options: .atomic)
                current = try readSettings()
            }

            // Statusline (vrais quotas) : idempotent, s'installe même si les hooks
            // l'étaient déjà — relu depuis le fichier à jour.
            try installStatusline(current: current)
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
        do {
            guard let current = try readSettings() else {
                print("aucun settings.json — rien à désinstaller")
                return denyRestoreFailed ? 1 : 0
            }
            guard HookSettingsEditor.isInstalled(in: current) ||
                  StatusLineEditor.isInstalled(in: current) ||
                  String(decoding: current, as: UTF8.self).contains("/.atoll/bin/") else {
                print("hooks non installés — rien à faire")
                return denyRestoreFailed ? 1 : 0
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
            return denyRestoreFailed ? 1 : 0
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

    /// Rockstar terminé : réinsère les règles parquées (union avec celles
    /// ajoutées entre-temps). Le fichier de parking ne disparaît QU'APRÈS
    /// l'écriture réussie de settings.json.
    static func rockstarRestore() -> Int32 {
        do {
            guard FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path) else {
                print("aucune règle parquée — rien à restaurer")
                return 0
            }
            let parkedData = try Data(contentsOf: BridgePaths.rockstarParkedDenyURL)
            guard let parked = RockstarPermissionsEditor.decodeParked(parkedData) else {
                // Corrompu : on le laisse en place pour diagnostic, on signale.
                FileHandle.standardError.write(Data("fichier de parking illisible : \(BridgePaths.rockstarParkedDenyURL.path)\n".utf8))
                return 1
            }
            let current = try readSettings()
            let updated = try RockstarPermissionsEditor.restore(into: current, parked: parked.deny)
            try updated.write(to: settingsURL, options: .atomic)
            try FileManager.default.removeItem(at: BridgePaths.rockstarParkedDenyURL)
            print("règles deny restaurées (\(parked.deny.count))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de la restauration des règles deny : \(error)\n".utf8))
            return 1
        }
    }

    static func status() -> Int32 {
        let settings = try? Data(contentsOf: BridgePaths.claudeSettingsURL)
        let state: [String: Any] = [
            "hooksInstalled": HookSettingsEditor.isInstalled(in: settings),
            "wrapperPresent": FileManager.default.isExecutableFile(atPath: BridgePaths.wrapperURL.path),
            "socketPresent": FileManager.default.fileExists(atPath: BridgePaths.socketPath),
            "denyParked": FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path),
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
case "statusline":
    // Tee des rate_limits vers l'app (fail-open, ne produit rien sur stdout).
    forwardStatusline()
    exit(0)
default:
    // Mode hook : tout échec est silencieux, exit 0 inconditionnel.
    forwardHookEvent()
    exit(0)
}
