# Réglages — organisation validée, implémentation et recette

11 septembre 2026 · branche `codex/settings-ux`, base `a961c10`.
Mehdi a validé le [plan des huit onglets](PLAN-2026-09-11-settings-organization.md)
et sa maquette, puis demandé application, commit, push et PR. La fusion attend
sa relecture ; aucune release ni remplacement de l'app stable dans ce lot.

## Organisation livrée dans la branche

| Onglet | Changement |
|---|---|
| Général | Apparence en premier, couleurs nommées par CLI, intensité du verre repliée, tailles indépendantes par écran ; erreur de lancement au démarrage affichée |
| Claude Code | Intégration et quota en premier, accès aux analyses, plugins et dépannage repliés ; erreurs de plugins toujours visibles |
| Codex | État du suivi puis raccourci vers les analyses ; diagnostic nommé « Vérifier les hooks » ; erreurs de catalogue visibles même fermé, chemins dans les détails |
| Autonomie | Portée Claude explicite, explication exacte du mode Manuel ; confirmation Rockstar et signal des règles suspendues conservés |
| Alertes | Deux sons communs Claude/Codex, « Tour terminé » clarifié ; anciens sons Claude en dernier, conditionnels ; restitution accessible sans intégration Claude |
| Apprentissage | Une seule édition du moteur et des modèles, limites communes, mémoire des deux CLI, notes et rangement, destination et revue des skills, journal replié |
| Mises à jour | Bouton Sparkle existant accessible ici, version/build, aide limitée à la vérification automatique ; aucun faux « à jour » |
| À propos | Identité, version/build et licence |

Les clés des préférences restent inchangées. Les modèles Claude conservent leurs
choix par tâche ; le rangement sans choix dédié suit toujours le modèle de bilan.
Le modèle Codex n'est jamais choisi automatiquement ni effacé lors d'une erreur,
d'une actualisation ou d'un changement de moteur. Les services d'intégration,
d'analyse et de mémoire gardent leurs contrats ; Rockstar reste propre à Claude.

## Vérifications

- Builds Debug et Release réussis ; avertissement AppIntents sans dépendance, déjà connu.
- **1 020 tests Core**, un test live ignoré, aucun échec.
- **58 parcours UI réussis** : OCR du contenu rendu, arbres d'accessibilité,
  interactions et préférences privées. Ils couvrent notamment les huit onglets
  en clair/sombre à leur largeur minimale et les états de panne utiles.
- **Six sabotages compilés et détectés**, avec les mêmes assertions : choix
  automatique du modèle, rappel restant actif sans indexation, sons masqués sans
  Claude, écoute proposée pour un fichier disparu, raccourci Codex sans navigation,
  absence de focus sur le modèle après ce raccourci.
- Parcours clavier réel vérifié avec CUA : raccourci, focus sur le modèle,
  Espace, deux flèches bas, Entrée ; « Modèle de test B » sélectionné.
  Propositions de skills et action de revue relues aussi en bas du panneau étroit.

Les [résultats UI](reviews/2026-09-11-settings-organization/ui-results.json),
[sabotages](reviews/2026-09-11-settings-organization/sabotages.json),
[conditions de validation](reviews/2026-09-11-settings-organization/validation.json)
et [captures](reviews/2026-09-11-settings-organization/README.md) sont conservés.

La copie de recette utilise la **vraie scène Settings macOS**, sur un domaine
UserDefaults privé. Ses actions externes sont simulées : aucune génération,
installation de hook/plugin, reconstruction de mémoire ou mise à jour réelle.
L'app stable reste v0.18.1, build 36. Sept empreintes sur huit sont inchangées :
préférences Atoll, hooks des deux CLI, rappel, sons et parkings. `config.toml`
a évolué pendant la session : la comparaison est non concluante pour ce fichier,
la modification n'est pas attribuée et son contenu a été laissé intact.

La taille minimale testée est un **contenu de 640 × 520 points**, auquel macOS
ajoute sa barre de titre et ses onglets. Les longs panneaux défilent. Les captures
sont relues ; l'OCR seul ne vérifie ni les alignements ni les coupures de texte.

