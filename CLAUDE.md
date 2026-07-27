# CLAUDE.md — instructions projet Atoll

> 📌 **REPRISE DE DEV : lire `docs/HANDOFF.md` en premier** — état exact, méthode de
> travail, et TOUS les pièges appris à la dure. (v0.12.0 publiée : Phase 12
> « Boucle fermée » — Atoll produit enfin des skills, cherche l'antériorité,
> diagnostique les plugins.)

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
- **Metal Toolchain (Xcode 26)** : composant TÉLÉCHARGEABLE à part
  (`xcodebuild -downloadComponent MetalToolchain`, ~700 Mo) — requis pour compiler
  `App/ExpansionRipple.metal` (sinon `CompileMetalFile` échoue « missing Metal Toolchain »).
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
- ✅ Phase 8 — « Sur rails » (v0.8.0) : découverte des sessions via l'interface
  SUPPORTÉE `claude agents --json` (autorité), hooks = temps réel, scan de
  processus = repli. Milestone A de la feuille de route « Atoll 2 ».
- ✅ Phase 9 — « Cockpit ambiant » (v0.9.0) : lancer une tâche en arrière-plan
  (`claude --bg`) depuis le notch (fenêtre dédiée), arrêter une session
  (`claude stop`, avec confirmation). Milestone C de la feuille de route.
- ✅ Phase 10 — « Verre & ondulation » (v0.10.0) : fond Liquid Glass (API PUBLIQUE,
  macOS 26) sur le panneau étendu, transparence réglable, onde d'expansion + hygiène.
- ✅ Phase 11 — « Mémoire vive » (v0.11.0) : Milestone B — curation périodique des
  notes, recall proactif (opt-in), qualité du recall (dédup inter-fichiers + récence).
- ✅ Phase 12 — « Boucle fermée » (v0.12.0) : la rétrospective produit VRAIMENT des
  skills (condensé Swift, quota persistant, journal), antériorité (`SkillCatalog`),
  inventaire des plugins, modèles par tâche.

