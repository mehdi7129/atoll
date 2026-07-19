import Foundation

/// Extraction DÉFENSIVE des derniers échanges d'un transcript JSONL
/// (`~/.claude/projects/…/<session>.jsonl`) pour afficher le contexte d'une
/// conversation reprise dans le chat de l'îlot.
///
/// Le format est officiellement interne et instable (règle projet n° 3) :
/// - lecture PAR LA FIN, fenêtre bornée (les fichiers atteignent 88 Mo,
///   les lignes 1 Mo) — jamais de lecture intégrale ;
/// - tout type de ligne ou champ inconnu est ignoré ;
/// - tout échec rend une liste vide : le chat reste fonctionnel sans historique.
///
/// Réalité du format (vérifiée sur transcripts v2.1.214) :
/// - `user.message.content` est polymorphe : String (vrai prompt, ou wrappers
///   `<command-name>`/`<system-reminder>`/`<local-command-stdout>`) OU liste de
///   blocs (en pratique quasi toujours des tool_result, à ignorer) ;
/// - une réponse assistant est éclatée en PLUSIEURS lignes (une par bloc
///   thinking/text/tool_use) partageant `message.id` → regrouper ;
/// - `isSidechain == true` = fil de sous-agent, à exclure ;
/// - `isMeta == true` = ligne technique, à exclure.
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

    /// Lit les derniers `maxBytes` du fichier et rend les `maxTurns` derniers
    /// messages réels (ordre chronologique). À appeler HORS du main thread.
    public static func load(path: String, maxTurns: Int = 12,
                            maxBytes: Int = 2_097_152) -> [HistoryTurn] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let window = try? handle.readToEnd() else { return [] }
        return parse(window: window, dropFirstLine: start > 0, maxTurns: maxTurns)
    }

    /// Cœur testable : parse une fenêtre d'octets NDJSON.
    /// `dropFirstLine` : la fenêtre a commencé au milieu d'une ligne.
    public static func parse(window: Data, dropFirstLine: Bool, maxTurns: Int) -> [HistoryTurn] {
        var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }

        var turns: [HistoryTurn] = []
        // Regroupement des lignes assistant consécutives d'un même message.id.
        var pendingAssistantID: String?
        var pendingAssistantText = ""

        func flushAssistant() {
            defer { pendingAssistantID = nil; pendingAssistantText = "" }
            let text = pendingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            turns.append(HistoryTurn(role: .assistant, text: truncate(text)))
        }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any] else { continue }
            guard (root["isSidechain"] as? Bool) != true,
                  (root["isMeta"] as? Bool) != true else { continue }
            let message = root["message"] as? [String: Any]

            switch root["type"] as? String {
            case "user":
                flushAssistant()
                if let text = userText(message) {
                    turns.append(HistoryTurn(role: .user, text: truncate(text)))
                }
            case "assistant":
                guard let message else { continue }
                let id = message["id"] as? String
                if id != pendingAssistantID { flushAssistant() }
                pendingAssistantID = id
                let fragment = assistantText(message)
                if !fragment.isEmpty {
                    pendingAssistantText += pendingAssistantText.isEmpty ? fragment : "\n" + fragment
                }
            default:
                // summary, attachment, mode, file-history-*, types futurs… : ignorés.
                continue
            }
        }
        flushAssistant()
        return Array(turns.suffix(maxTurns))
    }

    // MARK: - Interne

    /// Texte d'un VRAI message utilisateur, nil pour tout le reste
    /// (tool_results, wrappers de commandes, interruptions).
    private static func userText(_ message: [String: Any]?) -> String? {
        guard let content = message?["content"] else { return nil }
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("<command-name>"),
                  !trimmed.hasPrefix("<system-reminder>"),
                  !trimmed.hasPrefix("<local-command-stdout>"),
                  !trimmed.contains("[Request interrupted") else { return nil }
            return trimmed
        }
        if let blocks = content as? [[String: Any]] {
            // Une liste avec un tool_result n'est pas un message humain.
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            let text = joinedTextBlocks(blocks)
            return text.isEmpty ? nil : text
        }
        return nil
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
}
