import Foundation

/// Extraction DÉFENSIVE des derniers échanges d'un transcript JSONL
/// (`~/.claude/projects/…/<session>.jsonl`) pour afficher le contexte d'une
/// conversation reprise dans le chat de l'îlot.
///
/// Le format est officiellement interne et instable (règle projet n° 3) :
/// - lecture PAR LA FIN, fenêtre agrandie tant qu'il manque des échanges (les
///   sessions très outillées noient les prompts sous des tool_result de ~1 Mo ;
///   les fichiers atteignent 88 Mo) — jamais de lecture intégrale ;
/// - tout type de ligne ou champ inconnu est ignoré ;
/// - tout échec rend une liste vide : le chat reste fonctionnel sans historique.
///
/// Réalité du format (vérifiée sur transcripts v2.1.214, ~470 Mo) :
/// - `user.message.content` est polymorphe : String (vrai prompt, ou wrappers
///   `<command-name>`/`<system-reminder>`/… ) OU liste de blocs (quasi toujours
///   des tool_result à ignorer, parfois du texte : interruptions, contenu collé) ;
/// - une réponse assistant est éclatée en PLUSIEURS lignes partageant
///   `message.id`, parfois ENTRELACÉES avec des lignes user tool_result quand
///   Claude appelle plusieurs outils → regrouper par id sans supposer la
///   consécutivité ;
/// - `isSidechain` = sous-agent, `isMeta`/`isCompactSummary`/
///   `isVisibleInTranscriptOnly` = lignes techniques → toutes exclues.
public enum TranscriptHistory {

    public struct HistoryTurn: Equatable, Sendable {
        public enum Role: Equatable, Sendable { case user, assistant }
        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// Chaque message est tronqué pour l'affichage (et la mémoire) — le but
    /// est le CONTEXTE, pas l'archive.
    public static let maxCharactersPerTurn = 2_000

    /// Préfixes de lignes user qui ne sont PAS des messages humains.
    static let nonHumanPrefixes = [
        "<command-name>", "<command-message>", "<local-command-stdout>",
        "<local-command-caveat>", "<system-reminder>", "<task-notification>",
        "[Request interrupted",
    ]

    /// Lit le transcript par fenêtres croissantes jusqu'à obtenir
    /// `minExchanges` prompts utilisateur (ou épuiser le budget d'octets) puis
    /// rend au plus `maxExchanges` échanges (chacun = prompt user + réponses).
    /// À appeler HORS du main thread.
    public static func load(path: String, minExchanges: Int = 6, maxExchanges: Int = 8,
                            byteBudget: Int = 16_777_216) -> [HistoryTurn] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = (try? handle.seekToEnd()).map(Int.init), size > 0 else { return [] }

        var windowBytes = 2_097_152
        var best: [HistoryTurn] = []
        while true {
            let capped = min(windowBytes, min(size, byteBudget))
            let start = size - capped
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let window = try? handle.readToEnd() else { return best }
            let turns = parse(window: window, dropFirstLine: start > 0,
                              maxExchanges: maxExchanges)
            best = turns
            let exchanges = turns.filter { $0.role == .user }.count
            if exchanges >= minExchanges || capped >= min(size, byteBudget) { break }
            windowBytes *= 4
        }
        return best
    }

    /// Cœur testable : parse une fenêtre d'octets NDJSON.
    /// `dropFirstLine` : la fenêtre a commencé au milieu d'une ligne.
    public static func parse(window: Data, dropFirstLine: Bool, maxExchanges: Int) -> [HistoryTurn] {
        var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }

        var turns: [HistoryTurn] = []
        // Regroupement des lignes assistant d'un même message.id, SANS supposer
        // la consécutivité (tool_use parallèles → lignes entrelacées).
        var assistantByID: [String: Int] = [:]      // id → index dans `turns`
        var lastAssistantIndex: Int?                // pour un assistant sans id

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any] else { continue }
            guard (root["isSidechain"] as? Bool) != true,
                  (root["isMeta"] as? Bool) != true,
                  (root["isCompactSummary"] as? Bool) != true,
                  (root["isVisibleInTranscriptOnly"] as? Bool) != true else { continue }
            let message = root["message"] as? [String: Any]

            switch root["type"] as? String {
            case "user":
                guard let text = userText(message) else { continue }
                turns.append(HistoryTurn(role: .user, text: truncate(text)))
                assistantByID.removeAll()  // nouveau prompt : bloc assistant précédent clos
                lastAssistantIndex = nil
            case "assistant":
                guard let message else { continue }
                let fragment = assistantText(message)
                guard !fragment.isEmpty else { continue }
                let id = message["id"] as? String
                // id connu → on complète le tour existant ; sinon nouveau tour
                // (un assistant sans id n'est JAMAIS fusionné avec un autre).
                if let id, let index = assistantByID[id] {
                    turns[index] = HistoryTurn(
                        role: .assistant,
                        text: truncate(untruncate(turns[index].text) + "\n" + fragment))
                } else {
                    turns.append(HistoryTurn(role: .assistant, text: truncate(fragment)))
                    if let id { assistantByID[id] = turns.count - 1 }
                    lastAssistantIndex = turns.count - 1
                }
            default:
                continue  // summary, attachment, mode, types futurs… : ignorés.
            }
        }

        // Garder les `maxExchanges` derniers échanges : couper au 1er prompt
        // user des derniers maxExchanges (chaque échange démarre à un prompt).
        var userSeen = 0
        var cut = turns.startIndex
        for index in turns.indices.reversed() where turns[index].role == .user {
            userSeen += 1
            if userSeen == maxExchanges { cut = index; break }
        }
        return Array(turns[cut...])
    }

    // MARK: - Interne

    /// Texte d'un VRAI message utilisateur, nil pour tout le reste
    /// (tool_results, wrappers de commandes, interruptions). Même filtrage
    /// textuel pour la forme String et la forme liste-de-blocs.
    private static func userText(_ message: [String: Any]?) -> String? {
        guard let content = message?["content"] else { return nil }
        let raw: String
        if let text = content as? String {
            raw = text
        } else if let blocks = content as? [[String: Any]] {
            // Une liste avec un tool_result n'est pas un message humain.
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            raw = joinedTextBlocks(blocks)
        } else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !nonHumanPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        return trimmed
    }

    /// Blocs texte d'une ligne assistant (thinking/tool_use ignorés).
    private static func assistantText(_ message: [String: Any]) -> String {
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return joinedTextBlocks(blocks)
    }

    private static func joinedTextBlocks(_ blocks: [[String: Any]]) -> String {
        blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxCharactersPerTurn else { return text }
        return String(text.prefix(maxCharactersPerTurn)) + "…"
    }

    /// Retire une éventuelle troncature avant de concaténer un fragment (les
    /// fragments d'un même message assistant sont recollés puis re-tronqués).
    private static func untruncate(_ text: String) -> String {
        text.hasSuffix("…") ? String(text.dropLast()) : text
    }
}
