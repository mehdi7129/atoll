# CLAUDE.md — instructions projet Atoll

> 📌 **REPRISE DE DEV : lire `docs/HANDOFF.md` en premier** — état exact, méthode de
> travail, et TOUS les pièges appris à la dure.
>
> **Version publiée : v0.16.0** — la mémoire répond, et Atoll rend ce qui n'est pas à
> lui (quatre lots, **−910 lignes nettes**). Le cadre en vigueur n'est plus une
> feuille de route de fonctions mais `docs/VISION-2026-08.md` : Anthropic livre
> nativement de plus en plus de la surface d'Atoll, donc **soustraire avant
> d'ajouter**. Ne pas proposer d'ajout sans avoir lu ce document et son plan court
> terme — plusieurs idées séduisantes y sont déjà écartées, avec la raison.
>
> Auparavant : v0.15.1 (le son ne dépend plus de l'app — le helper joue quand elle est
> fermée) ; v0.15.0, Phase 14 « Arêtes franches » (coins hauts droits, contour au
> calibrage Apple, ouverture sans contour fantôme, badge « INPUT? » retiré) ;
> v0.14.1, audit complet — 59 + 25 défauts corrigés, cf. `docs/AUDIT-2026-07-27.md`.

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
  **FILMER plutôt que photographier** quand le défaut est une ANIMATION :
  `screencapture -x -v -V 3 -D 2 f.mov` puis `ffmpeg … tile=4x8` pour une planche
  de vignettes, ou un profil de luminance par image. C'est ce qui a permis de
  séparer, en Phase 14, deux causes qui se superposaient — voir plus bas.
  (`ffmpeg` est présent : `/opt/homebrew/bin/ffmpeg`.)

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

**AUDIT COMPLET DU 2026-07-27** — `docs/AUDIT-2026-07-27.md` (à lire avant tout
travail sur les zones citées). Workflow de 234 agents, 18 dimensions, chaque
défaut vérifié par 2 lentilles adversariales : 108 allégués → 71 confirmés, 30
contestés, 7 réfutés (59 distincts). **Tous corrigés**, puis une SECONDE revue
adversariale des corrections elles-mêmes (118 agents) a trouvé **25 régressions**,
également corrigées. 636 tests verts.

