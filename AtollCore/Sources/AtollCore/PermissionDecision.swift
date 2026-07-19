import Foundation

/// Construction des décisions renvoyées au hook bloquant `PermissionRequest`.
///
/// Format attendu par le CLI (docs/research/research-followup-gui-answering-mechanics.md,
/// vérifié contre open-vibe-island et la référence officielle des hooks) :
///
/// ```json
/// {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{…}}}
/// ```
///
/// - allow : `{"behavior":"allow"}` (+ updatedInput / updatedPermissions)
/// - deny  : `{"behavior":"deny","message":"…","interrupt":false}`
/// - rendre la main au terminal : PAS de sortie du tout (le helper sort en silence).
public enum PermissionDecision {

    public static func allow() -> Data {
        wrap(["behavior": "allow"])
    }

    public static func deny(message: String, interrupt: Bool = false) -> Data {
        wrap(["behavior": "deny", "message": message, "interrupt": interrupt])
    }

    /// Approbation d'un plan (ExitPlanMode). `acceptEdits` = « approuver et
    /// auto-accepter les éditions » : updatedPermissions avec setMode session.
    public static func approvePlan(acceptEdits: Bool) -> Data {
        var decision: [String: Any] = ["behavior": "allow"]
        if acceptEdits {
            decision["updatedPermissions"] = [
                ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
            ]
        }
        return wrap(decision)
    }

    /// Rejet d'un plan avec feedback : ExitPlanMode est bloqué, Claude reste en
    /// plan mode et révise à partir du message.
    public static func rejectPlan(feedback: String) -> Data {
        deny(message: feedback)
    }

    /// Réponses « par défaut » pour le mode rockstar : la PREMIÈRE option de
    /// chaque question (les modèles listent en général l'option recommandée en
    /// premier). Questions sans option → ignorées (rien à choisir).
    public static func defaultAnswers(for questions: [ParsedHookEvent.AskQuestion]) -> [String: String] {
        var answers: [String: String] = [:]
        for question in questions {
            if let first = question.options.first {
                answers[question.question] = first.label
            }
        }
        return answers
    }

    /// Réponse à AskUserQuestion : allow + updatedInput = tool_input original
    /// (passthrough OBLIGATOIRE de `questions`) + `answers` {question: réponse}.
    /// Réponses multiples jointes par « , » ; texte libre transmis tel quel.
    /// nil si le tool_input original ne peut pas être relu (on rend alors la
    /// main au terminal plutôt que d'envoyer une décision malformée).
    public static func answerQuestions(toolInputData: Data, answers: [String: String]) -> Data? {
        guard var toolInput = (try? JSONSerialization.jsonObject(with: toolInputData)) as? [String: Any],
              toolInput["questions"] != nil
        else { return nil }
        toolInput["answers"] = answers
        var decision: [String: Any] = ["behavior": "allow"]
        decision["updatedInput"] = toolInput
        return wrap(decision)
    }

    // MARK: - Interne

    private static func wrap(_ decision: [String: Any]) -> Data {
        let envelope: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        // Structure construite localement, toujours sérialisable.
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
}
