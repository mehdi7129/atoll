# Atoll

```
        ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
  ╭──────────────────────────────────────╮
  │ ⠹ claude · dynamic-island · working  │
  ╰──────────────────────────────────────╯
```

Une **Dynamic Island pour Claude Code** sur macOS, avec une esthétique ASCII/terminal
(dark / light / auto). Suivez et pilotez vos sessions Claude — permissions, questions,
validation de plans, quota, chat — directement depuis le notch, sans quitter votre flow,
y compris pour les sessions lancées depuis le terminal de Cursor.

**Gratuit et open source (GPL-3.0-or-later).**
**Statut : Phase 1 — coquille notch + thème ASCII (sessions factices).**
Voir le [plan détaillé](PLAN.md) et la [recherche](docs/research/).

## Principes

- **Natif** — Swift/SwiftUI, < 50 MB RAM, zéro Electron, zéro télémétrie.
- **Fiable** — cycle de vie des sessions surveillé au niveau noyau (kqueue), pas de
  sessions fantômes.
- **Exact** — quota 5 h/7 j issu du serveur Anthropic, jamais estimé.
- **ASCII** — grille de caractères disciplinée, box-drawing, spinners braille,
  mono + un accent.
- **Fail-open** — si Atoll est fermé, Claude Code fonctionne exactement comme avant.

## Builder

Prérequis : Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/Atoll.app
```

Atoll apparaît dans la barre de menus (icône vagues) et autour du notch.
Survoler l'îlot l'étend ; cliquer l'épingle ; cliquer ailleurs le referme.
Réglages (thème, palette, délai de survol) via l'icône de la barre de menus.

Tests du cœur :

```sh
cd AtollCore && swift test
```

## Structure

```
App/         cible app (fenêtre notch, thème, vues SwiftUI)
AtollCore/   package SPM : logique pure testée (palettes, ASCII, géométrie, modèles)
docs/        recherche et documents de conception
project.yml  définition XcodeGen (Atoll.xcodeproj est généré, non versionné)
```

## Licence

[GPL-3.0-or-later](LICENSE) — libre d'utiliser, d'étudier, de modifier et de
redistribuer ; les redistributions (modifiées ou non) doivent rester sous la même
licence, code source inclus.
