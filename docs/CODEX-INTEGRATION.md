# Atoll avec Codex CLI et Claude Code

État du code au **2026-09-11**. L'intégration a été publiée en v0.18.0.
Le retour au compact d'origine, le contexte chiffré et le diagnostic simplifié
sont publiés dans **v0.18.1, build 36** : voir leur
[validation](REVIEW-2026-09-10-island-context-setup.md). L'[audit initial](AUDIT-2026-09-09-codex-claude.md)
et le [rapport PR #2](REVIEW-2026-09-10-pr2-corrections.md) sont historiques.
Les [réglages réorganisés du 11 septembre](PLAN-2026-09-11-settings-organization.md)
sont publiés dans **v0.18.2, build 37**, après fusion de la PR #4.
État courant et preuves de livraison dans [HANDOFF](HANDOFF.md).

## Périmètre et choix de fournisseur

Codex CLI dans un terminal, y compris le terminal intégré de Cursor ou VS Code.
L'application Codex/ChatGPT, les extensions IDE, les sessions cloud et plusieurs
`CODEX_HOME` simultanés ne sont pas pris en charge par cette intégration.
Les rollouts Desktop présents dans le home sélectionné sont néanmoins indexés
par la mémoire commune : absence d'intégration GUI ne veut pas dire exclusion
du corpus. Leur contenu machine reçoit le même filtrage prudent.

Les boutons **CLAUDE CODE / CODEX** sélectionnent la liste, le quota principal et
la palette. Les deux collecteurs continuent d'observer leurs intégrations.
Claude garde son accent orange ; Codex reçoit un accent cyan. Les palettes sont
personnalisables séparément. Le bouton ne change ni l'abonnement des analyses,
ni la destination d'un skill, ni le fournisseur d'une conversation existante.
Le choix se trouve dans le panneau ouvert. En compact : une ligne, activité à
gauche et quota à droite, sans préfixe « CL/CX ». La couleur porte le fournisseur.
Sans activité ni Rockstar, l'îlot est invisible. La liste étendue est bornée
par le budget de rangées, sélecteur compris, avec « +N autres » pour le surplus.
Le quota garde sa place fixe. Les cartes et leurs contrôles défilants restent
hors du `layerEffect` de l'onde ; seuls en-tête, liste et pied de quota le portent.

Les demandes partagent une file de présentation, ordonnée par arrivée. La carte
visible reste épinglée ; une arrivée ne la remplace pas. La navigation est
volontaire. La carte conserve la palette de son fournisseur et les décisions
passent par le centre et le socket d'origine. Après sa résolution, la vue
retrouve le fournisseur choisi. Les compteurs signalent aussi les demandes de
l'autre fournisseur.

Rockstar appartient à Claude. Son réglage n'est pas changé par le sélecteur.
S'il reste actif pendant que Codex est affiché, un **losange rouge** reste visible
avec le quota compact, même sans session Claude. Son libellé d'accessibilité
nomme Claude Rockstar ; le panneau ouvert conserve **CLAUDE · ROCKSTAR**.

## Matrice du code actuel

Le rendu a été vérifié sur une copie isolée. Les parcours Codex authentifiés,
VoiceOver et sons de v0.18.0 sont documentés dans la
[validation finale PR #2](REVIEW-2026-09-10-skills-validation.md).
Claude authentifié et le retour à un terminal visible restent différés.

| Capacité | Claude Code | Codex CLI |
|---|---|---|
| Sessions et état | Collecteur existant | Hooks, identité TUI, registre et réconciliation |
| Permissions | Cartes existantes | Cartes dédiées, payload complet borné, refus/autorisation/retour natif |
| Questions et plans | Cartes Claude | Réponse dans le terminal |
| Interruption | Contrôle Claude existant | Retour au terminal, interruption native |
| Jump-back | Ancre terminal | Ancre capturée ; repli explicite lorsque l'onglet exact n'est pas identifiable |
| Sous-agents | Suivi existant | Lifecycle par agent_id, compteur observé et permissions rattachées au parent |
| Rockstar | Disponible | Non applicable |
| Quota | Statusline / sources Claude | RPC officiel, opt-in, fenêtres et resets serveur |
| Métadonnées | Sources Claude | Projet/modèle par hooks, branche initiale/prompt/contexte par rollout validé |
| Mémoire | Corpus local partagé | Même corpus, provenance distincte et instructions machine filtrées |
| Recall manuel | Skill Claude | Skill Codex installé avec le helper absolu |
| Recall proactif | Hook Claude optionnel | Désactivé ; recall manuel explicite |
| Skills appris | Destination Claude | Destination Codex, catalogue natif, validation avant installation |
| Usage des skills | Observations disponibles, couverture partielle | Non mesuré |
| Plugins | Catalogue et gestionnaire Claude | Catalogue local natif ; mutations dans le gestionnaire Codex |
| Analyses internes | Exécuteur sélectionnable | Exécuteur sélectionnable, modèle natif revalidé |
| Passation | Préparer un contexte pour Codex, si CLI et dossier existent | Préparer un contexte pour Claude, si CLI et dossier existent |

Une valeur absente ne devient pas zéro. Le contexte Codex provient de la dernière
mesure `last_token_usage.total_tokens` et de `model_context_window`, jamais des
tokens cumulés. Le détail montre nombres, fraction et heure de mesure. Une
compaction ou une nouvelle mesure invalide l'efface jusqu'au prochain relevé.
La lecture existante au fil des événements et toutes les 30 s est conservée.
La branche est celle du début du rollout. Ces enrichissements ne créent ni ne
réaniment une session. L'identité TUI reconnaît notamment l'alias `--yolo` ;
les processus auxiliaires du dossier Codex et les commandes headless sont exclus.
Une issue d'outil sans verdict explicite reste inconnue dans le condensé.
Aucun coût en dollars n'est déduit d'un abonnement.

## Installation et diagnostic

L'onboarding installe l'agent choisi. Un poste Codex seul ne crée pas de
configuration Claude. Réglages → Codex permet d'installer, réparer ou retirer
l'intégration, de choisir le home et de consulter son état natif.
Les premières étapes sont `/hooks`, puis un nouveau message dans le CLI.
Le panneau présente l'état du suivi ; les instructions d'approbation s'effacent
après réception d'un événement. « Vérifier la connexion » déplie le diagnostic
pour un **dossier de projet**, sans limiter le suivi aux sessions de ce dossier.
Le home Codex et le projet sont deux réglages distincts ; les chemins, la
réparation et le retrait se trouvent sous « Dépannage ».
Installer un CLI ne change pas le moteur des analyses, même si la préférence
est absente. L'accueil propose Réglages → Apprentissage ; cet onglet reste
l'unique lieu de configuration du moteur, des modèles et du budget. Codex affiche
le choix enregistré et un raccourci qui ouvre Apprentissage sur les analyses.
Le sélecteur Codex est visible quand ce moteur est choisi ou autorisé en repli.
Son catalogue est lu à l'ouverture, sans génération.
Aucun modèle n'est choisi automatiquement ; un choix absent du catalogue ou
une lecture en échec ne remplace pas la sélection enregistrée.

- Le home sélectionné est enregistré dans le fichier Atoll `codex-home.json`.
  Sans choix explicite, la détection utilise l'environnement puis `~/.codex`.
  Le chemin effectif est affiché. Une sélection invalide bloque l'opération.
- Installation et réparation mettent à jour les **12 définitions Atoll** de
  `hooks.json`, avec sauvegarde avant changement et préservation des hooks
  étrangers. JSON vide/invalide : refus, sans reconstruction destructive.
  Une seconde installation identique évite les écritures inutiles.
- Au démarrage, la migration ne recrée aucun événement retiré et ne réordonne
  pas les groupes. Les formes anciennes reconnues sont mises à niveau sur
  place ; les délais, messages et clés personnalisés sont conservés. Une
  permission de 3 s accompagnée d'un message ou d'une clé personnelle n'est
  pas assimilée à l'ancien hook de télémétrie. Si rien ne change, les octets
  et la date de `hooks.json` restent identiques. Chaque vraie migration crée
  sa sauvegarde datée 0600 ; la copie initiale n'est pas forcément pré-Atoll.
- Le superviseur `atoll-codex-bridge` pointe vers le helper absolu du bundle ;
  il est rafraîchi au démarrage si l'intégration est déjà installée.
  Le recall manuel géré par Atoll reçoit aussi ce chemin.
- `config.toml` et le trust restent gérés par Codex. **Ouvrir /hooks, relire
  et approuver les définitions dans le CLI.** Le diagnostic `hooks/list`
  distingue présence, ancien schéma, désactivation, absence de confiance et
  événement effectivement reçu. En cas de confiance partielle, il indique le
  nombre de hooks actifs et les noms exacts des événements à approuver.
- Retirer Codex conserve les hooks étrangers et la mémoire commune. Le recall
  modifié personnellement est conservé. Les skills gérés sont isolés par
  destination et par home. Un dossier hors manifest avec un SKILL.md différent
  provoque une collision. Un contenu strictement identique peut être adopté
  comme reprise d'une installation interrompue ; le dossier est archivé avant
  remplacement. Le recall applique aussi cette reprise au texte exact attendu.
- Un changement de home conserve les artefacts de l'ancien home ; le retrait
  vise le home actuellement choisi. Le panneau l'annonce. Un événement reçu
  pour un autre home est refusé et journalisé.

Les RPC de diagnostic ne créent aucun thread et ne modifient pas la confiance.
Le quota reste un opt-in distinct. Une erreur de compte, une catégorie ambiguë,
une mesure périmée ou un reset ne donnent pas un faux quota disponible.

## Identité, ordre et demandes

Le helper capture le processus **TUI** avec son PID et son instant de démarrage,
le session ID, le rollout et l'ancre terminal. Le registre ne déduit jamais une
session depuis le seul dossier ou la date d'un fichier. Les jobs internes
marqués `ATOLL_RETROSPECTIVE=1` sont exclus.

Fin de session et clôtures de tours gardent des tombstones bornées. Les scans
asynchrones ont leur génération ; leurs résultats anciens sont rejetés.
Une reprise explicite peut rouvrir le même UUID avec une nouvelle identité,
sans accepter les événements de l'ancien processus. Le registre permet de
retrouver un processus encore vivant après redémarrage d'Atoll, même si son
rollout date d'un autre jour.
Sans identité après une clôture, un événement non daté ou plus récent reste
`.unknown` : la demande est conservée, sans réanimer arbitrairement la session.
Une preuve d'antériorité donne `.closed`. Les clôtures expirent après une heure.
Une session anonyme sans nouvel événement passe à l'état non confirmé après
15 minutes ; sa rétention maximale de 24 h ne prouve pas qu'elle travaille.

Les enfants ont leur propre tour. Leurs événements ne remplacent jamais le
rollout, le modèle ou l'outil du parent. Une clôture enfant ne retire que les
cartes du même enfant, tour et processus. Une permission précoce d'un tour
encore inconnu est conservée. Une reprise d'enfant exige un démarrage explicite
daté ; ce cas est testé synthétiquement, sans capture native de reprise.

Une carte correspond à un request ID et un helper encore en attente. Le
contrôle du couple PID/démarrage, les clôtures certaines et l'expiration serveur
la retirent ; un clic tardif est revalidé. L'EOF seul ne prouve pas la mort :
le helper ferme normalement son côté écriture après l'envoi. Les payloads de
permission trop grands ou non représentables retournent au CLI.

Le superviseur conserve stdin avec `exec 3<&0`, lance le worker avec
`<&3 &`, attend par `wait $! 2>/dev/null`, puis sort 0. La mort du worker
devient une abstention. Cette garantie ne couvre pas un signal qui tue le
superviseur lui-même. Le timeout permission reste 600 s ; les autres événements
gardent le contrat court ou async défini dans le générateur.

## Mémoire, skills et plugins

Le corpus est commun par projet et source. Les enveloppes machine reconnues
sont classées `instruction`, avec conservation du texte humain qui les suit.
La correction d'un ancien index est ciblée et transactionnelle, précédée d'une
sauvegarde SQLite autonome. Elle ne reconstruit pas l'index et conserve les
sessions dont le transcript a été purgé.
Le discriminant Codex reste une **heuristique textuelle**. Les quatre familles
`task-notification`, `realtime_delegation`, `command-name` et
`local-command-stdout` sont désormais reconnues lorsqu'elles sont complètes
et en tête du texte ; citations et suffixes humains sont conservés. La
migration `codex-instructions-v2` reprend l'index existant. Sur le corpus
mesuré le 10 septembre, les 435 enveloppes de ces familles ont toutes un
jumeau `event_msg` : ce jumeau ne permet donc pas de distinguer une consigne humaine.
Un snapshot incomplet est retiré ; une sauvegarde complète est conservée.

Les résultats d'outils Codex sans verdict fiable restent inconnus et conservés
dans la limite du condensé. Ils ne fournissent pas une preuve de succès aux
propositions de skills. Les suggestions d'archivage automatique sont inactives
pour **les deux fournisseurs**, leur couverture d'usage étant insuffisante.

Les notes fusionnées conservent des références de sources résolubles jusque dans
les archives. Les propositions fixent leur destination avant l'analyse. Le
catalogue Codex vient de `skills/list` : scopes, enablement, plugin et erreurs
sont conservés. Une erreur de catalogue bloque l'approbation ; une nouvelle
antériorité impose une relecture.

Le manifest v2 vit séparément du v1 Claude. La migration ne déplace pas les
skills ; les changements faits par une ancienne app sont réconciliés ou
signalés en conflit. Le même slug peut exister pour les deux destinations.
Une mise à jour archive l'installation précédente et conserve ses ressources.
Les nouvelles ressources annexes d'une proposition sont refusées, car la revue
actuelle ne montre que `SKILL.md` ; elles ne sont pas installées sans lecture.
Seul un fichier `.DS_Store` ordinaire est toléré comme métadonnée Finder,
jamais copié dans l'installation ; un lien ou dossier homonyme reste refusé.

Le catalogue de plugins Codex utilise `plugin/list` limité aux marketplaces
locales. Les mutations restent dans `/plugins` ou les commandes montrées par
`codex plugin --help`. Une recherche IA sur le catalogue Claude peut employer
Codex comme exécuteur ; elle demeure une recherche de plugins Claude.

## Vérifications relançables

Versions natives vérifiées : **codex-cli 0.153.4** pour les fixtures initiales
et le runner réel ; **0.154.0** pour les catalogues et le recall lors de cette
relecture. Aucun minimum inférieur n'est déclaré compatible sur cette seule preuve.

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-runtime.py --sabotage-cancellation
python3 Scripts/test-runtime.py --sabotage-quota-projection
python3 Scripts/test-review-regressions.py
python3 Scripts/audit-codex-envelopes.py
python3 Scripts/test-codex-catalog.py
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath /private/tmp/atoll-codex-build build
python3 Scripts/test-codex-install-recall.py \
  /private/tmp/atoll-codex-build/Build/Products/Debug/Atoll.app/Contents/Helpers/atoll-bridge
```

La suite Core et le harness runtime utilisent des fixtures. Le test des catalogues
lance le CLI réel en lecture seule dans un home temporaire, sans compte ni modèle.
Le test helper utilise un home macOS de test, sans toucher aux réglages personnels.

L'appel réel optionnel suivant **consomme une génération** et exige une connexion
Codex existante ; il vérifie le runner App, le modèle, le schéma et l'isolation du
dossier de travail :

```sh
python3 Scripts/test-codex-exec.py --live
```

### Aperçu et recette GUI

Toujours lancer une **copie**, jamais le produit de build :

```sh
python3 Scripts/prepare-preview.py \
  /private/tmp/atoll-codex-build/Build/Products/Debug/Atoll.app \
  /private/tmp/Atoll-review.app
python3 Scripts/test-ui.py --app /private/tmp/Atoll-review.app \
  --output /private/tmp/atoll-ui-review
```

Preview Debug interactive, avec données fictives, préférences isolées et aucun
service de production. La copie reste dans ce mode même rouverte sans argument
par un outil macOS. Ne pas réutiliser une ancienne copie non protégée.
Options : `--preview-claude`, `--preview-compact`,
`--preview-empty`, `--preview-light`, `--preview-rockstar`,
`--preview-notch`, `--preview-detail`, `--preview-codex-card`,
`--preview-onboarding`, `--preview-codex-settings`. Les boutons permettent de changer la taille, rejouer les
cartes et les transitions. Ce mode ne prouve pas une permission réelle.

Vérifié : 16 scénarios avec captures de fenêtre et lecture des images,
clair/sombre, encoche/pilule, libellés longs, liste bornée, cartes, détail,
Rockstar, accueil et conservation du moteur. Navigation native entre cartes,
conservation du brouillon et refus au clavier ont été exercés ; un cycle de
transition avec encoche a été filmé et relu. L'OCR complète cette lecture,
il ne prouve ni le focus ni la qualité de l'animation.

Restent à vérifier avant fusion : VoiceOver parlé, matrice complète de motion
réduite/tailles et parcours authentifiés de permissions, sons, fin/reprise et
retour au terminal avec les deux CLI. Cette recette native nécessite une seule
instance normale d'Atoll ; le mode aperçu ne la remplace pas.

Le contexte de passation et les analyses sont détaillés dans
[CODEX-FAILOVER.md](CODEX-FAILOVER.md). L'historique de l'ancienne PR reste dans
git ; ses tableaux expérimentaux ont été remplacés ici pour éviter de décrire
des limites déjà corrigées comme l'état actuel.
