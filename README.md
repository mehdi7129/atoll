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
| 6 · Distribution (Developer ID, notarisation, DMG, Sparkle) | ✅ |
| 7a · Mémoire (index FTS5 de tous les transcripts + skill `atoll-recall`) | ✅ |
| 7b · Rétrospective (leçons + skills proposés en fin de session) | ✅ |
| 7c · Curation (revue des skills, stats d'usage, hygiène) | ✅ |

**Version courante : v0.7.0** (voir les [Releases](https://github.com/mehdi7129/atoll/releases)).

Voir le [plan détaillé](PLAN.md), la [recherche](docs/research/) et [CLAUDE.md](CLAUDE.md)
pour contribuer.

## Fonctionnalités

- **Suivi temps réel** de toutes vos sessions Claude Code (hooks → socket → machine à
  états), avec l'état de chacune (en cours, en attente, permission…) et le % de contexte.
- **Répondre depuis le notch** : permissions (⌘Y/⌘N), validation de plans, questions —
  sans quitter votre terminal.
- **Niveau d'autonomie** (Réglages) : Manuel, Auto (allowlist sûre) ou Rockstar (aucune
  protection — vos règles `deny` sont suspendues puis restaurées, à vos risques et périls).
- **Quota exact** 5 h / 7 j du serveur, jauge par modèle en option, reset lisible.
- **Mémoire longue durée** : tous vos transcripts (tous projets) indexés en local
  (SQLite FTS5, ~/.atoll/memory.db — rien ne quitte la machine). Vos sessions
  Claude interrogent ce passé via le skill `atoll-recall` : « retrouve quand on a
  parlé de… » cite dates, projets et sessions à reprendre (`claude --resume`).
- **Rétrospective (opt-in, expérimental)** : après chaque session substantielle —
  et seulement si votre fenêtre de quota 5 h a de la marge — une analyse en
  LECTURE SEULE extrait les leçons durables : notes mémoire (indexées, citées par
  recall) et éventuels skills proposés, placés en QUARANTAINE, jamais actifs sans
  votre approbation. Atoll apprend de vos sessions, sur votre souscription, avec
  des garde-fous durs (plafond de runs, budget, kill-switch immédiat).
- **Revue des skills appris** : les skills proposés se revoient dans une fenêtre
  dédiée (le SKILL.md complet est affiché avant toute décision — ⌘⏎ approuver,
  ⌘⌫ rejeter). Un skill approuvé devient un vrai skill Claude Code
  (`~/.claude/skills/atoll-<nom>/`) ; l'onglet Apprentissage montre l'usage de
  chacun et suggère d'archiver les inutilisés. Désinstallation chirurgicale
  (manifeste + empreinte SHA-256) : vos 18 skills tiers ne sont jamais touchés.
- **Retour au terminal** : un clic ouvre la fenêtre de la session (Cursor/VS Code direct,
  Terminal.app / iTerm2 via automatisation).
- **Personnalisable** : thème clair/sombre/auto, 4 palettes, et **taille de la barre
  compacte réglable par écran** (petit / moyen / large — ex. large sur un moniteur externe,
  moyen sur le MacBook).

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
Réglages (thème, palette, taille de l'îlot par écran, autonomie, mises à jour)
via l'icône de la barre de menus.

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
