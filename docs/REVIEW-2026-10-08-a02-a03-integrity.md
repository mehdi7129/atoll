# A02 / A03 — préserver les données dont la lecture échoue

Correctifs du 8 octobre 2026, base `aed6546`, après la release 0.18.5.
Ils traitent deux constats de la [PR d’audit #8](https://github.com/mehdi7129/atoll/pull/8).
Le code est préparé et validé sur une branche distincte ; **il n’est pas encore
fusionné ni distribué**. La version publique reste 0.18.5 / build 40.

## Comportement corrigé

### A02 — état du rangement

Un `curation.json` présent mais illisible devenait un état neuf. L’armement
du rangement pouvait alors remplacer ses octets, perdre les contradictions et
faire repartir l’échéance. Le service distingue maintenant une absence confirmée
d’une erreur de lecture ou de décodage. Il conserve le fichier, expose l’erreur
dans le diagnostic existant et refuse une nouvelle analyse tant que cet état
reste illisible.

La vérification porte aussi sur les retours asynchrones : une panne survenue
pendant la préparation interdit le lancement ; après le modèle, si elle est
détectée avant la bascule, elle conserve le résultat payé en checkpoint et les
notes originales. L’écriture de l’état
est elle-même précédée d’une vérification. La réparation est relue au prochain
geste ou passage du scheduler, sans ajouter de watcher ni changer la cadence.

Un état valide relu ne remplace pas une cadence plus récente conservée en RAM
après un échec d’écriture. Si la réparation laisse le fichier absent, le
scheduler réarme son échéance comme au premier démarrage ; le bouton manuel
reste utilisable immédiatement. Les anciens formats valides et la tolérance
sur une empreinte de corpus optionnelle invalide sont conservés.

### A03 — autorité du manifeste de skills

Une racine visible mais non traversable pouvait faire passer ses enfants pour
supprimés et retirer leurs entrées du manifeste. La réconciliation inventorie
maintenant la racine avec remontée des erreurs, puis interroge le chemin réel
de chaque entrée. Seule une absence confirmée autorise un retrait ; une erreur
d’accès diffère toute purge du manifeste, y compris si un autre skill manque
réellement. Une racine absente reste tolérée sans vider le manifeste.

Une lecture refusée de `SKILL.md` n’est plus présentée comme une modification
manuelle. Le fichier réellement manquant ou son UTF-8 invalide conserve le
comportement précédent. Les ressources jointes, les destinations Claude/Codex
et les politiques d’approbation, d’archivage et de désinstallation sont conservées.

Le centre de revue affiche les erreurs dans son diagnostic existant. Une
lecture réussie efface ce diagnostic seulement s’il n’a pas été remplacé par
une autre erreur d’action. Aucun fichier de vue n’est modifié.

## Validation et contre-revue

[Relevé vérifiable et empreintes des sources](audit-support/2026-10-08-a02-a03/validation.json).

| Vérification | Résultat |
|---|---|
| Suite Core complète | 1 102 tests, un test live opt-in ignoré, zéro échec |
| Sous-ensemble skills | 39 tests, dont 10 nouveaux A03 et les trois tests A19 |
| Service de curation, état | 48 parcours privés Claude/Codex |
| Curation et cadence existantes | 26 parcours |
| Reprise et collisions existantes | 104 parcours |
| Centre de revue réel | 12 parcours, dont erreurs d’accès et réparation |
| Nouveaux sabotages compilés | 14 détectés : six A02, cinq A03, trois diagnostics |
| Sabotage existant de reprise | `swap-marker-write` détecté après baseline de 104 parcours |
| Builds Xcode | Debug et Release réussis, signature désactivée, aucun lancement |
| Contrôle documentaire | `check-docs.py --no-tests` et `git diff --check` |

Les 190 parcours de services sont distincts de la suite Core. Les 39 tests
ciblés en sont un sous-ensemble : ils ne s’ajoutent pas aux 1 102.
Chaque nouveau sabotage impose une baseline verte puis un échec d’exécution
précis ; une erreur de compilation ne valide pas le sabotage. Les permissions
POSIX ont été réellement retirées puis rétablies dans des fixtures privées,
sous un utilisateur non root.

La contre-revue ciblée a trouvé trois régressions intermédiaires, corrigées
avant la validation finale : oubli de la cadence RAM après un échec de
sauvegarde, comparaison sensible à la casse sur APFS, départ automatique après
retrait d’un état illisible. Chaque cas possède son test et son sabotage.
Le verdict final de lecture ne relève plus de blocage ; il ne revendique pas
une nouvelle relecture exhaustive du projet.

Le scénario de reprise `target-seed` injecte désormais l’état illisible dans
le callback existant après la bascule, avant sa sauvegarde finale : une erreur
antérieure interdit maintenant cette bascule. Ses assertions de marqueur,
checkpoint, corpus, indexation, absence de nouvelle archive et reprise sans
second appel sont conservées. Le sabotage du marqueur reste détecté.

## Reproduire

Travailler hors du dossier Bureau si ses sources sont déchargées par iCloud.
Les harnesses utilisent leurs propres fixtures ; ne pas modifier les droits
des dossiers personnels pour tester ces erreurs.

```sh
swift test --package-path AtollCore --build-system native --jobs 4
ATOLL_CORE_BUILD="$(swift build --package-path AtollCore --build-system native --show-bin-path)"
python3 Scripts/test-curation-state.py --build-dir "$ATOLL_CORE_BUILD"
python3 Scripts/test-curation.py --build-dir "$ATOLL_CORE_BUILD"
python3 Scripts/test-curation-recovery.py --build-dir "$ATOLL_CORE_BUILD"
python3 Scripts/test-skill-review.py --build-dir "$ATOLL_CORE_BUILD"

for fault in empty-fallback spawn-guard write-guard apply-guard reload-cadence repaired-absent; do
  python3 Scripts/test-curation-state.py --build-dir "$ATOLL_CORE_BUILD" --sabotage "$fault"
done
python3 Scripts/test-skill-reconciliation-sabotage.py --output /tmp/atoll-a03-sabotages
for fault in access-error access-recovery access-clear; do
  python3 Scripts/test-skill-review.py --build-dir "$ATOLL_CORE_BUILD" --sabotage-"$fault"
done
python3 Scripts/test-curation-recovery.py --build-dir "$ATOLL_CORE_BUILD" --sabotage swap-marker-write
python3 Scripts/check-docs.py --no-tests
git diff --check
```

## Limites

- Fixtures privées et CLI factices : aucune génération authentifiée, recette
  GUI ou nouvelle mesure du transport quota.
- Aucun verrou interprocessus ajouté : une modification externe entre la
  vérification et l’écriture atomique reste possible.
- Les pannes I/O du writer de manifeste hors A03 ne sont pas injectées ; pas
  de simulation de disque plein.
- App stable 0.18.5 / build 40, quatre bundles Debug quotidiens et trois
  configurations personnelles contrôlés inchangés. Les builds de cette
  validation sont isolés et ne remplacent aucune installation.