Les parcours CLI authentifiés et les phrases réellement prononcées par VoiceOver
ne sont pas rejoués pour cette réorganisation. Les noms, rôles, états et actions
accessibles sont contrôlés dans l'arbre AX ; les dialogues sont annulés au clavier.
Les limites de recette historiques restent dans [HANDOFF](HANDOFF.md).

Le test de focus est explicite et exige la navigation clavier macOS. Le contrôle
a d'abord échoué avec cette option désactivée ; c'est la convention native des
contrôles d'activation, décrite par [Apple](https://developer.apple.com/documentation/swiftui/focusinteractions/activate).
Activée temporairement pour ce seul contrôle puis rétablie à sa valeur initiale,
elle permet le parcours sans modification supplémentaire du produit. Le menu
transitoire a été vérifié via CUA ; l'arbre AX parcouru par le script ne suffit
pas à prouver son ouverture au clavier.

## Seconde lecture du changement

Balayage ciblé du diff et des liaisons déplacées, sans nouvel audit complet des
services : `App/SettingsView.swift`, `App/ClaudeCodeSettingsPane.swift`,
`App/LearningSettingsPane.swift`, `App/MemorySettingsSection.swift`,
`App/AnalysisSettingsSection.swift`, `App/CodexAnalysisModelPicker.swift`,
`App/CodexSettingsPane.swift`, `App/CodexCatalogSection.swift`,
`App/SoundSettingsView.swift`, `App/SettingsHelp.swift`, `App/CodexPreview.swift`,
`App/AtollApp.swift`, les libellés Core et les deux scripts de recette.

1. **Déplacer sans réinitialiser.** Les liaisons gardent les clés et les appels
   de synchronisation existants. Couper l'indexation désactive aussi le rappel
   automatique et synchronise ses hooks. Les limites restent communes aux analyses.
2. **Ne pas masquer les actions requises.** Le modèle absent a un raccourci
   visible dans Codex ; ses erreurs sont dans Apprentissage. Les erreurs de
   plugins/catalogue, de rangement, de restitution et de règles suspendues restent
   hors des listes ou volets de détail.
3. **Ne pas généraliser une fonction Claude à Codex.** Seuls les deux événements
   sonores sont communs. Migration des sons, questions/plans et Rockstar gardent
   leur portée Claude. Aucun nouveau mécanisme de permissions n'est ajouté.
4. **Garder les confirmations utiles.** Reconstruction, Rockstar et installation
   de plugin conservent leurs dialogues. Les gestes réversibles existants n'en
   reçoivent pas un supplémentaire pour une simple réorganisation.
5. **Recette fidèle et isolée.** Un TabView dans une fenêtre générique différait
   de la scène Settings ; les captures utilisent maintenant cette dernière.
   Les activations ciblent le PID de recette et les tests GUI se sérialisent.
   Les résultats sont enregistrés après chaque cas pour permettre une reprise
   après interruption, sans assimiler un incident de focus à un échec du produit.

## Rejouer

Construire et préparer une copie avec les commandes de [HANDOFF](HANDOFF.md), puis :

```sh
python3 Scripts/test-ui.py --app /private/tmp/Atoll-settings-review.app \
  --output /private/tmp/atoll-settings-check \
  --case settings-codex-model-shared --case settings-memory-off \
  --case settings-alerts --case settings-alerts-missing \
  --case settings-autonomy-cancel --case settings-updates-manual
python3 Scripts/test-settings-sabotage.py --output /private/tmp/atoll-settings-mutants
python3 Scripts/check-docs.py --no-tests
```

Avec la navigation clavier macOS activée, deux contrôles supplémentaires explicites :

```sh
python3 Scripts/test-ui.py --app /private/tmp/Atoll-settings-review.app \
  --output /private/tmp/atoll-settings-focus --case settings-codex-model-focus
python3 Scripts/test-settings-sabotage.py \
  --output /private/tmp/atoll-settings-focus-mutant --mutation focus
```

Ces scripts ne modifient pas la préférence système. La recette habituelle ne
l'exige pas ; le contrôle de focus est exclu des cas lancés sans sélection.

Les mutants sont créés dans une copie temporaire. Un build raté ou une erreur du
harnais ne valide jamais un sabotage : le résultat doit contenir l'assertion
précise attendue pour ce défaut.
