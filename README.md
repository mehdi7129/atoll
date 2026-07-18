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

**Statut : phase de conception.** Voir le [plan détaillé](PLAN.md) et la
[recherche](docs/research/).

## Principes

- **Natif** — Swift/SwiftUI, < 50 MB RAM, zéro Electron, zéro télémétrie.
- **Fiable** — cycle de vie des sessions surveillé au niveau noyau (kqueue), pas de
  sessions fantômes.
- **Exact** — quota 5 h/7 j issu du serveur Anthropic, jamais estimé.
- **ASCII** — grille de caractères disciplinée, box-drawing, spinners braille,
  mono + un accent.
- **Fail-open** — si Atoll est fermé, Claude Code fonctionne exactement comme avant.
