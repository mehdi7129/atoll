import Foundation

/// Traduction des deux dépenses d'Atoll vers `codex exec` — la contrepartie de
/// `RetrospectivePrompt.cliArguments` / `NotesCurationPrompt.cliArguments`.
///
/// POURQUOI UN SEUL PLAN POUR LES DEUX JOBS. Le bilan de fin de session et le
/// rangement des notes posent au modèle exactement le même contrat : un texte
/// complet fourni dans le prompt, AUCUN outil à utiliser, et une réponse
/// conforme à un JSON Schema. Seuls le schéma et le prompt changent. Côté
/// Claude ce contrat est écrit deux fois (les deux `cliArguments` ne diffèrent
/// que par le schéma) ; ici il est écrit une fois.
///
/// CE QUI NE SE TRADUIT PAS, ET COMMENT ON S'EN PASSE :
/// - `--tools ""` n'a pas d'équivalent. Le plus proche est le bac à sable
///   `read-only`, qui n'empêche pas le modèle de LIRE mais garantit qu'il
///   n'écrit rien. Le condensé étant déjà dans le prompt, il n'a rien à aller
///   chercher — et `approval_policy=never` garantit qu'il ne restera jamais
///   suspendu à attendre une approbation qu'aucun humain ne verra passer.
/// - `--system-prompt` n'existe pas pour `codex exec` : les instructions
///   système sont concaténées EN TÊTE du prompt utilisateur (`fullPrompt`).
/// - `--max-budget-usd` n'a pas d'équivalent, et n'en a pas besoin : un
///   abonnement ChatGPT ne se facture pas à l'appel. C'est le quota, lu par
///   `CodexAccountClient`, qui borne la dépense — d'où la porte
///   `ProviderFailover` en amont.
/// - `--model` est VOLONTAIREMENT omis : le réglage de modèle d'Atoll nomme des
///   modèles Anthropic (`haiku`, `sonnet`…) qui ne veulent rien dire pour
///   Codex. Passer un nom inconnu ferait échouer le run ; on laisse donc le
///   défaut du compte, qui est le choix de l'utilisateur.
public enum CodexExecPlan {

    /// ⚠️ PIÈGE MESURÉ LE 2026-09-06, et il coûte dix minutes par run. `codex
    /// exec` LIT STDIN même quand le prompt est passé en argument : si stdin
    /// n'est ni un TTY ni fermé, il imprime « Reading additional input from
    /// stdin... » et attend EOF — soit, depuis Atoll, jusqu'au watchdog de
    /// 600 s. Les deux lanceurs posent bien `standardInput = .nullDevice` ; ne
    /// JAMAIS le retirer en croyant que « le prompt est déjà en argument ».
    /// (C'est documenté par le CLI, à l'envers : « if stdin is piped and a
    /// prompt is also provided, stdin is appended as a `<stdin>` block ».)
    ///
    /// Arguments de `codex exec`. `schemaPath` et `outputPath` sont des fichiers
    /// qu'Atoll crée lui-même : Codex rend son dernier message DANS un fichier
    /// (`--output-last-message`), là où Claude l'imprime sur stdout. C'est la
    /// différence de forme la plus importante entre les deux chemins.
    public static func arguments(schemaPath: String, outputPath: String,
                                 workingDirectory: String?) -> [String] {
        var arguments = [
            "exec",
            // Aucune session persistée : pas de transcript Codex à indexer, pas
            // de reprise possible — le pendant de `--no-session-persistence`.
            "--ephemeral",
            // Le job ne doit RIEN écrire. Atoll écrit lui-même ses fichiers,
            // dans des répertoires bornés, après revalidation.
            "--sandbox", "read-only",
            // Sans ça, une demande d'approbation suspendrait le process jusqu'au
            // watchdog : il n'y a personne pour répondre.
            "-c", "approval_policy=\"never\"",
            // Ni AGENTS.md du dépôt ni config personnelle : le prompt doit être
            // la seule instruction, comme `--setting-sources ""` côté Claude.
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--output-schema", schemaPath,
            "--output-last-message", outputPath,
        ]
        if let workingDirectory, !workingDirectory.isEmpty {
            arguments += ["--cd", workingDirectory]
        }
        return arguments
    }

    // MARK: - Schéma

