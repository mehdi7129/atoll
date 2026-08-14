import AtollCore
import Foundation

/// Suivi des transcripts JSONL (~/.claude/projects/…) en lecture seule.
///
/// Deux usages :
/// - détecter l'interruption Échap (« [Request interrupted by user] ») — aucun
///   hook n'existe pour cet événement ;
/// - extraire un titre de session (premier prompt utilisateur).
///
/// Le format est officiellement interne et instable : parsing défensif, jamais
/// une dépendance dure (CLAUDE.md règle 3).
@MainActor
final class TranscriptTailer {
    var onInterrupt: ((String) -> Void)?
    var onTitle: ((String, String) -> Void)?
    /// Le transcript vient d'être écrit → la session travaille (signal temps réel,
    /// utilisé pour les sessions découvertes par scan qui n'ont pas de hooks).
    var onActivity: ((String) -> Void)?
    /// (sessionID, modèle?, branche git?) extraits du transcript.
    var onMeta: ((String, String?, String?) -> Void)?

    private struct Watch {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
        var offset: UInt64
    }

    private var watches: [String: Watch] = [:]
    private let maxWatches = 24

    private static let interruptMarkers = [
        "[Request interrupted by user]",
        "Interrupted by user",
        "\"interrupted\":true",
    ]

    func watch(sessionID: String, path: String) {
        guard watches[sessionID] == nil, watches.count < maxWatches else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Toute écriture = activité (avant même de lire le contenu).
                self?.onActivity?(sessionID)
                self?.drain(sessionID: sessionID, path: path)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        watches[sessionID] = Watch(descriptor: descriptor, source: source, offset: size ?? 0)

        extractTitle(sessionID: sessionID, path: path)
    }

    func stopWatching(_ sessionID: String) {
        watches[sessionID]?.source.cancel()
        watches[sessionID] = nil
    }

    // MARK: - Interne

    private func drain(sessionID: String, path: String) {
        guard var watch = watches[sessionID],
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        // Lecture bornée (main thread) : si le fichier a grossi de plus d'1 Mo
        // d'un coup, on saute à la fin — les marqueurs d'interruption sont
        // toujours dans les dernières lignes.
        let fileSize = (try? handle.seekToEnd()) ?? watch.offset
        if fileSize < watch.offset {
            // Fichier tronqué/réécrit : repartir de zéro.
            watch.offset = 0
        }
        if fileSize - watch.offset > 1_048_576 {
            watch.offset = fileSize > 65_536 ? fileSize - 65_536 : 0
        }
        try? handle.seek(toOffset: watch.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            watches[sessionID] = watch
            return
        }
        watch.offset += UInt64(data.count)
        watches[sessionID] = watch

        // Les marqueurs d'interruption sont de l'ASCII pur : un décodage lossy suffit
        // même si on coupe un caractère multi-octets en bord de lecture.
        let text = String(decoding: data, as: UTF8.self)
        if Self.interruptMarkers.contains(where: { text.contains($0) }) {
            onInterrupt?(sessionID)
        }

        // Rafraîchir branche/modèle si de nouvelles lignes en portent (changement
        // de branche ou de modèle en cours de session). Scan gardé : uniquement
        // si les clés apparaissent dans le nouveau texte.
        if text.contains("gitBranch") || text.contains("\"model\"") {
            var model: String?
            var gitBranch: String?
            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                guard let line = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any] else { continue }
                if let branch = line["gitBranch"] as? String, !branch.isEmpty { gitBranch = branch }
                if let message = line["message"] as? [String: Any], let modelID = message["model"] as? String {
                    model = modelID
                }
            }
            if model != nil || gitBranch != nil {
                onMeta?(sessionID, model, gitBranch)
            }
        }
    }

    /// Cherche un titre dans la tête du fichier : ligne `ai-title` sinon premier
    /// message utilisateur textuel.
    private func extractTitle(sessionID: String, path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072), !data.isEmpty else { return }

        var firstUserText: String?
        var aiTitle: String?
        var model: String?
        var gitBranch: String?
        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let line = object as? [String: Any] else { continue }
            let type = line["type"] as? String

            if gitBranch == nil, let branch = line["gitBranch"] as? String, !branch.isEmpty {
                gitBranch = branch
            }
            if type == "assistant", let message = line["message"] as? [String: Any],
               let modelID = message["model"] as? String {
                model = modelID // le dernier vu = le plus récent
            }
            // `aiTitle` D'ABORD, `title` en repli — les DEUX graphies, comme le
            // fait `TranscriptLineParser` depuis toujours. Ce lecteur-ci ne
            // connaissait que `title`, qui n'existe pas : mesuré sur quatre
            // transcripts réels, 571 lignes `ai-title`, dont 0 portant `title`
            // et 571 portant `aiTitle`. La branche était donc MORTE et TOUTE
            // session retombait sur son premier prompt brut. Le savoir était
            // dans le parseur, pas dans cet appel — le motif du dépôt.
            if aiTitle == nil, type == "ai-title",
               let title = (line["aiTitle"] as? String) ?? (line["title"] as? String),
               !title.isEmpty {
                aiTitle = title
            }
            if firstUserText == nil, type == "user", (line["isMeta"] as? Bool) != true,
               !TranscriptLineParser.isMachineOrigin(line["origin"]),
               let message = line["message"] as? [String: Any] {
                let raw: String?
                if let text = message["content"] as? String {
                    raw = text
                } else if let blocks = message["content"] as? [[String: Any]] {
                    raw = blocks.lazy
                        .filter { ($0["type"] as? String) == "text" }
                        .compactMap { $0["text"] as? String }
                        .first
                } else {
                    raw = nil
                }
                // Mêmes écarts que le parseur : l'écho d'une slash-command et
                // les enveloppes machine ne sont pas un titre. Sans eux, une
                // session ouverte par `/gsd:next` s'intitulait
                // « <command-name>/gsd:next</command-name>… ».
                if let raw, !raw.hasPrefix("<command-"), !raw.hasPrefix("<local-command-") {
                    firstUserText = raw
                }
            }
        }
        if model != nil || gitBranch != nil {
            onMeta?(sessionID, model, gitBranch)
        }
        if let aiTitle {
            onTitle?(sessionID, aiTitle)
        } else if let firstUserText, !firstUserText.isEmpty {
            onTitle?(sessionID, firstUserText)
        }
    }
}
