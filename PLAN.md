# ATOLL — Plan détaillé

> Une « Dynamic Island » pour Claude Code sur macOS, avec une esthétique ASCII/terminal soignée
> (dark / light / auto), pour suivre et piloter tes sessions Claude sans jamais quitter ton flow —
> y compris les sessions lancées depuis le terminal intégré de Cursor.

```
        ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
  ╭──────────────────────────────────────╮
  │ ⠹ claude · dynamic-island · working  │
  ╰──────────────────────────────────────╯
```

*Nom de code : **Atoll** (un atoll = un îlot en anneau — renommable à tout moment).*

---

## 1. Vision

Le MacBook a un notch ; Claude Code a des moments où il a besoin de toi (permission, question,
plan à valider) et des moments où il travaille sans toi. Atoll transforme le notch en poste de
contrôle : un pilulier compact affiche l'état de toutes tes sessions Claude en temps réel, et
s'étend en cartes interactives quand Claude attend une réponse — approuver/refuser un outil,
répondre à une question, valider un plan, relancer un prompt — sans jamais faire Cmd-Tab.

**Différenciation vs Vibe Island et ses ~20 clones** (issue de l'analyse concurrentielle) :

1. **Esthétique ASCII unique** — tous les concurrents font du « glassy natif » ; personne ne fait
   une identité terminal-rétro disciplinée (grille de caractères, box-drawing, spinners braille,
   palette mono + 1 accent, scanlines subtiles). C'est notre signature visuelle.
2. **Fiabilité du cycle de vie des sessions** — la plainte n°1 sur TOUS les trackers d'issues
   concurrents : sessions fantômes, états périmés. On la résout au niveau noyau (kqueue
   `NOTE_EXIT`) plutôt qu'au polling.
3. **Quota exact, pas estimé** — les pourcentages viennent du serveur Anthropic (statusline
   `rate_limits`), pas d'une estimation JSONL locale qui dérive (le défaut structurel de ccusage).
4. **Chat intégré** — lancer/reprendre une session Claude *depuis* l'îlot (headless stream-json),
   ce que quasiment personne ne fait.

Périmètre v1 : **Claude Code uniquement**, fait à la perfection. Le multi-agents (Codex, Gemini…)
est une extension v2, pas une fondation.

---

## 2. Stack technique (décisions arrêtées)

| Décision | Choix | Pourquoi |
|---|---|---|
| Langage / UI | Swift + SwiftUI, AppKit pour la fenêtre | Natif, < 50 MB RAM (standard de la catégorie) |
| Projet | Xcode project (app) + package SPM local (logique) | Info.plist, entitlements, notarisation impossibles en pur SPM |
| Cible minimale | macOS 14.0 (Sonoma) | `@Observable`, `SettingsLink`, MenuBarExtra — tout ce qu'il faut ; couvre Sonoma→Tahoe |
| Type d'app | Menu-bar only (`LSUIElement`) + panneau notch | Pas d'icône Dock ; `MenuBarExtra(.window)` pour les réglages rapides |
| Sandbox | **OFF** (Hardened Runtime **ON**) | Requis pour : spawner `claude`, kqueue sur processus tiers, lire `~/.claude` — donc pas d'App Store, distribution directe |
| IPC hooks → app | Socket Unix `/tmp/atoll-$UID.sock` | Pattern éprouvé par Vibe Island / open-vibe-island / vibe-notch |
| Updates | Sparkle 2.8 (SPM), appcast sur GitHub Pages | À intégrer dès le début (le retrofit est pénible) |
| Distribution | DMG notarisé + stapled (Developer ID) | macOS 15+ a supprimé le bypass clic-droit → app non signée = quasi morte |
| Dépendances | Minimales : Sparkle, (option) KeyboardShortcuts, Defaults | Zéro Electron, zéro télémétrie (reproche récurrent envers vibe-notch/Mixpanel) |

**Licences à respecter** : boring.notch est GPL-3.0 → on s'inspire de l'architecture, on ne copie
pas le code. DynamicNotchKit / NotchDrop sont MIT. SF Mono ne peut pas être embarqué (licence
Apple) mais s'utilise à runtime via `Font.system(design: .monospaced)` ; JetBrains Mono et
Departure Mono sont OFL → embarquables.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Atoll.app (menu-bar, LSUIElement)                              │
│                                                                 │
│  ┌───────────────┐  ┌────────────────┐  ┌───────────────────┐   │
│  │ NotchWindow   │  │ SessionStore   │  │ ThemeEngine       │   │
│  │ NSPanel/écran │←─│ machine à états│  │ dark/light/auto   │   │
│  │ SwiftUI       │  │ + liveness     │  │ palettes ASCII    │   │
│  └───────────────┘  └───┬──────┬─────┘  └───────────────────┘   │
│                         │      │                                │
│  ┌───────────────┐  ┌───┴──┐ ┌─┴──────────┐  ┌──────────────┐   │
│  │ TerminalJump  │  │Bridge│ │ Transcript │  │ UsageTracker │   │
│  │ adapters AS/  │  │Server│ │ Tailer     │  │ statusline + │   │
│  │ CLI par term. │  │socket│ │ (FSEvents) │  │ oauth opt-in │   │
│  └───────────────┘  └──┬───┘ └────────────┘  └──────────────┘   │
│  ┌───────────────┐     │                                        │
│  │ ChatDriver    │     │ /tmp/atoll-$UID.sock                   │
│  │ claude -p     │     │                                        │
│  │ stream-json   │     │                                        │
│  └───────────────┘     │                                        │
└────────────────────────┼────────────────────────────────────────┘
                         │
       ~/.atoll/bin/atoll-bridge  ← helper natif appelé par les hooks
                         ↑
   ~/.claude/settings.json (bloc "hooks" géré + statusline tee-wrapper)
                         ↑
     claude CLI — n'importe quel terminal, y compris celui de Cursor
```

### 3.1 NotchWindow (la coquille)

Recette canonique validée sur boring.notch / DynamicNotchKit / NotchDrop :

- `NSPanel` : `styleMask [.borderless, .nonactivatingPanel]`, `level = .statusBar + 3`,
  `collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`,
  transparent, sans ombre, `canBecomeKey = false` par défaut, `orderFrontRegardless()`.
- **La fenêtre ne s'anime jamais** : frame fixe = taille max déployée, top-centrée ; toute
  l'animation expand/collapse est du SwiftUI (spring `response 0.42 / damping 0.8` à l'ouverture,
  `0.45 / 1.0` à la fermeture) avec une `NotchShape` dont les rayons de coins sont animables.
- Géométrie : `hasNotch = auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil` ;
  hauteur = `safeAreaInsets.top` ; largeur = `frame.width - aux gauche - aux droite`.
- **Macs sans notch / écrans externes** : pilule flottante top-center (~185 pt × hauteur de la
  barre de menus) — même UI, position simulée.
- Multi-écrans : une fenêtre + view-model par `NSScreen`, indexés par `displayUUID`
  (`CGDisplayCreateUUIDFromDisplayID`), reconstruits sur `didChangeScreenParametersNotification`.
- Hover : `.onHover` + durée minimale configurable avant ouverture, ~100 ms de grâce avant
  fermeture ; moniteur global `leftMouseDown` uniquement pour « clic dehors = fermer ».
- Saisie texte dans l'îlot (réponses libres, chat) : `canBecomeKey = true` seulement pendant
  l'expansion (précédent NotchDrop).
- Pas d'API privées (CGS/SkyLight) : l'affichage sur l'écran de verrouillage n'est pas un besoin.

### 3.2 BridgeServer + hooks (les yeux et les oreilles)

- **Installeur de hooks géré** : bloc balisé dans `~/.claude/settings.json` (backup avant toute
  écriture, réparation automatique, désinstallation propre restituant le fichier d'origine).
  Événements installés : `SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
  PostToolUseFailure, PermissionRequest (matcher "*", timeout 86400), PermissionDenied,
  Notification, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact,
  SessionEnd` — dans le settings utilisateur, jamais dans un plugin (SessionEnd n'y est pas fiable).
- **Helper natif** `atoll-bridge` (petit binaire Swift embarqué dans le bundle, wrapper dans
  `~/.atoll/bin`) : lit le JSON sur stdin, y ajoute `pid` (marche `getppid()` → remontée
  `pbi_ppid` jusqu'au processus `claude`), le TTY (`proc_bsdinfo.e_tdev` → `devname()`), la chaîne
  d'ancêtres, et un instantané d'env (`TERM_PROGRAM`, `ITERM_SESSION_ID`, `TMUX/TMUX_PANE`,
  `KITTY_*`, `WEZTERM_PANE`, `CLAUDE_CODE_ENTRYPOINT`, `__CFBundleIdentifier`…) ; envoie le tout
  sur le socket. **Fail-open absolu** : timeout de connexion < 1 s, `exit 0` sur toute erreur —
  les hooks ne doivent JAMAIS casser ou ralentir le CLI. Jamais d'Apple Events depuis le helper
  (l'attribution TCC serait faussée).
- Ces hooks globaux se déclenchent pour **toute** session CLI, y compris dans le terminal intégré
  de Cursor (vérifié : les hooks tournent dans le processus `claude` lui-même). Limite connue :
  le *panneau* de l'extension VS Code/Cursor officielle ne déclenche pas `PermissionRequest`
  (issue #16237) → ces sessions seront affichées en lecture seule avec badge « répondre dans
  l'éditeur ».

### 3.3 SessionStore (machine à états + liveness)

États : `STARTING → BUSY / TOOL_RUNNING → WAITING_PERMISSION / WAITING_INPUT / COMPACTING → DEAD`,
avec table de transitions explicite (mapping vibe-notch : `UserPromptSubmit→BUSY`,
`PreToolUse→TOOL_RUNNING`, `PermissionRequest→WAITING_PERMISSION`, `Stop/Notification[idle_prompt]
→WAITING_INPUT`, `PreCompact→COMPACTING`, `SessionEnd→DEAD`…).

**Anti-sessions-fantômes** (le différenciateur fiabilité) :
1. `DispatchSource.makeProcessSource(pid, .exit)` — kqueue `NOTE_EXIT` fonctionne sur des
   processus non-enfants du même utilisateur (vérifié empiriquement) → mort détectée à la
   milliseconde, même sur SIGKILL/crash où `SessionEnd` ne se déclenche jamais.
2. Après `resume()`, garde anti-course : `kill(pid, 0) == ESRCH` → déjà mort. Identité robuste
   = tuple `(pid, start_time)` via `proc_pidinfo(PROC_PIDTBSDINFO)` (survit aux redémarrages
   de l'app et à la réutilisation de PID).
3. Filet de sécurité : réconciliation `ps` toutes les 30–60 s (match `proc_name == "claude"` —
   attention, `proc_pidpath` renvoie `~/.local/share/claude/versions/X.Y.Z`), débounce
   2 passes manquées avant de déclarer mort (pattern open-vibe-island).
4. `/clear` et `/resume` : `SessionEnd(reason=clear|resume)` = bascule de session sur le même
   PID, pas une mort du terminal.
5. **Tail JSONL du transcript** (`~/.claude/projects/<cwd-encodé>/<session>.jsonl`, FSEvents) :
   seul moyen de détecter Échap/interruption utilisateur (`[Request interrupted by user]`) —
   aucun hook n'existe pour ça. Parsing défensif : le format est documenté comme interne et
   instable ; les hooks restent la source de vérité temps réel, le JSONL sert à l'affichage
   de l'historique et aux heuristiques de secours.

### 3.4 Interactions depuis l'îlot (le cœur du produit)

Tout passe par le hook bloquant `PermissionRequest` (la connexion socket reste ouverte jusqu'à
la décision, timeout 86400) :

- **Permission outil** : carte avec `tool_name` + `tool_input` (diff rendu pour Edit/Write,
  commande pour Bash) → `Allow ⌘Y / Deny ⌘N` →
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  ou `deny` + `message`. « Toujours autoriser » = renvoyer une entrée de `permission_suggestions`
  en `updatedPermissions`.
- **Validation de plan** : `ExitPlanMode` passe par le même dialogue ; `tool_input.plan` contient
  le markdown du plan → rendu complet dans l'îlot ; `allow` (option « + acceptEdits » via
  `updatedPermissions [{type:setMode, mode:acceptEdits, destination:session}]`) ; `deny` +
  feedback tapé par l'utilisateur → Claude reste en plan mode et révise.
- **Questions (`AskUserQuestion`)** : options cliquables + champ libre → `allow` + `updatedInput
  {questions: <passthrough>, answers: {"<question>": "<label ou texte libre>"}}` (mécanisme
  documenté officiellement, implémenté par open-vibe-island).
- **Course terminal ↔ îlot** (confirmée, issue #12176) : le prompt TUI s'affiche pendant que le
  hook bloque ; premier répondu gagne. On met en cache le `tool_use_id` depuis `PreToolUse`
  (PermissionRequest ne le fournit pas) et on annule la carte quand `PostToolUse`/`Stop` révèle
  que le terminal a répondu. « Laisser le terminal décider » = `exit 0` sans stdout.
- Si l'îlot est fermé/injoignable : fail-open, le prompt terminal normal fonctionne comme si
  Atoll n'existait pas.

### 3.5 TerminalJump (cliquer = retrouver son terminal)

Protocole `TerminalFocusAdapter` avec granularité déclarée (`pane / tab / window / app`) et
dégradation en cascade. Données d'ancrage capturées au moment du hook (TTY + env + ancêtres).
Tout AppleScript est exécuté par l'app principale (attribution TCC correcte), entitlement
`com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`, préflight
`AEDeterminePermissionToAutomateTarget`, fallback final `NSRunningApplication.activate()`
(aucune permission requise).

Ordre d'implémentation : **Terminal.app + iTerm2** (AppleScript par TTY, niveau pane) et
**tmux** (résolution `client_tty` récursive) d'abord ; puis Ghostty (AppleScript par id, TTY
natif à partir de 1.4), WezTerm (`wezterm cli`), kitty (remote control) ; Warp/Alacritty =
activation app seulement (limite de leurs APIs). VS Code/Cursor : `cursor -r <cwd>` + extension
compagnon optionnelle (`.vsix` embarqué, installée à la demande) qui matche
`terminal.processId` contre la chaîne d'ancêtres et fait `terminal.show()`.

### 3.6 UsageTracker (quota 5 h / 7 j exact)

- **Primaire — tee-wrapper statusline** (exact, sans credentials, conforme ToS) : le payload
  statusline contient `rate_limits {five_hour, seven_day}` **côté serveur** (en-têtes
  `anthropic-ratelimit-unified-*` mis en cache par le CLI). Le wrapper met en cache le payload
  puis exécute la statusline d'origine de l'utilisateur en passthrough parfait — jamais
  d'écrasement silencieux (le clash statusline est l'issue #107 de Vibe Island), désinstallation
  restituant l'original. `refreshInterval: 60` pour rester frais pendant l'idle ; le champ manque
  dans ~23 % des appels → toujours servir depuis le cache avec indicateur d'âge.
- **Secondaire — opt-in explicite** : `GET api.anthropic.com/api/oauth/usage` avec le token lu en
  lecture seule via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
  (couvre le démarrage à froid et l'usage claude.ai). **Jamais** toucher au refreshToken (sa
  rotation désynchronise le login de Claude Code). Zone grise ToS clairement documentée dans
  l'UI, désactivé par défaut.
- **Jamais** d'estimation JSONL pour les pourcentages de limite (dérive structurelle — les
  limites sont par compte, multi-appareils, pondération serveur non publiée).
- Affichage compact : `5h ▓▓░░░░░ 27% · 7j ▓░░░░░░ 11%` avec compte à rebours de reset.

### 3.7 ChatDriver (piloter Claude depuis l'îlot)

- Nouvelle session : spawn `claude -p --input-format stream-json --output-format stream-json
  --verbose --include-partial-messages` (processus persistant multi-tours, messages NDJSON sur
  stdin, deltas de streaming en sortie) ; `--session-id` pré-choisi pour tail-er le transcript
  immédiatement. Jamais `--bare` (désactive hooks + auth par abonnement).
- Relance d'une session existante : `claude -p --resume <id>` depuis le cwd d'origine ;
  `--fork-session` si la session est peut-être encore ouverte dans un terminal (pas de verrou :
  deux écrivains entrelaceraient le transcript).
- Résolution du binaire : `/bin/zsh -l -c 'command -v claude'` une fois au démarrage, sondes de
  secours (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), chemin surchargeable dans les
  réglages.
- Détection de capacités via `system/init.capabilities` (pas de comparaison de versions).

---

## 4. Design ASCII (l'identité)

**Discipline de grille de caractères** (le secret de SRCL/sacred.computer) : on mesure la cellule
d'un glyphe (`NSFont` advancement) et **tout** — bordures, padding, barres, cartes — s'aligne en
unités entières de cellule. `lineSpacing(0)` pour que les box-drawing se connectent.

- **Fontes** : SF Mono à runtime par défaut (zéro risque licence) ; JetBrains Mono + Departure
  Mono embarquées (OFL) en option « signature ». Jamais Berkeley Mono (licence).
- **Vocabulaire visuel** : cadres `╭─╮│╰╯`, spinners braille `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (frames de
  cli-spinners, 80 ms, `TimelineView(.periodic)`), barres de progression en huitièmes de bloc
  `▏▎▍▌▋▊▉█` (résolution 8× sous-caractère), sparklines `▁▂▃▄▅▆▇█`, états `[ WORKING ]`
  `[ AWAITING ]` `[ DONE ]`.
- **Thèmes** : enum `system / light / dark` en `@AppStorage`, appliqué via `NSApp.appearance`
  (`nil` = auto) ; palette en asset catalog avec variantes Any/Dark. Presets : **Mono+accent**
  (défaut, façon terminal.shop : noir/blanc tranché + un seul accent orange `#FF5C00`),
  **Phosphor** (`#33FF33` sur `#0D0208`), **Amber** (`#FFB000`), **Solarized** (paire
  light/dark native — idéale pour le mode auto).
- **Effets CRT** (opt-in, subtils) : glow par ombres empilées, vignette en dégradé radial,
  scanlines via shader Metal `.colorEffect` (référence MIT : Inferno/Interlace), 5–15 % max —
  une texture, pas un gimmick ; toggle accessibilité.
- **Rendu** : un seul `Text` multi-lignes AttributedString par surface (jamais une grille de
  `Text` par caractère) ; `Canvas` + `context.resolve` seulement si un effet 60 fps l'exige.

**Maquettes d'états :**

```
COMPACT (autour du notch)                       ÉTENDU — permission
╭───────────────────╮  ╭───────────────────╮   ╭─────────────────────────────────────╮
│ ⠹ dyn-island BUSY │  │ 5h ▓▓░ 27% 7j 11% │   │ ⚠ Bash(git push origin main)        │
╰───────────────────╯  ╰───────────────────╯   │ ~/Desktop/dynamic-island · claude   │
                                               │ ───────────────────────────────────  │
ÉTENDU — question                              │  $ git push origin main             │
╭─────────────────────────────────────╮        │ ───────────────────────────────────  │
│ ? Quelle approche préfères-tu ?     │        │  [ DENY ⌘N ]        [ ALLOW ⌘Y ]    │
│  ▸ 1. SwiftUI natif                 │        ╰─────────────────────────────────────╯
│    2. AppKit + NSHostingView        │
│    3. Autre… ▁▁▁▁▁▁▁▁▁▁▁▁          │        ÉTENDU — plan review : markdown du plan,
│  [ ENVOYER ⏎ ]                      │        scroll, [ APPROVE ] [ REVISE + feedback ]
╰─────────────────────────────────────╯
```

---

## 5. Roadmap

### Phase 0 — Fondations *(repo, projet)*
Repo privé ✔, projet Xcode (app + package SPM `AtollCore`), `.gitignore`, cible macOS 14,
LSUIElement, MenuBarExtra squelette, CI locale simple (`xcodebuild build test`).

### Phase 1 — La coquille notch + thème *(premier « wow » visuel)* — ✅ livrée 2026-07-18
NSPanel + géométrie + hover/expand/collapse animés, pilule simulée sans notch, multi-écrans,
ThemeEngine (system/light/dark + presets), composants ASCII de base (cadre, spinner, barre,
badge d'état) avec données factices. **Livrable : l'îlot vit sur l'écran et il est beau.**

### Phase 2 — Monitoring des sessions *(la valeur de fond)*
BridgeServer socket + `atoll-bridge` + installeur de hooks géré (backup/repair/uninstall),
SessionStore complet (états, kqueue, réconciliation, tail JSONL interruptions), cartes de
sessions en temps réel, notifications système en option. **Livrable : toute session `claude`,
lancée n'importe où (y compris terminal Cursor), apparaît et disparaît fiablement.**

### Phase 3 — Interactions *(le cœur)*
`PermissionRequest` bloquant : cartes permission (avec diff), plan review markdown, réponses
AskUserQuestion (choix + texte libre), gestion de la course terminal/îlot, raccourcis ⌘Y/⌘N.
**Livrable : on répond à Claude depuis l'îlot sans toucher au terminal.**

### Phase 4 — Jump-back terminal
Adapters Terminal.app + iTerm2 + tmux (niveau pane), onboarding TCC Apple Events propre,
fallback activation app pour le reste ; Ghostty/WezTerm/kitty ensuite ; extension compagnon
VS Code/Cursor (`.vsix`) en option. **Livrable : cliquer une carte focus le bon onglet/pane.**

### Phase 5 — Quota
Tee-wrapper statusline (chaînage respectueux + désinstallation propre), cache + indicateur
d'âge, jauge compacte 5 h/7 j + comptes à rebours ; polling OAuth opt-in. **Livrable : le quota
exact, en un coup d'œil.**

### Phase 6 — Chat intégré
ChatDriver stream-json persistant, composer dans l'îlot étendu (nouvelle session dans un dossier
choisi, ou reprise/fork d'une session existante), rendu streaming ASCII. **Livrable : on lance
et pilote Claude depuis le notch.**

### Phase 7 — Polish + distribution
Onboarding (installation hooks guidée, permissions), réglages complets, sons (packs 8-bit
optionnels), Sparkle + appcast, signature Developer ID + notarisation + DMG, site/README.

Chaque phase se termine par un build utilisable — tu peux t'arrêter (ou pivoter) à n'importe
quelle frontière de phase.

---

## 6. Risques connus & parades

| Risque | Parade |
|---|---|
| Sessions du *panneau* d'extension VS Code/Cursor : pas de `PermissionRequest` (issue #16237) | Badge « lecture seule / répondre dans l'éditeur », focus via `cursor -r` |
| Format JSONL des transcripts officiellement instable | Hooks = temps réel ; JSONL = affichage, parsing défensif |
| `SessionEnd` non fiable (SIGKILL, Ctrl-C, /exit — issues connues) | kqueue `NOTE_EXIT` = source de vérité, débounce en réconciliation |
| Course prompt terminal ↔ carte îlot | Premier répondu gagne ; annulation de carte sur `PostToolUse`/`Stop` |
| Endpoint OAuth usage = zone grise ToS | Opt-in explicite, lecture seule, jamais de refresh, statusline en primaire |
| Écrasement de la statusline d'un utilisateur | Détection + chaînage passthrough + refus si config inconnue |
| App non signée quasi inutilisable sur macOS 15+ | Compte Apple Developer 99 $/an avant toute distribution publique (usage perso : build Xcode local OK) |
| boring.notch en GPL-3.0 | Atoll étant lui-même GPL-3.0, adapter du code GPL est permis (avec attribution) ; en pratique on réécrit from scratch |

---

## 7. Décisions validées (Mehdi, 2026-07-18)

1. **Nom** : « Atoll » ✔
2. **Compte Apple Developer** : Mehdi en a un ✔ (signature/notarisation possibles) ; usage
   d'abord personnel.
3. **Périmètre v1** : Claude Code uniquement ✔
4. **Gratuit et open source** ✔ — licence **GPL-3.0-or-later** (protège contre les clones
   commerciaux fermés, comme open-vibe-island ; nous autorise aussi à adapter du code GPL
   comme boring.notch). Le repo GitHub reste privé jusqu'à nouvel ordre de Mehdi.
5. **Palette par défaut** : Mono + accent orange ✔ (Phosphor/Amber/Solarized en presets
   optionnels)
6. **Xcode** : 26.0.1 installé ✔

---

## Annexe — Recherche

Les 10 rapports de recherche détaillés (avec sources, schémas JSON exacts, vérifications
empiriques faites sur cette machine avec Claude Code 2.1.214) sont dans [`docs/research/`](docs/research/).