**LEÇON GÉNÉRALE** : une correction de sécurité mérite sa propre revue
adversariale. Le garde-fou des interpréteurs posé le matin se rouvrait en
retirant UNE ESPACE (`python3 -c'code'` collé produit un token unique qui
n'égalait aucun drapeau connu) ; le verrou anti-double-spawn de la rétrospective
bloquait sa propre file ; le filtre de quota masquait des jauges valides. Voir
`docs/AUDIT-2026-07-27.md`.
Les quatre qui comptent :
- **`&` n'était pas un séparateur de segment dans `AutoAcceptPolicy`** : une
  commande destructrice placée après un `&` était AUTO-APPROUVÉE (seul le
  premier mot était examiné), y compris `git status & git push --force` qui
  contournait ainsi la garde anti-force-push. Idem les interpréteurs à code en
  ligne (`node -e`, `python3 -c`, `awk 'BEGIN{system(…)}'`) — la garde `-c` ne
  connaissait que les noms de shells. Le jugement se fait désormais par
  SEGMENT, plus par regex globale (donc `grep -e node` n'est pas pris pour
  `node -e`). ⛔️ `AutoAcceptPolicy` est SUPPRIMÉE depuis le 2026-08-03 — avoir dû
  la corriger deux fois pour des contournements est l'argument même du retrait.
- **Un seul instantané de flotte vide annonçait toutes les tâches `--bg`
  terminées**, définitivement (`notified` idempotent), pendant que l'îlot les
  affichait « en cours ». Le store tolérait 2 absences, le journal aucune :
  deux politiques opposées sur le MÊME instantané (`fleetMissTolerance`).
- **Archiver/désinstaller un skill détruisait ses ressources jointes**
  (`references/`, `scripts/`) : seul `SKILL.md` était copié, puis le DOSSIER
  entier supprimé. On archive maintenant le dossier complet.
- **Le socket `/tmp` n'était pas authentifié** : `/private/tmp` est
  world-writable, un autre compte local pouvait préempter le chemin, lire tous
  les payloads et répondre `{"behavior":"allow"}` — décision que le CLI honore.
  Contrôle `LOCAL_PEERCRED` côté helper (vérifié : les hooks passent toujours).

**ARBITRAGE RENDU — l'îlot au repos.** Deux intentions écrites s'opposaient :
« au repos, l'îlot épouse l'encoche et reste invisible » (`IslandGeometry`) contre
« le losange rouge est un indicateur persistant » (`CompactView`). Elles sont
RANGÉES, pas fusionnées : l'invisibilité l'emporte pour tout ce qui est seulement
EN ATTENTE (un skill proposé sait attendre — il reste au menu et dès qu'une
session tourne), et cède pour **Rockstar SEUL**, parce que ce mode suspend les
règles `permissions.deny` que l'utilisateur a écrites lui-même. Mise en œuvre :
`hasActivity || rockstar` dans `NotchViewModel.islandSize(rockstar:)` et le HStack
de `CompactView`. Le drapeau vient de la VUE (`@AppStorage`) : `autonomyLevel` est
calculé depuis UserDefaults, donc invisible à `@Observable` — sans cela l'îlot ne
se redessine pas à la bascule.

**PIÈGE DE RELEASE (vécu en publiant v0.14.0)** : bouger `MARKETING_VERSION`
NE SUFFIT PAS. Sparkle identifie une mise à jour par `CFBundleVersion`
(= `CURRENT_PROJECT_VERSION`), et `generate_appcast` échoue à la toute fin —
APRÈS le build, les deux notarisations et les deux staples, soit ~8 min perdues —
avec « Duplicate updates are not supported. Found archives 'Atoll-X.zip' and
'Atoll-Y.zip' which contain the same bundle version ». Chaque release incrémente
`CURRENT_PROJECT_VERSION` de 1 (0.10.0 → 15 … 0.13.2 → 20, 0.14.0 → 21). Vérifier
AVANT de lancer `Scripts/release.sh` :
`grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' project.yml`. Et si l'échec
survient quand même, retirer l'archive fautive de `dist/updates/` avant de relancer
(sinon elle continue de provoquer la collision).

PIÈGES DE MÉTHODE appris pendant cet audit :
- **`claude agents --json` ne liste QUE les sessions vivantes** ; le champ
  `state` (`done`/`stopped`) n'apparaît qu'avec `--all`, et ces entrées-là
  n'ont PAS de `status`. Vérifié sur le CLI 2.1.220 — c'est ce qui a réfuté le
  défaut « critique » n° 1 de l'audit. `AgentsSnapshot` lit désormais `state`
  en repli : blindage si le CLI change, aucun changement de comportement.
- **Un moniteur de clic GLOBAL referme l'îlot à n'importe quel clic**
  (`NotchWindowController`), y compris ceux de l'utilisateur pendant qu'on
  travaille. Une capture prise 3 s après `debug.expand` montre donc l'îlot
  REPLIÉ et fait croire que le trigger est cassé : capturer SOUS LA SECONDE
  (le ressort se stabilise en ~0,42 s).
- Quand le 2e écran est débranché, ne PAS se rabattre sur l'écran 1 : capturer
  la fenêtre SEULE (`CGWindowListCopyWindowInfo` → `screencapture -x -o -l <id>`).
- Nouveau trigger debug : `seedPlugins` (inventaire de plugins factice, sans
  réseau — le code existait mais aucun geste ne l'atteignait).

## État des phases (voir PLAN.md §5)

- ✅ Phase 1 — coquille notch + thème ASCII (sessions factices)
- ✅ Phase 2 — monitoring des sessions réelles (hooks → socket → machine à états)
- ✅ Phase 3 — interactions (PermissionRequest bloquant : permissions, plans, questions)
- ✅ Vrais quotas (statusline tee), infos par session — ⛔️ l'auto-accept par
  allowlist maison est RETIRÉ (2026-08-03), `claude auto-mode` le fait nativement
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
- ⛔️ Phase 9 — « Cockpit ambiant » (v0.9.0) : **RETIRÉE le 2026-08-03**. Le
  lancement depuis le notch n'avait JAMAIS servi et partait sans `-w`. Seul
  l'arrêt d'une session (`claude stop`, avec confirmation) subsiste.
- ✅ Phase 10 — « Verre & ondulation » (v0.10.0) : fond Liquid Glass (API PUBLIQUE,
  macOS 26) sur le panneau étendu, transparence réglable, onde d'expansion + hygiène.
- ✅ Phase 11 — « Mémoire vive » (v0.11.0) : Milestone B — curation périodique des
  notes, recall proactif (opt-in), qualité du recall (dédup inter-fichiers + récence).
- ✅ Phase 12 — « Boucle fermée » (v0.12.0) : la rétrospective produit VRAIMENT des
  skills (condensé Swift, quota persistant, journal), antériorité (`SkillCatalog`),
  inventaire des plugins, modèles par tâche.
- ✅ Phase 13 — « Rendre la main » (v0.13.0) : deux sons personnalisables (avec
  reprise réversible des hooks `afplay`), vue de la flotte par état. ⛔️ L'annonce
  de fin de tâche `--bg` est RETIRÉE avec le cockpit (2026-08-03) : sa seule source
  était la fenêtre ⌘N, elle n'a jamais sonné une seule fois.
- ✅ Phase 14 — « Arêtes franches » (v0.15.0) : coins hauts droits, contour au
  calibrage Apple mesuré, ouverture sans contour fantôme, badge « INPUT? » retiré.
- ✅ v0.16.0 (2026-08-03) — **pas une phase, un RETRAIT** : la mémoire répond, elle
  cesse d'avaler le bruit, le niveau « Auto » et le cockpit partent. −910 lignes
  nettes. À partir d'ici le cadre est `docs/VISION-2026-08.md`, pas une liste de
  phases : la question n'est plus « qu'ajouter ? » mais « qu'est-ce qu'Atoll est
  seul à faire ? ».

**Phase 14 — « Arêtes franches » (v0.15.0, 2026-07-28)** — trois défauts signalés par
Mehdi sur la v0.14.1, tous reproduits et mesurés avant d'être corrigés.

- **LE BADGE « [ INPUT? ] » EST RETIRÉ.** `AsciiArt.statusBadge` renvoie désormais
  `String?`, et `nil` pour `.awaitingInput`. Ce n'était pas qu'une question de goût :
  `claude agents --json` rapporte `"status": "idle"`, `SessionStore.fleetPhase` écrase
  `idle` ET `needsInput` sur la même phase `.waitingInput`, et TOUTE session découverte
  par la flotte NAÎT `waitingInput` — le badge posait donc une question au nom d'une
  session qui ne demandait rien, sur la moitié de la flotte en permanence. Le glyphe
  de la ligne devait suivre : `.awaitingPermission` et `.awaitingInput` partageaient
  `Text("!")` en `colors.warn`. Retirer le badge SANS scinder le glyphe aurait laissé
  un « ! » orange inexpliqué — plus alarmant qu'avant. `.awaitingInput` prend donc un
  `·` en `colors.dim`, ce que `AgentSession.needsAttention` disait déjà (permission
  SEULEMENT). `badgeColor` est scindé de même : inatteignable aujourd'hui, mais y
  laisser `warn` était une mine pour la prochaine réintroduction.

- **LES COINS HAUTS SONT DROITS** (`App/NotchShape.swift`, réécrite). L'ancien tracé
  évasait les coins supérieurs vers l'extérieur par une quad-Bézier tangente au bord
  haut : le « coin » était un rebroussement à 180° qui dégénérait en biseau effilé
  sous-pixel, et l'arête haute était plus large que le corps — l'œil y lisait deux
  contours emboîtés (vérifié au zoom 4×). Cet évasement a un sens quand la surface
  ÉPOUSE l'encoche ; il n'en a aucun sur 600 pt de large quand l'encoche en fait 220.
  La forme est maintenant un `UnevenRoundedRectangle` `.continuous` (le squircle
  d'Apple), rayons hauts 0, rayon bas 18 déployé / 12 compact.
  - **`topRadius` N'EXISTE PLUS** et le piège « la NotchShape insète ses flancs de
    topRadius » est CADUC : il décrivait un effet de bord, pas une intention.
  - **`IslandGeometry.expandedContentInset` : 38 → 26.** 38 valait « 19 d'inset subi
    + 19 de respiration » ; sans inset subi, la marge redevient une décision de mise
    en page. Le corps visible passe de 562 à **600 pt** (mesuré : 565 → 601 px).
  - **Les règles ASCII étaient calibrées sur l'ancienne boîte** : 52 → 70 (SESSIONS,
    qui partage sa rangée avec `[ PROJET ]`/`[ ÉTAT ]`), 72 → 79 (QUOTA,
    APPRENTISSAGE, TÂCHE TERMINÉE), `rule(56)` → `rule(79)`. Chiffre à retenir :
    **l'avance de `AtollFont.mono(11)` vaut 6,7998 pt** (5,5635 pt à 9 pt) — dans une
    boîte de 548 pt, 79 caractères laissent 10,8 pt de mou et **81 débordent**.
  - **`NotchShape.sideInset`** (compact 6 / déployé 0) : sans inset latéral du tout,
    l'îlot AU REPOS occupait exactement la largeur rapportée de l'encoche. Or cette
    largeur est une BOÎTE ENGLOBANTE et la découpe physique a des coins bas arrondis :
    à un pixel près, du noir pouvait se peindre sur la dalle, invisible sur fond
    sombre et visible sur fond clair. Le retrait est donc remis, mais NOMMÉ, et
    seulement là où il sert.

- **LE CONTOUR EST REFAIT AU CALIBRAGE APPLE**, mesuré au pixel sur CETTE machine
  (macOS 26.5.2) et non supposé :
  - **`.glassEffect` ne dessine AUCUN liseré** (six configurations testées, dont un
    vrai `buttonStyle(.glass)`) : tout trait qu'on dessine est le SEUL trait, aucun
    risque de double bordure.
  - Un vrai menu système, sur fond gris contrôlé, donne la MÊME structure sur ses
    quatre côtés : **1 px de contour sombre au bord, puis 2 px de liseré clair juste
    à l'intérieur**. Apple pose donc DEUX traits, pas un. D'où `contourColor`
    (`black` 0,70 sombre / 0,45 clair, UNIFORME — le contour ne se dégrade pas) et
    `borderGradient` (`white` 0,35 → 0,24 sombre ; 0,60 → 0,42 clair). Le rapport
    haut/bas est **1 → 0,7**, jamais 1 → 0,2 : plus bas, les deux coins inférieurs —
    les SEULS coins arrondis du panneau — perdent leur arête.
  - **Épaisseur = 1 pixel PHYSIQUE** (`NotchViewModel.hairline = 1/backingScaleFactor`,
    soit 0,5 pt en interne et 1,0 pt sur le 4K) pour le contour, le double pour le
    liseré. C'est exactement ce qu'Apple mesure.
  - **Le trait est découplé de la palette.** Il utilisait `colors.dim`, qui vaut vert
    en Phosphor et or en Amber : le bord se lisait comme un élément d'art ASCII, pas
    comme l'arête d'un matériau. Ne PAS retoucher `Palette.Variant.dim` pour autant,
    il peint tout le texte secondaire des fenêtres secondaires.
  - **L'arête HAUTE n'est pas bordée**, et elle s'efface en FONDU sur 16 pt (5 % de la
    hauteur, donc ~2 pt en compact — une longueur fixe mangerait la moitié d'un bord
    de 26 pt). Un liseré à y = 0 tracerait une ligne claire en travers de la barre des
    menus, sur un bord qui n'existe pas physiquement. Apple n'a pas de cas « bordé
    d'un seul côté » : sous Tahoe ses menus FLOTTENT et ne touchent plus rien.
  - **`borderStrength`** : 0 sur l'encoche en compact (fusion), 0,55 sur la pilule
    compacte d'un écran sans encoche (elle porte ce bord 24 h/24, sans session), 1
    déployé.
  - **Deux ombres** après `.compositingGroup()` : courte (0,26 / r3 / y1) pour poser
    l'arête, longue (0,26 / r22 / **y5**) pour l'altitude. Le y valait 10 : deux fois
    trop, l'ajustement gaussien sur une vraie fenêtre macOS 26 donne σ ≈ 11,7 pt et un
    décalage de +5. Contrainte : la fenêtre ne fait que 760 × 460 et
    `NotchPanel.hasShadow = false` — `radius + |y| ≤ 70`, sinon l'ombre est coupée net.

- **L'OUVERTURE N'EXHIBE PLUS DE CONTOUR FANTÔME — DEUX causes distinctes**, trouvées
  parce qu'on a FILMÉ l'ouverture à 60 i/s au lieu de la photographier.
  - **Cause n° 1, visible seulement sur l'écran à ENCOCHE** : le trait était un enfant
    CONDITIONNEL de `.overlay` (`if !isCompactCap`), donc absent en compact. SwiftUI ne
    l'interpolait pas, il l'INSÉRAIT — et une vue insérée naît à sa géométrie FINALE
    avec un simple fondu. On voyait donc le contour du panneau déployé pendant que le
    corps mettait ~0,25 s à grandir jusqu'à lui : littéralement « d'abord le contour,
    ensuite la fenêtre qui vient s'y coller ». Contrôle décisif : sur l'écran 2
    (`isCompactCap` toujours faux, donc trait présent dans les deux états) le même
    trait se déplaçait continûment. Le bord est désormais TOUJOURS rendu, seule son
    opacité change. **Règle générale : ce qui doit s'animer ne doit jamais être un
    `if` dans un ViewBuilder.** Même correction appliquée à `IslandBackground`, qui
    basculait entre trois branches.
  - **Cause n° 2, sur les deux écrans, d'autant plus visible que le verre est fort** :
    le Liquid Glass met ~250 ms à se matérialiser, hors de notre contrôle. MESURÉ à
    100 % de verre : la luminance intérieure du panneau monte de 9 à 30 en ~250 ms
    alors que la géométrie est déjà à 66 % de sa largeur finale — le panneau est un
    contour presque vide. Le même relevé avec le verre à 0 donne une luminance
    CONSTANTE à 9,0. Correctif : `IslandBackground.glassReveal` (0 = fond plein,
    1 = l'intensité réglée), animé de 0 à 1 en `easeOut(0,30).delay(0,10)` à
    l'ouverture. Le verre se matérialise SOUS un aplat, personne ne le voit arriver.
    Après correction : luminance constante à 9,0 pendant toute la croissance.
  - **PIÈGE DU CORRECTIF** : `glassReveal` est un `@State`. Si la fenêtre est
    reconstruite alors que l'îlot est DÉJÀ déployé (écran branché, résolution
    changée), il repart à 0 et seule une TRANSITION vers `.expanded` le remonte — le
    panneau resterait en fond plein pour toujours. D'où le rattrapage dans `.onAppear`.

- **`glassEffect(_:in:isEnabled:)` N'EXISTE PAS sur macOS 26** (SDK vérifié :
  `SwiftUICore.swiftinterface` ne déclare que `glassEffect(_:in:)`). L'insertion
  conditionnelle du verre reste donc nécessaire — elle est simplement devenue
  INVISIBLE, puisqu'à l'instant où elle se produit l'aplat est opaque.

