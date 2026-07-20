import Foundation

/// Parseur défensif d'UNE ligne de transcript JSONL Claude Code (`~/.claude/projects/`),
/// sans le `\n` final. Produit le modèle neutre `TranscriptLine`.
///
/// Le format des transcripts est officiellement interne et instable (règle projet
/// n° 3) : ce parseur ne doit JAMAIS planter ni dépendre d'un champ « garanti ».
/// Tout ce qui n'est pas reconnu s'efface silencieusement — `nil` pour la ligne
/// entière, ou simplement un fragment en moins. Décisions de conception (chacune
/// validée, ne pas « simplifier ») :
///
/// - Ligne > 8 Mo, JSON invalide, pas un objet, `type` absent ou inconnu → `nil`.
/// - Seuls `user`, `assistant`, `summary` et `ai-title` portent de la substance
///   indexable ; TOUS les autres types (`system`, `last-prompt`, `attachment`,
///   `mode`, `permission-mode`, `file-history-*`, `queue-operation`, `progress`,
///   inconnus…) → `nil`.
/// - Une ligne reconnue mais sans fragment retenu renvoie quand même l'enveloppe
///   (`fragments` vide, PAS `nil`) : uuid/cwd/timestamp restent utiles à l'ingestion.
/// - `sessionId` et `session_id` coexistent dans le format réel → les deux graphies
///   sont acceptées, camelCase prioritaire.
/// - Heuristique anti-blob : toute chaîne candidate sans AUCUNE espace et longue de
///   plus de 256 caractères est écartée (base64, data-URI, JSON minifié) — appliquée
///   à chaque chaîne AVANT troncature, y compris à chaque partie d'un tool_result
///   et à chaque valeur d'input d'un tool_use.
/// - Caps de taille (l'index n'a pas besoin de plus) : thinking 4 000, tool_result
///   1 500, valeur d'outil 500, fragment d'outil 2 000 caractères.
/// - Un fragment dont le texte trimé est vide n'est jamais émis ; le texte émis
///   est le texte trimé.
public enum TranscriptLineParser {

    /// Garde-fou mémoire : une « ligne » plus grosse que ça est forcément un blob
    /// (paste géant, image base64) — on refuse même de la désérialiser.
    private static let maxLineBytes = 8 * 1024 * 1024
    /// Au-delà, une chaîne sans espace est considérée opaque (base64, minifié…).
    private static let opaqueLengthThreshold = 256
    private static let thinkingCap = 4_000
    private static let toolResultCap = 1_500
    private static let toolValueCap = 500
    private static let toolFragmentCap = 2_000

    /// Parse une ligne JSONL. `nil` = ligne sans aucun intérêt pour l'index
    /// (bruit technique, type inconnu, JSON illisible) — jamais une erreur.
    public static func parse(_ data: Data) -> TranscriptLine? {
        guard data.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let line = object as? [String: Any],
              let type = line["type"] as? String
        else { return nil }

        let fragments: [TranscriptLine.Fragment]
        switch type {
        case "user":
            fragments = userFragments(line)
        case "assistant":
            fragments = assistantFragments(line)
        case "summary":
            fragments = singleFragment(.summary, line["summary"] as? String)
        case "ai-title":
            // Les deux graphies observées selon les versions du CLI — défensif.
            fragments = singleFragment(.title, (line["aiTitle"] as? String) ?? (line["title"] as? String))
        default:
            return nil
        }

        return TranscriptLine(
            uuid: line["uuid"] as? String,
            sessionID: (line["sessionId"] as? String) ?? (line["session_id"] as? String),
            timestamp: (line["timestamp"] as? String).flatMap(parseISO8601),
            cwd: line["cwd"] as? String,
            gitBranch: line["gitBranch"] as? String,
            fragments: fragments
        )
    }

    // MARK: - Lignes user

    /// `message.content` est SOIT une String, SOIT un tableau de blocs — les deux
    /// formes existent. Blocs retenus : `text` (→ .user) et `tool_result`
    /// (→ .toolResult) ; tout le reste (image…) est ignoré.
    private static func userFragments(_ line: [String: Any]) -> [TranscriptLine.Fragment] {
        // isMeta : lignes fabriquées par le CLI (contexte injecté, slash-commands) —
        // l'enveloppe peut servir, le texte jamais.
        if line["isMeta"] as? Bool == true { return [] }
        guard let message = line["message"] as? [String: Any] else { return [] }

        if let text = message["content"] as? String {
            return userTextFragment(text).map { [$0] } ?? []
        }
        var fragments: [TranscriptLine.Fragment] = []
        for block in dictionaries(message["content"]) {
            switch block["type"] as? String {
            case "text":
                if let fragment = userTextFragment(block["text"] as? String ?? "") {
                    fragments.append(fragment)
                }
            case "tool_result":
                if let fragment = toolResultFragment(block) {
                    fragments.append(fragment)
                }
            default:
                break
            }
        }
        return fragments
    }

