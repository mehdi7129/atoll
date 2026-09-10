# Atoll

```
        ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
  ╭──────────────────────────────────────╮
  │ ⠹ atoll · refonte du README    62%   │
  ╰──────────────────────────────────────╯
```

**Une Dynamic Island pour Claude Code et Codex, dans l'encoche de ton MacBook.**

Trois sessions tournent : un `claude` dans un onglet Cursor, un `codex` dans un iTerm passé
derrière le navigateur, un troisième en arrière-plan lancé il y a vingt minutes. L'un des
trois est bloqué depuis huit minutes sur une demande de permission — tu ne sais pas lequel.
Tu ne sais pas non plus combien de quota il te reste, sur l'un ou sur l'autre abonnement, ni
comment tu avais réglé ce même bug le mois dernier, dans un autre projet.

Atoll met tout ça autour de l'encoche.

> **Atoll ne fait pas travailler les agents.
> Il SAIT ce qui se passe sur ta machine, il s'en SOUVIENT, et il t'APPELLE.**

macOS 14+ · **Claude Code et Codex** · Swift/SwiftUI natif, pas d'Electron ·
zéro télémétrie · zéro compte · **gratuit et open source (GPL-3.0-or-later)**

---

## Savoir — l'état réel, d'un coup d'œil

Tu descends la souris vers l'encoche, l'îlot se déplie :

```
── SESSIONS ────────────────────────────────────────────────────
  ▾ atoll · 2
      ⠹  refonte du README         ██████░░░░  62%   [ WORKING ]
      !  migration de l'index                        [ APPROVE? ]
      ⠹  drone-tracker · trajectoires  ██░░░░░░  19%  [ WORKING ]
      ·  site-vitrine · refonte CSS                   [ DONE ]
── QUOTA ───────────────────────────────────────────────────────
  5 h ███████▏░░  68 %  reset 14:05     7 j ████▎░░░░░  41 %
  Codex  5h  ██▌░░░░░░░  24 %           7j  █▏░░░░░░░░  11 %
```

Les boutons **CLAUDE CODE / CODEX** choisissent les sessions affichées, leur palette
et le quota principal. Les deux collecteurs restent actifs ; leurs compteurs signalent
les demandes en attente. Les sessions sont regroupées par dépôt ou par état, avec une
liste bornée et l'annonce « +N autres ». Le contexte s'affiche lorsqu'une mesure existe ; les fenêtres de quota
et leurs resets viennent des serveurs : **lus, jamais estimés**. Le schéma ci-dessus
illustre les informations disponibles ; la vue choisit celles du fournisseur sélectionné.

Un clic ouvre le détail d'une session. Le retour au terminal utilise l'origine capturée
— Cursor, VS Code, Terminal.app, iTerm2 — avec un repli si l'onglet exact n'est pas identifiable.

## Répondre sans changer de fenêtre

Quand une session demande une permission, une carte apparaît dans l'encoche avec les
détails de la demande. Les cartes de questions et de plans restent propres à Claude ;
avec Codex, ces échanges et l'interruption restent dans le terminal :

```
── PERMISSION ──────────────────
  atoll · migration de l'index
  Bash
  $ sqlite3 ~/.atoll/memory.db "VACUUM;"

  ┌──────────┐   ┌───────────┐
  │ DENY ⌘N  │   │ ALLOW ⌘Y  │
  └──────────┘   └───────────┘
```

`⌘Y`, elle repart. Sans ça, il faut retrouver le bon terminal parmi dix, relire le
contexte, répondre, puis revenir à ce qu'on faisait — trente secondes de concentration
perdues, plusieurs fois par jour.

## Claude Code et Codex, au même endroit

Si tu travailles avec les deux, tu as deux abonnements, deux terminaux, et deux façons de
savoir où en est une session. Atoll les met dans le même îlot, avec un bouton pour choisir
Claude ou Codex, un accent orange ou cyan et **le quota de l'agent choisi**. La carte déjà
affichée garde son fournisseur jusqu'à sa résolution ; une nouvelle demande ne la remplace
pas. Le retour au terminal utilise l'ancre capturée et propose un repli lorsque l'onglet
exact n'est pas identifiable.

