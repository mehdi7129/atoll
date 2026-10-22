# Quota Codex : afficher les jours restants jusqu'au reset

Correctif validé le 22 octobre 2026, en préparation de **v0.18.7/build 42**.
Mehdi a explicitement autorisé cette release. La publication, ses artefacts et
le flux servi restent des étapes distinctes à vérifier ; l'app installée n'est
pas remplacée pendant cette préparation.

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

## Reproduire

```sh
swift test --build-system native --package-path AtollCore \
  --filter 'CodexQuotaTests|ProviderFailoverTests'
python3 Scripts/check-docs.py --no-tests --preflight
```

Le précontrôle documentaire avant édition passe sans échec, avec 31
avertissements de couverture de relecture et d'artefacts absents. Le décompte
des tests ci-dessus provient des logs d'exécution, pas de `--no-tests`.
