import Foundation

/// Parse une ligne de rollout Codex (`~/.codex/sessions/**/*.jsonl`) vers le
/// MÊME `TranscriptLine` que le parseur Claude Code.
///
/// POURQUOI CE TYPE PIVOT PLUTÔT QU'UN CHEMIN PARALLÈLE. En normalisant à
/// l'entrée, `MemoryIndex` indexe et `TranscriptDigest` condense **sans une
/// ligne de changement**. Un second chemin d'indexation aurait dupliqué les
/// bornes, l'anti-injection et la déduplication — c'est-à-dire tout ce qui
/// protège la mémoire — et les aurait laissés diverger.
///
/// ⚠️ RÈGLE N° 3 DU PROJET : ce format est interne à Codex et instable. Parsing
/// DÉFENSIF uniquement — toute ligne inattendue rend `nil`, jamais une erreur.
///
/// TROIS PIÈGES, mesurés sur des rollouts réels le 2026-09-09 :
///
/// 1. **`event_msg` DUPLIQUE `response_item`.** Un `item_completed` reporte le
///    contenu du message qu'un `response_item` porte déjà. Tout indexer, c'est
///    indexer deux fois la même conversation — et fausser d'autant le recall.
///    On ne lit donc QUE `response_item`, plus `session_meta` pour le contexte.
/// 2. **`reasoning.encrypted_content` est du chiffré**, une longue chaîne
///    base64. L'indexer remplirait la base de bruit illisible et pèserait sur
///    chaque recherche. Seul `summary`, quand il est non vide, est du texte.
/// 3. **`role: "developer"` n'est pas une conversation** : ce sont les
///    instructions système (`<skills_instructions>`, la liste des skills…),
///    identiques d'une session à l'autre. Même raisonnement que l'exclusion des
///    enveloppes `<task-notification>` en v0.16.0, qui pesaient 17 % du corpus
///    `user` pour zéro valeur de rappel.
public enum CodexTranscriptParser {

    /// Enveloppes machine injectées dans un message `user` : ce n'est pas
    /// l'utilisateur qui parle, c'est le client qui se décrit. Heuristique
    /// textuelle ancrée, vérifiée sur les rollouts : leurs `UserMessage`
    /// miroirs existent aussi pour ces enveloppes et ne les distinguent pas.
    /// ⚠️ `<recommended_plugins>` A ÉTÉ AJOUTÉ APRÈS COUP, sur constat de Codex
    /// qui a compté **5 enveloppes** de ce type indexées comme paroles de
    /// l'utilisateur dans les rollouts de cette machine — avec
    /// l'`environment_context` concaténé à la suite dans le même message.
    /// Preuve, s'il en fallait, qu'une liste de préfixes se vérifie sur le
    /// corpus RÉEL et pas sur ce qu'on croit connaître du format.
    private static let machineEnvelopePrefixes = [
        "<environment_context>", "<skills_instructions>", "<user_instructions>",
        "<plan_mode>", "<system-reminder>", "<recommended_plugins>",
        "<task-notification>", "<realtime_delegation>",
    ]

    /// `nil` = ligne sans substance indexable (ou illisible). Jamais d'erreur :
    /// une ligne inconnue ne doit pas interrompre l'ingestion.
    public static func parse(_ data: Data) -> TranscriptLine? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        let kind = root["type"] as? String

        switch kind {
        case "compacted":
            // Les 18 captures locales du 10/09 ont message vide et un bloc
            // compaction chiffré dans replacement_history. Ne pas réindexer
            // cet historique (doublons), ni inventer un résumé en clair.
            guard let text = payload["message"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptLine(uuid: payload["compaction_response_id"] as? String,
                sessionID: nil, timestamp: timestamp(root["timestamp"]), cwd: nil, gitBranch: nil,
                fragments: [.init(role: .summary, text: text)])
        case "session_meta":
            // Aucun fragment : cette ligne porte le CONTEXTE (session, dossier),
            // que l'ingestion attache aux suivantes.
            return TranscriptLine(
                uuid: payload["id"] as? String,
                sessionID: payload["session_id"] as? String,
                timestamp: timestamp(payload["timestamp"]),
                cwd: payload["cwd"] as? String,
                gitBranch: branch(from: payload["git"]),
                fragments: [])
        case "response_item":
            guard let fragments = fragments(of: payload), !fragments.isEmpty else { return nil }
            // ⚠️ L'HORODATAGE EST SUR L'ENVELOPPE, pas dans le payload. L'oublier
            // fait afficher « date inconnue » sur CHAQUE extrait Codex du
            // recall — la récence entre alors dans le classement à l'aveugle,
            // alors que `MemoryRanking` la pondère à 0,25.
            return TranscriptLine(
                uuid: payload["id"] as? String, sessionID: nil,
                timestamp: timestamp(root["timestamp"]),
                cwd: nil, gitBranch: nil, fragments: fragments)
        default:
            // `event_msg`, `token_usage_record`, `world_state`, `turn_context` :
            // doublons ou télémétrie. Voir le piège n° 1.
            return nil
        }
    }

