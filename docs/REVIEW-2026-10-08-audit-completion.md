# Audit de robustesse : intégration et validation

Validation terminée le **9 octobre 2026**, sur
`integration/audit-completion-20261008`, source produit figée à `9eaa69d`.
La [PR #16](https://github.com/mehdi7129/atoll/pull/16) est fusionnée le 9 octobre,
merge `fd763f70ea2b8ca8114f71dcc7c82feec2cf5c06`. Les 22 constats sont corrigés
sur `main` et livrés ; la maintenance **0.18.6/build 41** est publiée le 9 octobre 2026.
Ce rapport suit les 22 constats de l'[audit initial](AUDIT-2026-10-08-robustesse-simplicite.md)
et de son [contre-audit](REVIEW-2026-10-08-counteraudit.md), issus de la
[PR documentaire #8](https://github.com/mehdi7129/atoll/pull/8).
La version publiée est **0.18.6, build 41**, depuis `3e10e804` après fusion de la
[préparation #17](https://github.com/mehdi7129/atoll/pull/17). Le code produit
qualifié est inchangé ; [les preuves de livraison](releases/0.18.6.json)
sont distinctes des résultats d'intégration ci-dessous.
Le [relevé consolidé](audit-support/2026-10-08-completion/validation.json)
conserve les résultats bruts, reprises, empreintes et limites de cette validation.
Le contenu historique de #8, réuni par `c25923f`, est intégré sur `main` par #16,
en conservant les 30 entrées alors présentes dans le registre des relectures.
La PR documentaire #8 est également marquée fusionnée après son intégration via #16.

## État des 22 constats

Les **22 corrections sont livrées** : A01, A19 et A22 en 0.18.5 ; les dix-neuf
autres en **0.18.6/build 41**, après les PR
[#14](https://github.com/mehdi7129/atoll/pull/14) (`13dad53`),
[#15](https://github.com/mehdi7129/atoll/pull/15) (`0016c0c`) puis
[#16](https://github.com/mehdi7129/atoll/pull/16) (`fd763f7`).

| ID | Correction | Livraison | Preuve ciblée |
|---|---|---|---|
| A01 | Collision de notes refusée avant remplacement, résultat conservé pour reprise | Livré en 0.18.5 | [Curation](REVIEW-2026-10-08-a01-curation-collision.md) |
| A02 | État de curation illisible conservé et retenté | Livré en 0.18.6, PR #14 | [Intégrité](REVIEW-2026-10-08-a02-a03-integrity.md) |
| A03 | Accès refusé à un skill distingué de sa disparition | Livré en 0.18.6, PR #14 | [Intégrité](REVIEW-2026-10-08-a02-a03-integrity.md) |
| A04 | Markdown remplacé transactionnellement, y compris à métadonnées identiques | Livré en 0.18.6, PR #16 | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A05 | Dernière ligne complète de `cwd` conservée | Livré en 0.18.6, PR #16 | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A06 | Carte Claude et phase corrélées à la demande et à son helper | Livré en 0.18.6, PR #16 | [Permissions](REVIEW-2026-10-08-claude-permissions.md) |
| A07 | Hooks sonores restitués dans leur matcher d'origine | Livré en 0.18.6, PR #15 | [Hooks](REVIEW-2026-10-08-a07-a08-hooks.md) |
| A08 | Doublons Atoll normalisés dans les groupes mixtes, hooks tiers conservés | Livré en 0.18.6, PR #15 | [Hooks](REVIEW-2026-10-08-a07-a08-hooks.md) |
| A09 | Résolution, processus et drains bornés ; budget des enfants vivants conservé | Livré en 0.18.6, PR #16 | [Processus](REVIEW-2026-10-08-processes.md) ; [consommateur plugins](REVIEW-2026-10-08-plugins.md) |
| A10 | Installation du helper sérialisée hors MainActor | Livré en 0.18.6, PR #16 | [Processus](REVIEW-2026-10-08-processes.md) |
| A11 | Identité du processus revérifiée avant chaque signal | Livré en 0.18.6, PR #16 | [Processus](REVIEW-2026-10-08-processes.md) |
| A12 | Annulation limitée à la recherche plugins concernée | Livré en 0.18.6, PR #16 | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A13 | Estimations limitées à deux CLI simultanés, une par identifiant | Livré en 0.18.6, PR #16 | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A14 | Cache de coût invalidé selon version, source, scope et disparition | Livré en 0.18.6, PR #16 | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A15 | Instance NSSound distincte par événement | Livré en 0.18.6, PR #16 | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A16 | Journal et notes du panneau invalidés après persistance | Livré en 0.18.6, PR #16 | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A17 | Fin du CLI attendue, granularité annoncée prouvée, ordre des jumps conservé | Livré en 0.18.6, PR #16 | [Feedback](REVIEW-2026-10-08-feedback.md) |
| A18 | Lecture refusée retentée sans acquittement anticipé de l'offset | Livré en 0.18.6, PR #16 | [Mémoire](REVIEW-2026-10-08-memory.md) |
| A19 | Échec d'archivage conservant le skill installé et son manifeste | Livré en 0.18.5 | [Archivage](REVIEW-2026-10-08-a19-skill-archive.md) |
| A20 | Catalogue associé au projet, binaire et home ; résultats tardifs ignorés | Livré en 0.18.6, PR #16 | [Plugins](REVIEW-2026-10-08-plugins.md) |
| A21 | Helper fail-open quand stdout est fermé | Livré en 0.18.6, PR #16 | [Processus](REVIEW-2026-10-08-processes.md) |
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
  Fleet et le Trousseau conservent leur sonde ; les commandes plugins gardent
  aussi leur workspace, verrou ou place de détail jusqu'à la sortie observée.
- **Mémoire, panne au deuxième lot JSONL** : l'offset d'un bloc de 4 Mio
  n'est plus acquis au premier flush de 500 lignes. Seules les lignes validées
  transactionnellement sont acquittées ; le reste sera relu.

La contre-review plugins a vérifié l'annulation pendant une lecture partagée,
la mutation concomitante, un coût d'ancienne version encore en vol et les
réponses tardives après changement de contexte. Aucun autre blocage confirmé
dans ce périmètre. Cette revue ne remplace pas les tests d'intégration UI.

La contre-review du runner offline a reproduit un descendant survivant au
timeout lorsque son leader sortait sur TERM. Le groupe créé reçoit désormais
KILL après une grâce bornée, avant de reap le leader qui réserve son PID/PGID.
Une fixture réelle et une mutation Python compilée puis exécutée prouvent la
détection. Ce correctif d'outillage ne change pas les délais du produit.

## Simplifications et entretien

La primitive de processus est partagée sans uniformiser les contrats d'auth,
les profils Codex, les décisions ou les reprises propres aux fournisseurs.
L'ingestion distingue explicitement les flux JSONL des documents Markdown.
Le catalogue Codex porte son état de chargement dans une petite façade dédiée.
Aucun framework de services, nouveau réglage ou changement de base n'est ajouté.

Le store de transaction de curation et le snapshot diagnostic immutable des
sessions restent des **pistes conditionnelles** de l'audit, pas des extractions
effectuées. Les invariants de conservation, de reprise et de corrélation sont
testés dans leurs composants actuels. Leur déplacement ne sera justifié que
s'il rend une dépendance ou un invariant mieux testable ou réduit un couplage
concret, conformément à la garde du tableau structurel de l'audit. Le lifecycle
des rétrospectives réutilise l'exécuteur borné en conservant les séparations
préparation/livraison et les API de la façade.

Les quatre tâches d'entretien de l'audit sont terminées et livrées :

| Tâche | État livré |
|---|---|
| Retrait des API sans consommateur produit | Intégré par `d0561e3` ; types et tests d'adoption utiles conservés |
| Commande offline commune et CI macOS | Intégrées par `4cb97df`, arrêt des descendants par `0424604`, préflight des sources par `d2749a5` ; [profils et commandes](VALIDATION.md), sans compte, génération ni publication automatique |
| Vérifications de distribution versionnées | Intégrées par `86ad979` ; DerivedData privé pour le packaging par `bf9cc0d` ; [procédure](RELEASE-VALIDATION.md) |
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
| Plugins A12/A13/A14/A20 et consommateur A09 | Nominal final : 145 assertions réussies ; douze sabotages compilés détectés ; 30 plugins : maximum deux lectures simultanées |
| Feedback A15/A17 | Sept assertions AppKit silencieuses, huit parcours IDE, quatre sabotages compilés détectés |
| Feedback A16 | Runners réels et observateurs des révisions ; sabotages journal et notes détectés dans les parcours de rétrospective |
| Processus A09/A10/A11/A21 | Six tests Core ciblés, 17 parcours services, huit parcours analyses, stdout fermé et écritures partielles/EINTR ; douze sabotages compilés détectés ; [relevé](audit-support/2026-10-08-processes/validation.json) |
| Runner offline | Huit contre-épreuves Python réussies, dont descendant survivant et mutation causale ; plan full de 120 étapes comprenant 85 variantes nommées |
| Core Debug et Release sur l'intégration finale | **1 131 tests, un skip, zéro échec** dans chaque configuration ; Release repris en 11,1 s sans modification de sources ni tests |
| Builds Debug et Release finaux | Réussis sur la source produit `9eaa69d` ; produits de build non lancés |
| Suite offline full | 120 étapes consolidées : 119 réussies au premier passage, A21 réussi après correction de sa fixture et rejeu nominal/mutant ; résultat brut en échec conservé |
| CI GitHub standard | [26 étapes sur 26 réussies](https://github.com/mehdi7129/atoll/actions/runs/37898153598), sur `3e10e804` ; source exacte de la release |
| Interactions GUI A16/A20 | Deux nominaux et trois mutants compilés détectés ; neuf captures inspectées ; [relevé](audit-support/2026-10-09-ui-refresh/validation.json) |

Les tests utilisent les classes produit et des fixtures privées. Un sabotage
doit compiler puis échouer sur l'oracle attendu ; une erreur de compilation ou
un nominal déjà cassé ne vaut pas détection. Les scripts et rapports de lots
donnent les commandes, les injections et leurs limites.

Le premier passage Core Release du 9 octobre à 08:36 a échoué sous une charge
système supérieure à 600 : quatre assertions du runner borné, une d'annulation
du client Codex et une borne de performance du parseur de tâches. Ce résultat
reste conservé dans `core-release-final.log`. Huit tests ciblés passent ensuite
en 2,1 s ; la suite complète repasse à 08:41, en 11,1 s, avec **les mêmes sources
et les mêmes tests**, dans `core-release-recheck-all.log`. Aucun seuil de produit
ou de test n'a été assoupli pour cette reprise.

La campagne full conserve son résultat brut `failed` et son exit 1 : la fixture
A21 utilisait un chemin de socket Unix trop long. Le correctif `1454f6b` porte
uniquement sur le harness ; le nominal et le mutant compilé ont ensuite passé,
avec leurs empreintes et oracles conservés. Le relevé consolidé conclut
`passed`, sans réécrire ce premier échec ni présenter les 120 étapes comme un
unique passage vert.

La première CI a également mis en évidence un ordre de préparation non
déterministe dans la fixture `queue-barrier`. Le défaut du test a été reproduit,
puis corrigé par `f8d802d` ; les 17 parcours et les mutants barrière,
sérialisation et coalescence ont été rejoués. La nouvelle CI passe les 26 étapes
sur cette tête. L'arbre produit est identique à celui de l'intégration finale ;
ce premier succès reste lié à sa tête. La campagne finale
[26 étapes sur 26](https://github.com/mehdi7129/atoll/actions/runs/37898153598)
passe sur la source exacte `3e10e804`, avec les évolutions de harness intégrées.
Les mises à jour documentaires de publication restent distinctes de cette CI.

**Interface :** sept cas OCR de la copie protégée passent : réglages Claude,
Codex, Apprentissage, Alertes, Autonomie, onboarding sans fournisseur et carte
Claude. La copie vient du premier build Debug `fedd2af` ; les fichiers UI sont
identiques dans la source produit `9eaa69d`. Les sept captures ont été inspectées visuellement : elles sont lisibles,
sans défaut nouveau visible dans ces états. Cette inspection et l'OCR ne
constituent pas une recette VoiceOver ni une qualification des animations.
Les [recettes d'interaction A16/A20](REVIEW-2026-10-09-ui-refresh.md) passent
séparément : journal et notes s'actualisent dans la même vue montée ; le vrai
bouton home invalide le catalogue affiché et une réponse tardive reste ignorée.
Deux nominaux, trois mutations UI compilées et neuf captures inspectées
qualifient ces raccordements. Le texte d'entrée du home et le lecteur catalogue
sont injectés ; la saisie clavier AppKit, le redémarrage des services Codex et
un catalogue authentifié ne sont pas qualifiés par cette recette.

**Distribution :** le nouveau vérificateur a été exercé sur les artefacts
existants de **0.18.5** : six signatures Sparkle acceptées et leurs copies
altérées rejetées, sept binaires universels, delta 39 → 40 et app du DMG
identiques aux 134 objets de l'archive, 19 URL et sept téléchargements SHA256.
Ce contrôle qualifie l'outil et cette ancienne livraison. La maintenance
**0.18.6, build 41** a ensuite reçu sa propre validation :

App et DMG universels arm64 / x86_64 signés Developer ID, notarisés,
staplés et acceptés par Gatekeeper. Les 6 signatures Sparkle sont vérifiées
et leurs 6 copies altérées rejetées. Le différentiel 40 → 41 et l'app du DMG
reproduisent les 134 fichiers, liens et modes du ZIP complet.
Les 7 téléchargements publics correspondent aux SHA256 et tailles validés ;
les 19 URL contrôlées sont disponibles. Le flux Sparkle a été publié après les
assets et sert les octets vérifiés, avec 0.18.6/build 41 en tête.
[Relevé de livraison 0.18.6](releases/0.18.6.json).

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
Le rapport GUI atteste également une lecture intégrale de son harness et de
ses trois fichiers Swift ; leur nouvelle entrée ne revendique aucune relecture
complète supplémentaire du code produit. Les 31 entrées antérieures sont
conservées, avec cette 32e entrée dédiée à la recette GUI.

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
- Outillage : plan, dépendances et verdicts dans `Scripts/validate-offline.py`,
  contre-épreuves de `Scripts/test-offline-validation.py`, isolation du packaging
  dans `Scripts/release.sh` et `Scripts/test-release-trash.py`, droits et artefacts
  de `.github/workflows/validation.yml`. Le runner `macos-26` est confirmé comme
  standard arm64 dans la [documentation GitHub](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/) ;
  sa campagne distante réussie est liée dans le tableau de validation.

La campagne n'effectue pas de génération authentifiée, d'écoute humaine des
sons ni de focus vers un terminal utilisateur authentifié. Les anciennes
recettes différées conservent ces limites. Les fixtures ne qualifient pas les
incidents matériels du disque ni les écritures concurrentes d'un fournisseur
cloud. L'app installée et les préférences personnelles ne sont pas remplacées
par une validation ou une publication. Le snapshot de reprise `local-resume.json`
est identique à `local-before.json` pour l'app stable, les quatre produits Debug
habituels et les trois configurations personnelles contrôlés.
Le contrôle de publication part d'un nouveau snapshot pris à sa reprise :
l'app, les quatre Debug et les trois configurations sont identiques jusqu'à
l'achèvement. Entre avant packaging et reprise, une différence de `config.toml`
a été constatée, d'origine indéterminée ; cet intervalle n'est pas présenté comme
une preuve d'intégrité de cette configuration. Le relevé de livraison conserve
ces comparaisons distinctes.

**Clôture :** les 22 constats et les quatre tâches d'entretien sont livrés.
Les artefacts 0.18.6/build 41, leurs téléchargements publics et le flux servi
sont vérifiés. L'app installée reste sous le contrôle de l'utilisateur ;
les limites de recette ci-dessus demeurent explicites.
