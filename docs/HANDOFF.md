# HANDOFF — reprise du développement d'Atoll

> Document de continuité pour reprendre le dev après un compactage de conversation.
> **À lire en premier** avec `CLAUDE.md` (règles) et `PLAN.md` (plan produit).
> Dernière mise à jour : **2026-07-21**, app **v0.7.0** (Phase 7 « Atoll apprend »
> COMPLÈTE : mémoire 7a + rétrospective 7b + curation/revue 7c).

---

## 0. TL;DR — où on en est

Atoll est une « Dynamic Island » ASCII pour Claude Code sur macOS (Swift/SwiftUI, GPL-3.0,
repo PUBLIC `github.com/mehdi7129/atoll`). **Phases 1 à 6 + Phase 7 (a/b/c) livrées et
publiées** (v0.7.0 sur GitHub Releases, DMG notarisé + appcast Sparkle). L'app tourne,
274 tests AtollCore verts, tout est poussé. Publier une nouvelle version =
`Scripts/release.sh` (voir §1). **Phase 7 « Atoll apprend » COMPLÈTE** — Atoll se
souvient (mémoire FTS5 + recall), apprend (rétrospective read-only → notes + skills
proposés) et cure (revue humaine, activation, désinstallation chirurgicale). Plan de
référence : `~/.claude/plans/indexed-snacking-dahl.md`. Rien de bloqué ; pistes
futures possibles (non demandées) : curation périodique des notes (NotesCuration existe
en AtollCore, non branchée à un service App), déduplication inter-fichiers de l'index.

Ce qui marche aujourd'hui, de bout en bout :
- Îlot notch ASCII (thème system/light/dark, 4 palettes, mono+orange par défaut).
- **Taille de la barre compacte réglable PAR ÉCRAN** (petit/moyen/large, Réglages › Général).
- Monitoring temps réel des vraies sessions Claude (hooks → socket → machine à états),
  avec l'activité des sessions hookless lue sur le transcript (plus de « en cours » figé).
- Réponses depuis le notch : permissions (⌘Y/⌘N), plans (approve/revise), questions.
- **Niveau d'autonomie** : 1 sélecteur exclusif **Manuel / Auto / Rockstar** (Réglages).
- Jump-back terminal (Cursor/VS Code via `cli -r`, Terminal.app/iTerm2 via AppleScript).
- Vrais quotas serveur (tee-wrapper statusline, quota périmé rejeté), jauge par modèle
  opt-in, % de contexte par session.
- Ouvrir la session dans son terminal (« OUVRIR DANS CURSOR ») via le jump-back.
- **Mémoire (7a)** : tous les transcripts indexés dans ~/.atoll/memory.db (FTS5,
  backfill 329 Mo ≈ 1 min, suivi temps réel par nudges de fin de tour) ; les
  sessions Claude interrogent via le skill `atoll-recall` → `atoll-bridge recall`
  (fail-open exit 0 toujours). Réglages › Claude Code › Mémoire (opt-out, stats,
  rebuild). Pièges et invariants : voir CLAUDE.md « Phase 7a ».
- **Apprentissage (7b + 7c)** : rétrospective de fin de session (opt-in OFF) →
  notes + skills proposés en quarantaine ; revue dans une fenêtre dédiée
  (⌘⏎/⌘⌫), activation dans ~/.claude/skills, usage suivi, désinstallation
  chirurgicale pilotée par manifeste+SHA256. Tout dans l'onglet Réglages ›
  Apprentissage. Pièges : voir CLAUDE.md « Phase 7b » et « Phase 7c ».

> **Chat intégré + dictée vocale RETIRÉS le 2026-07-19** (décision de Mehdi : il
> chatte et dicte dans Cursor). Le bouton du détail de session ouvre désormais le
> terminal Cursor. Ne pas ré-ajouter sans demande explicite.
>
> **Numérotation des phases** : la « distribution » était la Phase 7 dans le PLAN
> historique ; après le retrait du chat (ex-Phase 6), elle est devenue la Phase 6.
> Le README et CLAUDE.md sont la référence à jour.