**Phase 12 — « Boucle fermée » (v0.12.0, 2026-07-27)** — Atoll ne produisait AUCUN
skill. Diagnostic chiffré (agents) : **1 seule rétrospective lancée en 7 jours** sur
~29 sessions, 0 skill, et AUCUNE trace pour savoir pourquoi. Trois causes, corrigées :
- **CAUSE N° 1 — le quota ne vivait qu'en mémoire.** `LearningGate` refusait
  (`quotaMissing`) tant qu'aucune statusline n'était arrivée : donc après CHAQUE
  redémarrage d'Atoll, et pour toute session `claude --bg` (pas de TUI = pas de
  statusline). FIX : `QuotaSnapshot` est `Codable` et mis en cache dans
  `~/.atoll/quota-cache.json` (rechargé au `start()`, ignoré si la fenêtre 5 h a
  tourné) ; et « quota inconnu/périmé » n'est plus un refus sec mais autorise
  `unknownQuotaMaxPerWindow` run(s) (défaut 1) — le plafond de fenêtre, désormais
  évalué AVANT le quota, borne la dépense. Une lecture vieille dont `resets_at` est
  connu ET futur sert de MINORANT (l'usage ne redescend pas) → vrai refus au-delà du seuil.
- **CAUSE N° 2 — les transcripts sont hors de portée du budget.** Le gate a un plancher
  (100 Ko) mais aucun plafond : il sélectionnait des fichiers de 9 à 47 Mo que le modèle
  lisait avec Read sous 1,50 $ (il en voyait ~8 %). FIX : `AtollCore/TranscriptDigest`
  — Atoll extrait LUI-MÊME, en Swift, prompts utilisateur + conclusions + erreurs +
  commandes réussies, capé à 150 000 caractères, injecté DANS le prompt ; le modèle n'a
  plus AUCUN outil (`--tools ""`). MESURÉ : **47 Mo → 148 828 caractères en 2 s**
  (compression 154× à 589× selon les transcrits, sessions ordinaires passées intégralement).
- **CAUSE N° 3 — le prompt était dissuasif** (« When in doubt, return ZERO skills »).
  FIX (choix de Mehdi : *équilibré*) : proposer dès qu'une procédure a été EXÉCUTÉE
  avec succès et est rejouable, `confidence` honnête — la quarantaine + la revue ⌘⏎/⌘⌫
  SONT déjà le filtre.
- **RÉSULTAT VÉRIFIÉ EN VRAI** (sur le transcript de 47 Mo du projet) : **8 notes et
  2 skills proposés** (`release-pipeline`, `adversarial-review-workflow-recovery`), là
  où 7 jours d'usage n'avaient rien produit. Le SKILL.md contient la vraie procédure de
  release avec ses pièges (codesign -dvv, 404 d'appcast, ordre de publication).
- **JOURNAL D'APPRENTISSAGE** (`AttemptRecord` dans `retrospectives.json`, cap 100,
  affiché dans Réglages › Apprentissage) : chaque fin de session laisse une trace —
  décision, raison du refus, taille du transcript, quota au moment de la décision,
  coût, modèle dominant, notes/skills produits. C'est CE QUI MANQUAIT pour diagnostiquer.
- **RETRY** : un échec (`failed(...)`) ne marque plus la session « traitée » — elle
  repassera. Avant, un run avorté la grillait jusqu'à +50 Ko de croissance.
- **PIÈGE VÉCU AU 1ᵉʳ RUN RÉEL** : le modèle nomme spontanément son skill `atoll-…`
  (le sujet EST Atoll) — or `SkillSlug.validate` refuse ce préfixe réservé, la
  proposition était inapprouvable et le SKILL.md sortait en `atoll-atoll-…`.
  `RetrospectiveReport.validSlug` retire donc le préfixe (testé).
- **FAIT VÉRIFIÉ (CLI 2.1.220)** : `--safe-mode` fait intervenir **claude-sonnet-5 en
  plus** du `--model` demandé, et c'est lui qui domine la facture — deux runs, l'un en
  sonnet l'autre en haiku, ont coûté 0,864 $ et 0,873 $. Les alias `haiku`/`sonnet`/
  `opus`/`fable` sont bien reconnus (vérifiés un par un). D'où la ventilation
  `RetrospectiveReport.modelCosts` et l'affichage du modèle dominant dans le journal :
  sans elle, le réglage de modèle paraît sans effet.
- **MODÈLES PAR TÂCHE** (Réglages › Apprentissage) : rétrospective / curation /
  recherche, parmi haiku · sonnet · opus · fable. Défauts choisis par Mehdi :
  **Haiku pour chercher, Sonnet pour analyser**.
- **ANTÉRIORITÉ** : `AtollCore/SkillCatalog` inventorie ce que Claude peut DÉJÀ invoquer
  (18 skills utilisateur + 59 commands `gsd:*` + 40 skills de plugins = 117 entrées chez
  Mehdi) et le prompt le reçoit : « si ça existe déjà, ne le propose pas ». Pièges :
  le nom fait autorité par le DOSSIER (collision `apex` vécue), les commands ne sont pas
  des skills mais occupent le même espace de noms, plusieurs versions d'un plugin
  coexistent, un plugin désactivé n'est pas invocable.
- **VERRE** : « Transparence du verre » → **« Intensité du Liquid Glass »** (le nom
  d'Apple). BUG CORRIGÉ : même avec un scrim opaque à 100 %, `.glassEffect(.regular)`
  continue de réfracter — le bas de la plage ne rendait jamais un fond plein et le
  réglage « semblait mort ». Sous `VisualEffects.glassFloor` (6 %), on ne pose PLUS de
  verre du tout. Vérifié en captures 0 % / 50 % / 100 % sur le 2ᵉ écran.
- Debug : `notifyutil -p dev.mehdiguiard.atoll.debug.retroBig` lance une rétrospective
  sur le PLUS GROS transcript du projet (bypass gate) — c'est l'outil qui a permis de
  prouver la boucle sans attendre qu'une vraie session substantielle se termine.
- **12b ANTÉRIORITÉ** : `AtollCore/SkillCatalog` inventorie tout ce que Claude peut
  DÉJÀ invoquer (117 entrées chez Mehdi : 18 skills, 59 commands `gsd:*`, 40 skills de
  plugins) et le prompt le reçoit ; le modèle nomme ce que sa proposition recoupe
  (`similar_existing`, porté jusqu'au meta.json et affiché EN TÊTE de la revue).
  Doublé d'une détection LOCALE déterministe (`closestMatch`, mots significatifs
  partagés, seuil 0,5) : la garantie ne peut pas dépendre du bon vouloir du modèle.
  Pièges du catalogue : le nom fait autorité par le DOSSIER (collision `apex` vécue),
  les commands ne sont pas des skills mais occupent le même espace de noms, plusieurs
  versions d'un plugin coexistent (`unknown` perdant), un plugin désactivé n'est pas
  invocable.
- **12c PLUGINS** : `App/PluginInventory` pilote `claude plugin` (list, details,
  enable/disable/install) — watchdog par commande (8 s / 20 s réseau / 90 s install),
  pipes drainés en parallèle, spawn shell de login, process marqué
  `ATOLL_RETROSPECTIVE=1`. **Atoll n'écrit JAMAIS dans `enabledPlugins` de
  settings.json ni dans le cache** : seule la CLI modifie l'état, et aucune action
  n'est automatique. Mesuré en vrai : 31 installés / 4 activés / 1 cassé
  (`security-pro`, fichiers déclarés manquants) / 6 doublons entre marketplaces.
  ÉCART CLI : `plugin details` accepte l'id COMPLET `nom@marketplace` — l'utiliser,
  sinon on lit le coût du mauvais plugin homonyme.
- **12d MODÈLES PAR TÂCHE** : rétrospective / curation / recherche, parmi
  haiku · sonnet · opus · fable (défauts : Haiku pour chercher, Sonnet pour analyser).
- **RECALL VISIBLE** : le helper remonte le nombre de souvenirs injectés dans
  l'enveloppe (`enrich.recallInjected`) → affiché dans le détail de session. Sans ça
  l'injection était totalement muette (le bloc part avec `suppressOutput`).
- Plan et critères mesurables : `docs/ROADMAP-12-boucle-fermee.md`.

**Phase 11 — « Mémoire vive » (v0.11.0, 2026-07-26)** = Milestone B de la feuille de
route « Atoll 2 ». Trois volets, tous vérifiés en vrai :
- **CURATION DES NOTES** (`App/NotesCurationService.swift`, `AtollCore/NotesCurationPrompt`
  + `NotesCuration` déjà présent) : un `claude -p` SANS AUCUN OUTIL (`--tools ""`, tout le
  corpus est dans le prompt) relit toutes les notes de `~/.atoll/learning/notes` et rend
  `{notes[], contradictions[]}`. ORDRE IMPOSÉ, chaque étape peut tout annuler : ≥ 2 notes
  → budget de corpus (120 000 caractères, sinon REFUS — tronquer remplacerait toute la
  mémoire par la consolidation d'un échantillon) → quota 5 h sous le seuil (sinon
  REPORTÉ, `lastRunAt` non avancé) → parse → `NotesCurationPlanner` (0 note ou < 50 % du
  volume = refus) → **archive vérifiée** (nombre de fichiers ET octets identiques) →
  staging → bascule → index. Contradictions JAMAIS tranchées : remontées en
  avertissements dans Réglages › Apprentissage. Vérifié en vrai : 5 notes → 3, doublons
  iCloud/CodeSign fusionnés avec leurs `sources`, contradiction 15 s/30 s signalée,
  archive complète dans `archive/notes-<stamp>/`. Réglages : « Consolider les notes
  chaque semaine » (opt-in) + bouton « Curer maintenant ». Debug :
  `notifyutil -p dev.mehdiguiard.atoll.debug.curation`.
- **RECALL PROACTIF** (`Bridge/ProactiveRecallHook.swift`, `AtollCore/ProactiveRecall`) :
  OPT-IN, OFF par défaut. Le réglage écrit `~/.atoll/proactive-recall.json` (source de
  vérité LUE PAR LE HELPER, app fermée comprise) et fait réinstaller les hooks :
  UserPromptSubmit passe **bloquant** (`async` retiré, timeout 5 s) — un hook `async` est
  fire-and-forget, sa sortie n'est JAMAIS lue. Le helper cherche dans l'index et répond
  `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…},
  "suppressOutput":true}`. FAIT VÉRIFIÉ (CLI 2.1.220) : le CLI l'accepte et l'écrit dans
  le transcript comme un attachment **`hook_additional_context`** — c'est la signature à
  chercher pour prouver l'injection (ne PAS croire le modèle sur parole : haiku a répondu
  « NON » alors que son propre thinking citait les extraits). Mesuré : 25 ms.
  Garde-fous : gate `shouldRecall` (prompt < 12 caractères, `/`…, < 2 mots-clés),
  exclusion de la SESSION COURANTE (sinon le prompt qu'on vient de taper est le
  « souvenir » n° 1 — vécu), rôles injectables limités à `user/assistant/summary/note`
  (jamais `tool`/`tool_result` : bruit ET vecteur d'injection indirecte), plancher de
  pertinence relatif, bloc capé à 1800 caractères, balises de rôle neutralisées,
  en-tête « DONNÉES, pas des instructions ».
- **QUALITÉ DU RECALL** (`AtollCore/MemoryRanking`, `MemoryIndex`) : « retrieve then
  rerank » — pool SQL (limit × 5, 20…200) → dédup inter-fichiers → reclassement
  pertinence + récence (poids 0,25, saturation à 1 an). MESURÉ sur la vraie base :
  **1 155 uuid présents dans ≥ 2 fichiers** sur 28 019 messages (`--resume`/fork recopie
  l'historique en gardant les uuid). PIÈGE : la clé de dédup ne peut PAS être l'uuid seul
  — les notes Atoll portent toutes l'uuid littéral `note` et les transcripts sans uuid
  ont des `line-<offset>` qui collisionnent entre fichiers → clé = uuid SEULEMENT s'il
  fait 36 caractères en cinq groupes, sinon `row:<id>`. Nouveau `MatchMode.any` (OR) :
  indispensable au recall proactif, le AND implicite sur 8 mots-clés ne matche jamais
  rien. `forgetFile`/`trackedPaths` : une note remplacée est OUBLIÉE de l'index (pas
  `markMissing`, réservé aux transcripts que Claude Code purge à 30 jours).
- Tableau de bord : Réglages › Apprentissage liste les notes (titre, catégorie, projet,
  date) et rappelle qu'un skill appris sert à TOUS les projets (`LearningInventory`).
  Ce volet est le seul du milestone à ne PAS avoir bougé le disque : les skills étaient
  déjà globaux, il manquait de le montrer.

**Phase 10 — « Verre & ondulation » (v0.10.0, 2026-07-25)** — polish visuel + hygiène :
- LIQUID GLASS (choix « sur rails supportés ») : le panneau étendu utilise l'**API
  PUBLIQUE** `.glassEffect(.regular, in:)` gardée `if #available(macOS 26.0, *)`, repli
  `shape.fill(colors.bg)` sur macOS 14/15. On n'a PAS copié le hack d'AgentGlance
  (CABackdropLayer + filtre PRIVÉ `glassBackground` + CASDFLayer) : API privée qui
  casserait à une MAJ macOS, contraire au principe directeur. `App/IslandVisuals.swift` :
  `IslandBackground` (compact/encoche = noir opaque, JAMAIS de verre ; étendu = verre
  `.regular` + SCRIM `colors.bg.opacity(1 − transparence)` PAR-DESSUS → contraste ASCII
  ET vraie translucidité pilotable). PIÈGE VÉCU : le teint `Glass.tint` SEUL était
  imperceptible sur fond sombre (le curseur « semblait mort ») → c'est le scrim, blend
  alpha direct, qui donne l'effet net. Réglage « Transparence du verre » (0–100 %, défaut
  50 %, `@AppStorage glassTransparency`) dans Réglages › Général, gardé macOS 26.
- ONDE d'expansion : shader Metal `App/ExpansionRipple.metal` (exemple officiel Apple,
  `[[stitchable]]` + `SwiftUI::Layer`) via `layerEffect`/`keyframeAnimator`/`ShaderLibrary.default`
  (API PUBLIQUE, macOS 14+), appliqué au CONTENU (pas au verre → évite le compositing),
  rejoué → étendu (`trigger > 0` : jamais au 1er rendu), respecte Reduce Motion. Constantes
  `nonisolated` (lues dans la closure Sendable de layerEffect).