    /// Texte tapé par l'utilisateur. Les échos de slash-commands (`<command-…>`,
    /// `<local-command-…>`) sont du bruit machiné, jamais indexés.
    private static func userTextFragment(_ raw: String) -> TranscriptLine.Fragment? {
        guard let text = sanitize(raw) else { return nil }
        if text.hasPrefix("<command-") || text.hasPrefix("<local-command-") { return nil }
        return TranscriptLine.Fragment(role: .user, text: text)
    }

    /// `tool_result.content` : String directe OU tableau de blocs `{type:"text"}`.
    /// Chaque partie passe le filtre anti-blob individuellement (un blob au milieu
    /// ne condamne pas les parties lisibles), puis concaténation cap 1 500.
    private static func toolResultFragment(_ block: [String: Any]) -> TranscriptLine.Fragment? {
        var rawParts: [String] = []
        if let text = block["content"] as? String {
            rawParts.append(text)
        } else {
            for inner in dictionaries(block["content"]) where inner["type"] as? String == "text" {
                if let text = inner["text"] as? String { rawParts.append(text) }
            }
        }
        let parts = rawParts.compactMap(sanitize)
        guard !parts.isEmpty else { return nil }
        let text = String(parts.joined(separator: "\n").prefix(toolResultCap))
        return TranscriptLine.Fragment(role: .toolResult, text: text)
    }

    // MARK: - Lignes assistant

    /// Blocs retenus : `text` (→ .assistant), `thinking` (→ .thinking, cap 4 000),
    /// `tool_use` (→ .tool condensé). Une String directe est tolérée par symétrie
    /// avec user, même si le CLI émet toujours des blocs côté assistant.
    private static func assistantFragments(_ line: [String: Any]) -> [TranscriptLine.Fragment] {
        guard let message = line["message"] as? [String: Any] else { return [] }

        if let text = message["content"] as? String {
            return sanitize(text).map { [TranscriptLine.Fragment(role: .assistant, text: $0)] } ?? []
        }
        var fragments: [TranscriptLine.Fragment] = []
        for block in dictionaries(message["content"]) {
            switch block["type"] as? String {
            case "text":
                if let text = sanitize(block["text"] as? String ?? "") {
                    fragments.append(TranscriptLine.Fragment(role: .assistant, text: text))
                }
            case "thinking":
                // Les « pourquoi » des décisions — précieux, mais parfois énormes.
                if let text = sanitize(block["thinking"] as? String ?? "") {
                    fragments.append(TranscriptLine.Fragment(
                        role: .thinking, text: String(text.prefix(thinkingCap))
                    ))
                }
            case "tool_use":
                if let fragment = toolUseFragment(block) {
                    fragments.append(fragment)
                }
            default:
                break
            }
        }
        return fragments
    }

    /// Invocation d'outil condensée : « nom · v1 v2 … » où v1… sont les valeurs
    /// String de premier niveau de `input` (cap 500 chacune, fragment cap 2 000).
    /// `[String: Any]` n'a pas d'ordre stable → clés triées pour un rendu
    /// déterministe (Equatable, tests, dédup).
    private static func toolUseFragment(_ block: [String: Any]) -> TranscriptLine.Fragment? {
        guard let name = (block["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        let values = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] as? String, let clean = sanitize(value) else { return nil }
            return String(clean.prefix(toolValueCap))
        }
        let text = values.isEmpty ? name : "\(name) · \(values.joined(separator: " "))"
        return TranscriptLine.Fragment(role: .tool, text: String(text.prefix(toolFragmentCap)))
    }

    // MARK: - Aides communes

    /// Fragment unique pour les lignes à champ simple (summary, ai-title).
    private static func singleFragment(_ role: TranscriptLine.Role,
                                       _ raw: String?) -> [TranscriptLine.Fragment] {
        guard let raw, let text = sanitize(raw) else { return [] }
        return [TranscriptLine.Fragment(role: role, text: text)]
    }

    /// Trim + filtre anti-blob. `nil` = chaîne sans valeur indexable : vide une
    /// fois trimée, ou opaque (aucune espace et > 256 caractères — signature des
    /// base64/data-URI/minifiés, qui pollueraient l'index sans rien apporter).
    private static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > opaqueLengthThreshold, !trimmed.contains(" ") { return nil }
        return trimmed
    }

    /// Tableau de dictionnaires, tolérant aux éléments parasites (un élément d'un
    /// autre type ne fait pas perdre les blocs valides).
    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// ISO-8601 avec fractions de seconde (« 2026-07-19T15:07:03.869Z ») d'abord —
    /// la forme émise par le CLI — puis sans, en repli. Illisible → nil, jamais
    /// une erreur (l'ingestion sait vivre sans timestamp).
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractions.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
