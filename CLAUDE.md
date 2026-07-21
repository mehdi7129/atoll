# CLAUDE.md — instructions projet Atoll

> 📌 **REPRISE DE DEV : lire `docs/HANDOFF.md` en premier** — état exact, méthode de
> travail, et TOUS les pièges appris à la dure. (v0.4.4 publiée ; chat/voix retirés.)

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
- ✅ Phase 5 — quota exact (tee-wrapper statusline, rate_limits serveur + indicateur
  d'âge ; jauge par modèle opt-in ; % de contexte par session)
- ✅ Phase 6 — distribution (Developer ID + notarisation, DMG, Sparkle, onboarding)
- ✅ Phase 7a — mémoire (v0.5.0) : index FTS5 de TOUS les transcripts →
  ~/.atoll/memory.db + verbe `atoll-bridge recall` + skill `atoll-recall`
- ✅ Phase 7b — rétrospective (v0.6.0) : en fin de session substantielle,
  claude -p READ-ONLY → notes mémoire + skills en QUARANTAINE
- ✅ Phase 7c — curation (v0.7.0) : revue des skills proposés (fenêtre dédiée),
  activation dans ~/.claude/skills, stats d'usage, désinstallation chirurgicale

**Phase 7c — Curation (v0.7.0, 2026-07-21)** — la boucle qui empêche la pourriture :
- AtollCore : `SkillSlug` (validation stricte anti-traversée), `SkillProposal`
  (machine à états proposed→approved|rejected, approved→archived ; décodage
  défensif), `InstalledSkillsManifest` (+ SHA256 CryptoKit), `LearnedSkillStore`
  (racines injectées → testable ; approve crash-safe avec REPRISE d'une install
  interrompue ; uninstallAll fail-closed piloté par le manifeste ;
  sweepStagingLeaks ; atoll-recall = infra jamais « non géré »),
  `SkillUsageParser` (tool_use name=="Skill") + table skill_usage (schemaVersion
  1→2), `NotesCuration` (planner + garde-fous rétrécissement). App :
  `SkillReviewCenter` (@Observable), `SkillReviewWindow` (ASCII, ⌘⏎ approuver /
  ⌘⌫ rejeter — friction voulue vs ⌘Y/⌘N des permissions), onglet Apprentissage
  (regroupe rétrospective + skills proposés/appris + mémoire), glyphe `+`
  compact, bannière ExpandedView, item menu « ◆ Skill proposé (N)… ».
- VÉRIFIÉ EN VRAI : seedSkill → glyphe → fenêtre → approve → skill ACTIF (le
  system-reminder l'a listé comme skill Claude Code !) → uninstall retire SEULEMENT
  les skills du manifeste (16 tiers intacts, settings.json = backup).
- Pièges (revue adversariale, 36 agents, 5 confirmés corrigés) : approve doit
  REPRENDRE une install interrompue (dossier posé mais hors manifeste = collision
  éternelle sinon) ; moveItem final tolérant (pair concurrent) ; staging orphelin
  balayé au reconcile ; usage enregistré au rythme des lots (pas au flush final).
- Debug (#if DEBUG) : seedSkill, skillReview, approveSkill, rejectSkill.

- Plan détaillé de la Phase 7 (validé par Mehdi) : ~/.claude/plans/indexed-snacking-dahl.md

**Phase 7b — Rétrospective (v0.6.0, 2026-07-20)** — « Atoll apprend » :
- Chaîne : SessionStore.markEnded (3 chemins unifiés : hook SessionEnd, kqueue,
  GC reconcile — callback UNE fois par transition) → RetrospectiveRunner (file
  FIFO, délai 15 s PAR JOB, gate LearningGate pur testé) → spawn `zsh -l -c
  "unset ANTHROPIC_API_KEY…; exec claude -p"` avec `--safe-mode
  --setting-sources "" --no-session-persistence --tools Read,Grep,Glob
  --permission-mode plan --json-schema … --max-budget-usd 1.5` → parse
  structured_output (RetrospectiveReport, revalidation Swift complète +
  détection de contenu suspect) → ATOLL écrit (LearningArtifacts) : notes →
  ~/.atoll/learning/notes/ (indexées rôle `note`), skills →
  learning/proposed/<slug>/ (quarantaine). État : learning/retrospectives.json.
- Faits VÉRIFIÉS (V0 + run réel) : `--safe-mode` garde l'auth souscription et
  ne déclenche AUCUN hook (PAS --bare : API key only) ; la sortie structurée
  vit dans `structured_output` ; `--setting-sources ""` accepté ; rétrospective
  INVISIBLE dans l'îlot (internalPids + env ATOLL_RETROSPECTIVE=1 filtrés par
  reconcile ; --no-session-persistence = aucun transcript → boucle impossible).
- Pièges (revue adversariale, 52 agents) : le kill-switch doit porter SA PROPRE
  escalade SIGTERM→SIGKILL ; une reprise --resume APRÈS la purge de 8 s recrée
  la Tracked → onSessionResumed émis aussi à la création sur sessionStart ;
  anti-replay quota (même resets_at + fraction plus BASSE = vieux cache
  ignoré) ; sessions synthétiques exclues (transcript deviné = lossy) ; regex
  de suspicion larges (| zsh, bash <(curl), settings.local.json).
- Debug : `notifyutil -p dev.mehdiguiard.atoll.debug.retro` (bypass gate,
  DEBUG only) ; logs catégorie `retro` (log STREAM, pas show). Réglages ›
  Claude Code › Rétrospective (opt-in OFF, seuil 50-80 %, modèle
  haiku/sonnet/fable — défaut sonnet).

**Phase 7a — Mémoire (v0.5.0, 2026-07-20)** — « Atoll se rappelle de tout » :
- AtollCore : `TranscriptLineParser` (parse défensif → fragments rôlés, thinking
  inclus cap 4000, anti-base64), `TranscriptLineSplitter` (découpe crash-safe :
  une ligne sans \n n'avance JAMAIS l'offset), `MemoryIndex` (FTS5 external
  content, unicode61 remove_diacritics 2, bm25+snippet, `sanitizedMatchQuery`
  anti-injection MATCH, LIKE avec ESCAPE), `RecallSkill`. App : `MemoryIndexer`
  (@Observable + actor worker, scan 30 s + nudges fin de tour, backfill 329 Mo
  ≈ 1 min). Bridge : verbe `recall` (fail-open exit 0 TOUJOURS), `ensureSkill()`.
- Pièges appris : TranscriptTailer INADAPTÉ à l'indexation (saut > 1 Mo, 24
  watches max) → l'indexeur lit lui-même ; lecteur WAL read-only peut échouer
  sans -shm → repli RW-sans-création côté bridge ; `import SQLite3` marche
  nativement en SPM ; un échec d'ingest ne doit JAMAIS être avalé-puis-dépassé
  (l'offset avancerait par-dessus le trou : perte permanente silencieuse —
  trouvé par revue adversariale) ; `~/.claude/skills/` contient des skills
  tiers → ne toucher QUE atoll-recall/.
- Debug : `sqlite3 ~/.atoll/memory.db "SELECT COUNT(*) FROM messages;"` ;
  `~/.atoll/bin/atoll-bridge recall "mots clés" --limit 5` ; logs catégorie
  `memory`. Réglages › Claude Code › Mémoire (toggle opt-out, stats, rebuild).

**Chat intégré + dictée vocale : RETIRÉS le 2026-07-19** (décision de Mehdi — il
préfère parler et chatter dans Cursor). Supprimés : ChatCenter/ChatDriver/ChatView/
VoiceDictation/ClaudeLocator (App), ChatProtocol/StreamEvent/TranscriptHistory
(AtollCore) + tests. Le détail de session ouvre le terminal de la session
(« OUVRIR DANS CURSOR ») via le jump-back. NE PAS ré-ajouter sans le redemander.
Les pièges du chat restent en mémoire projet si jamais on y revient (spawn via
`zsh -l -c "exec claude"`, pipes POSIX + CLOEXEC, `--fork-session` obligatoire).

**Polish post-distribution (v0.4.1 → v0.4.4, 2026-07-20)** — corrections et ajouts
faits sur retours de Mehdi (chacun vérifié en vrai) :
- **Taille de l'îlot compacte réglable PAR ÉCRAN** (petit/moyen/large) : `IslandWidth`
  (AtollCore, largeur des ailes / de la pilule), `IslandSettings` (App, @Observable,
  clé = displayUUID), réglage dans Réglages › Général. N'affecte que le compact.
- **Quota figé** : une session INACTIVE renvoie via refreshInterval un `rate_limits`
  mis en cache AVANT la réinitialisation → `StatusLinePayload` rejette tout quota dont
  la fenêtre 5h est déjà expirée (resets_at passé), sinon il écrasait la vraie valeur.
- **Phase des sessions synthétiques** (découvertes par scan, sans hooks) : elles
  restaient « en cours » ; désormais l'activité se lit sur l'écriture du transcript
  (TranscriptTailer.onActivity + minuteur d'inactivité 15 s + filet dans reconcile).
- **Notch** : `needsAttention` = permission SEULEMENT (pas `awaitingInput`) — une
  session dormante ne s'affiche plus en alerte. La pilule (écran sans encoche) nomme
  aussi la session en cours.
- **Menu « Bienvenue… »** : `NSApp.delegate as? AppDelegate` renvoie NIL avec
  @NSApplicationDelegateAdaptor → le menu passe par la notif `.atollShowOnboarding`
  observée par l'AppDelegate (l'action se déclenchait mais showOnboarding jamais).

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
- En mode `-p` (headless), l'outil AskUserQuestion N'EXISTE PAS.
- Avec `defaultMode: bypassPermissions` dans le settings.json utilisateur, les sessions
  ne produisent presque jamais de PermissionRequest d'outils — l'auto-accept paraît
  alors « inactif » ; ce sont les règles deny qui bloquent encore. (Config de la
  machine de dev : voir la mémoire projet, pas ici — repo public.)
- Un claude lancé DEPUIS une session Claude Code (env CLAUDECODE/CHILD_SESSION) peut
  démarrer en bypass : nettoyer l'env pour tester des comportements de permissions.

Triggers debug (`#if DEBUG`, `notifyutil -p dev.mehdiguiard.atoll.debug.<x>`) :
`expand`/`compact` (îlot), `allow`/`deny` (1re carte), `select` (1re session),
`jump` (jump-back), `settings` (fenêtre Réglages), `onboarding` (fenêtre Bienvenue).

Debug des interactions (Phase 3) : `notifyutil -p dev.mehdiguiard.atoll.debug.allow`
(ou `.deny`) résout la première carte en attente via les mêmes chemins que les boutons ;
`state.json` liste `pendingInteractions`. Tester le vrai helper :
`echo '{"hook_event_name":"PermissionRequest","session_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}' | ~/.atoll/bin/atoll-bridge` bloque jusqu'à la décision (stdout = JSON de décision, vide = rendu au terminal).
Le hook PermissionRequest est BLOQUANT (async:false, timeout 86400) — tout le reste est async.
