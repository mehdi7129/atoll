# A22 — rendre le verdict du harness Codex fiable

Correctif du premier jalon de la [PR d'audit #8](https://github.com/mehdi7129/atoll/pull/8),
préparé le 8 octobre 2026 depuis `a1c7d69`. Les changements concernent uniquement
les tests hors ligne ; aucun code de l'app n'est modifié.

## Défaut et correction

Le faux `app-server` attendait encore l'ancien argv, sans
`-c features.plugins=false`. La préparation réelle échouait donc avant de
vérifier les instructions. Le mode sabotage acceptait cette même erreur
générique : même un sabotage neutralisé pouvait être annoncé comme détecté.

Le faux CLI exige maintenant les arguments du transport courant. Le harness
compile et réussit le nominal avant de produire le mutant. Celui-ci omet le
bloc écriture et permissions des instructions : garder le `chmod` d'un fichier
absent provoquerait une erreur de préparation, sans atteindre le garde testé.
Le verdict exige simultanément une sortie 1, le diagnostic exact sur les
instructions et l'absence de lancement `exec`. Une compilation ratée ne peut
pas valider le sabotage.

## Vérifications du 8 octobre

- Préparation réelle hors ligne : réussie, après reproduction de son échec sur
  le code initial. Quoting, modèle choisi, fichiers privés, isolation et
  nettoyage restent exercés par le harness existant.
- Sabotage compilé : le fichier absent est détecté avant lancement.
- Cinq contre-épreuves compilées : vrai sabotage accepté ; sabotage neutralisé,
  catalogue nominal invalide, catalogue mutant invalide et compilation mutante
  ratée tous refusés.
- Relecture ciblée du diff et de sa relation avec `CodexRun.prepare` et
  `CodexReadClient` ; couverture déclarée comme balayage, pas lecture intégrale
  des consommateurs.

Commandes reproductibles depuis la racine :

```sh
python3 Scripts/test-codex-exec.py --prepare-only
python3 Scripts/test-codex-exec.py --prepare-only --sabotage-instructions-file
python3 Scripts/test-codex-exec-verdict.py
python3 Scripts/check-docs.py --no-tests
git diff --check
```

Seuls des CLI factices sont lancés. Aucun appel modèle, aucune authentification
copiée, aucune modification de configuration personnelle. Le mode `--live`
existant n'est pas qualifié par cette recette hors ligne.
