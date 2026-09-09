import Foundation
import AtollCore
import os

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "codex-scan")

/// Retrouve les sessions Codex vivantes qu'Atoll n'a pas vues démarrer.
///
/// Pendant du repli par scan de processus côté Claude, et gouverné par la même
/// prudence : les HOOKS font autorité, ce scan ne fait que combler le trou du
/// démarrage. Un redémarrage d'Atoll — mise à jour, plantage, reboot — laissait
/// sinon les sessions Codex ouvertes invisibles jusqu'au prochain prompt.
enum CodexSessionScanner {

    /// Coût mesuré : on ne lit qu'UNE ligne par rollout (la `session_meta`, qui
    /// est la première), et seulement pour les fichiers du jour et de la veille.
    private static let recentDays = 2

    /// `known` = les sessions déjà connues par les hooks, qui font autorité.
    static func scan(known: Set<String>, now: Date = Date()) -> [CodexSessionDiscovery.Discovered] {
        let processes = ProcessInspector.allCodexPids().compactMap { pid -> CodexSessionDiscovery.RunningProcess? in
            guard let cwd = ProcessInspector.currentWorkingDirectory(of: pid) else { return nil }
            return .init(pid: pid, cwd: cwd)
        }
        // Aucun processus vivant ⇒ rien à découvrir, et surtout rien à lire :
        // on n'ouvre aucun fichier pour rien.
        guard !processes.isEmpty else { return [] }

        let rollouts = recentRollouts(now: now)
        let found = CodexSessionDiscovery.discover(processes: processes, rollouts: rollouts,
                                                   known: known, now: now)
        if !found.isEmpty {
            log.info("scan Codex : \(found.count) session(s) retrouvée(s) sans hook")
        }
        return found
    }

    /// Rollouts des derniers jours, avec leur `cwd` lu dans la première ligne.
    private static func recentRollouts(now: Date) -> [CodexSessionDiscovery.Rollout] {
        let fm = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var result: [CodexSessionDiscovery.Rollout] = []

        for offset in 0..<recentDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day
            else { continue }
            let directory = BridgePaths.codexSessionsURL
                .appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, dayOfMonth))
            guard let files = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard let cwd = firstLineCwd(of: file) else { continue }
                result.append(.init(path: file.path,
                                    sessionID: CodexRollout.sessionID(fromFileName: file.lastPathComponent),
                                    cwd: cwd, modifiedAt: modified))
            }
        }
        return result
    }

    /// Le `cwd` vit dans la ligne `session_meta`, qui est la PREMIÈRE. On ne lit
    /// donc qu'un en-tête, jamais le fichier entier — un rollout peut peser
    /// plusieurs mégaoctets et ce scan tourne périodiquement.
    private static func firstLineCwd(of url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024), !head.isEmpty else { return nil }
        guard let newline = head.firstIndex(of: 0x0A) else { return nil }
        return CodexTranscriptParser.parse(Data(head[..<newline]))?.cwd
    }
}