**VOCABULAIRE DE L'INTERFACE (v0.13.2)** — les identifiants de code restent
anglais et INCHANGÉS (`NotesCuration`, `RetrospectiveRunner`…), mais les
libellés affichés ont été dé-jargonnés à la demande de Mehdi :
« Curation des notes » → **« Ranger les notes »** · « Rétrospective » →
**« Bilan de fin de session »** (le picker : « Bilan de session ») ·
« Souvenirs proposés d'office » → **« Souvenirs joints à tes messages »**.
Gardés tels quels : « skill », « quarantaine », « quota », « plugins »
(vocabulaire de Claude Code ou déjà clair).

**FENÊTRE DES RÉGLAGES (v0.13.2)** — elle sautait de taille d'un onglet à
l'autre et refusait de s'étirer. Trois causes cumulées, toutes corrigées :
`.frame(width: 640)` figeait la largeur ; quatre volets forçaient leur hauteur
intrinsèque (`fixedSize`) pendant que deux autres étaient plafonnés à 620 ; et
surtout **une scène `Settings` produit une fenêtre NON redimensionnable, sans
que `.windowResizability(.contentMinSize)` y change quoi que ce soit** (vérifié
en capture : le bouton zoom restait éteint). Le style est donc ajouté à la
fenêtre elle-même via un `NSViewRepresentable` (`ResizableWindow`). Preuve
visuelle : la pastille verte s'allume. Tous les volets remplissent désormais la
fenêtre (`maxWidth/maxHeight: .infinity`) et leur Form défile.

