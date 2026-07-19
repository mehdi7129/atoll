# CLAUDE.md — instructions projet Atoll

> 📌 **REPRISE DE DEV : lire `docs/HANDOFF.md` en premier** — état exact, ce qu'il reste
> à faire (Phase 7), méthode de travail, et TOUS les pièges appris à la dure.

Atoll est une app macOS native (Swift/SwiftUI) : une « Dynamic Island » autour du notch,
esthétique ASCII, pour suivre et piloter les sessions Claude Code. Gratuit, open source,
**GPL-3.0-or-later**. Communication utilisateur en **français** ; identifiants de code en
anglais, commentaires en français.

## Commandes

```sh
xcodegen generate                                  # (re)génère Atoll.xcodeproj — jamais versionné
DD="$HOME/Library/Developer/Atoll-DerivedData"
xcodebuild -project Atoll.xcodeproj -scheme Atoll \
  -configuration Debug -derivedDataPath "$DD" build
ditto "$DD/Build/Products/Debug/Atoll.app" ~/Applications/Atoll.app
open ~/Applications/Atoll.app                      # lancer LA COPIE, jamais le produit de build
cd AtollCore && swift test                         # tests de la logique pure
```

Pièges de build appris à la dure :
- **DerivedData HORS du Bureau** : ce repo vit sur un Bureau synchronisé iCloud dont le
  file provider tamponne des xattrs qui cassent CodeSign (« resource fork / detritus »).
- **Lancer une copie** (~/Applications) : lancer le .app du dossier de build lui colle
  `com.apple.provenance` (ineffaçable) et casse le CodeSign du build suivant.
- `~/.local/bin/xattr` est un shim Blender **cassé** — toujours `/usr/bin/xattr`.
- Debug : `/usr/bin/log stream --predicate 'subsystem == "dev.mehdiguiard.atoll"' --level debug`
  (les niveaux info/debug ne sont pas persistés — `log show` ne les voit pas) ; état des
  sessions dans `~/Library/Application Support/Atoll/state.json`.
- **Vérification VISUELLE obligatoire** après tout changement d'UI :
  `notifyutil -p dev.mehdiguiard.atoll.debug.expand` étend + épingle l'îlot,
  `…debug.compact` le replie ; puis `screencapture -x f.png`, rogner la bande
  supérieure centrale avec sips, et REGARDER l'image (l'outil Read lit les PNG).
  Piège vu en vrai : la NotchShape insète ses flancs de topRadius → le contenu
  étendu doit s'écarter de `IslandGeometry.expandedContentInset`.

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
   EXCEPTION ENCADRÉE (Rockstar) : les règles `permissions.deny` de l'utilisateur
   sont suspendues pendant Rockstar — parquées dans `~/.atoll/rockstar-parked-deny.json`
   (écrit AVANT de toucher settings.json, crash-safe), restaurées à la sortie, au
   lancement de l'app (réconciliation) et à la désinstallation. C'est le SEUL cas où
   Atoll touche à des entrées non-Atoll, à la demande explicite de l'utilisateur.
3. **Transcripts JSONL** (`~/.claude/projects/`) : format officiellement interne et
   instable → parsing défensif uniquement, jamais une dépendance dure.
4. Pas de dépendances lourdes, pas d'Electron, **zéro télémétrie**.
5. Licences : MIT/Apache réutilisables avec attribution ; GPL compatible (Atoll est GPL) ;
   ne jamais embarquer SF Mono ni Berkeley Mono (licences).
6. Cible **macOS 14+**, Swift 5 language mode, sandbox OFF / Hardened Runtime ON.
7. **Détection des processus claude** : avec l'installeur natif, `proc_name` renvoie le
   numéro de version (« 2.1.214 »), PAS « claude » — matcher par chemin d'exécutable
   (`ProcessInspector.isClaudeProcess`). Vérifié empiriquement, ne pas « simplifier ».
8. **Pas de NWListener sur socket Unix** : connexions acceptées par le noyau mais jamais
   livrées au handler (constaté macOS 26). BSD sockets + DispatchSource, fd non-bloquants
   partout (un accept bloquant gèle la queue série).

## État des phases (voir PLAN.md §5)

