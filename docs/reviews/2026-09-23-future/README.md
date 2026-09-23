# Validation de l’exploration prospective

23 septembre 2026 · référence produit `6c1f987` · documentation et maquettes seulement.

[Propositions et preuves de code](../../EXPLORATION-2026-09-23-atoll-future.md) ·
[Ouvrir la maquette HTML](../../mockups/2026-09-23-future/index.html).
Télécharger le HTML et l’ouvrir dans un navigateur si GitHub en affiche le code.
Tout est embarqué dans ce fichier : aucune installation ni connexion nécessaire.

## Seconde lecture critique

Deux lectures indépendantes ont remis en cause les propositions après rédaction,
l’une sur les parcours, l’autre sur les invariants techniques. Changements retenus :

- **Journal :** « proposition créée » remplace « à revoir ». Le reçu ne connaît
  pas le statut courant de la revue. La durée inclut la préparation ; le rangement
  réécrit un corpus, sans prouver autant de connaissances nouvelles.
- **Reprise :** compter une consommation une fois et enrichir séparément la
  livraison ; aucune jointure approximative entre journaux.
- **Priorité :** le journal est un premier chantier si les analyses sont utilisées.
  Sinon, commencer par la recette du retour au terminal.
- **Mémoire :** la commande cherche déjà sans modèle. La valeur à démontrer est
  l’accès humain hors conversation ; mesurer le temps jusqu’à une source citée,
  pas prétendre améliorer le classement avec la seule interface.
- **Sources :** rôles, recherche élargie et contexte des décisions corrigées
  doivent être visibles. Une note trouvée n’est pas une décision validée.
- **Retour récent :** garder l’idée tardive ; vérifier le contrat de chaque CLI,
  définir conservation bornée, sans badge ni compteur non lu.
- **Repos :** comparer régime stabilisé et backfill séparément, sur le même corpus,
  avec les mêmes réglages/écrans. Aucun gain CPU ou batterie n’a été mesuré ici.
- **Quota expiré :** corriger sa présentation sans effacer la donnée brute ou
  affaiblir les gates d’apprentissage.

Idées écartées avant rédaction : refonte générale des réglages, nouvelles mesures
IA à chaque session, archivage sur absence d’usage, orchestration, relance des
tests par Atoll et duplication des améliorations déjà livrées dans les PR #4/#5.

## Maquettes relues

Contrôle dans Chrome par l’interface native : captures affichées et relues dans
la session de validation, fenêtre observée de 1 224 × 768 pixels dans les images
retournées. Aucun test de l’app Atoll n’est revendiqué. Les captures d’origine
SwiftUI sont celles déjà archivées dans les recettes des 10 et 11 septembre.

| Parcours | Contrôle effectué |
|---|---|
| Journal | Trois lignes, détails dépliables, création distincte de revue, mesure absente distincte de zéro |
| Sessions | Ouverture de la liste complète, sélection de la septième session, détail et retour, variantes cyan/orange |
| Sans surplus | Correction : ne pas afficher « Voir les 2 sessions » quand les deux lignes sont déjà visibles |
| Mémoire | Liste initiale, recherche élargie « capture absent », extrait attribué et cité, copie annoncée réussie, absence de résultat |

Les exemples, compteurs et dates de contenu sont fictifs. Le JavaScript filtre
trois exemples en mémoire : il ne reproduit pas le moteur FTS5 et ne valide pas
sa pertinence. Le bouton de copie utilise le clipboard ; son fallback de sélection
en cas de refus n’a pas été provoqué. Aucun terminal n’est ouvert depuis la maquette.

Le CSS prévoit une largeur étroite et `prefers-reduced-motion` ; il ne faut pas
confondre inspection du CSS avec recette exhaustive des tailles ou de VoiceOver.
La future implémentation SwiftUI devra reprendre les scénarios du plan et les
contrôles natifs aux tailles pertinentes.

## Contrôles documentaires

`Scripts/check-docs.py --no-tests` a réussi avant l’exploration. La vérification
finale, les liens locaux, la syntaxe JavaScript et la portée du diff sont consignés
dans [validation.json](validation.json).

Aucun build, test Core ou appel génératif Atoll relancé : les sources du produit,
le projet Xcode, le helper, les préférences et les artefacts publiés sont inchangés.
La PR reste une proposition ; sa présence n’engage aucun lot de développement.
