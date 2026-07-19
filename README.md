# Atoll

```
        ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
  ╭──────────────────────────────────────╮
  │ ⠹ claude · dynamic-island · working  │
  ╰──────────────────────────────────────╯
```

Une **Dynamic Island pour Claude Code** sur macOS, avec une esthétique ASCII/terminal
(dark / light / auto). Suivez et pilotez vos sessions Claude — permissions, questions,
validation de plans, quota — directement depuis le notch, sans quitter votre flow,
y compris pour les sessions lancées depuis le terminal de Cursor.

**Gratuit et open source (GPL-3.0-or-later).**

| Phase | Statut |
|---|---|
| 1 · Coquille notch + thème ASCII | ✅ |
| 2 · Monitoring des sessions réelles (hooks) | ✅ |
| 3 · Interactions (permissions, plans, questions) | ✅ |
| Auto-accept sûr · infos par session · quota exact | ✅ |
| 4 · Jump-back terminal (Cursor/VS Code · Terminal · iTerm2) | ✅ |
| 5 · Quota exact (statusline · jauge par modèle · % contexte) | ✅ |
| 6 · Distribution (notarisation, DMG, Sparkle) | ✅ |

Voir le [plan détaillé](PLAN.md), la [recherche](docs/research/) et [CLAUDE.md](CLAUDE.md)
pour contribuer.

## Principes

- **Natif** — Swift/SwiftUI, < 50 MB RAM, zéro Electron, zéro télémétrie.
- **Fiable** — cycle de vie des sessions surveillé au niveau noyau (kqueue), pas de
  sessions fantômes.
- **Exact** — quota 5 h/7 j issu du serveur Anthropic, jamais estimé.
- **ASCII** — grille de caractères disciplinée, box-drawing, spinners braille,
  mono + un accent.
- **Fail-open** — si Atoll est fermé, Claude Code fonctionne exactement comme avant.

## Installer

Téléchargez le dernier `Atoll-x.y.z.dmg` depuis les
[Releases](https://github.com/mehdi7129/atoll/releases), glissez Atoll dans
Applications, lancez. L'app est signée Developer ID et notarisée ; les mises à
jour arrivent ensuite automatiquement (Sparkle).

Au premier lancement, la fenêtre de bienvenue guide l'installation des hooks
Claude Code — fail-open garanti : Atoll fermé ou planté, le CLI `claude`
fonctionne exactement comme avant, et la désinstallation restitue votre
`settings.json` d'origine.

## Builder

Prérequis : Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate
DD="$HOME/Library/Developer/Atoll-DerivedData"
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath "$DD" build
ditto "$DD/Build/Products/Debug/Atoll.app" ~/Applications/Atoll.app
open ~/Applications/Atoll.app
```

(DerivedData hors du projet : si le repo vit dans un dossier synchronisé
iCloud/Dropbox, les xattrs du file provider cassent CodeSign.)

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
