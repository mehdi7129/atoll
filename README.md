# Atoll

```
        ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
  ╭──────────────────────────────────────╮
  │ ⠹ atoll · refonte du README    62%   │
  ╰──────────────────────────────────────╯
```

**Une Dynamic Island pour Claude Code, dans l'encoche de ton MacBook.**

Trois `claude` tournent : un dans un onglet Cursor, un dans un iTerm passé derrière le
navigateur, un en arrière-plan lancé il y a vingt minutes. L'un des trois est bloqué depuis
huit minutes sur une demande de permission — tu ne sais pas lequel. Tu ne sais pas non plus
combien de quota il te reste, ni comment tu avais réglé ce même bug le mois dernier, dans
un autre projet.

Atoll met tout ça autour de l'encoche.

> **Atoll ne fait pas travailler les agents.
> Il SAIT ce qui se passe sur ta machine, il s'en SOUVIENT, et il t'APPELLE.**

macOS 14+ · Swift/SwiftUI natif, pas d'Electron · zéro télémétrie · zéro compte ·
**gratuit et open source (GPL-3.0-or-later)**

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
```

Toutes tes sessions, **tous projets confondus**, regroupées par dépôt — ou par état, si la
vraie question du moment est « laquelle m'attend ? ». Le pourcentage est le contexte
consommé ; le quota 5 h et 7 j est celui que renvoie le serveur d'Anthropic : **lu, jamais
estimé**.

Un clic ouvre le détail d'une session, un autre ramène la fenêtre du terminal exact d'où
elle vient — Cursor, VS Code, Terminal.app, iTerm2. Fin de la chasse à l'onglet.

## Répondre sans changer de fenêtre

Quand une session demande une permission, soumet un plan ou pose une question, une carte
apparaît dans l'encoche, la commande en clair :

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

## Se souvenir — au-delà d'un seul dépôt

Tous les transcripts de toutes tes sessions passées sont indexés **en local** (SQLite FTS5,
dans `~/.atoll/memory.db`). Rien ne quitte la machine.

Le skill `atoll-recall` ouvre ce passé à Claude :

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

- **Il ne lance pas d'agents et n'orchestre rien.** `claude --bg` et `claude agents` le
  font, et le font mieux. Atoll observe ; il ne double pas l'outil.
- **Il ne décide d'aucune permission à ta place** par une politique maison. `claude
  auto-mode` est natif, actif par défaut, et bien plus complet que ce qu'on écrirait ici.
- **Il ne collecte rien.** Pas de télémétrie, pas de compte, pas de serveur, pas d'Electron.
- **Il ne peut pas casser ton CLI.** Règle absolue du projet : Atoll fermé, lent ou planté,
  `claude` fonctionne exactement comme avant. La désinstallation restitue ta configuration
  d'origine.

La découverte des sessions passe par l'interface **supportée** `claude agents --json`, pas
par du reverse-engineering : les mises à jour de Claude Code profitent à Atoll au lieu de le
casser.

## Installer

Télécharge le dernier `Atoll-x.y.z.dmg` depuis les
[Releases](https://github.com/mehdi7129/atoll/releases) et glisse Atoll dans Applications.

L'app est signée Developer ID et notarisée par Apple ; les mises à jour arrivent ensuite
toutes seules (Sparkle). Au premier lancement, une fenêtre de bienvenue installe les hooks
Claude Code — après t'avoir montré ce qu'elle va écrire.

Atoll vit dans la barre de menus et autour de l'encoche. Survoler l'îlot l'étend, cliquer
l'épingle, cliquer ailleurs le referme.

**Version courante : v0.16.3.**

---

<details>
<summary><strong>En option — Atoll apprend de tes sessions</strong></summary>

<br>

En fin de session substantielle, et seulement si ta fenêtre de quota a de la marge, une
analyse **en lecture seule** relit la session et en extrait ce qui dure :

- des **notes mémoire**, indexées et citées par les recherches suivantes ;
- des **procédures rejouables**, transformées en vrais skills Claude Code.

Les skills proposés arrivent en **quarantaine** : tu lis le `SKILL.md` complet dans une
fenêtre dédiée, tu approuves (⌘⏎) ou tu rejettes (⌘⌫). Rien n'est actif sans ton accord. Un
skill approuvé vit dans `~/.claude/skills` : il sert à *tous* tes projets.

Avant de proposer quoi que ce soit, Atoll compare le besoin à ce que Claude peut déjà
invoquer chez toi — tes skills, tes slash commands, ceux de tes plugins — et signale ce que
la proposition recoupe. Chaque fin de session laisse une trace lisible : analysée, ou sautée
et pourquoi, et ce que ça a coûté. Fonction désactivée par défaut.

</details>

<details>
<summary><strong>En option — souvenirs joints à tes messages</strong></summary>

<br>

Sans attendre que Claude pense au skill, Atoll peut joindre à chaque message les extraits de
tes sessions passées liés à ce que tu écris — marqués comme **données**, jamais comme des
instructions, et jamais des sorties d'outils. Recherche 100 % locale, quelques
millisecondes ; à la moindre anicroche, rien n'est injecté et le CLI continue.

Chaque passage laisse une ligne dans `~/.atoll/recall-journal.jsonl` — injecté, ou refusé
avec sa raison — que `atoll-bridge recall-stats` résume. Ce journal ne contient **ni tes
prompts ni le contenu des souvenirs** : des métadonnées, plafonnées, qui restent sur ta
machine. Il existe pour qu'une fonction qui ne sert pas puisse être **retirée sur preuve**
plutôt que gardée par habitude.

</details>

<details>
<summary><strong>En option — le mode Rockstar</strong></summary>

<br>

Rockstar suspend les règles de refus de permissions que tu as écrites toi-même, le temps
d'une session où tu veux avancer sans être interrompu, puis les restitue.

C'est le seul endroit où Atoll touche à une configuration qui n'est pas la sienne, et il le
fait avec un filet : tes règles sont mises de côté dans un fichier **avant** toute
modification, et restituées à la sortie du mode, au lancement suivant de l'app, à la
désinstallation — et par le helper lui-même si l'app se ferme ou plante en cours de route.

Tant que Rockstar est actif, l'îlot reste visible en permanence : on ne désarme pas une
machine en silence.

</details>

<details>
<summary><strong>Apparence, plugins, modèles</strong></summary>

<br>

- **Thème** clair / sombre / auto, 4 palettes, et taille de la barre compacte réglable **par
  écran** (large sur le moniteur externe, moyen sur le MacBook).
- **Liquid Glass** (macOS 26) sur le panneau déployé, curseur d'intensité et onde discrète à
  l'ouverture — qui respecte « Réduire les animations ». Repli sobre sur macOS 14 et 15.
- **Tes plugins, lisibles** : combien installés, combien réellement activés, lesquels sont
  cassés, et ce qu'ils coûtent en tokens à chaque session. Activer, désactiver ou installer
  passe toujours par la commande officielle `claude plugin`, sur ton geste explicite —
  jamais automatiquement.
- **Modèle par tâche** : Haiku pour chercher, Sonnet pour analyser, Opus ou Fable si tu
  préfères — réglable séparément pour chaque travail d'arrière-plan.

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
ditto "$DD/Build/Products/Debug/Atoll.app" ~/Applications/Atoll.app
open ~/Applications/Atoll.app
```

DerivedData hors du projet : si le dépôt vit dans un dossier synchronisé iCloud ou Dropbox,
les attributs étendus du file provider cassent la signature.

Tests du cœur : `cd AtollCore && swift test`

```
App/         cible app (fenêtre notch, thème, vues SwiftUI, services)
AtollCore/   package SPM : toute la logique pure, testée
Bridge/      helper CLI appelé par les hooks Claude Code, parle à l'app par socket Unix
docs/        recherche et documents de conception
```

Le plan produit est dans [PLAN.md](PLAN.md), les règles de contribution dans
[CLAUDE.md](CLAUDE.md), la direction du projet dans
[docs/VISION-2026-08.md](docs/VISION-2026-08.md).

</details>

## Licence

[GPL-3.0-or-later](LICENSE) — libre d'utiliser, d'étudier, de modifier et de redistribuer ;
les redistributions, modifiées ou non, doivent rester sous la même licence, code source
inclus.
