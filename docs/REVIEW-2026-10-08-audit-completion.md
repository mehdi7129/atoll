# Audit de robustesse : intégration et validation

État de préparation du **8 octobre 2026**, sur
`integration/audit-completion-20261008`, tête de préparation `4cb97df`.
Ce rapport suit les 22 constats de l'[audit initial et de son contre-audit (#8)](https://github.com/mehdi7129/atoll/pull/8).
Il distingue les corrections distribuées, le code fusionné et les validations
encore en cours. La version publiée reste **0.18.5, build 40**.

## État des 22 constats

Trois corrections sont livrées en 0.18.5. Quatre autres sont fusionnées sur
`main` par les PR [#14](https://github.com/mehdi7129/atoll/pull/14) (`13dad53`)
et [#15](https://github.com/mehdi7129/atoll/pull/15) (`0016c0c`), sans nouvelle
distribution. Les quinze restantes sont corrigées dans la branche d'intégration ;
leur validation globale finale est en cours.

| ID | Correction | État à cette étape | Preuve ciblée |
|---|---|---|---|
| A01 | Collision de notes refusée avant remplacement, résultat conservé pour reprise | Livré en 0.18.5 | [Curation](REVIEW-2026-10-08-a01-curation-collision.md) |
| A02 | État de curation illisible conservé et retenté | Fusionné, PR #14 | [Intégrité](REVIEW-2026-10-08-a02-a03-integrity.md) |
| A03 | Accès refusé à un skill distingué de sa disparition | Fusionné, PR #14 | [Intégrité](REVIEW-2026-10-08-a02-a03-integrity.md) |
| A04 | Markdown remplacé transactionnellement, y compris à métadonnées identiques | Intégration locale | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A05 | Dernière ligne complète de `cwd` conservée | Intégration locale | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A06 | Carte Claude et phase corrélées à la demande et à son helper | Intégration locale | [Permissions](REVIEW-2026-10-08-claude-permissions.md) |
| A07 | Hooks sonores restitués dans leur matcher d'origine | Fusionné, PR #15 | [Hooks](REVIEW-2026-10-08-a07-a08-hooks.md) |
| A08 | Doublons Atoll normalisés dans les groupes mixtes, hooks tiers conservés | Fusionné, PR #15 | [Hooks](REVIEW-2026-10-08-a07-a08-hooks.md) |
| A09 | Résolution, processus et drains bornés ; budget des enfants vivants conservé | Intégration locale | Lot processus ; [consommateur plugins](REVIEW-2026-10-08-plugins.md) |
| A10 | Installation du helper sérialisée hors MainActor | Intégration locale | Lot processus |
| A11 | Identité du processus revérifiée avant chaque signal | Intégration locale | Lot processus |
| A12 | Annulation limitée à la recherche plugins concernée | Intégration locale | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A13 | Estimations limitées à deux CLI simultanés, une par identifiant | Intégration locale | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A14 | Cache de coût invalidé selon version, source, scope et disparition | Intégration locale | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A15 | Instance NSSound distincte par événement | Intégration locale | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A16 | Journal et notes du panneau invalidés après persistance | Intégration locale | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A17 | Fin du CLI attendue, granularité annoncée prouvée, ordre des jumps conservé | Intégration locale | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A18 | Lecture refusée retentée sans acquittement anticipé de l'offset | Intégration locale | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A19 | Échec d'archivage conservant le skill installé et son manifeste | Livré en 0.18.5 | [Archivage](REVIEW-2026-10-08-a19-skill-archive.md) |
| A20 | Catalogue associé au projet, binaire et home ; résultats tardifs ignorés | Intégration locale | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A21 | Helper fail-open quand stdout est fermé | Intégration locale | Lot processus |
| A22 | Nominal Codex obligatoire et sabotage causal vérifié | Livré en 0.18.5 | [Harness Codex](REVIEW-2026-10-08-a22-codex-harness.md) |

## Corrections revues à leur tour

Les contre-reviews ont produit des corrections supplémentaires, chacune avec
une régression reproduite et un sabotage compilé :

- **A06, helper déjà sorti** : `LOCAL_PEERPID` peut rendre `ENOTCONN` avant
  l'installation du watcher. Ce cas ferme la seule carte concernée ; un helper
  vivant qui a fait `shutdown(SHUT_WR)` conserve sa carte. Une erreur incertaine
  ne vaut toujours pas preuve de clôture.
- **A17, deux jumps successifs** : des tâches indépendantes pouvaient rendre
  les callbacks dans l'ordre inverse des clics. La chaîne de tâches conserve
  l'ordre de l'ancienne queue série, avec travail hors MainActor et callbacks
  sur MainActor. Le test utilise deux CLI privés et une activation contrôlée.
- **A09, enfant encore vivant** : la fin de la collecte bornée ne prouve pas
  la fin du processus. L'ownership et le budget restent conservés tant que
  l'enfant identifié est vivant ; une seconde analyse ne peut utiliser sa place.
- **Mémoire, panne au deuxième lot JSONL** : l'offset d'un bloc de 4 Mio
  n'est plus acquis au premier flush de 500 lignes. Seules les lignes validées
  transactionnellement sont acquittées ; le reste sera relu.

La contre-review plugins a vérifié l'annulation pendant une lecture partagée,
la mutation concomitante, un coût d'ancienne version encore en vol et les
réponses tardives après changement de contexte. Aucun autre blocage confirmé
dans ce périmètre. Cette revue ne remplace pas les tests d'intégration UI.

## Simplifications et entretien

La primitive de processus est partagée sans uniformiser les contrats d'auth,
les profils Codex, les décisions ou les reprises propres aux fournisseurs.
L'ingestion distingue explicitement les flux JSONL des documents Markdown.
Le catalogue Codex porte son état de chargement dans une petite façade dédiée.
Aucun framework de services, nouveau réglage ou changement de base n'est ajouté.

Les quatre tâches d'entretien de l'audit sont suivies séparément :

| Tâche | État de préparation |
|---|---|
| Retrait des API sans consommateur produit | Intégré par `d0561e3` ; types et tests d'adoption utiles conservés |
| Commande offline commune et CI macOS | Intégrées par `4cb97df` ; [profils et commandes](VALIDATION.md), sans compte, génération ni publication automatique |
| Vérifications de distribution versionnées | Intégrées par `86ad979` ; [procédure](RELEASE-VALIDATION.md) |
| Instructions actives séparées de leur historique | `CLAUDE.md` ramené de 1 717 à 216 lignes ; [archive intégrale conservée](archive/CLAUDE-2026-10-08.md), intégrité vérifiée |

Les pistes de performance non caractérisées dans l'audit restent des pistes
de mesure : I/O sur MainActor, recherche de racine Git, tris et scans Markdown.
Elles ne sont pas présentées comme des bugs corrigés ni comme des optimisations
nécessaires à cette clôture. Les cadences, seuils, opt-in, modèles et gestes sont
conservés hors corrections explicitement décrites ci-dessus.

## Validation et portée des preuves

Les campagnes ci-dessous ont des périmètres différents et peuvent se recouvrir :
leurs nombres ne constituent pas un total de tests uniques.

| Campagne | Résultat acquis |
|---|---|
| Intégration #14 puis #15 | 1 129 tests Core, un skip, zéro échec ; 190 parcours services ; 12 parcours helper et sabotages ciblés ; builds Debug/Release réussis |
| Mémoire A04/A05/A18 | 37 tests Core ciblés, 40 scénarios runtime, neuf sabotages compilés détectés |
| Permissions A06 | 30 scénarios runtime, quatre sabotages compilés détectés |
| Plugins A12/A13/A14/A20 et consommateur A09 | 134 assertions, sept sabotages compilés détectés ; 30 plugins : maximum deux lectures simultanées |
| Feedback A15/A17 | Sept assertions AppKit silencieuses, huit parcours IDE, quatre sabotages compilés détectés |
| Feedback A16 | Runners réels et observateurs des révisions ; sabotages journal et notes détectés dans les parcours de rétrospective |
| Processus A09/A10/A11/A21 | Six tests Core ciblés, 15 parcours services, huit parcours analyses, stdout fermé et écritures partielles/EINTR ; dix sabotages compilés détectés |
| Suite offline et builds sur l'intégration finale | En cours ; ne pas substituer les résultats des lots au résultat de l'arbre combiné |

Les tests utilisent les classes produit et des fixtures privées. Un sabotage
doit compiler puis échouer sur l'oracle attendu ; une erreur de compilation ou
un nominal déjà cassé ne vaut pas détection. Les scripts et rapports de lots
donnent les commandes, les injections et leurs limites.

**Interface :** sept cas OCR de la copie protégée passent : réglages Claude,
Codex, Apprentissage, Alertes, Autonomie, onboarding sans fournisseur et carte
Claude. La copie vient du premier build Debug `fedd2af` ; les fichiers UI sont
identiques dans la tête de préparation `4cb97df`. Les sept captures ont été inspectées visuellement : elles sont lisibles,
sans défaut nouveau visible dans ces états. Cette inspection et l'OCR ne
constituent pas une recette VoiceOver ni une qualification des animations.

**Distribution :** le nouveau vérificateur a été exercé sur les artefacts
existants de **0.18.5** : six signatures Sparkle acceptées et leurs copies
altérées rejetées, sept binaires universels, delta 39 → 40 et app du DMG
identiques aux 134 objets de l'archive, 19 URL et sept téléchargements SHA256.
Ce contrôle qualifie l'outil et cette ancienne livraison ; il ne qualifie pas
une prochaine release. Les résultats de publication seront consignés dans leur
propre fiche de livraison. La cible de maintenance prévue est **0.18.6, build 41** ;
sa préparation ne modifie pas le statut publié de 0.18.5.

Les preuves locales de cette campagne sont regroupées dans
`~/Library/Caches/atoll-audit-completion-evidence-20261008/`, notamment `memory`,
`claude-permissions`, `plugins`, `feedback`, `feedback-order` et `counterreview`.
Les rapports versionnés ne contiennent pas les données privées des fixtures.

## Relectures documentées et limites

`docs/reviews.json` conserve toutes ses entrées précédentes. Les relectures des
corrections et de leurs interactions sont inscrites comme **sweep** : elles ne
prétendent pas couvrir intégralement les grands services ni toute l'app.
Le rapport plugins atteste une lecture intégrale de `App/PluginInventory.swift`,
`App/CodexCatalogState.swift` et `App/CodexCatalogSection.swift` ; seuls ces trois
fichiers de ce lot reçoivent la profondeur **line-by-line**. Les panneaux de
réglages ont une lecture ciblée de leurs points de raccordement.

Couverture ciblée attestée pour cette clôture :

- Mémoire : `App/MemoryIndexer.swift` et
  `AtollCore/Sources/AtollCore/MemoryIndex.swift`, ainsi que leurs nouveaux tests
  de document, indexeur et sabotages transactionnels.
- Permissions : `App/InteractionCenter.swift`, `App/SessionStore.swift`,
  `App/BridgeServer.swift`, callbacks d'`App/AppDelegate.swift` et transitions
  concernées d'`AtollCore/Sources/AtollCore/SessionPhase.swift`, avec le harness
  des connexions helper privées.
- Feedback : `App/SoundCenter.swift`, `App/TerminalJumpService.swift`,
  révisions d'`App/RetrospectiveRunner.swift` et raccordement de
  `App/LearningSettingsPane.swift`, avec les scénarios et sabotages associés.
- Plugins : annulation dans `App/ClaudeCodeSettingsPane.swift`, propagation
  du home dans `App/CodexSettingsPane.swift` et harness des services plugins.

La campagne n'effectue pas de génération authentifiée, d'écoute humaine des
sons ni de focus vers un terminal utilisateur authentifié. Les anciennes
recettes différées conservent ces limites. Les fixtures ne qualifient pas les
incidents matériels du disque ni les écritures concurrentes d'un fournisseur
cloud. L'app installée et les préférences personnelles ne sont pas remplacées
par une validation ou une publication.

**Avant clôture de cette préparation :** consigner le résultat de la commande
offline commune, des builds finaux et des contrôles documentaires ; préciser ensuite la PR, la fusion et la distribution
réellement effectuées. À cette étape, ces opérations ne sont pas déclarées faites.
