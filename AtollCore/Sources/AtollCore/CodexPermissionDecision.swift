import Foundation

/// Décision d'autorisation pour un hook `PermissionRequest` **Codex**.
///
/// ⚠️ DÉLIBÉRÉMENT DISTINCT de `PermissionDecision` (Claude), malgré des formes
/// qui se ressemblent aujourd'hui. C'est Codex lui-même qui l'a demandé, en
/// relisant son propre contrat : « l'isolation fournisseur qui a protégé les
/// événements doit aussi protéger les décisions ». Les deux protocoles peuvent
/// diverger à toute version, et une réponse Claude honorée par Codex — ou
/// l'inverse — serait une faute de sûreté, pas un détail de style.
///
/// ⚠️ LE HELPER NE RELAIE JAMAIS LES OCTETS DE L'APP. Il décode puis
/// RÉ-ENCODE via ce type. La raison est mesurée dans le contrat officiel :
/// renvoyer `updatedInput`, `updatedPermissions` ou `interrupt` sur un
/// `PermissionRequest` Codex **refuse la requête** — ce n'est pas « réponse
/// invalide puis invite native », c'est un refus par sécurité. Un octet
/// inattendu venant d'une version future d'Atoll bloquerait donc le travail de
/// l'utilisateur au lieu de lui rendre la main.
///
/// Toute forme inconnue, incomplète ou surdimensionnée devient une ABSTENTION —
/// et une abstention, côté helper, s'écrit « exit 0, stdout vide ». C'est le
/// seul chemin qui rend la main à l'approbation native de Codex.
public enum CodexPermissionDecision: Equatable, Sendable {
    case allow
    case deny(message: String?)

    /// Borne du message de refus. Le contrat ne promet rien au-delà, et un
    /// helper n'a pas à pousser un texte arbitraire dans le flux du CLI.
    public static let messageCap = 500

    /// Taille maximale acceptée pour la réponse de l'app. Au-delà, abstention :
    /// une réponse énorme est un bug ou une version qu'on ne comprend pas.
    public static let payloadCap = 64 * 1024

    // MARK: - Sortie (helper → Codex)

    /// Le JSON EXACT que le hook écrit sur stdout. L'allowlist est ici, et
    /// nulle part ailleurs : `hookEventName`, `behavior`, et `message`
    /// uniquement sur un refus. Aucune autre clé n'est jamais émise.
    public func hookOutput() -> Data? {
        var decision: [String: Any] = [:]
        switch self {
        case .allow:
            decision["behavior"] = "allow"
        case .deny(let message):
            decision["behavior"] = "deny"
            if let message, !message.isEmpty {
                decision["message"] = String(message.prefix(Self.messageCap))
            }
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: payload,
                                           options: [.withoutEscapingSlashes])
    }

    // MARK: - Entrée (app → helper)

    /// Décode ce que l'app a renvoyé sur le socket. `nil` = ABSTENTION, et il
    /// faut le lire comme un succès : le helper sortira en 0 sans rien écrire,
    /// et Codex affichera son invite native.
    ///
    /// Volontairement STRICT. On n'accepte que les deux formes attendues, et on
    /// ignore tout le reste — y compris des clés supplémentaires qu'une future
    /// version d'Atoll pourrait ajouter innocemment et qui, relayées telles
    /// quelles, feraient REFUSER l'action de l'utilisateur.
    public static func decode(_ data: Data?) -> CodexPermissionDecision? {
        guard let data, !data.isEmpty, data.count <= payloadCap,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // Deux enveloppes acceptées : celle du hook (telle qu'on l'émet) et la
        // forme nue `{"behavior": …}`, pour que l'app n'ait pas à connaître le
        // détail du protocole.
        let decision: [String: Any]
        if let output = root["hookSpecificOutput"] as? [String: Any] {
            guard output["hookEventName"] as? String == "PermissionRequest",
                  let nested = output["decision"] as? [String: Any] else { return nil }
            decision = nested
        } else if root["behavior"] != nil {
            decision = root
        } else {
            return nil
        }

        // Les trois champs RÉSERVÉS font refuser la requête s'ils atteignent
        // Codex. Leur présence ici trahit une réponse qu'on ne comprend pas :
        // on s'abstient plutôt que de deviner.
        for reserved in ["updatedInput", "updatedPermissions", "interrupt"]
        where decision[reserved] != nil || root[reserved] != nil {
            return nil
        }

        switch decision["behavior"] as? String {
        case "allow":
            return .allow
        case "deny":
            let message = (decision["message"] as? String).map {
                String($0.prefix(messageCap))
            }
            return .deny(message: message)
        default:
            return nil
        }
    }
}
