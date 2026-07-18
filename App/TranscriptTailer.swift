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
    }

    /// Cherche un titre dans la tête du fichier : ligne `ai-title` sinon premier
    /// message utilisateur textuel.
    private func extractTitle(sessionID: String, path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072), !data.isEmpty else { return }

        var firstUserText: String?
        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let line = object as? [String: Any] else { continue }
            let type = line["type"] as? String

            if type == "ai-title", let title = line["title"] as? String, !title.isEmpty {
                onTitle?(sessionID, title)
                return
            }
            if firstUserText == nil, type == "user", (line["isMeta"] as? Bool) != true,
               let message = line["message"] as? [String: Any] {
                if let text = message["content"] as? String {
                    firstUserText = text
                } else if let blocks = message["content"] as? [[String: Any]] {
                    firstUserText = blocks.lazy
                        .filter { ($0["type"] as? String) == "text" }
                        .compactMap { $0["text"] as? String }
                        .first
                }
            }
        }
        if let firstUserText, !firstUserText.isEmpty {
            onTitle?(sessionID, firstUserText)
        }
    }
}