---

## 1. CE QU'IL RESTE À FAIRE

Le gros est livré et publié. Reste surtout du polish à la demande, la CI optionnelle,
et la roadmap v2 (multi-agents) à NE PAS entamer sans le demander à Mehdi.

### Publier une version (routine, ~5 min)
1. Monter `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` dans `project.yml`, committer.
2. `./Scripts/release.sh` → build signé, notarisation, DMG, appcast (imprime les commandes).
3. `gh release create vX.Y.Z <dmg> <zip>` + joindre les `dist/updates/*.delta`.
4. `git add docs/appcast.xml && git commit && git push` (servi par GitHub Pages).
Profil notarytool : `atoll-notary` (déjà enregistré). Clé privée Sparkle EdDSA dans
le Keychain de Mehdi — À SAUVEGARDER, elle signe toutes les mises à jour.

### Distribution — LIVRÉE (Phase 6, 2026-07-19)
Tout est en place ; publier une release = **`Scripts/release.sh`** (build Release signé
Developer ID + Hardened Runtime → re-signature des binaires imbriqués Sparkle →
notarisation `--keychain-profile atoll-notary` → staple → DMG notarisé → appcast).
Le script imprime les 2 commandes de publication (gh release create, push de
docs/appcast.xml — servi par GitHub Pages : main//docs).
- Debug reste **adhoc** (boucle dev inchangée) ; updater Sparkle **inactif en Debug**
  (sinon le build de dev s'auto-remplacerait par la release notarisée).
- Sparkle : opt-in (SUEnableAutomaticChecks **false** + Toggle Réglages, zéro réseau
  par défaut) ; gentle reminders (app LSUIElement → ◆ dans le menu, jamais de fenêtre
  cachée derrière) ; clé privée EdDSA dans le Keychain de connexion (À SAUVEGARDER).
- Pièges vérifiés en revue : `xcodebuild build` (non-archive) injecte get-task-allow
  → `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` en Release ; Autoupdate/Updater.app de
  Sparkle livrés adhoc → re-signés par release.sh ; `codesign -dv` n'affiche PAS
  `Authority=` (verbosité 2 requise : `-dvv`).
- Onboarding premier lancement (`OnboardingView`, flag `onboardingDone`, menu
  « Bienvenue… ») ; icône ASCII générée (`App/Assets.xcassets`).
- **CI** (optionnel, non fait) : GitHub Actions archive → notarytool → stapler → generate_appcast.

### Reste de la roadmap (voir PLAN.md §5) — après la 7
- Multi-agents (Codex/Gemini/…) : v2, hors périmètre v1 (Claude-only), NE PAS l'entamer
  sans le demander à Mehdi.

### Éléments différés VOLONTAIREMENT (ne pas « corriger » sans raison)
- **Polling OAuth du quota** (endpoint `api.anthropic.com/api/oauth/usage`) : laissé de
  côté — zone grise des CGU. Le tee-wrapper statusline suffit et est conforme. NE PAS
  ajouter sans accord explicite de Mehdi.
- **Jump-back pane-level pour VS Code/Cursor** (extension `.vsix` compagnon) : v1 fait
  du focus fenêtre via `cursor -r <racine>`, suffisant. L'extension est un gros chantier
  optionnel (voir `docs/research/research-followup-terminal-jump-back.md`).
- **Résumé de raisonnement (thinking) dans le chat** : parsé (`StreamEvent.thinkingDelta`)
  mais non affiché en v1.
- **API privées CGS/SkyLight** (affichage sur écran verrouillé) : non implémenté, pas un besoin.

---

## 2. MÉTHODE DE TRAVAIL QUI MARCHE (à reconduire)

### Revue adversariale multi-agents (le pilier qualité)
Après CHAQUE phase, j'ai lancé un `Workflow` de revue adversariale : plusieurs agents
attaquent le code par dimension (concurrence, sécurité, races, fuites…), chaque constat
est ensuite soumis à un agent « vérificateur » qui tente de le **réfuter**. Seuls les
constats confirmés (non réfutés) sont corrigés. **Ça a trouvé de vrais bugs à chaque
phase** (crash SIGPIPE, faille sécurité des triggers debug, blocklist auto-accept
contournable, perte de la statusline, mélange du flux chat…). **Reconduire pour la Phase 7.**
- Pièges d'écriture des scripts Workflow : chaînes JS pures, **pas de backticks ni
  d'apostrophes non échappés** dans les prompts (ça casse le parse). Utiliser `'...'`
  et concaténer `ROOT`, ou template literals sans backtick/apostrophe interne.

### Vérification VISUELLE obligatoire (exigence de Mehdi)
Après tout changement d'UI : `notifyutil -p …debug.expand`, `screencapture -x f.png`,
rogner la bande centrale supérieure avec `sips`, puis **REGARDER l'image** (l'outil Read
lit les PNG). Plusieurs bugs (débordement de contenu, cap noir du notch, badge, chat muet)
n'ont été trouvés que comme ça. **Ne jamais déclarer un changement d'UI « fait » sans l'avoir vu.**

### Tester en VRAI, pas juste compiler
Les bugs les plus coûteux (readabilityHandler mort en LSUIElement, spawn chat muet,
pipes Foundation croisés) sont invisibles en tests unitaires. Toujours lancer l'app,
déclencher, observer `state.json` + `log stream` + screenshots.

### Discipline AtollCore
Toute logique testable sans AppKit vit dans `AtollCore/` avec ses tests. Vérifier
`cd AtollCore && swift test` vert AVANT de brancher l'UI.

---

## 3. BOUCLE DE BUILD / DEBUG (copier-coller)

```sh
# Build (DerivedData HORS du Bureau iCloud, sinon CodeSign casse)
xcodegen generate                       # si project.yml ou nouveaux fichiers
DD="$HOME/Library/Developer/Atoll-DerivedData"
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug -derivedDataPath "$DD" build
ditto "$DD/Build/Products/Debug/Atoll.app" ~/Applications/Atoll.app   # lancer LA COPIE
pkill -x Atoll; sleep 1; open ~/Applications/Atoll.app                # relancer

cd AtollCore && swift test              # 131 tests

# Debug runtime
/usr/bin/log stream --predicate 'subsystem == "dev.mehdiguiard.atoll"' --level debug
cat ~/Library/"Application Support"/Atoll/state.json                  # sessions + pending + autonomy
```

### Triggers de debug (`notifyutil -p <nom>`) — allow/deny/select/jump/chat sont `#if DEBUG`
- `dev.mehdiguiard.atoll.debug.expand` / `.compact` — étend+épingle / replie l'îlot
- `.select` — sélectionne la 1re session (vue détail)
- `.allow` / `.deny` — résout la 1re carte en attente
- `.jump` — jump-back de la 1re session à ancre résolvable
- `.chat` — démarre un chat de test dans /tmp + envoie un message

### Piloter le vrai helper
```sh
~/.atoll/bin/atoll-bridge status        # {hooksInstalled, wrapperPresent, socketPresent}
~/.atoll/bin/atoll-bridge install       # (ré)installe hooks + statusline (idempotent)
~/.atoll/bin/atoll-bridge uninstall     # restaure l'existant
# simuler un événement (bloque jusqu'à décision pour PermissionRequest) :
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}' | ~/.atoll/bin/atoll-bridge
```

---

## 4. PIÈGES APPRIS À LA DURE (chacun a coûté cher — NE PAS RÉGRESSER)

### Build / signature
- **DerivedData hors du Bureau** : le Bureau est synchronisé iCloud, son file provider
  tamponne des xattrs qui cassent CodeSign (« resource fork / detritus »). Build dans
  `~/Library/Developer/Atoll-DerivedData`, jamais dans le repo.
- **Lancer une COPIE** (`~/Applications/Atoll.app`) : lancer le `.app` du dossier de build
  lui colle `com.apple.provenance` (ineffaçable) → casse le CodeSign suivant.
- `~/.local/bin/xattr` est un **shim Blender cassé** → toujours `/usr/bin/xattr`.
- Le hook Bash de cette session **bloque `rm -rf`** même dans un `echo` → reformuler.
- Un `Atoll 2.xcodeproj` parasite peut apparaître (XcodeGen) → `.gitignore` a `*.xcodeproj/`.

### Runtime / système
- **`proc_name` des processus claude = numéro de version** (« 2.1.215 »), PAS « claude »
  (installeur natif) → matcher par CHEMIN d'exécutable (`ProcessInspector.isClaudeProcess`).
- **NWListener cassé sur socket Unix** (macOS 26) : connexions acceptées par le noyau mais
  jamais livrées au handler → BSD sockets + DispatchSource, fd non-bloquants (un accept
  bloquant gèle la queue série).
- `log show` ne voit PAS les niveaux info/debug (non persistés) → utiliser `log stream`.

### Chat / sous-processus (Phase 6, le plus douloureux)
- **`readabilityHandler` ne se déclenche PAS** sur un pipe dans une app LSUIElement (la run
  loop ne le pompe pas) → lire avec `read(2)` sur un thread dédié.
- **Les `Pipe`/`FileHandle` Foundation croisent les fds** sous concurrence (vérifié à l'lsof :
  le reader lisait le pipe stdin !) → **pipes POSIX explicites** (`pipe()`) + **`FD_CLOEXEC`**
  sur les 4 fds (sinon l'enfant hérite du socket du bridge et des extrémités de pipe).
- **Spawner `claude` DIRECTEMENT depuis l'app GUI le laisse MUET** : il n'émet même pas
  l'init, main thread bloqué, zéro I/O. Ce n'est NI l'environnement NI les fds (testé
  exhaustivement : env minimal, env exact d'Atoll, __CFBundleIdentifier, setsid, PATH…
  tout marche depuis un shell). **FIX : spawner via `/bin/zsh -l -c "exec <claude> <args>"`**
  → claude hérite des pipes POSIX mais tourne dans un contexte de shell de login (comme le
  terminal, où il marche). Voir `ChatDriver.spawn`.
- **Livrer les événements au main via `DispatchQueue.main.async` (FIFO garanti)**, PAS
  `Task { @MainActor }` (ordre NON garanti → flux NDJSON mélangé sous charge).
- `claude -p --input-format stream-json` sort tout seul (~1s) quand son stdin se ferme →
  pas d'orphelin au crash/force-kill ; + `ChatCenter.close()` à `applicationWillTerminate`.

### Interactions (Phase 3)
- **Course terminal ↔ îlot** (issue #12176) : le prompt TUI et le hook bloquant coexistent,
  premier répondu gagne. On annule la carte sur PostToolUse/Stop/SessionEnd/mort de session.
- Le `PermissionRequest` hook ne fire PAS dans le panneau d'extension VS Code/Cursor
  (issue #16237) — seulement le terminal intégré (qui, lui, marche). Sessions panneau =
  lecture seule.
- **SIGPIPE** en écrivant à un helper mort tuait TOUTE l'app → `SO_NOSIGPIPE` sur chaque fd
  client + `signal(SIGPIPE, SIG_IGN)` au démarrage.
- **Triggers Darwin de décision (allow/deny) uniquement `#if DEBUG`** : sinon tout process
  local pourrait approuver des permissions.

### settings.json de l'utilisateur (SACRÉ)
- Distinguer « fichier absent » de « fichier illisible » : ne JAMAIS écrire en cas de doute
  (sinon on remplace la config par du vide). Résoudre les symlinks (dotfiles). Backup dans
  `~/.claude/settings.json.atoll-backup`. Restaurer la statusline depuis le backup si
  `~/.atoll` a disparu. Valeurs mal formées → refus d'écrire, pas suppression.

### Auto-accept (sécurité)
- **Une blocklist regex de `rm` est TRIVIALEMENT contournable** (`/bin/rm`, `bash -c "rm"`,
  `git -C x push --force`, `base64|sh`, `${IFS}`…). → **ALLOWLIST** : n'auto-accepter que des
  commandes dont chaque segment est un outil de dev connu ET non destructeur ; rejet
  structurel de tout ce qui est opaque (interpréteur `-c`, `$()`, `eval`, `xargs`…). Les
  lanceurs `npx/bunx/dlx` vérifient le **paquet réel** (`npx rimraf` bloqué). Voir
  `AutoAcceptPolicy` + ses 22 tests de bypass.
- **Règles `deny` et hooks bloquants de l'utilisateur** : ils passent dans Claude Code
  AVANT Atoll → aucun hook ne peut les outrepasser (vérifié : même
  `updatedPermissions setMode bypassPermissions` est ignoré par le CLI 2.1.215, et les
  deny s'appliquent MÊME en bypassPermissions). D'où le design Rockstar (2026-07-19,
  demande explicite de Mehdi « aucune protection ») : les règles deny sont PARQUÉES
  dans `~/.atoll/rockstar-parked-deny.json` pendant Rockstar (verbes atoll-bridge
  `rockstar-park`/`rockstar-restore`, logique dans `RockstarPermissionsEditor`),
  restaurées à la sortie / au lancement / à la désinstallation. Crash-safe : le
  fichier de parking est écrit avant toute modification de settings.json. Les hooks
  bloquants de l'utilisateur (GSD…) restent actifs — choix assumé, ce sont des
  éléments de workflow, pas des protections Atoll. Autres faits vérifiés : questions
  AskUserQuestion passent par le hook même en bypass (rockstar y répond) ; l'outil
  n'existe pas en mode `-p` (chat). La config exacte de la machine de dev vit dans la mémoire projet (pas ici : repo public).

---

## 5. CARTE DE L'ARCHITECTURE (fichiers clés)

### `AtollCore/` (logique pure, testée — pas d'AppKit)
- `Palette`, `AsciiArt`, `IslandGeometry`, `ModelName` — thème/rendu/géométrie.
- `SessionModel` (AgentSession), `SessionPhase` (+ `SessionReducer`), `HookEvent`
  (`ParsedHookEvent` : décode l'enveloppe du helper).
- `HookSettingsEditor` / `StatusLineEditor` / `BridgePaths` — édition chirurgicale de
  settings.json (hooks + statusline), chemins partagés.
- `PermissionDecision` — construit les décisions JSON du hook PermissionRequest.
- `AutoAcceptPolicy` / `AutonomyLevel` — auto-approbation (allowlist) + niveau exclusif.
- `Quota` (`StatusLinePayload`, `QuotaSnapshot`) — parse le payload statusline.
- `TerminalTarget` (`TerminalResolver`, `WorkspaceRoot`, `IDECommandLine`) /
  `TerminalScripts` — résolution du terminal + AppleScript (jump-back).
- `StreamEvent` / `ChatProtocol` — parse le flux `claude -p` + messages user NDJSON.

### `App/` (fenêtre, IPC, vues — @MainActor)
- `AtollApp` / `AppDelegate` — @main, MenuBarExtra, démarrage (bridge server, store,
  migration autonomie, warmUp claude), triggers debug, reconstruction des fenêtres par écran.
- `NotchPanel` / `NotchWindowController` / `NotchViewModel` / `NotchRootView` /
  `NotchShape` / `NSScreen+Notch` — la coquille notch (NSPanel par écran, focus, géométrie).
- `CompactView` / `ExpandedView` / `SessionDetailView` / `InteractionCardView` /
  `ChatView` — les vues ASCII (priorité d'affichage étendu : carte > chat > détail > liste).
- `BridgeServer` — socket Unix BSD, reçoit les enveloppes du helper (events + statusline),
  garde les fd des PermissionRequest ouverts (`reply`/`cancelPending`).
- `SessionStore` (singleton @Observable) — source de vérité des sessions : reducer, kqueue
  NOTE_EXIT, réconciliation `ps`, tail transcript, quota réel, ancres terminal, snapshot.
- `InteractionCenter` (singleton) — cartes en attente + décisions + auto-approbation.
- `ChatCenter` (singleton) + `ChatDriver` — chat `claude -p` persistant.
- `TerminalJumpService` + `AutomationPermission` — jump-back (hors main + timeout).
- `HookInstaller` / `ClaudeLocator` — façade install, résolution du binaire claude.
- `ThemeManager` / `ThemeColors` — application du thème (NSApp.appearance).

### `Bridge/main.swift` — helper `atoll-bridge` (CLI embarqué dans le bundle)
Modes : (défaut) forward hook event enrichi (pid/tty/env) au socket, **fail-open absolu
exit 0** ; `statusline` (tee des rate_limits) ; `install`/`uninstall`/`status`.
`Shared/ProcessInspector.swift` (libproc, KERN_PROCARGS2) est partagé app/helper via
`Shared/BridgingHeader.h`.

### Flux de données
```
claude CLI (n'importe quel terminal) ──hook──▶ ~/.atoll/bin/atoll-bridge
     │                                              │ (enrichit pid/tty/env)
     └──statusline──▶ atoll-statusline ──tee──▶     ▼
                                            /tmp/atoll-$UID.sock (BSD socket)
                                                    │
                                            BridgeServer ──▶ SessionStore / InteractionCenter
                                                    │                    │
                                              (@Observable) ──────▶ NotchRootView (par écran)
```

---

## 6. DÉCISIONS & CONTRAINTES (validées par Mehdi)

- Nom **Atoll** ✔ · **gratuit + open source GPL-3.0** ✔ · repo **public depuis le 2026-07-19** (décision Mehdi
  sur décision de Mehdi) · palette **mono + accent orange** ✔ · **v1 = Claude Code only** ✔.
- **Compte Apple Developer : Mehdi en a un** → notarisation possible (Phase 7).
- Cible **macOS 14+**, Swift 5 language mode, **sandbox OFF / Hardened Runtime ON**.
- **Fail-open absolu** : rien de ce qu'Atoll installe ne doit pouvoir casser/ralentir le CLI.
- **Zéro télémétrie**, pas d'Electron, pas de dépendances lourdes.
- Mehdi **exige des vérifications visuelles (screenshots)** à chaque itération UI.
- Communication en **français** ; identifiants de code en anglais, commentaires en français.

### Environnement machine de Mehdi
- MacBook 14" à encoche, écran seul, résolution « More Space » 1800×1169, barre de menus masquée.
- **Ses sessions claude tournent dans le terminal intégré de Cursor**
  (`__CFBundleIdentifier=com.todesktop.230313mzl4w4u92`, `TERM_PROGRAM=vscode`) → le jump-back
  vise Cursor en priorité.
- Il a des hooks GSD + sons `afplay` + statusline `bun` custom dans `~/.claude/settings.json`
  → **préservés** (vérifié). Détails de config locale : voir la mémoire projet (repo public).
- node est via nvm mais aussi `/usr/local/bin/node` (donc trouvable par le PATH augmenté).

---

## 7. PROCHAINE ACTION CONCRÈTE

Quand Mehdi dit « go Phase 7 » :
1. Demander/confirmer le Team ID Apple Developer et créer le certificat Developer ID.
2. Écrire l'onboarding (première ouverture → proposer d'installer les hooks + expliquer).
3. Scripter signature + notarisation + DMG (tester sur un build local d'abord).
4. Intégrer Sparkle 2.8, générer les clés, poser l'appcast.
5. **Lancer la revue adversariale de la Phase 7** (distribution : sécurité de la mise à
   jour, intégrité de la signature, robustesse de l'onboarding/désinstallation).
6. Vérification visuelle de l'onboarding + du DMG.

Ne pas oublier : mettre à jour `PLAN.md` §5, le tableau du `README.md`, ce fichier, et la
mémoire projet à chaque phase.