- HYGIÈNE (audit multi-agents + 2 revues adversariales) : 3 warnings d'isolation MainActor
  corrigés (constantes shader / `NotchViewModel.store` résolu DANS l'init / `Retrospective
  Runner.stdoutCapBytes` → `nonisolated`) ; 9 symboles morts retirés (`terminalName`,
  `HookInstaller.backupExists`, `TerminalScripts.tmuxSelect`/`tmuxListPanes`,
  `TerminalAnchor.tmuxPane`/`itermSessionID`, `BridgePaths.installedSkillsManifestURL`
  [doublon mort : `LearnedSkillStore.manifestURL` reste l'autorité injectable],
  `HookSettingsEditor.managedMarker` [distinct de `SkillSlug.managedPrefix`, gardé],
  `AutonomyLevel.isAutonomous`). GARDÉS car échafaudage assumé : `NotesCuration`
  (Milestone B), `MockData`/helpers testés, champs de hook parsés défensivement.
- CONTEXTE : né de l'analyse du dépôt jumeau **AgentGlance** (github.com/ixjosemi/AgentGlance,
  MIT, multi-provider Codex/OpenCode/Pi/Convoy, découverte par SCAN DE PROCESSUS — PAS
  `agents --json`, donc VULNÉRABLE au daemon qu'Atoll a réglé). Leur verre = API PRIVÉE
  (CAFilter `glassBackground`). Retenu par Mehdi : l'onde (API publique) ; verre en API
  publique, pas leur hack. Reste en réserve : jump-back Ghostty/tmux, multi-provider.
- Debug : `notifyutil -p dev.mehdiguiard.atoll.debug.expand` (le verre + l'onde jouent).

**Phase 9 — « Cockpit ambiant » (v0.9.0, 2026-07-24)** — piloter la flotte depuis
le notch (lancement sur demande EXPLICITE, pas d'objectif auto-généré) :
- AtollCore : `FleetLaunch` (parseSessionID défensif de la sortie `claude --bg`
  colorée ANSI — ne PAS dépendre du format, l'autorité reste le FleetPoller ;
  shellQuote ; isValidTask ; testé). App : `FleetLauncher` (@Observable ;
  launch(task,cwd) = spawn `zsh -l -c "unset ANTHROPIC_API_KEY; exec claude --bg
  <task>"` avec cwd + watchdog ; stop(id) async avec retour ; mémoire du dernier
  dossier ; GARDE de ré-entrance : isLaunching posé AVANT l'await, sinon
  double-clic = deux `claude --bg`), `FleetLauncherWindow`/View (ASCII : TextEditor
  tâche + dossier pré-rempli/Parcourir + LANCER ⌘⏎ + avertissement Rockstar).
  Item menu « Lancer une tâche… » (⌘N). Bouton ARRÊTER dans SessionDetailView
  avec CONFIRMATION (footgun : arrête n'importe quelle session vivante, dont la
  tienne). La tâche lancée est une session Claude normale → FleetPoller + hooks la
  suivent ; permissions en cartes dans le notch (auto-approuvées en Rockstar).
