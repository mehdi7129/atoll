# Rangement des notes : réutiliser une analyse déjà payée

23 septembre 2026 · PR #5, sans fusion ni release.

## Problème et correction

Le rangement conservait l’ancien corpus en cas d’échec d’archive ou de staging,
mais perdait la réponse du modèle. Un cycle suivant pouvait donc payer la même
analyse. Après un appel lancé, ce cycle automatique suivait la cadence habituelle
de sept jours ; il ne s’agissait pas d’une boucle de génération toutes les trente minutes.

Atoll sauvegarde maintenant le résultat validé avant de toucher aux notes. Le bouton
existant ou le prochain cycle autorisé tente d’abord une reprise locale, même si le
modèle ou le quota n’est plus disponible. Aucun nouvel appel ni nouveau reçu de
consommation : les écritures confirmées complètent le reçu de l’analyse initiale.

- Notes d’origine inchangées : le résultat repasse par le planificateur, avec les
  archives relues, les mêmes contrôles de provenance et de rétrécissement.
- Résultat déjà appliqué avant l’interruption : l’état et l’index sont réconciliés,
  sans réécriture ni nouvelle archive ; les contradictions restent visibles.
- Hors bascule interrompue, notes ajoutées, modifiées ou retirées : l’ancienne réponse est invalidée. Le
  cycle normal conserve ses garde-fous avant toute éventuelle nouvelle analyse.
- Bascule interrompue : archive source, staging et fichiers présents sont comparés
  au plan sauvegardé. Un marqueur lié au checkpoint atteste que le remplacement
  avait commencé. Les sources sont restaurées avant la reprise ; une preuve
  insuffisante conserve les fichiers et refuse toute nouvelle analyse.
- Résultat sauvegardé illisible : refus local explicite, aucune génération de secours.

Les empreintes portent les noms et contenus de toutes les notes lues. Les noms des
sources, la date de rendu et le reçu initial sont conservés, sans recopier le corps
des sources dans le checkpoint. Lecture limitée à 2 Mio, dossier privé `0700`,
fichier `0600`. Un résultat appliqué n’est retiré qu’après confirmation de l’état persistant.

## Gain et limites

Cette correction évite **un appel supplémentaire par reprise éligible**. Elle ne
réduit pas le prompt d’un rangement normal. La baisse précédente de 69,3 % concernait
deux fixtures du générateur ; elle n’est pas remesurée ici et ne devient pas une
garantie globale. Ni nouvelle limite de contexte, ni changement de modèle ou de
contenu utile pour obtenir ce gain.

Si la première sauvegarde du résultat échoue elle-même, les notes restent intactes,
mais la réponse ne survit pas à la fermeture. La reprise respecte l’opt-in et la
cadence existants ; le simple lancement d’Atoll ne force pas un rangement.

Pendant la réparation d’une bascule interrompue, les fichiers ajoutés ou modifiés
qui ne correspondent à aucune source ni sortie attendue bloquent la reprise. Sans marqueur de début du remplacement, une source
supprimée bloque aussi la reprise. Après le début attesté du remplacement, une suppression manuelle peut
être indiscernable d’une suppression interrompue par Atoll : les sources manquantes
sont alors restaurées depuis l’archive. Ces vérifications ne constituent pas un verrou contre les écritures
simultanées d’autres applications.

## Relecture et vérification

La relecture indépendante a trouvé un cas oublié : après un crash au milieu de
la bascule, l’ancien réparateur pouvait mélanger sources restaurées et sorties
partielles, puis invalider le résultat payé. La récupération vérifie désormais
les contenus avant ce réparateur historique. Sans checkpoint, le comportement
historique reste conservé. Les changements de `NotesCurationService.swift` et
`CurationCheckpoint.swift` ont fait l’objet d’un balayage ciblé ; aucune relecture
intégrale de leurs consommateurs n’est revendiquée.

La validation utilise les services et le journal réels avec deux exécutables CLI
factices, dans des racines privées. Les états de crash sont reconstitués sur disque,
puis relus par un nouveau processus du harness. Aucune app GUI ni aucun CLI
authentifié lancé ; aucune génération facturée. Les builds ne sont
pas installés sur le poste. Aucun réglage personnel Codex/Claude n’est modifié.

- **1 083 tests Core**, un skip opt-in, aucun échec.
- **98 parcours de reprise**, **26 parcours de cadence/annulation** et les
  **60 parcours runtime existants** passent avec les services réels.
- **Sept sabotages compilés et détectés** : empreinte Core, sauvegarde du résultat,
  changement concurrent, récupération du swap, preuve des fichiers, contrôle et
  écriture effective du marqueur.
- Builds Debug et Release réussis ; contrôle documentaire validé.
- [Résultats structurés et preuves](audit-support/2026-09-23-curation-recovery/validation.json) ;
  [parcours détaillés](audit-support/2026-09-23-curation-recovery/recovery.json).

```sh
swift test --package-path AtollCore --build-system native --jobs 4
python3 Scripts/test-runtime.py
python3 Scripts/test-curation.py --build-system native
python3 Scripts/test-curation-recovery.py
python3 Scripts/test-curation-recovery.py --sabotage checkpoint
python3 Scripts/test-curation-recovery.py --sabotage fingerprint
python3 Scripts/test-curation-recovery.py --sabotage swap-recovery
python3 Scripts/test-curation-recovery.py --sabotage swap-proof
python3 Scripts/test-curation-recovery.py --sabotage swap-marker
python3 Scripts/test-curation-recovery.py --sabotage swap-marker-write
python3 Scripts/test-learning-core.py --sabotage curation-checkpoint-match
python3 Scripts/check-docs.py --no-tests
```

`test-curation-recovery.py` et `test-learning-core.py` acceptent
`--build-dir AtollCore/.build/arm64-apple-macosx/debug` pour réutiliser une
compilation native, sans lancer SwiftPM en concurrence.
