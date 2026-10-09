# Reproductions du contre-audit de la PR #8

Voir le [bilan de contre-audit](../../../REVIEW-2026-10-08-counteraudit.md) et
les [fiches A04/A18–A22](../../../AUDIT-2026-10-08-robustesse-simplicite.md).
Code produit testé : `a1c7d6999d6921906f26c405fc4f48e7bde30e91` ; première PR
relue : `910836add0e179a832f1a2bb751c24d8ac11eacc`.
[validation.json](validation.json) contient les sorties synthétiques conservées.

Les scripts ci-dessous **reproduisent les défauts de cette base**. Certains exigent
que le défaut existe pour sortir à zéro : ce ne sont pas les futurs tests de
non-régression des correctifs. Après correction, adapter leurs attentes et vérifier
le sabotage causal. Les copies de contrôle ne modifient jamais le produit du dépôt.

## Rejouer

Depuis la racine du checkout de la PR, macOS/Xcode/Swift/Python disponibles.
Réutiliser un build Core natif existant ou le construire avant les probes :

```sh
swift build --package-path AtollCore --build-system native
atoll_counter_build="$(swift build --package-path AtollCore --build-system native --show-bin-path)"
atoll_counter_output="$(mktemp -d -t atoll-counteraudit)"

python3 docs/audits/2026-10-08/counteraudit/memory/probe-memory.py --repo . --build-dir "$atoll_counter_build" --output "$atoll_counter_output/memory"
python3 docs/audits/2026-10-08/counteraudit/archive/run.py . --build-dir "$atoll_counter_build"
python3 docs/audits/2026-10-08/counteraudit/catalog/run.py . --build-dir "$atoll_counter_build"
python3 docs/audits/2026-10-08/counteraudit/codex-stdout/run.py . "$atoll_counter_build"
python3 docs/audits/2026-10-08/counteraudit/harness/probe-harness-drift.py .
```

Exécuter séquentiellement : le dernier runner reconstruit le package si nécessaire.
Les autres lient les objets existants. Les sources Swift générées, bases et logs
restent temporaires/hors dépôt ; aucun home personnel ou CLI authentifié n'est utilisé.
Le probe mémoire exige un compte non root pour son refus de lecture chmod 000 ;
il rétablit les permissions de sa seule fixture. Le bridge fermé provoque volontairement
l'abort d'un exécutable synthétique ; il n'utilise pas le socket Atoll de production.

| Dossier | Méthode de preuve | Contrôles |
|---|---|---|
| `memory` | MemoryIndexWorker source intacte, BridgePaths privé | Accès réellement refusé ; mtime seul modifié ; réduction non vide ; disparition réellement marquée missing |
| `archive` | LearnedSkillStore réel avec archive inaccessible | Archive normale conservant une copie de la ressource ajoutée |
| `catalog` | Méthodes de CodexCatalogSection extraites, State partagé contrôlé, parseur réel | Contexte inchangé ; changement home en vol rejeté. Pas de rendu SwiftUI |
| `codex-stdout` | CodexBridge source entière, socket/process/sound simulés, vrai pipe | Lecteur ouvert ; copie temporaire réutilisant le writer Claude existant ; JSON nominal identique |
| `harness` | Cinq exécutions de copies de test-codex-exec, offline seulement | Nominal original échoué ; faux PASS sans mutation ; argv de fixture actualisés → nominal et vrai sabotage réussis |

Le probe mémoire rapporte les observations ; les quatre autres familles vérifient
leurs observations attendues sur cette base. Les stderr détaillés/chemins de machine
ne sont pas publiés. `catalog` reconstitue explicitement la conservation du State
quand les inputs de la vue changent ; une recette native reste nécessaire au correctif.

## Contrôles supplémentaires

Ces scripts existants ont également été exécutés, avec le helper Debug construit
lors du premier audit. Ils utilisent des racines synthétiques, pas l'app normale :

```sh
python3 Scripts/test-claude-uninstall.py /chemin/du/helper/Debug/atoll-bridge
python3 Scripts/test-release-trash.py
```

Le second crée de petits artefacts de test récupérables dans la corbeille et vérifie
que le nettoyage neutralisé échoue. Aucun artefact de release réel n'est déplacé.
Pas de nouvelle exécution GUI, VoiceOver, appel IA, notarisation ou publication.
