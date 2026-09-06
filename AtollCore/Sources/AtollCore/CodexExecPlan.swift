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