- ✅ Phase 1 — coquille notch + thème ASCII (sessions factices)
- ✅ Phase 2 — monitoring des sessions réelles (hooks → socket → machine à états)
- ✅ Phase 3 — interactions (PermissionRequest bloquant : permissions, plans, questions)
- ✅ Auto-accept sûr (allowlist), vrais quotas (statusline tee), infos par session
- ✅ Phase 4 — jump-back terminal (Cursor/VS Code via `<cli> -r`, Terminal.app/iTerm2
  via AppleScript par TTY, fallback activation app ; ancre capturée aux hooks + KERN_PROCARGS2)
- ✅ Phase 5 — quota exact (tee-wrapper statusline, rate_limits serveur + indicateur d'âge)
- ✅ Phase 6 — chat intégré (`claude -p` stream-json persistant, composer dans l'îlot)
- ⬜ Phase 7 — distribution (notarisation, DMG, Sparkle)

Chat (Phase 6) : ChatDriver spawne `claude -p --input/--output-format stream-json`.
PIÈGES VÉCUS (chacun a coûté cher) :
- `readabilityHandler` sur le pipe stdout ne se déclenche PAS dans l'app LSUIElement
  (run loop) → lecture par read(2) sur un thread dédié.
- Les Pipe/FileHandle de Foundation croisaient les fds sous concurrence (le reader
  lisait le pipe stdin — vérifié à l'lsof) → pipes POSIX explicites + FD_CLOEXEC.
- **Spawner claude DIRECTEMENT depuis l'app GUI le laisse MUET** (n'émet même pas
  l'init, main thread bloqué, aucune I/O — pas l'env ni les fds, testé exhaustivement).
  FIX : spawner via `/bin/zsh -l -c "exec claude …"` — claude hérite des pipes mais
  tourne dans un contexte de shell de login (comme le terminal, où il marche).
- Livraison des événements au main via DispatchQueue.main.async (FIFO), PAS Task {} (ordre non garanti → flux mélangé).
Débug : `notifyutil -p dev.mehdiguiard.atoll.debug.chat`.

Jump-back : les sessions de Mehdi tournent dans le terminal intégré de **Cursor**
(`com.todesktop.230313mzl4w4u92`, TERM_PROGRAM=vscode) → `cursor -r <cwd>` remonte la
fenêtre, AUCUNE permission TCC. AppleScript (Terminal/iTerm2) exécuté par l'app seulement
(attribution TCC). Debug : `notifyutil -p dev.mehdiguiard.atoll.debug.jump`.

Permissions Claude Code — faits VÉRIFIÉS empiriquement (CLI 2.1.215, tests pty/expect) :
- `updatedPermissions setMode bypassPermissions` renvoyé par un hook PermissionRequest
  est IGNORÉ par le CLI (contrairement à `acceptEdits`, honoré — utilisé pour les
  plans en rockstar). Impossible de faire passer une session en bypass depuis un hook.
- Les règles `permissions.deny` s'appliquent MÊME en bypassPermissions, et AVANT
  les hooks (l'îlot ne voit jamais la demande refusée) → seul le parking les lève.
- En bypassPermissions, AskUserQuestion déclenche QUAND MÊME le hook PermissionRequest
  (et la décision du hook est honorée) → rockstar répond aux questions même en bypass.
- En mode `-p` (headless, donc le chat intégré), l'outil AskUserQuestion N'EXISTE PAS.
- Avec `defaultMode: bypassPermissions` dans le settings.json utilisateur, les sessions
  ne produisent presque jamais de PermissionRequest d'outils — l'auto-accept paraît
  alors « inactif » ; ce sont les règles deny qui bloquent encore. (Config de la
  machine de dev : voir la mémoire projet, pas ici — repo public.)
- Un claude lancé DEPUIS une session Claude Code (env CLAUDECODE/CHILD_SESSION) peut
  démarrer en bypass : nettoyer l'env pour tester des comportements de permissions.

Debug des interactions (Phase 3) : `notifyutil -p dev.mehdiguiard.atoll.debug.allow`
(ou `.deny`) résout la première carte en attente via les mêmes chemins que les boutons ;
`state.json` liste `pendingInteractions`. Tester le vrai helper :
`echo '{"hook_event_name":"PermissionRequest","session_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}' | ~/.atoll/bin/atoll-bridge` bloque jusqu'à la décision (stdout = JSON de décision, vide = rendu au terminal).
Le hook PermissionRequest est BLOQUANT (async:false, timeout 86400) — tout le reste est async.
