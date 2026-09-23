# Apprentissage — consommation Codex réelle

22 septembre 2026 · complément authentifié de la [validation hors ligne](REVIEW-2026-09-22-learning-efficiency.md).
Mehdi a demandé de valider l’usage réel avant fusion. Code produit `61f2914`,
Codex CLI **0.155.1**, modèle **gpt-5.6-luna**, déjà choisi dans Atoll et vérifié
dans le catalogue natif. Trois appels, aucun nouvel essai après leurs résultats.

**Mesure validée, objectif qualitatif partiellement atteint.** Les compteurs
d’entrée, de sortie, de cache lu et de raisonnement correspondent au parseur
d’Atoll et sont conservés par son vrai journal.
Le générateur s’abstient sur le cas banal ; le cas positif ne produit pas le
skill attendu. Ce résultat reste un échec du benchmark, sans changement de son attente.

## Résultats observés

| Cas synthétique | Caractères fournis | Tokens d’entrée | Tokens de sortie | Durée CLI | Résultat |
|---|---:|---:|---:|---:|---|
| Contrat minimal | 234 | 13 397 | 58 | 4,89 s | Schéma accepté, `ok=true`, isolation vérifiée |
| Renommage banal | 4 095 | 14 330 | 119 | 9,02 s | Aucune note ni skill, comme attendu |
| Procédure d’export vérifiée | 4 562 | 14 658 | 840 | 43,78 s | Trois notes, aucun skill ; le test en attendait un |

Total observé : **42 385 tokens d’entrée, 1 017 de sortie, 57,70 secondes**.
Cache lu annoncé : zéro pour chaque appel. Le champ natif supplémentaire
`cache_write_input_tokens`, également nul dans les trois captures, reste archivé
dans les preuves ; il n’est pas représenté dans `AnalysisUsage`. Les champs de cache et de raisonnement
ne sont pas ajoutés aux totaux. Aucune conversion en dollars ou économie projetée.
Les [mesures et sorties synthétiques](audit-support/2026-09-22-learning-live/summary.json)
sont archivées avec les [preuves du journal](audit-support/2026-09-22-learning-live/journal-replay.json).

La très courte consigne du premier appel suffit à constater un contexte d’entrée
important fourni par le CLI. La capture ne distingue pas ses instructions natives,
définitions d’outils, schéma et éventuels éléments globaux. Elle ne prouve pas que
les skills personnels en sont la cause. `--ignore-user-config` n’exclut pas à lui
seul toutes les instructions ou skills globaux.

Complément ultérieur : une [capture locale sans génération](REVIEW-2026-09-22-codex-context.md)
identifie les blocs ajoutés par le CLI et vérifie le retrait du catalogue de skills
avec une option de processus. Elle ne décompose pas les tokens natifs ci-dessus.

## Limite qualitative constatée

La fixture positive contient une transformation inhabituelle et vérifiée,
une commande, un test numérique, des invariants et aucun skill équivalent.
Le [rapport rendu](audit-support/2026-09-22-learning-live/operational.json) conserve
la transformation et les invariants, répartis dans trois notes. Il omet :

- `exporter --space target --unit m` ;
- le contrôle `(100,200,300) → (-2,3,1)` ;
- les 40 points aller-retour et l’erreur maximale de `0.000001 cm`.

Le contrat permet **0 à 2 skills** : zéro n’est pas une erreur de protocole.
Le parsing réussit et aucun skill n’est rejeté pour longueur. L’attente d’un skill
est un objectif qualitatif du benchmark. Une seule réponse ne permet pas de conclure
à une régression générale, ni de comparer des modèles. La relecture indépendante
confirme cette distinction ; l’assertion reste en échec, sans relance jusqu’au succès.

## Ce qui a réellement été exercé

Les trois appels passent par **CodexRun → CodexExecPlan → codex exec --json**,
avec un home privé et une copie d’authentification en `0600`, supprimés ensuite.
Les données de test fournies explicitement sont synthétiques. Aucun skill n’est installé, aucune app Atoll
n’est lancée ; les trois configurations personnelles contrôlées sont identiques
avant/après. Le watchdog est de 120 secondes par appel et stdout est drainé avec
une rétention maximale de 4 Mio plus un octet témoin.

Les événements d’usage capturés sont ensuite rejoués **sans appel CLI** dans le
vrai `AnalysisBudget`, avec les collaborateurs du harness runtime : égalité des
compteurs, prompt, modèle, rechargement à froid, dépense unique et plafond persisté.
La durée de ce replay est distincte de la durée CLI. Les fixtures du générateur
appellent directement son prompt : elles ne démontrent pas que `LearningGate`
aurait admis leurs sessions. Ce test ne fait pas passer une session interactive réelle dans tout `RetrospectiveRunner` et ne mesure pas
la qualité de ses résumés d’antériorité. Le code produit et ses opt-ins restent ceux
de la PR ; seuls les scripts de recette et la documentation changent ici.

## Rejouer sans dépenser de quota

```sh
python3 Scripts/test-codex-exec.py --prepare-only
python3 Scripts/test-skill-generation.py --prepare-only --output /private/tmp/atoll-generator-prepare
python3 Scripts/test-learning-usage-replay.py \
  docs/audit-support/2026-09-22-learning-live/contract.json \
  docs/audit-support/2026-09-22-learning-live/routine.json \
  docs/audit-support/2026-09-22-learning-live/operational.json \
  --output /private/tmp/atoll-live-usage-replay.json
```

Pour une nouvelle recette explicitement demandée, les scripts existants acceptent
`--live --model gpt-5.6-luna`. Le générateur se borne avec `--provider codex` et
`--case routine --case operational`. Son cas positif peut échouer comme ici ;
les rapports et compteurs restent sur disque. Ne pas relancer pour obtenir du vert.

## Conséquence pour la suite

La priorité donnée aux appels évités par la PR reste pertinente : même une analyse
banale a un coût d’entrée visible. Le prochain benchmark devrait comparer la
conservation des preuves et le choix note/skill sur quelques cas identiques,
avant tout changement de prompt ou de modèle. Trois appels ne mesurent ni les
économies de la PR dans la durée, ni le temps humain de revue, ni la réutilisation
future des connaissances proposées.
