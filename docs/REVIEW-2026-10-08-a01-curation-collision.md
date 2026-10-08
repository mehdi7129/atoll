# A01 — préserver une note qui bloque la consolidation

Correctif du premier jalon de la [PR d'audit #8](https://github.com/mehdi7129/atoll/pull/8),
préparé le 8 octobre 2026 depuis `a1c7d69`.

## Défaut et correction

Une note illisible est absente du corpus lu et de son archive. Si une nouvelle
note prend le même nom, l'ancien code déplaçait ce fichier vers `.orphan`, puis
tentait de le supprimer si ce déplacement échouait. Des octets non archivés
pouvaient ainsi être perdus.

Après vérification de l'archive et préparation des sorties, le service refuse
désormais une destination occupée qui ne fait pas partie des sources, avant
le marqueur de bascule et toute suppression. La note reste au même chemin et
le résultat du modèle reste dans le checkpoint existant. Après résolution
explicite du conflit, la reprise locale peut appliquer ce résultat sans nouvel
appel au modèle.

La branche `.orphan` et son fallback destructeur sont retirés. Une collision
arrivée après le contrôle fait échouer `moveItem` et déclenche la restauration
existante des sources. Les noms appartenant au corpus archivé restent admis :
le remplacement nominal des notes conserve son fonctionnement.

## Preuves du 8 octobre

La nouvelle fixture place une note non UTF-8 au nom exact d'une sortie. Elle
utilise le vrai service et le vrai budget avec deux fournisseurs factices,
dans des racines privées. Aucun timestamp ou hasard n'est nécessaire.

- Avant correction : compilation réussie, puis échec précis sur la note
  déplacée ou détruite après les 49 scénarios Claude existants.
- **104 scénarios de récupération réussis**, dont trois nouveaux par fournisseur :
  conflit initial, nouvelle tentative après redémarrage avec conflit persistant,
  puis reprise après déplacement explicite de l'obstacle par la fixture.
- Vérifications : octets et chemin de l'obstacle, sources et archives fidèles,
  checkpoint complet et reçu préservés, aucun callback d'indexation ni note
  comptée comme écrite pendant le refus, empreinte du dernier succès conservée.
- La reprise réussie atteint l'empreinte cible, actualise l'index, conserve les
  contradictions et retire le checkpoint après état confirmé, sans resolver
  ni nouveau CLI même quand la configuration d'analyse est bloquée.
- **26 scénarios de curation et cadence réussis.** Le remplacement avec les
  mêmes noms est également couvert par les scénarios de récupération existants.
- Deux sabotages compilés sont détectés après une baseline verte : retrait du
  contrôle préalable, puis réintroduction du comportement `.orphan`. Le verdict
  exige une assertion précise et une sortie 1 ; une erreur inattendue sort en 2.
- Les six anciens modes de sabotage restent détectés avec ce verdict resserré,
  chacun après une baseline de 104 scénarios : checkpoint, fingerprint,
  swap-recovery, swap-proof, swap-marker et swap-marker-write.

Relecture ciblée de `apply`, de la restauration, de la reprise avant sélection
du modèle et des tests ; aucune revendication de relecture intégrale du service.
La contre-relecture indépendante ne relève aucun bloquant.

Les changements produit des trois lots ont aussi été réunis dans un worktree
de validation : build Xcode Debug réussi et 104 scénarios de récupération
réussis avec le Core corrigé par A19. Les **1 092 tests Core** ont été exécutés
sur les mêmes sources Core dans la PR #10. Le relevé d'intégration contient
les [empreintes des fichiers testés](audit-support/2026-10-08-milestone1/validation.json).
Cette validation n'est ni une fusion sur `main`, ni une release, ni une recette GUI.

```sh
python3 Scripts/test-curation-recovery.py --build-system native
python3 Scripts/test-curation.py --build-system native
python3 Scripts/test-curation-recovery.py --build-system native --sabotage collision-preflight
python3 Scripts/test-curation-recovery.py --build-system native --sabotage collision-preservation
python3 Scripts/check-docs.py --no-tests
git diff --check
```

Le correctif ne crée pas de verrou contre les écrivains externes. La collision
tardive est contrôlée par le refus de remplacement de `moveItem` et le sabotage
sans précontrôle, pas par une qualification de toutes les courses de fichiers.
Une corruption de l'état de curation reste un autre constat de l'audit (A02).
Aucune GUI ni génération authentifiée n'est lancée pour cette recette.