**LE SON NE DÉPEND PLUS DE L'APP (2026-08-03)** — panne constatée sur la machine de
Mehdi : Atoll avait parqué ses deux hooks `afplay` le 27 juillet (donc **0 occurrence
d'`afplay` dans `settings.json`**), puis l'app est restée fermée deux jours. Résultat :
**rien ne sonnait**, ni ses hooks ni ceux d'Atoll — alors qu'il a mis ces sons
précisément pour être APPELÉ plutôt que surveiller un écran. Prendre quelque chose à
l'utilisateur et mourir avec, c'est l'esprit de la règle n° 1 violé.
- **`SoundFallback` (AtollCore)** + **`Bridge/SoundPlayer.swift`** : le helper joue
  lui-même, **uniquement si l'app n'a pas été jointe**. `sendToSocket` rend désormais un
  `SocketOutcome{reached, reply}` — un `Data?` ne distinguait pas « app absente » de
  « envoyé, rien à lire ». Exactement un des deux sonne, jamais les deux.
- **`~/.atoll/sound-settings.json`** : réglages ÉCRITS par l'app (`publishSettings()`, à
  chaque mutation) et LUS par le helper — même dispositif que `proactive-recall.json`.
  Les `UserDefaults` ne conviennent pas : autre binaire, autre domaine, cache `cfprefsd`.
