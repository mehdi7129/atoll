# PR #2 — corrections après la relecture de Claude

> État de cette première passe. La validation suivante, les P3 supplémentaires
> et les limites actuelles avant fusion sont dans le
> [rapport skills et validation native](REVIEW-2026-09-10-skills-validation.md).

État du **10 septembre 2026**, branche `codex/claude-codex-compatibility`.
La [PR #2](https://github.com/mehdi7129/atoll/pull/2) reste en brouillon pour
relecture par Mehdi. Aucune release ni remplacement de l'app stable.

Cette passe reprend les constats du [document de passation](../codex/MESSAGE-DE-CLAUDE.md)
portant sur `f25fee6`, transmis dans `63f1ba9`. Elle complète le
[rapport initial](IMPLEMENTATION-2026-09-10-codex-claude.md), qui est historique.
Le périmètre produit est **Codex CLI dans le terminal**, avec Claude Code en
parallèle ; Rockstar demeure exclusivement Claude.

## Les cinq décisions de Mehdi

Les cinq réponses explicites de cette conversation sont appliquées :

| Décision | Comportement |
|---|---|
| Repos | Invisible sans session ni Rockstar ; sélecteur avec activité ou Rockstar |
| Liste | Rangées bornées par l'espace disponible ; surplus « +N autres » |
| Compact Rockstar | Marqueur Claude et quota simultanés |
| Hooks au démarrage | Migration des anciennes formes, retraits et personnalisations préservés |
| Bienvenue | Proposition de régler le moteur ; aucun changement automatique du choix existant, même clé absente |

Le moteur et son budget se règlent uniquement dans **Apprentissage** ; le
catalogue et le choix du modèle Codex restent dans **Réglages → Codex**. Le choix
de vue, la destination des skills et le moteur des analyses restent distincts.

## R01 à R11 : résultat et preuve

| Constat | Correction | Vérification effective |
|---|---|---|
| R01 — panneau vide | Retrait du scroll au niveau du corps ; liste `VStack` bornée | Captures Claude et Codex sous l'onde ; ancien build détecté comme défaillant |
| R02 — îlot peint au repos | Géométrie et contenu compact conditionnés par activité ou Rockstar | Capture encoche vide, test du pixel de l'aile ; ancien build échoue |
| R03 — carte et boutons masqués | Scroll interne contraint, actions prioritaires ; cartes/détails hors du `layerEffect` parent | Plan, feedback et trois boutons Codex visibles ; variante réintroduisant le défaut échoue |
| R04 — surplus silencieux | Retour à `IslandRowBudget.rows`, place du sélecteur déduite | 12 sessions : 4 rangées et « +8 autres » dans le cas sans bannière ; test Core saboté |
| R05 — quota perdu en Rockstar | Deux lignes compactes, marqueur Claude + quota ; marge de bord | Captures pilule/encoche, quota 18 % et marqueur simultanés ; ancien build échoue |
| R06 — capture perdue et onboarding | Refus journalisés avec cause ; installation sans écriture du moteur | Trois refus réels des runners ; accueil avec clé absente, Claude ou Codex ; sabotage du journal et de l'écrasement |
| R07 — préparation facturée au redémarrage | États persistés `preparing` / `launching` / `running`, intention juste avant spawn | 3 consommateurs × 4 états de reprise ; sabotages de la récupération et de chacun des trois appels de lancement |
| R08 — reprise anonyme fermée | Incertitude `.unknown` ; preuve ancienne `.closed` ; expiration à 1 h | Reprise sans réanimation arbitraire, antériorité et expiration ; deux sabotages Core |
| R09 — hooks réimposés | Migration en place, sauvegarde datée, lanceur rafraîchi indépendamment | 11/12 événements sans réécriture, délai 999, délai court personnalisé, ordre et hooks étrangers conservés ; trois sabotages |
| R10 — passation vers CLI absent | Dossier existant et CLI exécutable exigés ; cache revérifié après retrait | Fixtures de fichiers réels, suppression du CLI, capture sans bouton ; sabotage de la condition |
| R11 — enveloppes machine en mémoire | Quatre familles ajoutées, fermeture exigée, migration v2 et sauvegarde nettoyée si incomplète | Mesure locale, citations/suffixes, migration idempotente et snapshot ; trois sabotages Core |

Pour R09, une configuration manuelle **strictement identique** à l'ancien
schéma ne porte aucune preuve permettant de la distinguer d'une installation
ancienne. Elle peut donc être migrée, avec sauvegarde. Un message de statut,
un `async: false` ou une clé personnelle empêche d'assimiler une permission de
3 s à l'ancienne télémétrie. La réparation complète reste une action explicite.

## Mesure mémoire et seconde analyse

`Scripts/audit-codex-envelopes.py` lit les rollouts et n'émet que des agrégats.
Échantillon du 10 septembre : **109 fichiers, 1 298 messages `user`, aucune
ligne JSON malformée**. Parmi eux : 280 `task-notification`, 76 `command-name`,
72 `local-command-stdout`, 7 `realtime_delegation`, soit **435 enveloppes**,
toutes d'origine `Codex Desktop` et toutes munies d'un jumeau `event_msg`.
Les 863 autres messages se répartissent en 775 avec jumeau et 88 sans.

La piste de Claude consistant à utiliser ce jumeau comme preuve structurelle
est donc **réfutée sur ce corpus**. Le schéma rencontré est
`event_msg.payload.item.type == "UserMessage"`. Une liste de tags, même
enrichie, reste une heuristique textuelle : le commentaire et la documentation
ne la présentent plus comme une preuve structurelle. Les nouvelles enveloppes
incomplètes, les citations et le texte placé après une enveloppe complète
restent humains. Les six anciennes familles conservent leur comportement
historique ; voir les limites ci-dessous.

La seconde passe a également amélioré le premier correctif :

- Rétablir la liste bornée ne suffisait pas : les champs natifs restaient
  incompatibles avec l'onde du parent. Le rendu et les clics ont conduit à
  limiter l'effet aux groupes qui se dessinent correctement.
- Ne plus compter `preparing` ne devait pas créer une dépense invisible entre
  spawn et sauvegarde. L'état durable `launching` couvre cette courte fenêtre.
- Le lien de bienvenue utilisait une mauvaise clé d'onglet. La recette vérifie
  maintenant `apprentissage`, en plus de la conservation du moteur.
- Une recette d'accueil sans clic effectif pouvait donner un faux résultat.
  Elle exige maintenant le changement visible « HOOKS INSTALLÉS » avant
  d'évaluer la préférence ; le sabotage est refusé si le clic n'a pas eu lieu.
- Les hooks personnalisés avec un délai court ont reçu un test supplémentaire,
  rouge avant correction, puis vert et saboté après correction.

## Vérifications exécutées

| Vérification | Résultat |
|---|---|
| Suite AtollCore complète | **1 005 tests, 1 skip, 0 échec** |
| Harness des runners et cartes de production | **58 scénarios, 0 échec**, sans génération IA |
| Sabotages Core | **12 mutations détectées**, compilation réussie exigée avant de compter un échec |
| Sabotages runtime | **10 mutations détectées**, dont chacun des trois consommateurs |
| Matrice GUI finale | **16 scénarios réussis**, captures et OCR ; images relues |
| Sabotages GUI/helper | Liste, repos, Rockstar, carte Codex, écrasement du moteur, mauvais onglet et helper appelé par nom nu détectés |
| Builds macOS | Debug et Release réussis ; signature Release vérifiée avec `codesign --verify --deep --strict` |
| CLI natif 0.154.0 | `hooks/list` (12 définitions), `skills/list`, `plugin/list`, installation/recall/retrait et nom nu du helper réussis en environnement de test |

Le skip Core est `testLiveReadOnlyAccount`, opt-in de lecture du compte réel ;
il n'est pas compté comme une réussite. Les appels de catalogue sont en lecture seule, avec home
temporaire. Le test de génération réelle du rapport initial concernait le
runner sur Codex 0.153.4 ; aucune nouvelle génération IA n'a été lancée ici.
Ces deux versions testées ne suffisent pas à promettre la compatibilité de
toutes les versions antérieures ou futures.
Le panneau Réglages Codex de l'aperçu est volontairement en lecture seule :
ses boutons de configuration n'agissent pas sur le home réel pendant cette
recette de rendu. Sa capture a été revérifiée après cette protection.

Les sabotages runtime relançables sont `cancellation`, `quota-projection`,
`budget-recovery`, `budget-admission`, `capture-journal`, `launch-retro`,
`launch-curation`, `launch-search`, `curation-retry`, `curation-journal`
(options `--sabotage-…` de `Scripts/test-runtime.py`). Les mutations Core
vivent dans `Scripts/test-review-regressions.py`. Les défauts GUI réintroduits
se testent avec `Scripts/test-ui-sabotage.py` ou une copie ancienne isolée et
`Scripts/test-ui.py --case … --expect-failure`.

### Preuves visuelles conservées

Les fichiers ci-dessous ne contiennent que la fenêtre de recette et ses
données fictives. Les captures originales sont conservées sans retouche.

- Listes : [Codex](reviews/2026-09-10-pr2/list-codex.png), [Claude](reviews/2026-09-10-pr2/list-claude.png), [clair](reviews/2026-09-10-pr2/light.png).
- Cartes : [plan Claude](reviews/2026-09-10-pr2/card-claude.png), [permission Codex](reviews/2026-09-10-pr2/card-codex.png).
- Compact : [repos](reviews/2026-09-10-pr2/idle-notch.png), [Rockstar et quota](reviews/2026-09-10-pr2/rockstar-notch.png), [session](reviews/2026-09-10-pr2/compact.png).
- Parcours : [détail sans CLI de destination](reviews/2026-09-10-pr2/detail-cli-absent.png), [bienvenue après installation simulée](reviews/2026-09-10-pr2/onboarding-unset.png).
- Animation : [extrait de 4 secondes](reviews/2026-09-10-pr2/transition-notch.mp4), [24 vues de l'ouverture](reviews/2026-09-10-pr2/transition-opening.png).

L'inspection native a aussi exercé la navigation Claude/Codex par clic, conservé
le brouillon `brouillon_ATOLL_verifie` après aller-retour, puis utilisé ⌘N :
seule la carte visée disparaît. Les agents sont identifiés dans l'arbre
d'accessibilité. Cela ne constitue **pas** un test VoiceOver parlé ni une
permission d'un vrai CLI.

Un cycle de repli/ouverture avec encoche a été filmé sur la copie 4, puis relu
image par image. La vidéo source mesure 1 560 × 1 224, 1 687 images sur 29,992 s,
soit environ 56 images/s en moyenne ; le fichier annonce aussi un débit nominal
de 240, qui n'est pas une mesure de fluidité. Les premières tentatives ayant
manqué le clic d'animation ont été écartées. Le cycle retenu revient à la liste
complète sans panneau durablement vide. La copie 5 diffère seulement par le
libellé de surplus, la marge compacte et la navigation des réglages ; leurs
captures finales ont été relues. L'animation n'est pas validée sur toutes les
tailles, tous les matériaux ni tous les modes d'accessibilité.

## P3 : traitement explicite

| Zone | Corrigé dans cette passe |
|---|---|
| Interface | Glyphe de skill rétabli ; nom compact conservé ; quota principal de repli et libellé court ; agent Claude explicite ; clé de palette commune ; moteur regroupé dans Apprentissage ; date fictive récente ; termes simplifiés |
| Analyses | Chargement du budget avant admission ; curation sans boucle sur absence de travail/corpus trop gros ; refus persistés ; ancienne comptabilité et drapeau morts retirés ; modèle/raison de quota au journal ; fraîcheur Claude 600 s ; message de journal corrompu avec chemin ; état d'attente non republié chaque seconde |
| Sessions/helper | Refus de home journalisé ; résolution du véritable chemin du helper, même invoqué par nom nu ; documentation de l'exclusion des processus internes corrigée |
| Fichiers | Snapshot partiel et fichiers SQLite associés retirés ; sauvegarde initiale décrite correctement ; métadonnée Finder tolérée sans installation ; erreur de manifest adaptée aussi à une approbation ; ancien home conservé annoncé |
| API/doc | `IslandRowBudget.rows` et `refreshWrapper` à nouveau utilisés en production ; caractère heuristique du parser et différences des condensés explicités |

Les points suivants demeurent des limites ou du travail ultérieur ; ils ne sont
pas rebaptisés « corrigés » :

| Point restant | Comportement actuel et suite proposée |
|---|---|
| Survol du sélecteur compact | Déploiement après 150 ms, choix accessible dans l'îlot ouvert. Mesurer le conflit clic/survol avant de modifier la règle globale |
| Revue des skills | Après décision, retour à la première proposition ; catalogue Codex vérifié au premier clic, nouvelle antériorité à relire avant confirmation. Préserver la position et précharger la sélection dans une recette dédiée |
| Préférences de recette | Le harness nettoie ses domaines ; un aperçu lancé à la main puis tué peut laisser un plist privé orphelin. Ajouter un nettoyage borné si cet usage devient courant |
| `CodexRun` | Paramètre `workingDirectory` inutilisé (l'isolation est correcte) ; catalogue modèle illisible encore confondu avec modèle non validé. Séparer les raisons d'échec et supprimer ce paramètre sans affaiblir la revalidation avant dépense |
| Watchdog sans identité lisible | Pas de signal si `proc_pidinfo` échoue. Ne pas réintroduire un `kill(pid)` risquant un PID recyclé ; tester des tentatives bornées de lecture et un protocole de supervision d'enfant |
| Journal corrompu | Refus de nouvelles dépenses jusqu'à correction du fichier et redémarrage, désormais expliqué avec son chemin. Pas de réparation destructive automatique |
| Interruption parent/enfant | Les tours enfants sont distincts ; une interruption parent ne prouve pas leur clôture. Cartes bornées par helper/timeout. Exiger une preuve causale native avant élargissement |
| Événement anonyme après reprise | Attribution plausible à l'incarnation courante ; absence d'identité ne peut fournir une certitude. Ne pas inventer une identité |
| Résolution externe d'une carte | La suivante devient cible clavier immédiatement. Un éventuel délai de grâce demande une décision UX et une recette focus spécifique |
| Permission non représentable | Son d'attention conservé : la décision humaine reste nécessaire dans le terminal ; aucune fausse autorisation par l'îlot |
| Manifest v1 corrompu | Opérations refusées pour préserver les fichiers ; retrait Claude historique encore silencieux dans ce cas. Prévoir un diagnostic et une réparation explicite, sans deviner la propriété des dossiers |
| Anciennes enveloppes non fermées | Les six familles historiques peuvent absorber un suffixe humain ambigu ; aucun cas observé dans le corpus de revue. Ajouter des fixtures natives avant de changer cette ancienne heuristique |
| Preuves de succès et archivage | Pas de succès d'outil Codex inventé ; tool results conservés sous plafond. Pas de suggestion d'archivage pour les deux agents, couverture insuffisante |
| Sources de notes et catalogues | Une note sans source ou un catalogue tiers cassé bloque l'opération ; conserver cette protection jusqu'à une revue capable de montrer les éléments incertains |
| API de diagnostic | `CodexSessionDiscovery.discover` et `CodexHookSettingsEditor.needsMigration` restent utilisés seulement par leurs tests ; en production la migration calcule directement le résultat une seule fois. Avertissements conservés, sans suppression de tests pour embellir la carte |

L'ordre du travail restant avant fusion est : recette native des deux TUI
(permissions, sons, interruption/reprise, retour au terminal), VoiceOver et
motion réduite, puis arbitrage des P3 d'interaction. Les améliorations de
diagnostic et supervision se traitent ensuite par fixtures de panne ciblées.
La présente passe ne déclare donc ni une recette E2E complète, ni une release
prête à distribuer.

## Incident de recette et état restauré

Pendant l'inspection, l'outil macOS a rouvert la copie 3 fermée **sans arguments**,
donc comme Atoll normal, brièvement aux côtés de l'app stable. Cette violation
de l'isolation a été constatée et annoncée à Mehdi, puis la copie arrêtée.
Elle avait actualisé les wrappers, le chemin du recall Codex, les réglages
Claude via leur installateur, et exécuté l'hygiène mémoire/migration de manifest.

Les chemins ont été restaurés vers le bundle stable, puis celui-ci a été
redémarré après vérification de l'absence d'enfant actif. Les deux sockets ont
été vérifiés connectables ; une seule app normale subsiste. Le bundle stable
v0.17.2 build 34 n'a pas été remplacé. `hooks.json` n'a pas été réécrit pendant
l'incident. Faute d'empreinte antérieure des réglages Claude, leur identité
octet pour octet avant/après n'est **pas** affirmée.

La sauvegarde mémoire complète créée pendant l'incident est conservée :
`~/.atoll/memory-before-codex-hygiene-9F886506-6D1A-4A4B-B0EE-DE126BE866BF.sqlite`
(122 384 384 octets). L'index n'a pas été remplacé par cette copie, ce qui aurait
effacé d'éventuelles écritures plus récentes. Le manifest v2 Claude a été
initialisé ; l'ancien v1 est conservé. Aucune génération IA n'a été déclenchée.

La protection ajoutée est reproductible : `Scripts/prepare-preview.py`
fabrique une copie Debug avec un bundle ID unique et `AtollPreviewOnly=true`.
Une ouverture **sans** `--codex-preview` de cette nouvelle copie a été testée :
elle reste une recette fictive. L'installation de hooks y est simulée et les
services normaux ne démarrent pas. Les anciennes copies non protégées ne
doivent plus être utilisées par un outil susceptible de les lancer.

## Portée de la relecture documentaire

Balayage **sweep**, sans prétention de lecture ligne par ligne de tout le dépôt :
diffs des correctifs, appels du rendu, budget et runners, hooks et sessions,
mémoire/skills, helper, harness et documentation associée. Les fichiers de cette
passe sont nommés dans l'entrée correspondante de `docs/reviews.json`.
Les fichiers non modifiés de la base n'acquièrent pas une nouvelle relecture
par simple voisinage. `check-docs.py` et `review-map.py` restent des contrôles
de cohérence et de couverture, pas des preuves de qualité graphique ou E2E.
Le contrôle complet, tests inclus, passe : **13 familles, 17 avertissements**
(2 API utilisées seulement en tests et 15 signaux de couverture de relecture).
Une entrée sweep supplémentaire ne prétend pas résoudre les manques de lecture
ligne par ligne signalés par la carte.
