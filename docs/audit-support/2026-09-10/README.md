# Contrats natifs et recettes de mise en œuvre

Date : 2026-09-10. CLI vérifié : **codex-cli 0.153.4**, modèle des captures
`gpt-6-astra`. Cette version est une référence testée, pas la preuve d'un
minimum compatible parmi les versions précédentes.

## Captures

Les 28 fichiers `event-*.json` proviennent de sessions **Codex CLI interactives**
de test, dans un projet et un home temporaires. Les commandes Bash, le patch et
le serveur MCP local ne contiennent que des données de recette. Les permissions
ont été refusées volontairement par le hook de capture ; elles ne prouvent pas
qu'un utilisateur a cliqué une carte dans Atoll.

Les identifiants et racines de machine ont été remplacés de façon cohérente.
`_atoll_test_enrich` est ajouté par la capture Atoll : ce n'est **pas** un champ
du payload natif Codex. Son PID a été remplacé par 4242. L'ordre numéroté décrit
l'arrivée observée ; il ne constitue pas une garantie d'ordre des hooks async.

| Pièces | Contrat effectivement observé |
|---|---|
| `permission-bash.json` / événement 04 | Outil `Bash`, objet tool_input avec command et description |
| `permission-apply-patch.json` / événement 08 | Outil apply_patch, patch complet dans tool_input.command |
| Événements 10, 13, 16, 19 | Parent et enfant ont des turn_id différents ; session_id désigne le parent, agent_id l'enfant |
| Événement 13 | SubagentStart : transcript_path de l'enfant |
| Événement 16 | Permission de l'enfant : son tour et son transcript, session_id du parent |
| Événement 19 | SubagentStop : transcript_path du parent, agent_transcript_path de l'enfant |
| `permission-mcp.json` / événement 26 | Nom MCP complet, arguments propres à l'outil, même enveloppe de permission |

La reprise d'un enfant sur un nouveau tour est couverte par des tests synthétiques,
pas par ces captures. Interrupt et compaction ne sont pas ajoutés artificiellement
à ce lot. L'inspection locale a trouvé des compacted.payload.message vides et
un replacement_history opaque : le parser ne prétend pas y lire un résumé.

## Schémas

Les neuf JSON du dossier `schemas/` sont les sorties non modifiées de :

```sh
codex app-server generate-json-schema --out /private/tmp/atoll-codex-schema
```

Sous-ensemble v2 conservé : requêtes/réponses hooks/list, skills/list,
plugin/list et model/list, puis réponse account/rateLimits/read. Ils servent
de référence de protocole ; les fixtures synthétiques et les tests des RPC
réels servent à vérifier les comportements, dont la confiance native.

## Recettes relançables depuis le dépôt

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-runtime.py --sabotage-cancellation
python3 Scripts/test-runtime.py --sabotage-quota-projection
python3 Scripts/test-codex-catalog.py
```

- Core : événements permutés, reprise, tombstones, identité de processus,
  permissions complètes, mémoire/FTS/sauvegarde, destinations et collisions.
- Runtime : compile les vrais runners et le vrai centre de cartes avec des
  collaborateurs contrôlés ; aucun appel IA. Le sabotage travaille sur des
  copies temporaires, jamais sur le code de production.
- Catalogues : véritable CLI, home avec espaces et projet via symlink ; les
  12 hooks générés sont reconnus et restent non approuvés. skills/list et
  plugin/list local sont interrogés sans création de thread ni génération.

Après build, `Scripts/test-codex-install-recall.py <chemin-du-helper>` vérifie
le vrai helper : installation Codex seul deux fois, recall avec les commandes
de reprise Claude/Codex, puis retrait. Il redirige le home Foundation du
processus de test, conserve les hooks étrangers et la mémoire, et ne crée pas
de configuration Claude. Aucun compte n'est nécessaire.

`Scripts/test-codex-exec.py --live` est distinct : **il consomme une génération**
avec la connexion Codex existante. Le test copie la connexion dans son home
privé temporaire et le supprime à la fin ; il ne la journalise pas. Il compile
le vrai CodexRun App et ses résolveurs, valide le modèle et le schéma, puis
vérifie cwd, home après profil, clé API retirée, stdin EOF et marqueur interne.
Il ne démontre pas l'absence de toutes les instructions globales de Codex.

Les résultats et limites GUI sont consignés dans le
[rapport de mise en œuvre](../../IMPLEMENTATION-2026-09-10-codex-claude.md).
Les probes du [9 septembre](../2026-09-09/README.md) décrivent les défauts de
la base auditée ; elles ne sont plus une recette attendue du code corrigé.