Sans activité ni Rockstar, l'îlot disparaît. La liste reste bornée et annonce les
sessions supplémentaires. Rockstar conserve son marqueur Claude et le quota en compact.

Le reste suit : les rollouts Codex entrent dans la même mémoire locale, le bilan de fin de
session sait les relire, et les sons sonnent pareil.

**Les décisions restent étanches.** Socket séparé, événements séparés, décisions séparées :
une permission Codex ne traverse jamais la logique écrite pour Claude, et une règle que tu as
posée pour l'un ne s'applique jamais à l'autre — le mode Rockstar, en particulier, ne décide
jamais pour Codex. C'est une isolation réelle, pas un drapeau dans une fonction commune.

**La mémoire, elle, est commune — et c'est voulu.** Un index unique, pas deux : c'est tout
l'intérêt de se souvenir d'un dépôt plutôt que d'un outil, et un souvenir venu d'une session
Codex peut donc remonter pendant une session Claude. Si tu veux que les deux n'aient rien en
commun, l'indexation se coupe dans Réglages → Mémoire — elle les coupe alors tous les deux.

L'installation est distincte et facultative — Atoll marche très bien avec un seul des deux.
Pour Codex, elle gère ses définitions dans `hooks.json`, leur lanceur et le skill manuel
`atoll-recall`. Les hooks étrangers sont conservés et sauvegardés avant modification.
Au démarrage, Atoll migre ses anciennes définitions en respectant les retraits et les
personnalisations ; leur réinstallation complète passe par « Réparer ». Le choix du CLI
à l'accueil conserve le moteur d'analyse existant et propose d'ouvrir ses réglages.
`config.toml` et les choix de confiance restent gérés par Codex : les hooks doivent être
relus et approuvés dans `/hooks`.

## Se souvenir — au-delà d'un seul dépôt

Tous les transcripts de toutes tes sessions passées — Claude Code **et** Codex — sont
indexés **en local** (SQLite FTS5, dans `~/.atoll/memory.db`). La recherche est locale ;
les extraits rappelés dans une conversation ou fournis à une analyse sont ensuite traités
par le fournisseur choisi pour cette conversation ou cette analyse.

Le skill manuel `atoll-recall` ouvre ce passé à Claude comme à Codex :

> « comment on avait réglé ce problème de signature, le mois dernier ? »

La réponse cite la date, le projet, et la commande pour reprendre la session concernée.

**Le point clé** : la mémoire native de Claude Code est *par dépôt*. Celle d'Atoll traverse
toute la machine — elle sait qu'une solution trouvée sur un projet de drones s'applique à
ton app iOS.

## T'appeler — même app fermée

Deux sons distincts et personnalisables : **une décision t'attend**, et **une session a
fini**. Au choix parmi les sons macOS ou tes propres fichiers, avec un volume par événement.

Ils sonnent **même si Atoll est fermé** : c'est le helper appelé par les hooks qui joue, pas
l'app. Un outil qui ne t'appelle que lorsqu'il tourne ne sert à rien le jour où tu l'as
quitté.

Si tu jouais déjà des sons via des hooks `afplay`, Atoll te propose de reprendre tes
fichiers et met tes hooks de côté pour éviter le double — réversible d'un clic, et restitué
automatiquement à la désinstallation.

---

## Ce qu'Atoll ne fait pas — volontairement

- **Il n'orchestre pas ton travail.** Tu lances tes sessions dans leur CLI ; Atoll les
  observe. Ses analyses facultatives servent uniquement à la mémoire et aux skills.
- **Il laisse les politiques de permissions aux CLI.** Les cartes transmettent ta
  décision ; le mode Rockstar Claude reste un choix explicite, décrit plus bas.
- **Il ne collecte rien.** Pas de télémétrie, pas de compte, pas de serveur, pas d'Electron.
- **Il ne peut pas casser ton CLI.** Règle absolue du projet : Atoll fermé, lent ou planté,
  Claude Code et Codex continuent. La désinstallation restitue ta configuration
  d'origine.

Claude est découvert par `claude agents --json`, complété par ses hooks. Codex utilise ses
hooks, l'identité de son processus et les rollouts locaux ; chaque intégration reste distincte.

