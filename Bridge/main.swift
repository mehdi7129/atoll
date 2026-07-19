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
    // Décision de l'îlot → stdout (le CLI la parse). Connexion fermée sans
    // données = on rend la main au prompt du terminal, en silence.
    if let reply, !reply.isEmpty {
        FileHandle.standardOutput.write(reply)
    }
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
            let current = try readSettings()
            // Déjà installé → rien à écrire : pas de réécriture à chaque
            // lancement de l'app, fenêtre de course minimale avec le CLI.
            if HookSettingsEditor.isInstalled(in: current) {
                print("hooks déjà installés — wrapper vérifié")
                return 0
            }
            try refreshBackup(currentData: current)
            let updated = try HookSettingsEditor.install(into: current, command: BridgePaths.hookCommand)
            try updated.write(to: settingsURL, options: .atomic)
            print("hooks installés (backup : \(BridgePaths.settingsBackupURL.path))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de l'installation : \(error)\n".utf8))
            return 1
        }
    }

    static func uninstall() -> Int32 {
        do {
            guard let current = try readSettings() else {
                print("aucun settings.json — rien à désinstaller")
                return 0
            }
            guard HookSettingsEditor.isInstalled(in: current) ||
                  String(decoding: current, as: UTF8.self).contains(".atoll/bin/atoll-bridge") else {
                print("hooks non installés — rien à faire")
                return 0
            }
            let updated = try HookSettingsEditor.uninstall(from: current)
            try updated.write(to: settingsURL, options: .atomic)
            // Le wrapper reste en place : les sessions Claude déjà ouvertes le
            // référencent encore, et il est fail-open (exit 0 sans binaire).
            print("hooks désinstallés")
            return 0
        } catch {
            FileHandle.standardError.write(Data("échec de la désinstallation : \(error)\n".utf8))
            return 1
        }
    }

    static func status() -> Int32 {
        let settings = try? Data(contentsOf: BridgePaths.claudeSettingsURL)
        let state: [String: Any] = [
            "hooksInstalled": HookSettingsEditor.isInstalled(in: settings),
            "wrapperPresent": FileManager.default.isExecutableFile(atPath: BridgePaths.wrapperURL.path),
            "socketPresent": FileManager.default.fileExists(atPath: BridgePaths.socketPath),
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
default:
    // Mode hook : tout échec est silencieux, exit 0 inconditionnel.
    forwardHookEvent()
    exit(0)
}
