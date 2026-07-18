# CLAUDE.md — instructions projet Atoll

Atoll est une app macOS native (Swift/SwiftUI) : une « Dynamic Island » autour du notch,
esthétique ASCII, pour suivre et piloter les sessions Claude Code. Gratuit, open source,
**GPL-3.0-or-later**. Communication utilisateur en **français** ; identifiants de code en
anglais, commentaires en français.

## Commandes

```sh
xcodegen generate                                  # (re)génère Atoll.xcodeproj — jamais versionné
xcodebuild -project Atoll.xcodeproj -scheme Atoll \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Atoll.app          # lancer
cd AtollCore && swift test                         # tests de la logique pure
```

Si CodeSign échoue avec « resource fork / detritus » : `xattr -cr .` puis rebuild
(métadonnées Finder du Bureau).

## Architecture

- `App/` — cible app : fenêtre notch (NSPanel non-activant par écran, frame fixe,
  animations 100 % SwiftUI), thème, vues. Pas de logique métier ici.
- `AtollCore/` — package SPM : **toute la logique pure, testée** (palettes, art ASCII,
  géométrie, modèles, machine à états des sessions, édition de settings.json).
  Règle : ce qui peut être testé sans AppKit vit ici, avec ses tests.
- `Bridge/` — helper CLI `atoll-bridge` embarqué dans le bundle (Contents/Helpers) :
  appelé par les hooks Claude Code, enrichit le payload (pid, tty, env) et l'envoie
  au socket Unix de l'app.
- `docs/research/` — 10 rapports de recherche (hooks, notch, quota, jump-back…).
  **Source de vérité technique** : formats JSON exacts, APIs vérifiées, pièges connus.
  Les consulter avant d'implémenter une intégration.
- `PLAN.md` — plan produit/technique et roadmap par phases (état d'avancement inclus).

## Règles critiques

1. **Fail-open absolu** : rien de ce qu'Atoll installe (hooks, statusline, wrapper) ne
   doit JAMAIS pouvoir casser ou ralentir le CLI `claude`. Timeouts courts, `exit 0`
   sur toute erreur, hooks `async` sauf besoin bloquant explicite.
2. **`~/.claude/settings.json` est sacré** : merge chirurgical (nos entrées sont
   identifiables par `atoll-bridge`), backup avant première écriture, désinstallation
   restituant l'existant, refus propre si le fichier n'est pas du JSON valide.
   L'utilisateur a des hooks GSD + sons + statusline custom : les préserver.
3. **Transcripts JSONL** (`~/.claude/projects/`) : format officiellement interne et
   instable → parsing défensif uniquement, jamais une dépendance dure.
4. Pas de dépendances lourdes, pas d'Electron, **zéro télémétrie**.
5. Licences : MIT/Apache réutilisables avec attribution ; GPL compatible (Atoll est GPL) ;
   ne jamais embarquer SF Mono ni Berkeley Mono (licences).
6. Cible **macOS 14+**, Swift 5 language mode, sandbox OFF / Hardened Runtime ON.

## État des phases (voir PLAN.md §5)

- ✅ Phase 1 — coquille notch + thème ASCII (sessions factices)
- 🚧 Phase 2 — monitoring des sessions réelles (hooks → socket → machine à états)
- ⬜ Phases 3-7 — interactions, jump-back, quota, chat, distribution