- **Table de correspondance VOLONTAIREMENT plus étroite** que celle de l'app :
  `Notification` → décision, `Stop` → terminé, et RIEN d'autre. Celle de `SoundCenter`
  reconnaît aussi `PermissionRequest` et `SubagentStop` parce qu'elle sert à REPRENDRE
  des hooks ; ici on JOUE — les accepter ferait sonner deux fois la même demande et
  tinter chaque sous-agent. Ce sont exactement les deux événements sur lesquels Mehdi
  avait posé ses `afplay`.
- **`POSIX_SPAWN_SETSID` + les trois descripteurs sur `/dev/null`** : sans session
  propre, `afplay` reste dans le groupe de processus du hook et peut être emporté ;
  et **stdout est le canal de réponse d'un hook** — un octet de trop et le CLI lit une
  réponse invalide. Anti-rafale par mtime d'un témoin dans `~/.atoll/run/` (le helper est
  un processus neuf à chaque hook, il n'a aucune mémoire).
- MESURÉ : app fermée → `afplay -v 0.100 …/finish.mp3` lancé ; app ouverte → helper
  muet ; stdout et stderr du hook **vides** ; latence **11 ms avec son contre 12 ms
  sans** ; trois `Stop` d'affilée → **un seul** son.

**v0.16.0 — QUATRE LOTS : la mémoire répond, et Atoll rend ce qui n'est pas à lui**
(2026-08-03, cadre : `docs/VISION-2026-08.md` — Atoll SAIT, se SOUVIENT, APPELLE).

