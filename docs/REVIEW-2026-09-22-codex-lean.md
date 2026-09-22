# Analyses Codex : contexte utile et consommation mesurée

22 septembre 2026 · PR #5, sans fusion ni release.

## Résultat réel

Deux nouvelles exécutions authentifiées, mêmes fixtures, prompts métier, schémas,
CLI **0.155.1** et modèle **gpt-5.6-luna** que la
[première recette](REVIEW-2026-09-22-learning-live.md) :

| Cas | Entrée avant | Entrée après | Réduction | Résultat après |
|---|---:|---:|---:|---|
| Tâche banale | 14 330 tokens | 4 576 tokens | 68,1 % | Aucune note ni skill, attendu |
| Procédure réutilisable | 14 658 tokens | 4 900 tokens | 66,6 % | Deux notes, aucun skill ; attente qualitative non atteinte |

**28 988 → 9 476 tokens d’entrée, soit 67,3 % de moins sur ces deux cas.**
Sortie après : 869 tokens au total. Cache lu annoncé : zéro. Les compteurs de cache
et de raisonnement ne sont pas additionnés aux totaux. Aucune conversion monétaire,
extrapolation à tous les projets ou promesse sur le quota de l’abonnement.
Les deux appels ont duré 42,18 secondes au total ; aucun nouvel essai ensuite.

[Résumé des mesures](audit-support/2026-09-22-codex-lean/summary.json),
[cas banal](audit-support/2026-09-22-codex-lean/routine.json),
[cas réutilisable](audit-support/2026-09-22-codex-lean/operational.json).

## Ce qui change

Le profil s’applique aux trois analyses internes utilisant `CodexRun` : bilan,
rangement des notes et recherche de plugins. Aucune session interactive ni
configuration personnelle n’est modifiée.

- Instructions générales de codage remplacées par **475 caractères** : matière
  fournie uniquement, données non fiables, aucun outil ni secret, preuves et JSON.
- Injection automatique du catalogue de skills désactivée ; instructions du
  projet exclues. L’antériorité et le catalogue préparés par Atoll restent entiers.
- Shell, images, questions interactives et recherche web désactivés pour le job.
  La [capture native locale](audit-support/2026-09-22-codex-lean/context.json)
  montre 5 603 caractères de définitions d’outils contre 10 698 auparavant.

Le fichier d’instructions est créé en `0600` dans le dossier privé `0700` du job,
puis supprimé par son nettoyage habituel. Impossible de l’écrire : préparation
refusée avant lancement. Modèle validé, abonnement, stdin fermé, sandbox read-only,
approval never, schéma strict, stdout borné et journal sont conservés.

`promptCharacters` continue de mesurer le prompt métier ; les 475 caractères du
profil et les ajouts natifs ne sont pas inclus. Les tokens proviennent du CLI.

## Vérifications

- **1 071 tests Core**, un skip opt-in, aucun échec ; **60 parcours runtime**.
- Builds Debug et Release réussis ; aucune app lancée ou installée.
- Vrai `CodexRun.prepare` exercé avec CLI factice : choix de modèle, permissions
  des fichiers, chemin contenant espaces/apostrophe/guillemets/Unicode, cleanup.
- Cinq sabotages compilés et détectés : absence d’écriture des instructions,
  retour des instructions natives, des skills, des instructions du projet ou des
  outils inutiles. [Quatre captures natives](audit-support/2026-09-22-codex-lean/context-sabotages.json).
- [Deux usages réels rejoués dans le vrai journal](audit-support/2026-09-22-codex-lean/journal-replay.json),
  persistance à froid et plafond vérifiés sans nouvel appel CLI.
- Relecture indépendante du profil et de sa sonde ; configurations Codex/Claude
  contrôlées identiques avant/après les deux appels.

```sh
swift test --package-path AtollCore --build-system native --jobs 4
python3 Scripts/test-codex-exec.py --prepare-only
python3 Scripts/test-codex-exec.py --prepare-only --sabotage-instructions-file
python3 Scripts/probe-codex-context.py --production-plan --output /private/tmp/atoll-lean-context.json
python3 Scripts/test-runtime.py
```

## Limites conservées

Le benchmark positif échoue toujours : les deux notes conservent transformation,
unités, frontière d’export, identifiants et timestamps, mais omettent la commande,
le test numérique et la précision mesurée. Aucun skill n’est rejeté par le parseur.
L’économie est mesurée ; l’amélioration qualitative n’est pas démontrée. Les appels
synthétiques n’exercent pas toute la chaîne `LearningGate → RetrospectiveRunner`.

Codex garde les wrappers `exec`/`wait` et l’outil imbriqué `apply_patch` : ne pas
annoncer zéro outil. La sandbox et la consigne d’abstention restent nécessaires.
Le CLI charge aussi son `AGENTS.md` global malgré `project_doc_max_bytes=0` ; la
sonde le mesure explicitement. Les essais ont un home privé, le runtime utilise
celui choisi par l’utilisateur. Un contexte global important peut donc encore
augmenter la consommation réelle. Aucun déplacement de credentials ni changement
de home n’a été ajouté au runtime pour contourner cette limite.

Références : [configuration officielle](https://learn.chatgpt.com/docs/config-file/config-reference),
[chargement global dans Codex 0.155.1](https://github.com/openai/codex/blob/rust-v0.155.1/codex-rs/codex-home/src/instructions/mod.rs),
[diagnostic précédent](REVIEW-2026-09-22-codex-context.md).
