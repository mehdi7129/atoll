import Foundation

/// Une invocation de skill relevée dans un transcript : l'identité du bloc
/// `tool_use` (`toolUseID`, clé de dédup de la table `skill_usage`), le nom du
/// skill, et le contexte de la ligne porteuse (session, horodatage) quand il
/// est lisible.
public struct SkillInvocation: Equatable, Sendable {
    /// `id` du bloc tool_use (`toolu_…`) — l'identité stable d'une invocation,
    /// clé de dédup de `MemoryIndex.recordSkillUsage`. Chaîne vide si le
    /// transcript n'en porte pas (l'invocation devient alors non enregistrable :
    /// sans identité, pas de dédup possible au rejeu).
    public let toolUseID: String
    /// Nom du skill invoqué (`input.skill`) — jamais vide (garanti par le parseur).
    public let skill: String
    /// `sessionId` de la ligne (graphie camelCase prioritaire, `session_id` en repli).
    public let sessionID: String?
    /// `timestamp` ISO-8601 de la ligne ; nil si absent ou illisible.
    public let timestamp: Date?

    public init(toolUseID: String, skill: String, sessionID: String?, timestamp: Date?) {
        self.toolUseID = toolUseID
        self.skill = skill
        self.sessionID = sessionID
        self.timestamp = timestamp
    }
}

/// Extracteur défensif des invocations de skills dans UNE ligne de transcript
/// JSONL Claude Code (sans le `\n` final) — la matière première des statistiques
/// d'usage (table `skill_usage` de `MemoryIndex`, Phase 7c : mesurer quels
/// skills servent vraiment, éclairer la revue approuver/archiver).
///
/// Format VÉRIFIÉ sur transcript réel : ligne `type == "assistant"` dont
/// `message.content[]` contient des blocs
/// `{type:"tool_use", id:"toolu_…", name:"Skill", input:{skill:"<nom>", args:"…"}}` ;
/// `input.skill` est le nom du skill invoqué.
///
/// Le format des transcripts est officiellement interne et instable (règle
/// projet n° 3) : parsing 100 % défensif, rien ici ne plante jamais —
/// - JSON invalide, non-objet, `type` ≠ "assistant" → `[]` ;
/// - `message` ou `content` absent ou d'un autre type (String directe…) → `[]` ;
/// - bloc non-dictionnaire, non `tool_use`, `name` ≠ "Skill", ou sans
///   `input.skill` String non vide → le bloc est ignoré, les autres survivent ;
/// - `id` absent → `toolUseID` vide (le bloc est rendu quand même : l'appelant
///   décide, `recordSkillUsage` l'écartera faute d'identité).
public enum SkillUsageParser {

    /// Garde-fou mémoire, aligné sur `TranscriptLineParser` : une « ligne »
    /// plus grosse est forcément un blob — on refuse même de la désérialiser.
    private static let maxLineBytes = 8 * 1024 * 1024

    /// Extrait les invocations de skills d'une ligne JSONL. `[]` = rien à
    /// relever (ligne non assistant, JSON illisible…) — jamais une erreur.
    public static func invocations(inLine line: Data) -> [SkillInvocation] {
        guard line.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line),
              let dict = object as? [String: Any],
              dict["type"] as? String == "assistant",
              let message = dict["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return [] }

        // Contexte de la ligne, partagé par tous ses blocs.
        let sessionID = (dict["sessionId"] as? String) ?? (dict["session_id"] as? String)
        let timestamp = (dict["timestamp"] as? String).flatMap(parseISO8601)

        var invocations: [SkillInvocation] = []
        for case let block as [String: Any] in content {
            guard block["type"] as? String == "tool_use",
                  block["name"] as? String == "Skill",
                  let input = block["input"] as? [String: Any],
                  let skill = input["skill"] as? String,
                  !skill.isEmpty
            else { continue }
            invocations.append(SkillInvocation(
                toolUseID: block["id"] as? String ?? "",
                skill: skill,
                sessionID: sessionID,
                timestamp: timestamp
            ))
        }
        return invocations
    }

    /// ISO-8601 avec fractions de seconde (« 2026-07-19T15:07:03.869Z ») d'abord —
    /// la forme émise par le CLI — puis sans, en repli. Illisible → nil, jamais
    /// une erreur (les stats savent vivre sans date).
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractions.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