- **LA MÉMOIRE RÉPOND ENFIN.** L'index contenait **8 135 messages « drone »** et
  `recall "drone Houdini trajectoire"` rendait « Aucun résultat » : en `MatchMode.all`
  les trois mots doivent tenir dans le MÊME fragment (404 caractères en moyenne). Le
  défaut n'était pas dans `MemoryIndex` mais dans son APPEL — `Bridge/Recall.swift` ne
  passait aucun mode. Le commentaire de `MatchMode` le savait déjà (« avec plusieurs
  mots, le AND ne trouve JAMAIS rien ») : la leçon n'avait été appliquée qu'au recall
  PROACTIF. `searchRelaxing` : strict d'abord, élargi SEULEMENT sur zéro — jamais sur
  « peu de résultats », qui diluerait les recherches précises qui marchent.
  CONTREPARTIE : un OR de mots fréquents apparie jusqu'à 22 366 messages (64 % de la
  base), donc la recherche ne rend presque plus jamais « rien ». D'où **trois ceintures
  non optionnelles** : bandeau « RECHERCHE ÉLARGIE », champ `relaxed` sur chaque objet
  JSON (par objet, pour ne casser aucun consommateur du tableau), et tri par COUVERTURE
  (`MemoryRanking.byCoverage`, qui compte les termes réellement marqués « … » par FTS5).
  Plus une section du SKILL.md qui apprend au modèle à ne jamais tirer un « on avait
  décidé X » d'une recherche élargie.