    private static func fragments(of payload: [String: Any]) -> [TranscriptLine.Fragment]? {
        switch payload["type"] as? String {
        case "message":
            guard let role = payload["role"] as? String else { return nil }
            // `developer` = instructions système, jamais une conversation.
            guard role == "user" || role == "assistant" else { return nil }
            let text = joinedText(payload["content"])
            guard !text.isEmpty else { return nil }
            if role == "user" { return classifiedUserText(text) }
            return [.init(role: role == "user" ? .user : .assistant, text: text)]

        case "custom_tool_call", "function_call":
            let name = (payload["name"] as? String) ?? "outil"
            let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
            let summary = input.isEmpty ? name : "\(name) · \(condensed(input))"
            return [.init(role: .tool, text: summary, isError: nil,
                          toolUseID: payload["call_id"] as? String, toolOutcome: .unknown)]

        case "custom_tool_call_output", "function_call_output":
            let text = joinedText(payload["output"])
            guard !text.isEmpty else { return nil }
            // `isError` reste NIL : le rollout ne porte pas de verdict d'échec —
            // `status` décrit l'aboutissement de l'APPEL, pas de la commande.
            // Le deviner en cherchant « error » dans la sortie a été mesuré à
            // 5× trop de faux positifs côté Claude ; on ne recommence pas.
            return [.init(role: .toolResult, text: condensed(text), isError: nil,
                          toolUseID: payload["call_id"] as? String, toolOutcome: .unknown)]

        case "reasoning":
            // JAMAIS `encrypted_content` (piège n° 2) : seul `summary` est du texte.
            let text = joinedText(payload["summary"])
            guard !text.isEmpty else { return nil }
            return [.init(role: .thinking, text: condensed(text, cap: 4_000))]

        default:
            return nil
        }
    }

    /// Concatène les parts textuelles d'un `content` / `output` / `summary`,
    /// qu'il soit une chaîne, une liste de chaînes ou une liste d'objets.
    private static func joinedText(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let parts as [Any]:
            let pieces = parts.compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let object = part as? [String: Any] else { return nil }
                return (object["text"] as? String) ?? (object["content"] as? String)
            }
            return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    /// Contrat ancré : citer AGENTS.md dans une phrase reste une parole humaine.
    /// Une consigne humaine après les balises est conservée séparément.
    public static func classifiedUserText(_ raw: String) -> [TranscriptLine.Fragment] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [TranscriptLine.Fragment] = []
        while !text.isEmpty {
            // Les commandes du client sont trois balises COMPLÈTES, avec le
            // contenu sur la ligne d'ouverture. Une citation incomplète reste
            // humaine ; le texte après l'enveloppe complète aussi.
            if let end = inlineClientEnvelopeEnd(in: text) {
                result.append(.init(role: .instruction, text: String(text[..<end])))
                text = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let close: String?
            if text.hasPrefix("# AGENTS.md instructions for /"),
               let newline = text.firstIndex(of: "\n"),
               text[newline...].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "<INSTRUCTIONS>" {
                close = "</INSTRUCTIONS>"
            } else if let prefix = machineEnvelopePrefixes.first(where: {
                text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) == $0
            }) {
                close = "</" + prefix.dropFirst()
            } else {
                result.append(.init(role: .user, text: text))
                break
            }
            guard let close, let end = closingLine(close, in: text) else {
                // Les deux nouvelles familles exigent leur fermeture. Sans
                // elle, on ne peut pas séparer une notification d'une citation.
                let requiresClosing = text.hasPrefix("<task-notification>") || text.hasPrefix("<realtime_delegation>")
                result.append(.init(role: requiresClosing ? .user : .instruction, text: text))
                break
            }
            result.append(.init(role: .instruction, text: String(text[..<end.upperBound])))
            text = text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func inlineClientEnvelopeEnd(in text: String) -> String.Index? {
        let tags: [String]
        if text.hasPrefix("<command-name>") {
            tags = ["command-name", "command-message", "command-args"]
        } else if text.hasPrefix("<local-command-stdout>") {
            tags = ["local-command-stdout"]
        } else { return nil }
        var cursor = text.startIndex
        for tag in tags {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let remainder = String(text[cursor...])
            guard remainder.hasPrefix("<\(tag)>"),
                  let closing = closingLine("</\(tag)>", in: remainder, inline: true) else { return nil }
            cursor = text.index(cursor, offsetBy: remainder.distance(from: remainder.startIndex, to: closing.upperBound))
        }
        return cursor
    }

    private static func closingLine(_ closing: String, in text: String, inline: Bool = false) -> Range<String.Index>? {
        var fence: Character?
        var fenceLength = 0
        var start = text.startIndex
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = line.first, first == "`" || first == "~" {
                let length = line.prefix { $0 == first }.count
                if length >= 3 {
                    if fence == nil { fence = first; fenceLength = length }
                    else if fence == first && length >= fenceLength &&
                            line.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                }
            }
            let end = text.index(start, offsetBy: raw.count)
            if fence == nil, line == closing || (inline && line.hasSuffix(closing)) { return start..<end }
            start = end == text.endIndex ? end : text.index(after: end)
        }
        return nil
    }

    /// Borne un texte comme le fait le parseur Claude : un rollout peut porter
    /// des sorties de plusieurs mégaoctets, et l'index n'a pas à les avaler.
    private static func condensed(_ text: String, cap: Int = 2_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= cap ? trimmed : String(trimmed.prefix(cap)) + "…"
    }

    private static func branch(from git: Any?) -> String? {
        guard let git = git as? [String: Any] else { return nil }
        return (git["branch"] as? String) ?? (git["current_branch"] as? String)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
