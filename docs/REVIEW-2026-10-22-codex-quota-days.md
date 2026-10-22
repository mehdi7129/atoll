# Quota Codex : afficher les jours restants jusqu'au reset

Correctif validé et publié le 22 octobre 2026 en
**[v0.18.7/build 42](https://github.com/mehdi7129/atoll/releases/tag/v0.18.7)**,
après fusion de la [PR #20](https://github.com/mehdi7129/atoll/pull/20), source
`82b90725e17d434616ed48210711d955a034192f`. Mehdi a explicitement autorisé cette
release. L'app installée n'a pas été remplacée.

## Défaut et correction

Le quota hebdomadaire affichait son intervalle complet (**7j**), même lorsque
le reset reçu de Codex était dans cinq jours. Le pourcentage et la date de reset
étaient déjà distincts de ce label.

`CodexQuota.Window.displayLabel(at:)` conserve la durée totale dans `label` et
calcule l'affichage des fenêtres d'au moins un jour depuis `resetsAt`. Le délai
est arrondi à l'unité supérieure : **5j** à cinq jours du reset, **4j** le
lendemain, puis heures et minutes sous un jour. L'îlot compact, le panneau
étendu et Réglages → Codex utilisent ce calcul commun.

La fenêtre courte **5h** reste une durée de fenêtre. Sans reset exploitable ou
après échéance, le label d'origine sert de repli ; la gestion existante des
fenêtres périmées est conservée. Pourcentages, fraîcheur, polling, transport,
hooks, préférences et choix des modèles ne sont pas modifiés.

## Preuves ciblées

- **30 tests passent**, zéro échec : `CodexQuotaTests` et `ProviderFailoverTests`.
  Les assertions couvrent 5j → 4j, l'arrondi après une minute, 23h, 1min,
  l'échéance, la fenêtre courte et l'absence de reset.
  Log : `/private/tmp/atoll-quota-days-tests-final.log`.
- **Sabotage causal compilé** : rendre le label total d'origine réintroduit
  **7j** ; le test de compte à rebours échoue sur ses cinq valeurs attendues.
  Log : `/private/tmp/atoll-quota-days-mutant.log` (`Build complete!`, puis
  un test exécuté et cinq échecs d'assertion).
- **Build Debug réussi**, sans lancement du produit de build.
  Log : `/private/tmp/atoll-quota-days-build.log` (`BUILD SUCCEEDED`).
- **Suite Core Release complète : 1 133 tests, un skip, zéro échec**,
  en 10,656 secondes. Log : `/private/tmp/atoll-0187-core-release.log`.
- **Deux cas UI passent** : `quota-codex-countdown` et
  `settings-codex-quota-countdown`, dans une copie d'aperçu protégée et fictive.
  Les captures ont été effectivement lues ; elles montrent **2j** pour le
  reset fictif à deux jours, avec **5h** conservé. L'OCR natif a échoué dans
  `e5rt` ; le repli Accessibility fournit les libellés utilisés par les
  assertions. Résultats et captures : `/private/tmp/atoll-quota-days-ui-ax/`.

Ces recettes ne sont ni une génération authentifiée ni une validation du quota
réel dans l'app installée. La correction ne réclame aucun nouvel appel au modèle.
Les 30 tests ciblés et la suite Core Release complète sont des exécutions distinctes.

## Livraison vérifiée

La [CI de la PR #20](https://github.com/mehdi7129/atoll/actions/runs/39759975021)
passe **26 étapes sur 26**, avec **1 133 tests, deux skips, zéro échec**.

App et DMG signés Developer ID, notarisés et staplés, acceptés par Gatekeeper.
Les sept binaires sont universels arm64 / x86_64. Les six signatures Sparkle
sont valides et leurs six copies altérées rejetées. Le delta **41 → 42** et
l'app du DMG reproduisent les **134 fichiers, liens et modes** du ZIP complet.
Le produit Release n'a pas été lancé. Les sept assets téléchargés depuis la
release publique correspondent aux SHA256 et tailles du package validé.

L'activation du flux Sparkle `e94c4cd` suit les assets ; le contenu servi est
identique aux octets validés, avec **0.18.7/build 42** en tête. Le
[relevé de livraison](releases/0.18.7.json)
conserve les preuves de distribution et de publication, issues de
`/private/tmp/atoll-0187-distribution/run-lnf2zlu5/validation.json` et
`/private/tmp/atoll-0187-public-before-feed/public-validation.json`.
Le flux téléchargé est conservé dans `/private/tmp/atoll-0187-feed-served.xml`.

La publication ne remplace pas l'app stable, observée en **0.18.6/build 41**
avant livraison. La mise à jour depuis Atoll ou le DMG reste à appliquer.

## Reproduire

```sh
swift test --build-system native --package-path AtollCore \
  --filter 'CodexQuotaTests|ProviderFailoverTests'
python3 Scripts/check-docs.py --no-tests --network
```

Le précontrôle documentaire avant édition passe sans échec, avec 31
avertissements de couverture de relecture et d'artefacts absents. Le décompte
des tests ci-dessus provient des logs d'exécution, pas de `--no-tests`.