- **LA MÉMOIRE CESSE D'AVALER LE BRUIT.** 134 enveloppes `<task-notification>` étaient
  indexées comme messages `user` — **17 % de tout le corpus `user`**, or `user` ne pèse
  que 792 messages sur 34 785 (contre 12 990 `tool`). Discriminant STRUCTUREL :
  `origin.kind == "task-notification"`, vérifié **127/127 sur douze versions du CLI**.
  Écartés : `promptSource == "system"` (129 lignes, dont **2 vraies instructions**) et
  tout filtre textuel (une conversation qui PARLE de ces balises en serait victime).
  Il faut LES DEUX BOUTS : le filtre d'ingestion n'est pas rétroactif (`openFile` ne
  recule l'offset que sur inode/troncature), d'où `runHygieneIfNeeded`.
  **PIÈGE ÉVITÉ** : la purge ne passe PAS par `schemaVersion` — toute valeur inattendue
  de `user_version` fait passer `migrateIfNeeded` par `recreateFromScratch`, qui
  SUPPRIME la base, et **548 messages appartiennent à cinq transcripts disparus du
  disque**. Le compteur vit dans `PRAGMA application_id`. Et `ProactiveRecall` refuse
  désormais un prompt qui EST lui-même une enveloppe machine (la boucle se refermait :
  15 des 84 injections observées répondaient à une notification par des notifications).
- **LE NIVEAU « AUTO » EST RETIRÉ.** `claude auto-mode` est first-party, actif par
  défaut, 35,5 Ko de politique `allow`/`soft_deny`/`hard_deny`. Notre allowlist avait
  été corrigée DEUX fois pour des contournements. `AutonomyLevel.resolve` normalise le
  décodage (recopié à cinq endroits sans un test) et tout inconnu — « auto » compris —
  retombe sur `.manual`, le plus PRUDENT : un réglage orphelin ne promeut personne en
  Rockstar. **ORDRE IMPÉRATIF, et il a payé** : `ShellSplitter` est partagé avec
  `SoundHookEditor` et n'avait AUCUN test propre — les 22 tests de la politique étaient
  sa seule couverture. `ShellSplitterTests`, écrit AVANT la suppression, a trouvé
  aussitôt un vrai défaut : **`\r\n` est UN SEUL Character en Swift**, le `switch` ne
  testait que `\n` et `\r`, donc une commande à fins de ligne Windows n'était pas
  découpée.
- **LE COCKPIT EST RETIRÉ** (fenêtre ⌘N, Phase 9). Jamais utilisé —
  `launched-tasks.json` = `{"tasks":[]}` (le fichier SUBSISTE sur la machine de Mehdi,
  vide, plus lu ni écrit par personne — inoffensif, à balayer si on repasse par là)
  — et `FleetLauncher` lançait `claude --bg`
  **sans `-w/--worktree`** alors que le drapeau existe : une tâche écrivait dans l'arbre
  de travail de Mehdi pendant qu'il éditait, en Rockstar. **LE PIÈGE** :
  `SessionStore` joue le son de fin dans le MÊME bloc `if event.kind == .stop` que
  l'appel au notifier — retirer le bloc recassait la v0.15.1. La ligne du son porte
  désormais un avertissement. NE SE SUPPRIMENT PAS : `FleetLauncher` (bouton ARRÊTER)
  et `FleetLaunch.shellQuote` (bilan, plugins, curation). `TaskCompletion` est
  CONSERVÉ et documenté comme échafaudage : `inputCap` est vivant (`HookEvent`) et
  `plainText` est la brique du rapport de retour prévu au moyen terme.

**REVUE ADVERSARIALE DU DIFF COMPLET** (5 lentilles, puis un réfutateur par défaut
allégué — 35 agents) : **30 allégués → 6 confirmés**, 24 réfutés. La consigne « en
cas de doute, RÉFUTE » est ce qui rend le chiffre exploitable ; sans elle on corrige
du bruit. Deux enseignements, plus utiles que les correctifs eux-mêmes :

- **RETIRER DU CODE FAIT MONTER LA SURFACE DE DOCUMENTATION FAUSSE.** 5 des 6
  confirmés étaient documentaires — le README PUBLIC vendait encore le cockpit ⌘N et
  la notification de fin de tâche AU PRÉSENT, et la liste de triggers debug de ce
  fichier se disait « exhaustive » en omettant `retroBig`, `plugins` et
  `pluginSearch`. La passe docs fait partie du retrait, pas d'après. Corollaire de
  méthode : **confronter les listes au code par script**, ne pas les relire — c'est
  ce qui a trouvé les trois triggers manquants et un compte de tests annoncé à deux
  valeurs différentes (492 et 653) pour 644 réels.
- **LE BOUTON ARRÊTER ÉTAIT MORT DEPUIS LA PHASE 9** — voir le fait dédié plus haut
  (« UN IDENTIFIANT DE SESSION N'EST PAS UN IDENTIFIANT DE JOB »). La phrase
  ci-dessus, « NE SE SUPPRIMENT PAS : `FleetLauncher` (bouton ARRÊTER) », a été
  écrite en croyant ce bouton fonctionnel : la justification d'un module reposait sur
  un chemin qui n'avait jamais rendu EXIT=0. **Garder du code parce qu'« il sert »
  demande de vérifier qu'il sert vraiment**, surtout quand on est en train
  d'élaguer — c'est le moment où l'on est le moins enclin à le faire.

**Phase 13 — « Rendre la main » (v0.13.0, 2026-07-27)** — Atoll savait démarrer et
surveiller ; il apprend à rendre la main. Plan : `docs/ROADMAP-13-rendre-la-main.md`.
- ⛔️ **FIN DE TÂCHE ANNONCÉE — RETIRÉE le 2026-08-03** avec le cockpit
  (`LaunchedTask`, `TaskCompletionNotifier`, `FleetLauncherWindow` supprimés ; plus
  aucune ligne du dépôt n'importe `UserNotifications`). Sa SEULE source était la
  fenêtre ⌘N, qui n'a jamais lancé une tâche : l'annonce n'a donc **jamais sonné une
  seule fois**. `TaskCompletion` est conservé et documenté comme échafaudage
  (`inputCap` est vivant, `plainText` est la brique du rapport de retour prévu).
  CE QUI RESTE VRAI, et qu'il faudra rappeler si le rapport de retour rouvre le
  sujet : le signal préféré est le hook `Stop`, qui porte `last_assistant_message`
  (décodé dans `ParsedHookEvent`, tronqué à 20 000 caractères) ; ne PAS se fier à
  `AgentSessionInfo.Kind.background` (une session interactive a déjà été rapportée
  `background`) ; `UNUserNotificationCenter.delegate` est une référence FAIBLE, le
  délégué doit être retenu sinon les clics ne font rien.
- **UN IDENTIFIANT DE SESSION N'EST PAS UN IDENTIFIANT DE JOB.** Le fait était écrit
  ici depuis la Phase 13 — « `claude --bg` peut n'imprimer qu'un PRÉFIXE (8 hex)
  alors que les hooks portent l'UUID complet » — mais n'avait été appliqué qu'à la
  comparaison des notifications. Il vaut AUSSI pour `claude stop`, et le bouton
  ARRÊTER en est mort sans bruit de la Phase 9 au 2026-08-03 : la commande liste
  `~/.claude/jobs/`, ne garde que les entrées `^[a-f0-9]{8}$`, puis retient celles
  dont le nom COMMENCE par l'argument — un dossier de 8 caractères ne peut jamais
  commencer par une chaîne de 36. MESURÉ sur le job mort `1b6e885d` : préfixe →
  « stopped 1b6e885d », EXIT=0 ; UUID complet → « No job matching '…' », EXIT=1.
  D'où `FleetLaunch.jobIdentifier` (AtollCore, testé), et `FleetLauncher.stop` qui
  REMONTE désormais le stderr de la CLI au lieu d'inventer une cause.
- **FAIT VÉRIFIÉ (macOS 26)** : `UNUserNotificationCenter` REFUSE l'enregistrement
  d'un build signé « adhoc » (« Notifications are not allowed for this application ») —
  donc AUCUNE notification depuis la boucle de dev Debug. C'est l'appel à
  `requestAuthorization` qui INSCRIT l'app (sans lui, Atoll n'apparaît même pas dans
  Réglages système › Notifications et le statut lu est `denied`). D'où la demande au
  démarrage quand la fonction est active, et l'état affiché dans Réglages › Alertes
  avec la raison exacte. AUTRE PIÈGE VÉCU : `ditto` FUSIONNE — recopier un build
  Release par-dessus un Debug laisse `Atoll.debug.dylib` dans le bundle et casse le
  sceau (`spctl` : « a sealed resource is missing or invalid »). Déplacer l'ancien
  bundle AVANT de ditto.
- **SONS** (`AtollCore/SoundPreferences`, `SoundHookEditor`, `App/SoundCenter`,
  `App/SoundSettingsView`) : deux événements — `decisionNeeded` (une carte apparaît,
  après les chemins d'auto-approbation : en Auto/Rockstar, ce qui est tranché sans toi
  ne sonne pas) et `taskCompleted` (hook `Stop`). Choix par événement : silencieux ·
  14 sons macOS · fichier importé (COPIÉ dans `~/.atoll/sounds`, donc insensible au
  déplacement de l'original), volume séparé (défaut 0,10 = le `afplay -v 0.1` de
  Mehdi), anti-rafale 2 s. Réglage général OFF par défaut.
  MIGRATION = EXCEPTION ENCADRÉE à la règle n° 2 (même régime que le parking
  Rockstar) : les hooks sonores de l'utilisateur sont MONTRÉS avant toute action,
  leurs fichiers audio repris, puis les entrées parquées dans
  `~/.atoll/parked-sound-hooks.json` (écrit AVANT settings.json, crash-safe) et
  restituées à la désactivation, à la désinstallation (`HookInstaller.uninstall`) et
  par réconciliation au lancement. Détection VOLONTAIREMENT conservatrice (`afplay`,
  `/System/Library/Sounds`, `say`, `beep`, extensions audio ; jamais un hook Atoll) —
  un faux positif retirerait un hook qui fait autre chose. VÉRIFIÉ EN VRAI sur la
  config de Mehdi : 2 hooks retirés (21 → 19), statusLine et 15 événements préservés,
  puis restitution **JSON-identique** à la sauvegarde.
- **FLOTTE PAR ÉTAT** (`AtollCore/SessionGrouping`) : bascule `[ PROJET ] / [ ÉTAT ]`
  dans l'îlot, ordre imposé à examiner → en attente de toi → en cours → terminées.
  BORNÉ à 4 lignes (`ExpandedView.stateRowBudget`) : le panneau a une hauteur FIXE et
  la vue dépliée poussait le quota hors du cadre (vu en capture) ; le surplus est
  ANNONCÉ (« +N autres »), jamais tronqué en silence.
- Nouveaux triggers debug (`#if DEBUG`, ils écrivent) : `adoptSounds`, `restoreSounds`,
  `playSounds`, `taskDone`.
- PIÈGE UI : la barre d'onglets des Réglages débordait à 7 onglets (macOS repliait
  « Mises à jour » et « À propos » derrière un chevron) → largeur portée à 640.

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

**⛔️ Phase 9 — « Cockpit ambiant » (v0.9.0, 2026-07-24) — RETIRÉE le 2026-08-03.**
Ce qui SUBSISTE : le bouton ARRÊTER de `SessionDetailView`, `FleetLauncher.stop`
et `FleetLaunch.shellQuote`/`jobIdentifier`. Tout le reste décrit ci-dessous
(`FleetLauncherWindow`, `launch`, `parseSessionID`, `isValidTask`, l'item de menu
⌘N) N'EXISTE PLUS — conservé comme historique de décision, pas comme description
de l'état du code :
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
  `retroBig` (rétrospective sur le PLUS GROS transcript du projet, sans passer par
  le gate — ~0,87 $ le run ; c'est LUI qui a prouvé la boucle d'apprentissage),
  `curation` (curation des notes),
  `plugins` (inventaire réel via `claude plugin list --json`, catégorie de log
  `plugins`) / `pluginSearch` (recherche d'un plugin — consomme du quota),
  `seedSkill` / `skillReview` / `approveSkill` / `rejectSkill` (curation des skills),
  `seedPlugins` (inventaire de plugins factice, pour travailler l'UI sans réseau),
  `adoptSounds` / `restoreSounds` (reprise et restitution des hooks sonores —
  ÉCRIVENT dans settings.json), `playSounds` (écoute des deux sons),
  (`launcher` et `taskDone` retirés avec le cockpit, 2026-08-03).

Debug des interactions (Phase 3) : `notifyutil -p dev.mehdiguiard.atoll.debug.allow`
(ou `.deny`) résout la première carte en attente via les mêmes chemins que les boutons ;
`state.json` liste `pendingInteractions`. Tester le vrai helper :
`echo '{"hook_event_name":"PermissionRequest","session_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}' | ~/.atoll/bin/atoll-bridge` bloque jusqu'à la décision (stdout = JSON de décision, vide = rendu au terminal).
Le hook PermissionRequest est BLOQUANT (async:false, timeout 86400) — tout le reste est async.
