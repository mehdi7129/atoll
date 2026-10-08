# A19 — conserver le skill si son archivage échoue

Correctif du premier jalon de la [PR d'audit #8](https://github.com/mehdi7129/atoll/pull/8),
préparé le 8 octobre 2026 depuis `a1c7d69`.

## Défaut et correction

`LearnedSkillStore.archiveInstalled` ignorait l'erreur de copie de l'archive,
puis supprimait le dossier installé et son entrée du manifeste. Des ressources
ajoutées après installation pouvaient ainsi disparaître sans copie.

La correction propage cette erreur avant tout retrait. Le flux d'erreur existant
de `SkillReviewCenter` la présente déjà à l'utilisateur ; une nouvelle tentative
reste possible après réparation de la destination. Une seule ligne fonctionnelle
change, de `try?` à `try`. L'archive réussie copie toujours le dossier complet.
La politique distincte de `uninstallAll` et la migration des anciens manifestes
restent inchangées.

## Vérifications du 8 octobre

Trois nouveaux tests exercent Claude et Codex, avec un manifeste v2 et des
ressources propres au dossier installé, dont un fichier binaire imbriqué :

1. Copie complète avant retrait de la source et du manifeste.
2. Parent d'archive remplacé par un fichier : erreur propagée, source et
   manifeste conservés octet pour octet, obstacle intact.
3. Réparation de ce parent puis nouvelle tentative : archivage réussi sans
   réinstaller le skill ni reconstruire son manifeste.

Avant correction : trois tests exécutés, quatorze assertions en échec.
Après correction : **1 092 tests Core, un skip, zéro échec**.
Le script de sabotage réussit d'abord les trois tests, remet `try?` dans une
copie temporaire du package, vérifie sa compilation puis l'échec de l'assertion
qui exige la propagation de l'erreur. Ce mutant déclenche douze assertions en
échec sur le test de conservation, pour les deux destinations.

Relecture ciblée du diff, de la copie d'archive, des tests et du flux UI d'erreur ;
pas de relecture intégrale de tous les consommateurs.

```sh
swift test --package-path AtollCore --build-system native --jobs 4
python3 Scripts/test-skill-archive-sabotage.py --output /tmp/atoll-a19-sabotage
python3 Scripts/check-docs.py --no-tests
git diff --check
```

Fixtures privées uniquement ; aucun skill personnel modifié. La panne injectée
est un parent d'archive non-répertoire : la recette ne simule pas un disque plein
ni une interruption physique de copie. Le chemin UI existant a été inspecté,
sans lancement de l'app ni recette graphique.
