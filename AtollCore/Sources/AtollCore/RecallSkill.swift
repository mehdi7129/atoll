import Foundation

/// Le skill « atoll-recall » : contenu EXACT du `SKILL.md` que l'app installe
/// dans `~/.claude/skills/atoll-recall/`.
///
/// Pattern du repo (cf. `StatusLineEditor`) : tout contenu généré puis écrit
/// sur disque vit dans AtollCore, en constante, pour être testable sans AppKit.
/// Ce markdown est une SPEC VALIDÉE — il enseigne à Claude Code quand et
/// comment interroger l'index mémoire local via `atoll-bridge recall`.
///
/// Invariants à préserver si le texte évolue :
/// - frontmatter YAML `name`/`description` en tête, clos par `---` : le CLI
///   s'en sert pour décider de charger le skill — la description porte les
///   déclencheurs (« on avait dit », « la dernière fois », …), c'est elle qui
///   fait exister le rappel mémoire aux yeux du modèle ;
/// - fail-open explicite : index absent ou vide → le skill dit de continuer
///   sans, jamais de blocage (règle n° 1 du projet) ;
/// - la promesse de localité (« aucune donnée ne quitte la machine ») reste
///   écrite noir sur blanc.
public enum RecallSkill {
    /// Markdown intégral, frontmatter compris, terminé par un saut de ligne
    /// (le fichier écrit sur disque doit finir proprement).
    public static let markdown = """
    ---
    name: atoll-recall
    description: Recherche dans la mémoire longue durée de TOUTES les sessions Claude Code passées (tous projets), indexée localement par l'app Atoll. Utiliser dès que l'utilisateur fait référence à une conversation, décision, commande ou solution passée (« on avait dit », « la dernière fois », « retrouve quand », « déjà fait/réglé »), ou pour vérifier si un problème a déjà été résolu dans un autre projet.
    ---

    # Rappel mémoire Atoll

    Atoll indexe en continu les transcripts de `~/.claude/projects/` dans un index
    plein-texte local (aucune donnée ne quitte la machine).

    ## Interroger

    ```sh
    "$HOME/.atoll/bin/atoll-bridge" recall "mots clés" --limit 8
    ```

    Options :
    - `--limit N` — nombre de résultats (défaut 8, max 50)
    - `--project <chemin>` — restreindre à un projet (`--project "$PWD"` pour le projet courant)
    - `--json` — sortie structurée

    Conseils de requête : mots-clés concrets (noms de fichiers, d'outils, messages
    d'erreur, termes techniques) ; `mot*` cherche par préfixe ; accents ignorés.
    Peu de résultats pertinents ? Reformuler avec des synonymes ou élargir.

    ## Lire les résultats

    Chaque résultat donne : date, projet, titre de session, rôle (user/assistant/
    thinking/tool/résumé), extrait avec les termes en «…», et l'identifiant de
    session. Citer la date et le projet dans la réponse. Si le contexte complet est
    nécessaire, proposer : `claude --resume <session-id>` (depuis le bon dossier).

    ## Si la mémoire est indisponible

    Sortie vide ou message « Aucun index mémoire » : l'app Atoll n'a pas (encore)
    construit l'index. Le dire simplement et continuer sans — ne jamais bloquer.

    """
}