    /// Traduit un JSON Schema écrit pour Anthropic vers ce qu'OpenAI accepte en
    /// sortie structurée stricte.
    ///
    /// ⚠️ MESURÉ LE 2026-09-07, ET C'ÉTAIT BLOQUANT. Le schéma du bilan, envoyé
    /// tel quel, a été REFUSÉ par l'API : « 'required' is required to be
    /// supplied and to be an array including every key in properties. Missing
    /// 'confidence'. » — HTTP 400, `invalid_json_schema`, aucun fichier produit.
    /// Anthropic tolère un `required` partiel ; OpenAI l'interdit. Le lot de
    /// bascule ne pouvait donc RIEN produire avant ce correctif, et aucun test
    /// unitaire ne l'aurait dit : il fallait le vrai appel.
    ///
    /// Trois transformations, toutes exigées par le mode strict :
    /// 1. `required` liste TOUTES les clés de `properties` ;
    /// 2. une clé qui n'était pas requise devient NULLABLE (`["string","null"]`)
    ///    — sinon on forcerait le modèle à remplir `similar_existing`, c'est-à-dire
    ///    à INVENTER une capacité existante que sa proposition recouperait, ce
    ///    qui est exactement ce que l'antériorité sert à éviter ;
    /// 3. les mots-clés de validation non supportés (`pattern`, `maxLength`,
    ///    `maxItems`…) sont retirés.
    ///
    /// LE POINT 3 EST SANS DANGER, et c'est une propriété du code existant, pas
    /// un pari : `RetrospectiveReport` et `NotesCurationOutput` revalident tout
    /// en Swift — bornes, slugs, énumérations —, « indépendamment du
    /// `--json-schema` du CLI », dit leur commentaire. Le schéma sert à guider
    /// le modèle ; il n'a jamais été ce qui protège Atoll.
    ///
    /// Une seule source de vérité : le schéma Anthropic. Écrire un second
    /// schéma à la main l'aurait fait diverger au premier changement.
    public static func openAISchema(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else { return nil }
        let converted = convert(object)
        guard let out = try? JSONSerialization.data(withJSONObject: converted,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// Mots-clés de validation qu'OpenAI refuse en mode strict. Retirés partout,
    /// y compris là où ils sont inoffensifs : une liste d'exceptions serait un
    /// second endroit à tenir à jour.
    private static let unsupportedKeywords: Set<String> = [
        "pattern", "maxLength", "minLength", "format",
        "maxItems", "minItems", "uniqueItems",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "maxProperties", "minProperties", "default", "examples",
    ]

    /// Un nœud converti s'il est un objet, rendu tel quel sinon.
    private static func converted(_ value: Any) -> Any {
        (value as? [String: Any]).map { convert($0) as Any } ?? value
    }

    private static func convert(_ node: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in node where !unsupportedKeywords.contains(key) {
            switch value {
            case let child as [String: Any]:
                // `converted(_:)` plutôt qu'un `?? $0` : ce dernier compose un
                // `Any?` que Swift coerce implicitement en `Any`, ce qui
                // stockerait un optionnel EMBALLÉ dans le dictionnaire — il
                // ressortirait à l'encodage JSON en tant que tel.
                result[key] = key == "properties"
                    ? child.mapValues(converted)
                    : convert(child)
            case let array as [Any]:
                result[key] = array.map(converted)
            default:
                result[key] = value
            }
        }
        guard let properties = result["properties"] as? [String: Any] else { return result }

        // Les clés absentes de `required` deviennent nullables AVANT d'y être
        // ajoutées : c'est ce qui préserve leur caractère facultatif.
        let previouslyRequired = Set(result["required"] as? [String] ?? [])
        var updated = properties
        for (name, value) in properties where !previouslyRequired.contains(name) {
            guard var field = value as? [String: Any] else { continue }
            field["type"] = nullable(field["type"])
            // Un enum doit accepter `null`, sinon la valeur nullable qu'on vient
            // d'autoriser ne serait valide pour aucune branche.
            if var options = field["enum"] as? [Any] {
                options.append(NSNull())
                field["enum"] = options
            }
            updated[name] = field
        }
        result["properties"] = updated
        result["required"] = properties.keys.sorted()
        return result
    }

    private static func nullable(_ type: Any?) -> Any {
        switch type {
        case let single as String:
            return single == "null" ? single : [single, "null"]
        case let many as [String]:
            return many.contains("null") ? many : many + ["null"]
        default:
            return ["string", "null"]
        }
    }

    /// Instructions système + tâche, dans un seul prompt.
    ///
    /// La séparation est EXPLICITE et nommée : sans elle, un condensé de
    /// transcript collé à la suite d'instructions système se lit comme leur
    /// continuation. Le condensé est déjà annoncé comme des DONNÉES par les
    /// prompts eux-mêmes ; cet en-tête ne fait que ne pas défaire ce travail.
    public static func fullPrompt(system: String, user: String) -> String {
        """
        \(system)

        ---

        \(user)
        """
    }
}