- Pièges (revue adversariale, 48 agents, 4 confirmés + 2 sûretés corrigés) :
  double-lancement (bouton non désactivé + isLaunching après l'await) ; stop
  fire-and-forget qui ment sur son résultat ; resolveClaudePath sans garde
  triedLoginResolve ; lastError périmé à la réouverture ; + confirmation d'arrêt
  et avertissement Rockstar.
- Debug : `notifyutil -p dev.mehdiguiard.atoll.debug.launcher`.

**Clarté des sessions — regroupement par projet (v0.9.1, 2026-07-24)** : `agents
--json` liste TOUTE la flotte (tous projets, sessions oubliées, session de dev
imbriquée) → l'îlot pouvait montrer plus de sessions que Mehdi n'en compte (vécu :
3 pour 2, la 3e = notre session de dev nichée dans le même dépôt). PAS un bug (toutes
réelles) mais déroutant. FIX (choix de Mehdi : « comme des dossiers avec une flèche
pour voir les sous-sessions ») : `App/ExpandedView.swift` regroupe par PROJET (racine
`.git` via l'enum `ProjectRoot` qui remonte au `.git` — regroupe un dépôt et ses
sous-dossiers) ; adaptatif : 1 session = ligne directe, ≥2 = dossier pliable
`▸ Nom · N` (replié par défaut, glyphe d'attention/spinner sur l'en-tête). `@State
expandedProjects`. VÉRIFIÉ VISUELLEMENT : « ▸ Dynamic_Island · 2 » + « Val d'Isere »
en ligne = 2 éléments pour 2 projets.
- RESTE de la feuille de route « Atoll 2 » : Milestone B (mémoire approfondie).
  À FAIRE ensuite (demandé par Mehdi) : CLARTÉ de l'affichage des sessions —
  `claude agents --json` liste TOUTE la flotte (tous projets, sessions oubliées,
  session imbriquée) → peut afficher plus de sessions que l'utilisateur n'en
  compte. Pistes : libellé projet plus net + marqueur « autre projet », grouper
  par projet, marquer la session courante.

**Phase 8 — « Sur rails supportés » (v0.8.0, 2026-07-24)** — profiter des MAJ de
Claude sans casse :
- CONTEXTE : l'Agent View (`claude agents`) a officialisé le dashboard multi-sessions
  avec un DAEMON d'arrière-plan qui CASSE le scan de processus d'Atoll (les sessions
  bg sont des descendants du daemon → exclues comme subagents ; seuls les hooks les
  sauvaient). Réponse : migrer la découverte sur l'interface supportée.
- AtollCore : `AgentsSnapshot` (décodage défensif de `claude agents --json` : champs
  sessionId/pid/cwd/name/status/kind, tolérant aux nuls, startedAt en ms epoch),
  `FleetReconciler.correlate` (par sessionId PUIS pid — l'id peut diverger à un
  fork/compaction, le pid reste). App : `FleetPoller` (@Observable, poll ADAPTATIF
  2 s actif / 6 s repos, watchdog 5 s tuant un `claude` figé, résolution du chemin
  claude : check cheap ~/.local/bin à chaque fois + login shell UNE fois),
  `SessionStore.applyFleetSnapshot` (autorité de découverte ; hooks restent
  autoritaires pour la phase fine/permissions ; une session découverte par flotte
  puis recevant un hook rebascule `isSynthetic→false` ; retrait par ABSENCE du JSON
  avec tolérance 2 tours + jamais si carte de permission en attente ; no-op si rien
  ne change = pas de re-render). Scan de processus GATÉ derrière `fleetPolled &&
  !fleetAvailable` (repli si CLI ancien / daemon absent).
- VÉRIFIÉ EN VRAI : sessions bg apparaissent avec vrais ids + titres (nom agent-view),
  hooks vivants (toolRunning), session stoppée retirée (~25 s), îlot rend flotte+hooks
  ensemble ; `claude agents --json` liste TOUTES les sessions actives (même non
  lancées par l'agent view).
- Pièges (revue adversariale, 40 agents, 3 confirmés corrigés) : `agents --json` SANS
  timeout gèle la boucle de poll ET neutralise le repli (available reste true) →
  watchdog obligatoire ; le `name` JSON ne doit toucher que les sessions de flotte
  (sinon il écrase le titre = 1er prompt d'une session à hooks) ; ne pas re-sourcer
  le login shell à chaque poll ; le pid d'une session bg (enrich) SURVIT à `claude
  stop` → ne PAS l'utiliser pour la liveness, le JSON du daemon est l'autorité.
- Feuille de route « Atoll 2 » complète (validée par Mehdi) :
  ~/.claude/plans/indexed-snacking-dahl.md — Milestone A (robustesse) ✅, B (mémoire
  approfondie), C (cockpit ambiant : lancer une tâche/skill en bg depuis le notch).

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

Triggers debug (`notifyutil -p dev.mehdiguiard.atoll.debug.<x>`) — liste exhaustive,
tenue à jour avec `App/AppDelegate.swift` :
- TOUJOURS enregistrés (release comprise, aucun pouvoir de décision) :
  `expand` / `compact` (étend+épingle / replie l'îlot).
- `#if DEBUG` UNIQUEMENT (ils décident, dépensent du quota ou écrivent) :
  `allow` / `deny` (1re carte), `select` (1re session), `jump` (jump-back),
  `settings`, `onboarding`, `retro` (rétrospective sur la dernière session terminée),
  `curation` (curation des notes), `launcher` (fenêtre de lancement),
  `seedSkill` / `skillReview` / `approveSkill` / `rejectSkill` (curation des skills).

Debug des interactions (Phase 3) : `notifyutil -p dev.mehdiguiard.atoll.debug.allow`
(ou `.deny`) résout la première carte en attente via les mêmes chemins que les boutons ;
`state.json` liste `pendingInteractions`. Tester le vrai helper :
`echo '{"hook_event_name":"PermissionRequest","session_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}' | ~/.atoll/bin/atoll-bridge` bloque jusqu'à la décision (stdout = JSON de décision, vide = rendu au terminal).
Le hook PermissionRequest est BLOQUANT (async:false, timeout 86400) — tout le reste est async.
