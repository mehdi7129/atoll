# Atoll avec Codex CLI et Claude Code

État du code au **2026-09-10**, développé sur `1b08ebd` (v0.17.2).
Ces changements ne sont **pas encore publiés**. Voir le [rapport de mise en œuvre](IMPLEMENTATION-2026-09-10-codex-claude.md) pour les preuves et les vérifications restantes, et l'[audit initial](AUDIT-2026-09-09-codex-claude.md) pour les défauts de la base.

## Périmètre et choix de fournisseur

Codex CLI dans un terminal, y compris le terminal intégré de Cursor ou VS Code.
L'application Codex/ChatGPT, les extensions IDE, les sessions cloud et plusieurs
`CODEX_HOME` simultanés ne sont pas pris en charge par cette intégration.

Les boutons **CLAUDE CODE / CODEX** sélectionnent la liste, le quota principal et
la palette. Les deux collecteurs continuent d'observer leurs intégrations.
Claude garde son accent orange ; Codex reçoit un accent cyan. Les palettes sont
personnalisables séparément. Le bouton ne change ni l'abonnement des analyses,
ni la destination d'un skill, ni le fournisseur d'une conversation existante.

Les demandes partagent une file de présentation, ordonnée par arrivée. La carte
visible reste épinglée ; une arrivée ne la remplace pas. La navigation est
volontaire. La carte conserve la palette de son fournisseur et les décisions
passent par le centre et le socket d'origine. Après sa résolution, la vue
retrouve le fournisseur choisi. Les compteurs signalent aussi les demandes de
l'autre fournisseur.

Rockstar appartient à Claude. Son réglage n'est pas changé par le sélecteur.
S'il reste actif pendant que Codex est affiché, **CLAUDE · ROCKSTAR** reste
visible, y compris en compact et sans session Claude.

## Matrice du code actuel

« Implémenté » décrit le code et les tests cités ; le parcours GUI complet
reste à valider, comme indiqué dans le rapport.

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
| Usage des skills | Observations disponibles, couverture partielle | Non mesuré ; aucune suggestion d'archivage sur un faux zéro |
| Plugins | Catalogue et gestionnaire Claude | Catalogue local natif ; mutations dans le gestionnaire Codex |
| Analyses internes | Exécuteur sélectionnable | Exécuteur sélectionnable, modèle natif revalidé |
| Passation | Préparer un contexte pour Codex | Préparer un contexte pour Claude |

Une valeur absente ne devient pas zéro. Le contexte Codex provient de la dernière
mesure `last_token_usage`, jamais des tokens cumulés. La branche est celle du
début du rollout. Ces enrichissements ne créent ni ne réaniment une session.
Une issue d'outil sans verdict explicite reste inconnue dans le condensé.
Aucun coût en dollars n'est déduit d'un abonnement.

## Installation et diagnostic

L'onboarding installe l'agent choisi. Un poste Codex seul ne crée pas de
configuration Claude. Réglages → Codex permet d'installer, réparer ou retirer
l'intégration, de choisir le home et de consulter son état natif.

- Le home sélectionné est enregistré dans le fichier Atoll `codex-home.json`.
  Sans choix explicite, la détection utilise l'environnement puis `~/.codex`.
  Le chemin effectif est affiché. Une sélection invalide bloque l'opération.
- Installation et réparation mettent à jour les **12 définitions Atoll** de
  `hooks.json`, avec sauvegarde avant changement et préservation des hooks
  étrangers. JSON vide/invalide : refus, sans reconstruction destructive.
  Une seconde installation identique évite les écritures inutiles.
- Le superviseur `atoll-codex-bridge` pointe vers le helper absolu du bundle ;
  il est rafraîchi au démarrage si l'intégration est déjà installée.
  Le recall manuel géré par Atoll reçoit aussi ce chemin.
- `config.toml` et le trust restent gérés par Codex. **Ouvrir /hooks, relire
  et approuver les définitions dans le CLI.** Le diagnostic `hooks/list`
  distingue présence, ancien schéma, désactivation, absence de confiance et
  événement effectivement reçu.
- Retirer Codex conserve les hooks étrangers et la mémoire commune. Le recall
  modifié personnellement est conservé. Les skills gérés sont isolés par
  destination et par home. Un dossier hors manifest avec un SKILL.md différent
  provoque une collision. Un contenu strictement identique peut être adopté
  comme reprise d'une installation interrompue ; le dossier est archivé avant
  remplacement. Le recall applique aussi cette reprise au texte exact attendu.

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

Le catalogue de plugins Codex utilise `plugin/list` limité aux marketplaces
locales. Les mutations restent dans `/plugins` ou les commandes montrées par
`codex plugin --help`. Une recherche IA sur le catalogue Claude peut employer
Codex comme exécuteur ; elle demeure une recherche de plugins Claude.

## Vérifications relançables

Version native vérifiée : **codex-cli 0.153.4**. Aucun minimum inférieur n'est
déclaré compatible sur cette seule preuve.

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-runtime.py --sabotage-cancellation
python3 Scripts/test-runtime.py --sabotage-quota-projection
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

### Aperçu et recette GUI restante

Toujours lancer une **copie**, jamais le produit de build :

```sh
ditto /private/tmp/atoll-codex-build/Build/Products/Debug/Atoll.app /private/tmp/Atoll-preview.app
open -n /private/tmp/Atoll-preview.app --args --codex-preview --preview-many --preview-cards
```

Preview Debug interactive, avec données fictives, préférences isolées et aucun
service de production. Options : `--preview-claude`, `--preview-compact`,
`--preview-empty`, `--preview-light`, `--preview-rockstar`,
`--preview-notch`. Les boutons permettent de changer la taille, rejouer les
cartes et les transitions. Ce mode ne prouve pas une permission réelle.

À terminer avec les permissions macOS nécessaires : capture **de la fenêtre de
test**, lecture des images et film ; clair/sombre, encoche/pilule, libellés longs,
défilement de toutes les sessions, carte+switch+quota+Rockstar, clavier,
VoiceOver et réduction des animations. Puis vérifier une vraie TUI Codex et une
vraie TUI Claude avec la copie de test, sans lancer deux Atoll normaux sur les
mêmes sockets. Valider la carte cliquée, les sons app ouverte/fermée, fin/reprise
et retour au terminal. Aucun de ces parcours GUI n'est déclaré réussi ici.

Le contexte de passation et les analyses sont détaillés dans
[CODEX-FAILOVER.md](CODEX-FAILOVER.md). L'historique de l'ancienne PR reste dans
git ; ses tableaux expérimentaux ont été remplacés ici pour éviter de décrire
des limites déjà corrigées comme l'état actuel.