## Installer

Télécharge le dernier `Atoll-x.y.z.dmg` depuis les
[Releases](https://github.com/mehdi7129/atoll/releases) et glisse Atoll dans Applications.

L'app est signée Developer ID et notarisée par Apple. Les mises à jour passent par Sparkle,
avec une vérification automatique activable dans les réglages. L'accueil propose de choisir
Claude Code ou Codex CLI et installe cette seule intégration. Les hooks existants sont
préservés et la configuration modifiée est sauvegardée. Codex seul ne crée pas de
configuration Claude.

Atoll vit dans la barre de menus et autour de l'encoche. Survoler l'îlot l'étend, cliquer
l'épingle, cliquer ailleurs le referme.

La seconde intégration peut être installée séparément dans les réglages. Réglages › Codex
affiche aussi le home utilisé et vérifie les définitions et leur confiance avec le CLI.

**Version courante : v0.18.0.** [Notes de version](https://github.com/mehdi7129/atoll/releases/tag/v0.18.0).

---

<details>
<summary><strong>En option — Atoll apprend de tes sessions</strong></summary>

<br>

En fin de session substantielle, et en tenant compte de ta fenêtre de quota, une
analyse **en lecture seule** relit la session et en extrait ce qui dure :

- des **notes mémoire**, indexées et citées par les recherches suivantes ;
- des **procédures rejouables**, proposées pour une destination Claude Code ou Codex CLI.

Le générateur garde l'essentiel : connaissances non évidentes, commandes vérifiées et
contrôles utiles. Une tâche banale ou déjà couverte ne produit pas de skill. Le texte
vise généralement 200–600 tokens ; une procédure trop longue est écartée et signalée,
jamais coupée au milieu d'une commande.

Les skills proposés arrivent en **quarantaine** : tu lis le `SKILL.md` complet dans une
fenêtre dédiée, tu approuves (⌘⏎) ou tu rejettes (⌘⌫). Rien n'est actif sans ton accord. Un
skill approuvé vit dans les skills de sa destination : `~/.claude/skills` pour Claude,
ou le dossier `skills` du home choisi pour Codex. La destination est affichée et figée
dans la proposition ; le bouton d'affichage ne la change pas.
La revue affiche le nombre de mots et, pour une mise à jour, le texte installé à côté
de la proposition. Après une décision, elle conserve ta position dans la liste.

Atoll compare le besoin au catalogue de la destination et le vérifie de nouveau avant
l'approbation. Pour Codex, il utilise le catalogue natif `skills/list`. Une erreur de
lecture ou une nouvelle antériorité demande une nouvelle vérification. L'usage Codex est
affiché « non mesuré », sans suggestion d'archivage fondée sur un faux zéro.

Le moteur des analyses se choisit séparément : Claude ou Codex, pour le bilan, le rangement
des notes et la recherche IA facultative de plugins. Le budget interne est partagé ; le
failover vers l'autre abonnement est un opt-in distinct. Chaque fin de session laisse une
trace de son traitement ou de son abstention. Apprentissage désactivé par défaut.

</details>

<details>
<summary><strong>En option — souvenirs joints à tes messages</strong></summary>

<br>

Sans attendre que Claude pense au skill, Atoll peut joindre à chaque message les extraits de
tes sessions passées liés à ce que tu écris — marqués comme **données**, jamais comme des
instructions, et jamais des sorties d'outils. Recherche 100 % locale, quelques
millisecondes ; à la moindre anicroche, rien n'est injecté et le CLI continue.

L'injection proactive reste propre à Claude. Pour Codex, utiliser le recall manuel :
la consommation d'un contexte additionnel depuis un hook async n'est pas tenue pour acquise.

Chaque passage laisse une ligne dans `~/.atoll/recall-journal.jsonl` — injecté, ou refusé
avec sa raison — que `atoll-bridge recall-stats` résume. Ce journal ne contient **ni tes
prompts ni le contenu des souvenirs** : des métadonnées, plafonnées, qui restent sur ta
machine. Il existe pour qu'une fonction qui ne sert pas puisse être **retirée sur preuve**
plutôt que gardée par habitude.

</details>

<details>
<summary><strong>En option — le mode Rockstar</strong></summary>

<br>

Rockstar, **pour Claude uniquement**, suspend les règles de refus de permissions que tu as écrites toi-même, le temps
d'une session où tu veux avancer sans être interrompu, puis les restitue.

C'est l'un des trois seuls endroits où Atoll touche à une configuration qui n'est pas la
sienne — avec la reprise de tes hooks sonores, et la statusline, qu'il enveloppe pour lire
ton quota sans rien retirer à la tienne. Chaque fois avec le même filet : ce qui existait
est mis de côté dans un fichier **avant** toute modification, et restitué à la sortie du
mode, au lancement suivant de l'app, à la désinstallation — et par le helper lui-même si
l'app se ferme ou plante en cours de route.

Tant que Rockstar est actif, l'îlot reste visible en permanence : on ne désarme pas une
machine en silence. L'indicateur `CLAUDE · ROCKSTAR` reste visible pendant que tu regardes
Codex, y compris en compact. Changer de vue ne modifie pas cette préférence.

</details>

<details>
<summary><strong>Apparence, plugins, modèles</strong></summary>

<br>

- **Thème** clair / sombre / auto, 5 palettes, et taille de la barre compacte réglable **par
  écran** (large sur le moniteur externe, moyen sur le MacBook).
- **Liquid Glass** (macOS 26) sur le panneau déployé, curseur d'intensité et onde discrète à
  l'ouverture. « Réduire les animations » désactive l'onde ; les fondus et transitions de
  taille demeurent. Repli sobre sur macOS 14 et 15.
- **Tes plugins, lisibles** : combien installés, combien réellement activés, lesquels sont
  cassés, et ce qu'ils coûtent en tokens à chaque session. Activer, désactiver ou installer
  passe toujours par la commande officielle `claude plugin`, sur ton geste explicite —
  jamais automatiquement.
- **Modèles d'analyse** : choix par tâche côté Claude ; modèle choisi dans le catalogue
  natif côté Codex. Le moteur d'analyse se règle dans Apprentissage, séparément de la vue.

</details>

<details>
<summary><strong>Compiler depuis les sources</strong></summary>

<br>

Prérequis : **Xcode 26** (SDK macOS 26 — le fond Liquid Glass utilise `.glassEffect`, gardé
par `if #available`, mais il faut le SDK pour compiler), la **Metal Toolchain**
(`xcodebuild -downloadComponent MetalToolchain`, composant téléchargeable à part, requis par
le shader de l'onde) et [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). L'app tourne, elle, à partir de macOS 14.

```sh
xcodegen generate
DD="$HOME/Library/Developer/Atoll-DerivedData"
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath "$DD" build
PREVIEW="/private/tmp/Atoll-preview-$(uuidgen).app"
python3 Scripts/prepare-preview.py "$DD/Build/Products/Debug/Atoll.app" "$PREVIEW"
open "$PREVIEW"
```

DerivedData hors du projet : si le dépôt vit dans un dossier synchronisé iCloud ou Dropbox,
les attributs étendus du file provider cassent la signature.
La copie ci-dessus montre des données fictives et préserve l'installation stable. Pour
tester les CLI réels, les scripts et précautions sont dans [la fiche de reprise](docs/HANDOFF.md).

Tests du cœur : `cd AtollCore && swift test`

```
App/         cible app (fenêtre notch, thème, vues SwiftUI, services)
AtollCore/   package SPM : toute la logique pure, testée
Bridge/      helper CLI appelé par les hooks Claude Code et Codex, par socket Unix
docs/        recherche et documents de conception
```

Pour reprendre le développement : [fiche de reprise](docs/HANDOFF.md),
[règles du projet](CLAUDE.md) et [direction produit](docs/VISION-2026-08.md).
[PLAN.md](PLAN.md) conserve le plan initial historique. Les résultats mesurés et les
limites de validation sont dans [le rapport de recette](docs/REVIEW-2026-09-10-skills-validation.md).

</details>

## Licence

[GPL-3.0-or-later](LICENSE) — libre d'utiliser, d'étudier, de modifier et de redistribuer ;
les redistributions, modifiées ou non, doivent rester sous la même licence, code source
inclus.
