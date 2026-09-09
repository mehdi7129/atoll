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
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let escaped = helperURL.resolvingSymlinksInPath().path.replacingOccurrences(of: "'", with: "'\\''")
            // ⚠️ SUPERVISEUR, PAS `exec`. Avec `exec`, le worker REMPLACE le
            // shell : un `SIGTERM` ou `SIGKILL` du worker devient la mort du
            // hook, et Codex la voit comme un échec au lieu d'une abstention.
            // Personne ne peut alors la convertir en « exit 0, stdout vide ».
            //
            // Ici le shell reste vivant, attend le worker, et sort TOUJOURS 0 :
            // ce que le worker a écrit sur stdout est déjà parti vers Codex
            // (allow/deny), et s'il est mort sans rien écrire, l'abstention est
            // exactement ce qu'il faut. Constat de la revue de Codex du
            // 2026-09-09 : « sans ce changement, l'architecture demandée est
            // absente ».
            //
            // Un `SIGKILL` du SUPERVISEUR lui-même reste non garantissable —
            // aucun processus ne survit à SIGKILL — et c'est documenté comme tel.
            let wrapper = """
                #!/bin/sh
                BIN='\(escaped)'
                [ -x "$BIN" ] || exit 0
                "$BIN" codex-hook
                exit 0
                """ + "\n"
            let url = binDirectory.appendingPathComponent("atoll-codex-bridge")
            let temporary = binDirectory.appendingPathComponent(".codex-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: temporary) }
            try wrapper.write(to: temporary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        // Best-effort concurrent-edit detection (not an atomic compare-and-swap).
        let latest = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        guard latest == current else { throw CocoaError(.fileWriteFileExists) }
        try edited.write(to: target, options: .atomic)
        // Hook commands may contain personal paths or credentials. The backup
        // and settings are user-only; no widening of the existing access.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
