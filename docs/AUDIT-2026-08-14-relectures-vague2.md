# Campagne de relecture du 2026-08-14 — vague 2

Les **60 fichiers restants**, soit **8 404 lignes** : tout ce que la carte
signalait encore comme jamais lu ligne à ligne. Neuf lots par sous-système.
**41 constats : 12 sérieux, 29 mineurs.**

Avec la vague 1, **le dépôt entier a désormais été relu au moins une fois en
adversaire** — 92 fichiers, 23 800 lignes. La carte passe de 53 % de code jamais
lu à 0 %.

## Corrigé dans la foulée

- **LE TITRE IA N'ÉTAIT JAMAIS TROUVÉ.** `TranscriptTailer.extractTitle` lisait
  le champ `title` ; le CLI écrit `aiTitle`. MESURÉ sur quatre transcripts réels :
  **571 lignes `ai-title`, dont 0 portant `title` et 571 portant `aiTitle`**. La
  branche était donc morte et TOUTE session retombait sur son premier prompt
  brut — ce que l'état de l'app confirme (des titres comme « Fais un audit
  complet du projet. Regarde s'il n'y a pas… »). Le parseur, lui, lisait les deux
  graphies « défensif » depuis toujours : le savoir était dans le code, pas dans
  cet appel. Encore le motif du dépôt.
- **Le repli de titre n'appliquait aucun filtre du parseur** : une session ouverte
  par une slash-command s'intitulait `<command-name>/gsd:next</command-name>…`, et
  une enveloppe machine pouvait devenir un titre. Les deux écarts sont repris —
  et `isMachineOrigin` est devenue publique plutôt que recopiée, parce que deux
  implémentations du même filtre finissent par diverger, ce qui venait
  précisément d'arriver au champ du titre.
- **Deux sessions du même projet étaient prises pour deux projets homonymes.**
  `ProjectNaming` comptait des OCCURRENCES là où il fallait des chemins DISTINCTS,
  et `SessionStore` lui passe une entrée par session : ouvrir une seconde session
  dans un dossier suffisait à allonger son nom en « Desktop/Dynamic_Island ». Cas
  ordinaire chez Mehdi. Reproduit, corrigé, 2 assertions échouent sans le
  correctif.

## Examiné et NON retenu

- **`ExpandedView:105` — « CLAUDE.md annonce 70, le code dit 68 ».** Réfuté :
  CLAUDE.md dit bien 68 (ligne 410) et le code aussi. L'agent a lu la note
  *historique* du rapport du 12 août, qui consignait une dérive DEPUIS corrigée.
- **`IslandSettings:35` — le réglage par écran « fuit » entre deux moniteurs
  identiques.** Réel, mais seulement sur le chemin de REPLI (quand la lecture de
  l'UUID d'affichage échoue), et le corriger en ajoutant le cadre ou le numéro
  d'écran ferait perdre le réglage à chaque déplacement de moniteur. Aucune mesure
  ne montre que ce repli se déclenche. Documenté, pas changé.
- **`NotchViewModel:172` — un clic referme l'îlot alors qu'une carte attend.**
  Comportement connu et documenté dans CLAUDE.md ; l'îlot compact garde son
  glyphe d'alerte et le son a déjà retenti. Rendre l'îlot non refermable
  pendant une carte le ferait camper par-dessus le travail de l'utilisateur —
  arbitrage, pas défaut.

## Tous les constats


### [serious] Le SEUL chemin de réconciliation du recall proactif jette le message d'erreur que la fonction est écrite pour rendre
**/Users/mehdiguiard/Desktop/Dynamic_Island/App/AppDelegate.swift:41**

`syncProactiveRecall()` est documentée « Renvoie un message d'erreur à afficher, nil si tout est en ordre » et porte `@discardableResult`. Ses trois appelants d'interface affichent bien ce message (SettingsView.swift:547, 560, 573, 596 → `proactiveRecallError = …`). Le quatrième appelant — celui du LANCEMENT, c'est-à-dire précisément la réconciliation « après un crash ou une édition manuelle » que sa propre documentation invoque — le laisse tomber au sol : pas d'affectation, pas de `log.error`, aucune trace. Motif « correctif appliqué à une PARTIE de ses points d'application » : 3 des 4 appelants sur 4.

<details><summary>Preuve</summary>

```
App/LearningSettings.swift:138-140 → `/// Renvoie un message d'erreur à afficher, nil si tout est en ordre.` puis `@discardableResult func syncProactiveRecall() -> String?` ; les deux sorties d'erreur, ligne 155 `return "Réglage du recall proactif non enregistré : \(error.localizedDescription)"` et ligne 169 `return "Hooks non mis à jour pour le recall proactif : \(error.localizedDescription)"`. App/AppDelegate.swift:41 → `LearningSettings.shared.syncProactiveRecall()` seul sur sa ligne, valeur ignorée, aucun log alentour (lignes 33-49 lues). À comparer avec App/SettingsView.swift:547 → `proactiveRecallError = LearningSettings.shared.syncProactiveRecall()`.
```

**Repro** : Chemin le plus net : le recall proactif est ACTIF, `~/.claude/settings.json` est momentanément non inscriptible (verrou d'un autre écrivain, permissions, disque plein). Au lancement, `try HookInstaller.install()` (LearningSettings.swift:166) lève, la fonction rend « Hooks non mis à jour… », AppDelegate le jette. `~/.atoll/proactive-recall.json` a pourtant été réécrit avec `enabled: true` (ligne 153, avant le guard), donc le helper cherche et répond — mais le hook UserPromptSubmit est resté `async`, et un hook async est fire-and-forget : sa sortie n'est JAMAIS lue (fait déjà documenté en Phase 11). Le recall est mort silencieusement, l'îlot et les Réglages continuent d'afficher « activé », et rien dans `log stream` ne le dit. Symétrique à la bascule inverse : le hook peut rester BLOQUANT (timeout 5 s) alors que le réglage est passé à OFF.

**Piste** : Au lancement, ne pas jeter : `if let message = LearningSettings.shared.syncProactiveRecall() { log.error("recall proactif : \(message, privacy: .public)") }`, et/ou stocker le message pour que Réglages › Apprentissage l'affiche à l'ouverture. Aucun changement de comportement du recall (gel du 2026-09-09 respecté) : on ne fait que cesser d'avaler l'erreur.
</details>

### [serious] Le réglage « par écran » fuit d'un écran à l'autre : la clé displayUUIDString n'est PAS unique, et le dépôt le sait déjà ailleurs
**App/IslandSettings.swift:35**

La largeur compacte est indexée par `screen.displayUUIDString`. Or ce même identifiant est documenté DANS LE DÉPÔT comme non unique — App/AppDelegate.swift:443-445 : « Un tableau (pas un dictionnaire) : deux écrans identiques peuvent partager le même UUID CGDisplay » — et il retombe en plus sur `localizedName` quand CGDisplayCreateUUIDFromDisplayID rend nil, or deux moniteurs du même modèle portent le MÊME localizedName. Le correctif a donc été appliqué à UN seul des deux consommateurs de cette clé (screenSignature, qui prend soin d'utiliser un tableau) et pas à l'autre (IslandSettings + le ForEach des Réglages). Conséquences : (a) régler « Large » sur un moniteur externe le règle aussi sur son jumeau, alors que SettingsView.swift:101 promet « Réglable INDÉPENDAMMENT par écran » ; (b) `ForEach(screens)` sur un `ScreenChoice: Identifiable` dont l'`id` est cet UUID reçoit deux identifiants identiques — comportement indéfini de SwiftUI (avertissement « ID occurs multiple times », une des deux rangées disparaît), donc un des deux écrans n'a plus de ligne de réglage du tout.

<details><summary>Preuve</summary>

```
App/IslandSettings.swift:33-36 → `func setWidth(_ width: IslandWidth, for displayID: String) { widths[displayID] = width; UserDefaults.standard.set(width.rawValue, forKey: Self.widthKeyPrefix + displayID) }`
App/NSScreen+Notch.swift:24-31 → `var displayUUIDString: String { guard let number = …, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return localizedName } … }`
App/AppDelegate.swift:443-445 → `/// Empreinte de la configuration d'écrans. Un tableau (pas un dictionnaire) :\n/// deux écrans identiques peuvent partager le même UUID CGDisplay.`
App/SettingsView.swift:97-100 → `private struct ScreenChoice: Identifiable { let id: String       // displayUUIDString`
App/SettingsView.swift:105-107 → `ForEach(screens) { screen in Picker(screen.label, selection: widthBinding(for: screen.id))`
App/SettingsView.swift:189 → `return ScreenChoice(id: screen.displayUUIDString, label: label)`
App/NotchViewModel.swift:53,58 → `var compactWidth: IslandWidth { IslandSettings.shared.width(for: displayID) }` / `displayID = screen.displayUUIDString`
```

**Repro** : Brancher deux moniteurs identiques (même modèle, EDID sans numéro de série distinct — le cas que le commentaire d'AppDelegate décrit), ou tout écran pour lequel CGDisplayCreateUUIDFromDisplayID rend nil. Ouvrir Réglages › Général › « Taille de l'îlot » : la section n'affiche qu'UNE rangée pour deux écrans, et la changer élargit les deux îlots. Vérifiable sans matériel en instrumentant NSScreen.displayUUIDString pour qu'il rende `localizedName` : deux écrans du même modèle produisent alors la même clé.

**Piste** : Désambiguïser la clé au point de fabrication : concaténer le NSScreenNumber (ou l'index de NSScreen.screens trié) à l'UUID — `"\(uuidOrName)#\(number.uint32Value)"` — ou, a minima, dans refreshScreens(), suffixer les identifiants en collision (`id + "#\(index)"`) et faire porter la même clé à NotchViewModel.displayID pour que Réglages et îlot restent d'accord. Les clés déjà écrites dans UserDefaults changent de nom : accepter le retour au défaut « moyen » plutôt que tenter une migration.
</details>

### [serious] /usr/bin/security lu sans borne de temps dans une continuation non annulable : un dialogue Trousseau sans réponse gèle le poller définitivement
**App/ModelQuotaPoller.swift:102**

readAccessToken lance /usr/bin/security find-generic-password -w puis bloque sur readDataToEndOfFile() sans watchdog ni terminate(). Or ce verbe déclenche le dialogue d'autorisation du Trousseau (c'est précisément ce que documente le commentaire des l. 83-86 : on passe par /usr/bin/security pour avoir une identité STABLE, donc une autorisation demandée à l'utilisateur). Tant que ce dialogue n'est pas répondu, security ne sort pas, la continuation n'est jamais reprise, et comme withCheckedContinuation n'est pas annulable, task?.cancel() ne la débloque pas : la boucle de poll ne fait plus jamais un seul tour.

<details><summary>Preuve</summary>

```
l. 96-103 : do { try process.run() } catch { continuation.resume(returning: nil); return } ; let data = output.fileHandleForReading.readDataToEndOfFile() ; process.waitUntilExit() — aucun timeout, aucun terminate. l. 45-50 : task = Task { while !Task.isCancelled { await self?.fetchOnce(); try? await Task.sleep(for: .seconds(120)) } } — fetchOnce await readAccessToken() en première instruction (l. 54). l. 38-39 : task?.cancel(); task = nil. À comparer avec FleetPoller, qui porte un watchdog 5 s pour exactement cette raison (« agents --json SANS timeout gèle la boucle de poll »).
```

**Repro** : Activer les jauges par modèle (SettingsView l. 607 → syncWithSettings). Au premier tick, macOS affiche « security veut utiliser vos informations confidentielles stockées dans Claude Code-credentials ». L'app est LSUIElement : le dialogue peut passer inaperçu. Sans réponse : plus aucun fetch, displayedLimits rend [] au bout de 10 min (l. 27-30) et les jauges disparaissent définitivement de l'îlot (App/ExpandedView.swift:357) jusqu'au redémarrage de l'app. Décocher puis recocher le réglage n'y change rien et empile : la Task précédente reste suspendue sur la continuation, un thread de la queue globale reste bloqué et un process security de plus reste vivant.

**Piste** : Même patron que FleetPoller : DispatchQueue.global().asyncAfter(deadline: .now() + N) { if process.isRunning { process.terminate() } }, et resume(returning: nil) une seule fois via un drapeau, pour que la continuation soit TOUJOURS reprise.
</details>

### [serious] Un clic sur le panneau referme l'îlot alors qu'une carte de permission attend une décision — et le moniteur local exempte pourtant explicitement le panneau
**App/NotchViewModel.swift:172**

Quand une carte arrive, `syncInteractionState` pose `isPinned = true` puis `open()`. À partir de cet instant, la PREMIÈRE tape sur une zone morte du panneau (l'en-tête, la règle ASCII, un Spacer, le texte du plan) atteint le `.onTapGesture` de `NotchRootView` et tombe dans la branche `state == .expanded, isPinned` de `togglePinned()`, qui appelle `close()`. La carte disparaît de l'écran, `onChange(of: viewModel.state)` rend le focus clavier (`onKeyFocusRequest?(… && newState == .expanded && …)` = false), et `previousApp` est remis à nil — pendant que le helper `atoll-bridge` bloque toujours le CLI en attendant la décision. L'utilisateur doit redécouvrir l'îlot au survol pour reprendre la main. Il n'existe AUCUN garde-fou lié à une carte en attente dans `togglePinned()`, alors que `syncInteractionState` en a un (`wasUserPinnedBeforeCard`) pour le cas symétrique. L'incohérence est nette : `NotchWindowController` prend soin d'exclure les clics sur le panneau (`if event.window !== panel`), donc l'intention de conception est bien « un clic SUR le panneau ne le referme pas » — le tap gesture la contredit.

<details><summary>Preuve</summary>

```
NotchViewModel.swift:171-179 — `/// Clic sur l'îlot : épingle l'état étendu (ne se referme plus au départ de la souris).` puis `func togglePinned() { if state == .expanded, isPinned { close() } else { isPinned = true; open() } }`. NotchViewModel.swift:72-76 — `if pendingCount > 0, previousCount == 0 { wasUserPinnedBeforeCard = isPinned; isPinned = true; open(); onKeyFocusRequest?(true) }`. NotchRootView.swift:312-314 — `.onTapGesture { viewModel.togglePinned() }` posé sur la ZStack de l'îlot, après `.contentShape(shape)`. NotchWindowController.swift:62 — `if event.window !== panel { viewModel.close() }`.
```

**Repro** : Faire arriver une carte (`notifyutil -p dev.mehdiguiard.atoll.debug.allow` n'est pas suffisant, il faut une vraie carte ou un `echo '{"hook_event_name":"PermissionRequest",…}' | ~/.atoll/bin/atoll-bridge`), attendre que l'îlot s'ouvre seul, puis cliquer sur le texte d'en-tête de la carte (hors des boutons `[ DENY ⌘N ]` / `[ ALLOW ⌘Y ]`) : l'îlot se replie, la demande reste en attente et le helper reste bloqué.

**Piste** : Faire porter au view model le fait qu'une carte tient l'îlot ouvert : dans `syncInteractionState`, poser un `private var isHeldByCard` (true en 0→N, false en N→0), et le tester dans `togglePinned()` — `if state == .expanded, isPinned, !isHeldByCard { close() }`. Ne PAS interroger `InteractionCenter.shared` depuis le view model : `syncInteractionState` reçoit déjà le compte en argument, c'est ce chemin-là qui doit rester l'unique source.
</details>

### [serious] Le repli « activation sans permission » n'a été posé que sur UNE des deux sorties -1743
**App/TerminalJumpService.swift:127**

Le correctif de l'audit du 2026-07-27 (« le repli activate ne demande AUCUNE permission : la fenêtre doit remonter même sans autorisation ») a été appliqué au préflight (.denied, l. 113) mais PAS au chemin symétrique où c'est l'exécution de l'AppleScript qui rend -1743 (l. 127) : là, la fonction retourne .needsAutomationPermission sans jamais appeler activateBundle. Motif « correctif appliqué à une partie de ses points d'application ».

<details><summary>Preuve</summary>

```
l. 106-117 : case .denied: activateBundle(bundleID); return .needsAutomationPermission(appName: appName) — précédé du commentaire « Le repli activate ne demande AUCUNE permission … le bouton principal du détail de session ne produisait donc rien d'autre qu'un avertissement (audit du 2026-07-27) ». l. 124-128 : if let errorInfo { let code = …; if code == -1743 { return .needsAutomationPermission(appName: appName) } ; return activateApp(bundleID: bundleID, kind: kind) } — aucun activateBundle avant le return -1743, alors que toutes les AUTRES erreurs (l. 128) passent bien par activateApp.
```

**Repro** : Session hébergée par Terminal.app ou iTerm2. AutomationPermission.check rend .undetermined (App/AutomationPermission.swift l. 34-37 : errAEEventWouldRequireUserConsent, ou le default de la l. 36 sur tout OSStatus non prévu — cas atteignable quand le prompt TCC ne peut pas être affiché, l'app étant LSUIElement). On tombe donc dans « case .granted, .undetermined: break » (l. 115) et le script s'exécute ; le CLI/TCC répond -1743. Résultat : l'îlot affiche « autorisation requise » et AUCUNE fenêtre ne remonte, alors que NSRunningApplication.activate() aurait fonctionné sans aucune permission — exactement le symptôme que l'audit du 2026-07-27 dit avoir corrigé.

**Piste** : À la l. 127, appeler activateBundle(bundleID) avant de retourner .needsAutomationPermission, comme à la l. 113.
</details>

### [serious] extractTitle lit le champ `title` alors que le CLI écrit `aiTitle` — le titre de session IA n'est jamais trouvé ✅ CORRIGÉ
**App/TranscriptTailer.swift:144**

Le correctif « les deux graphies observées selon les versions du CLI » a été appliqué au parseur MAIS PAS au tailer : `extractTitle` ne lit que `line["title"]`, or les lignes `ai-title` du CLI actuel portent `aiTitle`. La branche est donc morte et TOUTE session retombe sur le repli « premier prompt utilisateur brut » (motif « 3 des 5 écrivains »).

<details><summary>Preuve</summary>

```
App/TranscriptTailer.swift:144 → `if aiTitle == nil, type == "ai-title", let title = line["title"] as? String, !title.isEmpty {` — contre AtollCore/Sources/AtollCore/TranscriptLineParser.swift:60 : `fragments = singleFragment(.title, (line["aiTitle"] as? String) ?? (line["title"] as? String))` avec le commentaire l.59 « Les deux graphies observées selon les versions du CLI — défensif ».
```

**Repro** : Sur 6 transcripts réels (~/.claude/projects, find -size +200k | head -6) : 1 639 lignes `"type":"ai-title"` au total, dont **0** contiennent `"title"` et **1 639** contiennent `"aiTitle"` (99/0, 20/0, 450/0, 634/0, 68/0, 368/0). `grep '"type":"ai-title"' f.jsonl | grep -c '"title"'` → 0.

**Piste** : Aligner sur le parseur : `let title = (line["aiTitle"] as? String) ?? (line["title"] as? String)`. Mieux : faire passer extractTitle par `TranscriptLineParser.parse` et lire le fragment `.title`, pour qu'il n'existe qu'UN lecteur de ce format.
</details>

### [serious] Le repli de titre n'applique aucun des filtres du parseur : une session ouverte par une slash-command est titrée avec l'enveloppe XML ✅ CORRIGÉ
**App/TranscriptTailer.swift:164**

`extractTitle` ne filtre que `isMeta`. Il ignore les deux autres gardes que le parseur juge indispensables sur exactement le même texte : l'écho de slash-command (`<command-…>`) et l'origine machine (`origin.kind == "task-notification"`). Et il n'applique aucun cap de longueur. Comme le chemin `ai-title` est mort (constat précédent), ce repli est utilisé pour TOUTES les sessions.

<details><summary>Preuve</summary>

```
App/TranscriptTailer.swift:147-156 : `if firstUserText == nil, type == "user", (line["isMeta"] as? Bool) != true, let message = …` puis l.164 `} else if let firstUserText, !firstUserText.isEmpty { onTitle?(sessionID, firstUserText) }` — aucun test de préfixe, aucun test d'`origin`, aucun `prefix(n)`. Contre AtollCore/Sources/AtollCore/TranscriptLineParser.swift:146 : `if text.hasPrefix("<command-") || text.hasPrefix("<local-command-") { return nil }` et l.92 `if isMachineOrigin(line["origin"]) { return [] }`.
```

**Repro** : Sur données réelles : les lignes contenant `<command-name>` sont bien `"type":"user"` et ne portent AUCUN champ `isMeta` (mesuré 0 ligne avec `"isMeta":true` sur 1, 1 et 3 occurrences dans trois transcripts ; `cut -c1-160` montre `…,"type":"user","message":{"role":"user…`). Une session dont le premier message est `/gsd:next` reçoit donc comme titre `<command-name>/gsd:next</command-name><command-message>…`.

**Piste** : Réutiliser `TranscriptLineParser.parse` (le fragment `.user` est déjà filtré et trimé) et borner le titre (ex. `prefix(120)`) avant `onTitle`.
</details>

### [serious] `coverage` ne compte PAS les termes marqués par FTS5 — c'est une recherche de sous-chaîne sur tout le snippet, et c'est le chiffre qui doit trancher le 2026-09-09
**AtollCore/Sources/AtollCore/MemoryRanking.swift:145**

Le commentaire de la fonction (l.133-136) affirme : « On compte dans le SNIPPET, où FTS5 encadre chaque terme trouvé de «…» — c'est donc la liste des mots qui ont RÉELLEMENT matché, pas une approximation textuelle. » Le corps de la fonction ne regarde JAMAIS les marqueurs « et » : il teste l'appartenance du terme au snippet entier, marqueurs et contexte non marqué compris. C'est exactement l'« approximation textuelle » que le commentaire déclare éviter — et l'invariant que la fiche de périmètre présentait comme tenu. Conséquence double : (1) `byCoverage` (l.152) peut classer devant un extrait qui n'a apparié qu'UN terme mais dont le contexte contient les autres ; (2) surtout, le champ `coverage` du journal d'instrumentation (Bridge/ProactiveRecallHook.swift:174) est calculé par cette même fonction — la « répartition des couvertures » qui doit décider en septembre si la mémoire proactive survit est donc SUR-ESTIMÉE, et la part des extraits n'appariant qu'un seul mot sous-estimée.

<details><summary>Preuve</summary>

```
l.133-136 : « On compte dans le SNIPPET, où FTS5 encadre chaque terme trouvé de `«…»` — c'est donc la liste des mots qui ont RÉELLEMENT matché, pas une approximation textuelle. »
l.139-146 :
        let folded = hit.snippet.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        var found = 0
        for term in terms where !term.isEmpty {
            let needle = term.folding(...)
            if folded.contains(needle) { found += 1 }
        }
Aucune occurrence de « ou » dans tout le fichier : le marqueur n'est ni cherché ni utilisé.
```

**Repro** : `coverage(of: Hit(snippet: "«houdini» : la trajectoire du drone"), terms: ["houdini", "drone"])` rend 2 alors que FTS5 n'a marqué QUE « houdini » — « drone » vient du contexte non marqué que `snippet()` ajoute autour du terme trouvé, ce qui est la raison d'être d'un snippet. Sur-comptage aussi par sous-chaîne : terms ["js"] compte dans « adjusted ». Aucun test ne sépare les deux comportements : MemoryRelaxedSearchTests.swift:37 passe `hit("les «drone»s en «houdini»")`, un snippet où TOUS les termes présents sont marqués — il rend 2 avec l'une comme avec l'autre implémentation.

**Piste** : NE RIEN CHANGER AU COMPORTEMENT AVANT LE 2026-09-09 (gel du recall) : corriger maintenant l'ordre d'injection invaliderait la moitié de la campagne de mesure. Deux gestes séparés : (a) tout de suite, corriger le commentaire l.133-136 pour qu'il décrive ce que le code fait, et noter dans docs/HANDOFF.md que le `coverage` du journal est un MAJORANT — sinon les trois chiffres du rendez-vous seront lus comme des mesures exactes ; (b) après le rendez-vous, extraire les segments encadrés (`snippet.components(separatedBy: "«")` puis jusqu'au « ») et ne tester l'appartenance que là-dedans, avec un test qui échoue sur l'implémentation actuelle (snippet où un terme n'apparaît QUE hors marqueurs).
</details>

### [serious] Deux sessions du MÊME projet sont prises pour des projets homonymes : le nom s'allonge en « Desktop/Dynamic_Island » ✅ CORRIGÉ
**AtollCore/Sources/AtollCore/ProjectNaming.swift:36**

`displayName` compte les voisins par ÉGALITÉ DE DERNIER COMPOSANT sans dédoublonner les chemins identiques. Or `SessionStore.uiSessions` fournit un chemin PAR SESSION : dès que deux sessions tournent dans le même dossier — le cas documenté « ▸ Dynamic_Island · 2 » —, `duplicated` devient vrai et les deux lignes affichent deux composants au lieu d'un. Le fichier a précisément été écrit pour que la même session ne porte pas deux noms selon le mode d'affichage ; ici l'en-tête de dossier (ExpandedView, qui passe des racines DISTINCTES) dit « Dynamic_Island » pendant que les lignes de session disent « Desktop/Dynamic_Island ». La condition ne devrait se déclencher que pour des projets DIFFÉRENTS de même nom de base (« /a/app » vs « /b/app »).

<details><summary>Preuve</summary>

```
ProjectNaming.swift:36 — `let duplicated = siblings.filter { lastComponent($0) == base }.count > 1` (le doc l.10 dit pourtant « deux PROJETS ouverts en même temps portent le même dernier composant », et le `> 1` n'est là que pour tolérer `path` lui-même, cf. testSelfInSiblingsIsNotADuplicate). Appelant : App/SessionStore.swift:183-184 — `let paths = sorted.map { $0.cwd ?? "claude" }` puis `let names = ProjectNaming.displayNames(for: paths)` : `paths` contient un doublon exact par session supplémentaire du même cwd. Aucun test ne couvre le doublon exact : ProjectNamingTests n'a que des chemins distincts (« /a/app », « /b/app »).
```

**Repro** : ProjectNaming.displayNames(for: ["/Users/m/Desktop/Dynamic_Island", "/Users/m/Desktop/Dynamic_Island"]) rend ["Desktop/Dynamic_Island", "Desktop/Dynamic_Island"] au lieu de ["Dynamic_Island", "Dynamic_Island"]. En vrai : deux sessions Claude ouvertes dans le même dépôt.

**Piste** : Compter sur les chemins DISTINCTS : `let duplicated = Set(siblings).filter { lastComponent($0) == base }.count > 1` (ou `Set(siblings.filter { lastComponent($0) == base }).count > 1`). Ajouter le test manquant : même chemin deux fois → nom court.
</details>

### [serious] Le correctif « un sous-agent ne referme pas la carte » (v0.16.1) n'a été appliqué qu'à la CARTE, pas à la PHASE : l'îlot cesse d'alerter pendant qu'un helper est bloqué
**AtollCore/Sources/AtollCore/SessionPhase.swift:51**

Tout PostToolUse / PostToolUseFailure / SubagentStart / SubagentStop portant le session_id du parent fait passer la phase de `.waitingPermission` à `.busy`, sans regarder l'outil. La carte survit (elle, est protégée), mais la session est projetée en `.working` : `needsAttention` devient false, le glyphe orange de l'îlot compact disparaît, `attentionCount` retombe à 0 et le regroupement par état la range en « EN COURS » au lieu de « À EXAMINER » — alors qu'un helper `atoll-bridge` est toujours bloqué sur la décision. C'est exactement le motif « correctif appliqué à une PARTIE de ses points d'application ».

<details><summary>Preuve</summary>

```
SessionPhase.swift:51-54 —
```swift
case .postToolUse, .postToolUseFailure, .permissionDenied, .subagentStart, .subagentStop:
    // Un événement de complétion tardif (outil asynchrone terminé après
    // Stop) ne doit pas ré-afficher un spinner sans porte de sortie.
    return phase == .waitingInput ? .waitingInput : .busy
```
Le demi-correctif est visible côté carte, App/SessionStore.swift:297-301 :
```swift
case .postToolUse, .postToolUseFailure:
    // Un hook d'OUTIL ne prouve rien tout seul : ceux d'un sous-agent
    // portent le session_id du parent. On ne referme que la carte du
    // même outil — voir `cancelForSession(_:tool:)`.
    InteractionCenter.shared.cancelForSession(event.sessionID, tool: event.toolName)
```
…et la phase, elle, est écrasée juste après, sans filtre, App/SessionStore.swift:323 : `session.phase = SessionReducer.reduce(session.phase, event)`.
La chaîne jusqu'à l'UI : App/SessionStore.swift:191 `status: tracked.phase.uiStatus` → AtollCore/SessionModel.swift:70-75 `needsAttention` (true pour `.awaitingPermission` SEULEMENT) → App/CompactView.swift:39/74/84 et App/NotchViewModel.swift:110 `attentionCount`. Aucun chemin ne reforce la phase : `markAutoApproved` (SessionStore.swift:263-269) ne fait que l'écraser dans l'autre sens, et la garde flotte (S
```

**Repro** : Session parente bloquée sur un PermissionRequest Bash pendant qu'un sous-agent Task lancé plus tôt termine un Read : le hook PostToolUse(tool_name:"Read", session_id: <parent>) arrive → `cancelForSession(_:tool:"Read")` n'annule rien (correct, la carte est Bash) → mais `SessionReducer.reduce(.waitingPermission, postToolUse)` rend `.busy`. Cas encore plus net avec SubagentStop, qui ne porte aucun tool_name : `cancelForSession(_:tool:nil)` sort immédiatement (InteractionCenter.swift:249 `guard let tool, !tool.isEmpty else { return }`) tandis que le reducer, lui, écrase la phase quand même.

**Piste** : Rendre `.waitingPermission` collante pour ces quatre événements, comme la carte : ne quitter la phase que si l'événement concerne le MÊME outil. Le reducer étant pur, comparer sur le nom nu — `if case .waitingPermission(let tool) = phase, let name = event.toolName, tool == nil || tool == name || tool!.hasPrefix(name + "(") { /* la permission a été tranchée ailleurs → .busy */ } else { return phase }` — et faire sortir de la phase par les quatre événements qui prouvent vraiment l'avancée (stop, sessionEnd, permissionDenied, userPromptSubmit), déjà inconditionnels côté carte. Verrouiller par un test qui ÉCHOUE sans le correctif (SubagentStop sur une phase `.waitingPermission`).
</details>

### [serious] Les parts réservées font sacrifier les `.user` avant des `.tool` protégés — le commentaire affirme l'inverse
**AtollCore/Sources/AtollCore/TranscriptDigest.swift:356**

Le commentaire justifie l'absence de réserve pour `.user` par un invariant (« ils sont déjà les derniers sacrifiés ») que la réserve elle-même casse. En passe 0, une entrée d'un rôle réservé encore dans sa part est ÉPARGNÉE (`continue`) ; les `.user`, sans réserve, restent sacrifiables. Dès que les rôles de rang 2 et 4 (assistant, summary) sont épuisés, l'élagage attaque l'INTENTION utilisateur pendant que 40 % du budget (25 % `.tool` + 15 % `.toolResult`) reste sanctuarisé pour des rôles que le fichier lui-même classe moins précieux.

<details><summary>Preuve</summary>

```
TranscriptDigest.swift:189-195 : `if pass == 0, let reserve = protectedBudget[role] { … if kept <= reserve { continue } }` — et `reservedShares` (l.356-359) ne contient que `.tool: 0.25` et `.toolResult: 0.15`, tandis que `sacrificeRank` (l.335-344) donne `.user: 5`, dernier. Le commentaire l.353-355 : « Les `.user` n'ont pas besoin de réserve : ils sont déjà les derniers sacrifiés ». Et l.324-327 : « On n'ampute JAMAIS… on enlève par valeur croissante ».
```

**Repro** : Condition d'atteinte, purement arithmétique : la passe 0 s'arrête d'élaguer quand `estimatedTotal() <= budget` ; il reste au plus 37 500 caractères de `.tool` et 22 500 de `.toolResult` protégés, donc les `.user` commencent à être supprimés dès que la somme de leurs blocs dépasse `budget − 60 000` = 90 000 caractères (soit ~45 prompts au cap de 2 000, ou ~300 prompts de 300 caractères) — un transcript de 45 Mo comme celui qui a motivé la réserve dépasse largement ce seuil.

**Piste** : Soit exclure explicitement les rangs supérieurs à celui du rôle réservé de la passe 0 (ne rendre sacrifiables en passe 0 que les rôles de rang ≤ 4), soit donner aussi une part réservée à `.user`, soit corriger le commentaire pour dire que la réserve INVERSE volontairement la priorité — mais le choix actuel n'est écrit nulle part.
</details>

### [serious] KERN_PROCARGS2 : la taille renvoyée par le SECOND sysctl n'est pas revérifiée, et `4..<Int(size)` piège si elle est < 4
**Shared/ProcessInspector.swift:110**

`environment(of:)` valide `size > 4` sur le premier sysctl (celui qui, pour KERN_PROCARGS2, renvoie le MAXIMUM `arg_max`, pas la taille réelle : ~256 Ko à 1 Mo), puis le second sysctl ÉCRASE `size` avec le nombre d'octets réellement écrits — sans nouvelle vérification. La boucle l.110 construit alors `4..<Int(size)` : si le noyau rend 0 et écrit moins de 4 octets, `Range requires lowerBound <= upperBound` fait TRAPPER le processus. Le code lui-même sait que ce tampon peut faire moins de 4 octets — il s'en protège trois lignes plus haut (`min(4, bytes.count)`) puis l'oublie. L'asymétrie est le défaut : une garde posée à un seul de ses deux points d'application, motif récurrent du dépôt. Le fichier étant dans Shared/, le trap tomberait aussi bien dans l'app (SessionStore.swift:720/930, reconciliation périodique) que dans le helper sur un chemin de hook (fail-open violé : un hook qui trappe ne rend pas exit 0).

<details><summary>Preuve</summary>

```
l.96  guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }   // taille MAX, pas la taille réelle
l.97  var buffer = [CChar](repeating: 0, count: size)
l.98  guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }          // size est RÉÉCRIT ici, plus jamais contrôlé
l.100 let bytes = buffer.prefix(size)
l.103     for i in 0..<min(4, bytes.count) { … }   // ← le code admet ici que bytes.count peut être < 4
l.110 for index in 4..<Int(size) {                 // ← et le nie ici : trap si size < 4
```

**Repro** : Non reproduit sur cette machine (je n'ai lancé aucun code) : dans les cas courants le noyau rend EINVAL plutôt qu'une taille < 4, et le second appel est protégé par `== 0`. La preuve est l'asymétrie interne ci-dessus, pas un plantage observé — le contrat de `sysctl` n'interdit rien de tel, et le coût de la garde est nul. Effet secondaire déjà réel, lui, sans hypothèse : `size > 4` ne valide RIEN d'utile puisqu'il porte sur `arg_max`, valeur constante et toujours grande.

**Piste** : Après le second sysctl : `guard sysctl(...) == 0, size > 4 else { return [:] }` (rejouer la même garde sur la valeur réécrite). Accessoirement, `idx += Int(argc)` l.128 n'est pas borné non plus — un `argc` aberrant ferait sortir `idx` du tableau ; `idx = min(idx + max(Int(argc), 0), tokens.count)` referme les deux bouts.
</details>

### [minor] @Observable sur une classe sans aucune propriété stockée : l'annotation ne peut rien observer
**/Users/mehdiguiard/Desktop/Dynamic_Island/App/LearningSettings.swift:12**

`LearningSettings` est marquée `@Observable`, mais TOUTES ses propriétés d'instance sont calculées et lisent `UserDefaults.standard` à chaque accès ; il n'existe aucune propriété stockée à instrumenter. La macro ne peut donc enregistrer aucune dépendance : une vue SwiftUI qui lirait `LearningSettings.shared.isEnabled` (ou `quotaThreshold`, `model`, `isCurationScheduled`…) dans son `body` ne se redessinerait jamais sur changement. C'est mot pour mot le piège déjà payé et documenté dans CLAUDE.md pour `autonomyLevel` (« calculé depuis UserDefaults, donc invisible à @Observable — sans cela l'îlot ne se redessine pas à la bascule »). Constat LATENT : je n'ai pas trouvé de vue qui en dépende aujourd'hui (les Réglages passent par `@AppStorage` et `modelBinding`), donc rien n'est cassé — mais l'annotation promet une observabilité qu'elle ne peut pas rendre, et le prochain qui s'y fie n'aura aucun message d'erreur.

<details><summary>Preuve</summary>

```
App/LearningSettings.swift:11-13 → `@MainActor` / `@Observable` / `final class LearningSettings {` ; puis, de la ligne 47 à la ligne 114, chaque membre d'instance est un `var` calculé : `var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }` (47-49), `var quotaThreshold` (53-56), `var model` (58-60), `var curationModel` (63-65), `var searchModel` (68-70), `var maxPerWindow` (80-83), `var gateConfig` (86-90), `var isCurationScheduled` (95-97), `var isProactiveRecallEnabled` (99-101), `var proactiveRecallConfig` (105-114). Aucun `let`/`var` stocké d'instance dans tout le fichier.
```

**Repro** : Écrire dans n'importe quelle vue `Text(LearningSettings.shared.isEnabled ? "ON" : "OFF")`, puis basculer le réglage depuis un autre volet : le texte ne change pas tant que la vue n'est pas reconstruite pour une autre raison.

**Piste** : Soit retirer `@Observable` (la classe est un accesseur sans état — l'annotation est trompeuse), soit, si l'on veut vraiment l'observabilité, refléter les réglages dans de vraies propriétés stockées mises à jour dans `syncWithSettings()`. Retirer l'annotation est le geste le moins risqué et cohérent avec « soustraire avant d'ajouter ».
</details>

### [minor] Un commentaire affirme que la mesure du volume exclut le front-matter et les noms de fichiers ; la fonction appelée compte les deux
**/Users/mehdiguiard/Desktop/Dynamic_Island/App/SettingsView.swift:859**

Le commentaire de `refreshNotes()` justifie l'alignement sur le garde-fou en affirmant « l'inventaire ne compte que les CORPS, sans front-matter ni noms de fichiers ». C'est l'inverse de ce que fait `corpusCharacterCount`, qui additionne le contenu ENTIER du fichier (front-matter compris, puisque `readNotes()` rend le fichier brut) ET la longueur du nom. La correction elle-même est bonne (les deux chiffres viennent maintenant de la même fonction et coïncident) ; c'est sa JUSTIFICATION écrite qui est fausse — un commentaire qui affirme une garantie que le code ne tient pas, sur la ligne même qu'un futur intervenant relira avant de toucher au budget.

<details><summary>Preuve</summary>

```
App/SettingsView.swift:858-864 → `// MÊME mesure que le garde-fou (\`NotesCurationPrompt.fitsBudget\`) : / // l'inventaire ne compte que les CORPS, sans front-matter ni noms de / // fichiers.` puis `noteVolume = NotesCurationPrompt.corpusCharacterCount(notes: NotesCurationService.readNotes())`. Or NotesCurationPrompt.swift:203-205 → `public static func corpusCharacterCount(notes:) -> Int { notes.reduce(0) { $0 + $1.content.count + $1.name.count } }`, documenté ligne 200 « contenus + noms de fichiers (les noms sont rendus dans le prompt, ils comptent) ». Et App/NotesCurationService.swift:666-669 rend `content` = `String(contentsOf: …)`, le FICHIER entier, front-matter inclus.
```

**Repro** : Sur 20 notes, chaque fichier porte ~150-200 caractères de front-matter : le « % du budget de rangement » affiché est majoré de ~4 % du plafond par rapport au corps réel. Sans conséquence fonctionnelle (le gate mesure pareil), mais quiconque corrige le pourcentage en se fiant au commentaire re-désaligne les deux chiffres — exactement la régression que l'audit du 2026-07-27 avait fermée.

**Piste** : Réécrire le commentaire : « MÊME fonction que le garde-fou — donc mêmes conventions : fichier ENTIER (front-matter compris) + nom de fichier. Ne pas réécrire cette mesure ici sans la réécrire dans NotesCurationPrompt. »
</details>

### [minor] Le picker de modèle lit UserDefaults sans valider contre l'allowlist que le lecteur métier applique
**/Users/mehdiguiard/Desktop/Dynamic_Island/App/SettingsView.swift:934**

`LearningSettings.validModel` retombe sur le défaut dès que la valeur stockée n'est pas dans `availableModels` — garde écrite explicitement pour « un alias retiré par une MAJ du CLI ». `modelBinding` (l'écrivain/lecteur de l'interface) ne fait pas cette validation : il rend la chaîne brute. Deux lecteurs du MÊME réglage avec deux politiques de repli différentes — le motif exact recherché. Symptôme : le Picker reçoit une `selection` sans `tag` correspondant, donc n'affiche AUCUN modèle sélectionné, pendant que la curation/le bilan tournent bel et bien sur le repli.

<details><summary>Preuve</summary>

```
App/SettingsView.swift:932-937 → `private func modelBinding(_ key: String, _ fallback: String) -> Binding<String> { Binding(get: { UserDefaults.standard.string(forKey: key) ?? fallback }, set: { UserDefaults.standard.set($0, forKey: key) }) }` — aucun filtrage. App/LearningSettings.swift:75-78 → `private func validModel(_ raw: String?, fallback: String) -> String { guard let raw, Self.availableModels.contains(raw) else { return fallback }; return raw }`, précédé du commentaire 72-74 « Un réglage corrompu (ou un alias retiré par une MAJ du CLI) ne doit pas faire échouer tous les runs ». `availableModels` = `["haiku", "sonnet", "opus", "fable"]` (ligne 29).
```

**Repro** : `defaults write dev.mehdiguiard.atoll learningRetrospectiveModel opus-4` (ou attendre qu'un alias disparaisse côté CLI), ouvrir Réglages › Apprentissage : le picker « Bilan de session » est vide, aucune ligne cochée ; `LearningSettings.shared.model` rend « sonnet » et c'est ce qui part en `--model`. Note : c'est la version atténuée du défaut déjà corrigé au repli du picker de curation (SettingsView:679-681) — la validation, elle, n'a pas suivi.

**Piste** : Faire passer le `get` de `modelBinding` par la même règle : `let raw = UserDefaults.standard.string(forKey: key); return LearningSettings.availableModels.contains(raw ?? "") ? raw! : fallback` (ou exposer `validModel` en statique et l'appeler des deux côtés — un seul lieu de décision).
</details>

### [minor] Le budget de corpus de curation documenté (120 000) n'est plus celui du code (80 000)
**/Users/mehdiguiard/Desktop/Dynamic_Island/CLAUDE.md:896**

CLAUDE.md — le document « à lire en premier » — annonce un budget de corpus de curation de 120 000 caractères. Le code le fixe à `maxNotes * maxNoteCharacters` = 40 × 2 000 = 80 000, et son commentaire explique pourquoi il a été RÉDUIT (aligner le budget d'entrée sur la capacité de sortie du schéma). Le chiffre de 120 000 est celui d'avant la revue ; il survit dans la doc de continuité, et il a été recopié tel quel dans le brief de cette relecture comme « invariant documenté ». Motif « les documents de continuité dérivent » : la valeur fausse est de 50 % au-dessus de la vraie.

<details><summary>Preuve</summary>

```
CLAUDE.md:896 → `→ budget de corpus (120 000 caractères, sinon REFUS — tronquer remplacerait toute la`. AtollCore/Sources/AtollCore/NotesCurationPrompt.swift:193 → `public static let maxCorpusCharacters = maxNotes * maxNoteCharacters` avec, lignes 197-198, `public static let maxNotes = 40` et `public static let maxNoteCharacters = 2_000`. Le commentaire 184-189 acte la révision : « Accepter un corpus de 120 000 revenait à garantir une perte d'un tiers du volume… Le budget d'ENTRÉE ne dépasse donc jamais la capacité de SORTIE. »
```

**Repro** : grep -n '120 000' CLAUDE.md, puis comparer à `NotesCurationPrompt.maxCorpusCharacters` (80 000). Un futur intervenant qui dimensionne une décision sur 120 000 (par exemple « on a encore de la marge ») se trompe d'un tiers.

**Piste** : Remplacer 120 000 par 80 000 dans CLAUDE.md:896, ou mieux : y écrire la FORMULE (`maxNotes × maxNoteCharacters`) plutôt qu'une constante recopiée, pour que la doc ne puisse plus diverger seule.
</details>

### [minor] Le commentaire affirme que `.windowResizability(.contentMinSize)` rend la fenêtre Réglages étirable — mesuré FAUX, et le vrai correctif est ailleurs
**App/AtollApp.swift:36**

Le commentaire posé sur la scène `Settings` conclut que `.contentMinSize` « ne garde que le PLANCHER — on peut agrandir la fenêtre à volonté ». La vérification empirique du projet dit le contraire, et elle est écrite mot pour mot dans App/SettingsView.swift : `.windowResizability(.contentMinSize)` n'y change rien, bouton zoom éteint, et c'est le `NSViewRepresentable` `ResizableWindow` qui insère `.resizable` dans le styleMask. Deux commentaires du même dépôt affirment donc l'inverse l'un de l'autre sur le même modificateur. Le risque n'est pas cosmétique : celui qui lit AtollApp.swift croit que le redimensionnement est acquis là, et un élagage (« ce hack NSView ne sert à rien, le modificateur SwiftUI le fait ») refermerait le défaut corrigé en v0.13.2.

<details><summary>Preuve</summary>

```
App/AtollApp.swift l.36-41 : « `.contentMinSize` ne garde que le PLANCHER — on peut agrandir la fenêtre à volonté. » suivi de `.windowResizability(.contentMinSize)`
App/SettingsView.swift l.61-64 : « Une scène `Settings` produit une fenêtre NON redimensionnable, et `.windowResizability(.contentMinSize)` n'y change rien : vérifié en capture, le bouton zoom restait désactivé et la fenêtre refusait toute autre taille que celle de son contenu. »
App/SettingsView.swift l.72 : `view.window?.styleMask.insert(.resizable)`
```

**Repro** : Lecture croisée des deux commentaires ; le fait est déjà tranché par capture d'écran (CLAUDE.md, fenêtre des Réglages v0.13.2 : « vérifié en capture : le bouton zoom restait éteint »).

**Piste** : Réécrire le commentaire d'AtollApp.swift : `.contentMinSize` est gardé parce qu'il transmet le plancher de contenu, PAS parce qu'il rend la fenêtre étirable — renvoyer explicitement à `ResizableWindow` (SettingsView.swift:67) qui est le seul mécanisme qui la rend redimensionnable, et interdire de retirer l'un en croyant l'autre suffisant.
</details>

### [minor] CLAUDE.md annonce la règle SESSIONS recalibrée à 70 ; le code dit 68 ⛔️ RÉFUTÉ
**App/ExpandedView.swift:105**

Le document « à lire en premier » chiffre la recalibration Phase 14 des règles ASCII : « 52 → 70 (SESSIONS, qui partage sa rangée avec [ PROJET ]/[ ÉTAT ]) ». Le code appelle sectionHeader avec 68. Les deux autres chiffres de la même phrase (79 pour QUOTA et APPRENTISSAGE) sont, eux, exacts — c'est donc une dérive isolée, du type que la mémoire projet « les documents de continuité dérivent » décrit : un nombre faux dans un document qui inspire confiance, et qui sera recopié tel quel à la prochaine recalibration.

<details><summary>Preuve</summary>

```
App/ExpandedView.swift:105 → `Text(AsciiArt.sectionHeader("SESSIONS", width: 68))`
App/ExpandedView.swift:302 → `Text(AsciiArt.sectionHeader("APPRENTISSAGE", width: 79))`
App/ExpandedView.swift:341 → `Text(AsciiArt.sectionHeader("QUOTA", width: 79))`
CLAUDE.md (Phase 14) → « Les règles ASCII étaient calibrées sur l'ancienne boîte : 52 → 70 (SESSIONS…), 72 → 79 (QUOTA, APPRENTISSAGE, TÂCHE TERMINÉE) »
```

**Repro** : grep -n 'sectionHeader("SESSIONS"' App/ExpandedView.swift puis grep -n '52 → 70' CLAUDE.md.

**Piste** : Corriger le 70 en 68 dans CLAUDE.md (ou passer 68 à 70 dans le code si 70 était la valeur mesurée — mais alors le vérifier en capture, la rangée SESSIONS partage sa ligne avec le sélecteur [ PROJET ]/[ ÉTAT ]).
</details>

### [minor] L'en-tête du FleetPoller annonce `agents --json --all`, la commande réellement lancée est sans `--all` (et le code le souligne)
**App/FleetPoller.swift:8**

Le commentaire de classe décrit la sonde comme `claude agents --json --all`, alors que `runAgentsJSON` lance délibérément `["agents", "--json"]` et documente au même endroit pourquoi `--all` est exclu. La distinction n'est pas cosmétique : `--all` est précisément le mode où apparaissent les entrées à `state` terminal sans `status`, autour desquelles tout le blindage d'`AgentsSnapshot` et la garde `isTerminal` d'`appendFleetSession` ont été écrits. Un lecteur qui croit l'en-tête conclut que les sessions terminées sont listées et que le retrait par absence ne peut pas fonctionner.

<details><summary>Preuve</summary>

```
App/FleetPoller.swift:8-9 —
```swift
/// Interroge périodiquement `claude agents --json --all` — l'interface SUPPORTÉE
/// d'énumération de la flotte — et en fait l'AUTORITÉ de découverte des sessions.
```
Contre App/FleetPoller.swift:134-136 :
```swift
// SANS --all : seules les sessions ACTIVES (une session terminée
// sort du snapshot → Atoll la clôt).
process.arguments = ["agents", "--json"]
```
```

**Repro** : Lecture seule : les deux affirmations coexistent dans le même fichier et se contredisent ; la ligne 136 fait foi.

**Piste** : Retirer `--all` de la ligne 8. Ce genre d'écart se confronte par script plutôt qu'en relisant : `grep -n 'agents", "--json' App/FleetPoller.swift` contre les mentions de `--all` dans les commentaires.
</details>

### [minor] `runHelper` bloque le MainActor sur `waitUntilExit()` avec deux pipes non drainés — le contraire de la pratique documentée dans le fichier jumeau
**App/HookInstaller.swift:104**

`runHelper` attache un `Pipe()` à stdout sans jamais le lire, lit stderr seulement APRÈS `waitUntilExit()`, et fait tout cela sur le MainActor (l'enum est `@MainActor`, `runHelper` est synchrone). Si le helper émet plus que la capacité du tube (~64 Ko) sur l'un ou l'autre canal, il se bloque en écriture, `waitUntilExit()` ne rend jamais la main et l'interface gèle définitivement — plus de quit propre. Même sans atteindre ce volume, install/uninstall/rockstar-park/rockstar-restore bloquent le thread principal pendant toute la durée du helper. Le fichier jumeau tient explicitement la pratique inverse (App/FleetLauncher.swift:56-63 : « il est drainé avant waitUntilExit »), et aucun watchdog n'est armé ici, contrairement aux deux autres lanceurs de processus du dépôt.

<details><summary>Preuve</summary>

```
App/HookInstaller.swift:100-111 —
```swift
let process = Process()
process.executableURL = helperURL
process.arguments = [verb]
let errorPipe = Pipe()
process.standardOutput = Pipe()   // jamais lu
process.standardError = errorPipe
try process.run()
process.waitUntilExit()           // sur le MainActor, avant tout drain
guard process.terminationStatus == 0 else {
    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
```
À comparer à App/FleetLauncher.swift:54-63, qui documente la règle : « Le message est court (« No job matching '…' ») — pas de risque de blocage de pipe, et il est drainé avant `waitUntilExit`. »
```

**Repro** : Je n'ai PAS lu Bridge/main.swift en entier : le volume de sortie des verbes install/uninstall/rockstar-* n'est pas établi (33 `print(` dans tout Bridge/), donc le blocage n'est pas démontré sur la version actuelle du helper — je le rapporte comme latent. Le blocage du MainActor pendant l'exécution du helper, lui, est inconditionnel, sur des chemins appelés au lancement (`repairIfInstalled`, `syncDenyParking`) et à chaque bascule Rockstar.

**Piste** : Rediriger stdout sur `FileHandle.nullDevice` (rien ne le lit), drainer stderr avec `readToEnd()` AVANT `waitUntilExit()` comme le fait FleetLauncher, armer le même watchdog SIGTERM→SIGKILL, et rendre `runHelper` asynchrone (`Task.detached`) pour cesser de bloquer le MainActor.
</details>

### [minor] L'état des réponses est indexé par le TEXTE de la question et le LIBELLÉ de l'option : deux questions (ou deux options) homonymes fusionnent, et `sendAnswers` envoie alors moins de réponses que le CLI n'en attend
**App/InteractionCardView.swift:231**

`selectedOptions` et `freeTexts` sont des dictionnaires `[String: …]` dont la clé est `question.question`, alors que les questions elles-mêmes sont identifiées par leur INDICE (`ForEach(Array(questions.enumerated()), id: \.offset)`). Si `AskUserQuestion` rend deux questions au libellé identique, elles partagent une seule case d'état : cocher une option dans la première coche visuellement la seconde, `allAnswered` renvoie true dès qu'UNE des deux est remplie, et surtout `sendAnswers` construit `answers[question.question]` — la seconde écriture écrase la première, si bien que le dictionnaire transmis à `center.answerQuestions` contient N-1 entrées pour N questions. Or le commentaire ligne 196 pose l'invariant inverse : « Le CLI attend une réponse à CHAQUE question ». Même mécanique un cran plus bas : `ForEach(question.options, id: \.label)` fait des libellés d'options des identités SwiftUI (collision d'ID si deux options portent le même libellé) et `toggle(question:label:)` bascule par libellé, donc deux options homonymes se sélectionnent ensemble. Rien dans le décodage ne garantit l'unicité de ces chaînes — elles viennent du `tool_input` du modèle.

<details><summary>Preuve</summary>

```
InteractionCardView.swift:231 — `let isSelected = selectedOptions[question.question, default: []].contains(option.label)` ; ligne 179 — `ForEach(Array(questions.enumerated()), id: \.offset) { _, question in` ; ligne 217 — `ForEach(question.options, id: \.label) { option in` ; lignes 286-296 — `for question in questions { … answers[question.question] = free … }` ; lignes 196-197 — `// Le CLI attend une réponse à CHAQUE question : ENVOYER reste // désactivé tant que tout n'est pas répondu.`
```

**Repro** : Un `AskUserQuestion` portant deux fois la même chaîne de question (ou deux options au même `label`) : répondre à la première, `[ ENVOYER ⏎ ]` s'active, et le JSON de décision ne contient qu'une entrée pour les deux questions.

**Piste** : Clés d'état composites et stables : indexer par l'indice de la question (`selectedOptions[i]`, `freeTexts[i]`) plutôt que par son texte, et donner aux options une identité par offset (`ForEach(Array(question.options.enumerated()), id: \.offset)`). Le dictionnaire final de `sendAnswers` reste forcément keyé par texte (c'est le contrat du CLI), mais il faut au minimum refuser d'envoyer quand `answers.count != questions.count` au lieu du `guard !answers.isEmpty` actuel (ligne 300).
</details>

### [minor] `expansionRipple(trigger:active:)` est un `if` de ViewBuilder autour de TOUT le contenu de l'îlot : basculer « Effets visuels » ou « Réduire les animations » détruit le sous-arbre et vide la carte en cours de saisie
**App/IslandVisuals.swift:154**

Le modificateur enveloppe `content` (donc `CompactView`/`ExpandedView`, donc `InteractionCardView`) dans un `_ConditionalContent` : `if active { modifier(...) } else { self }`. Changer de branche n'est pas un changement de modificateur pour SwiftUI, c'est une destruction/insertion d'identité — tous les `@State` descendants repartent à zéro. Conséquence concrète : décocher l'interrupteur des effets visuels dans les Réglages, ou activer « Réduire les animations » dans macOS (`reduceMotion` est lu ligne 285 de NotchRootView et injecté dans `active`), pendant qu'une carte PLAN est affichée efface le texte tapé dans `planFeedback`, la case `planAcceptEdits`, ainsi que `selectedOptions`/`freeTexts` d'une carte QUESTION à demi remplie. La demande, elle, reste en attente : l'utilisateur retrouve un formulaire vierge. C'est exactement le motif que le dépôt s'est déjà interdit deux fois — le contour conditionnel de `NotchRootView` et les trois branches d'`IslandBackground` (commentaire lignes 60-74 de ce même fichier).

<details><summary>Preuve</summary>

```
IslandVisuals.swift:153-162 — `@ViewBuilder func expansionRipple(trigger: Int, active: Bool) -> some View { if active { modifier(ExpansionRipple(trigger: trigger)) } else { self } }`. NotchRootView.swift:283-285 — `content.expansionRipple(trigger: rippleTrigger, active: visualEffects && !reduceMotion)`, où `visualEffects` est un `@AppStorage(VisualEffects.enabledKey)` (ligne 11) et `reduceMotion` un `@Environment` (ligne 16). InteractionCardView.swift:35-39 — `@State private var planFeedback = ""` / `planAcceptEdits` / `selectedOptions` / `freeTexts`.
```

**Repro** : Ouvrir une carte PLAN, taper un feedback dans « feedback si révision… », puis basculer Réglages › Général › effets visuels (ou Réglages Système › Accessibilité › Réduire les animations) : le champ est vidé.

**Piste** : Rendre le modificateur inconditionnel et neutraliser l'onde par ses paramètres, comme `IslandBackground` le fait pour le verre : `modifier(ExpansionRipple(trigger: active ? trigger : 0))` — `ExpansionRipple` teste déjà `trigger > 0` dans son `isEnabled` (ligne 140), donc trigger 0 ne coûte rien et ne dessine rien. Le type de vue ne change alors jamais.
</details>

### [minor] Une réponse arrivée après la désactivation du réglage opt-in republie les jauges pour 10 minutes
**App/ModelQuotaPoller.swift:75**

fetchOnce publie scopedLimits et lastSuccessAt sans revérifier isEnabled ni Task.isCancelled après ses deux points de suspension. syncWithSettings vide bien l'état à la désactivation (l. 41-42), mais une requête déjà revenue le repeuple juste après, et displayedLimits la sert encore pendant 10 minutes alors que l'utilisateur a coupé une fonction explicitement opt-in.

<details><summary>Preuve</summary>

```
l. 74-76 : guard let usage = OAuthUsage(data: data) else { return } ; scopedLimits = usage.scopedLimits ; lastSuccessAt = Date() — aucun guard isEnabled. l. 37-42 : func syncWithSettings() { task?.cancel(); task = nil; guard isEnabled else { scopedLimits = []; lastSuccessAt = nil; return } }. l. 27-30 : displayedLimits ne filtre que sur la fraîcheur (600 s), jamais sur isEnabled.
```

**Repro** : Décocher « jauge par modèle » pendant qu'un fetch est en vol et déjà servi par le réseau : l'annulation ne fait plus rien à ce stade, les deux affectations passent sur le MainActor après le vidage, et App/ExpandedView.swift:357 continue d'afficher les jauges par modèle jusqu'à expiration des 10 min.

**Piste** : guard isEnabled, !Task.isCancelled else { return } juste avant les deux affectations — ou faire dériver displayedLimits de isEnabled.
</details>

### [minor] Le `deinit` se présente comme un « filet de sécurité » mais retire des moniteurs AppKit depuis un contexte non-MainActor — et il est de toute façon inatteignable
**App/NotchWindowController.swift:86**

Le commentaire affirme une garantie que le code ne peut pas tenir. `NotchWindowController` est `@MainActor`, mais un `deinit` est nonisolated : il s'exécute là où tombe la dernière libération, alors que `NSEvent.removeMonitor(_:)` est une API AppKit à n'appeler que sur le thread principal. Par ailleurs le filet est vide en pratique : le SEUL point de libération des contrôleurs est `AppDelegate.rebuildWindows()`, qui appelle `tearDown()` sur chacun AVANT de réaffecter `controllers` — donc `globalClickMonitor` et `localClickMonitor` valent déjà nil quand le `deinit` s'exécute, et ses deux `if let` ne font jamais rien. Le bloc est du code mort qui documente une sûreté imaginaire ; s'il devenait un jour atteignable (un chemin de libération qui oublierait `tearDown`), il retirerait les moniteurs hors du thread principal, ce qui est précisément le cas qu'un filet est censé rendre sûr.

<details><summary>Preuve</summary>

```
NotchWindowController.swift:86-94 — `deinit { // Filet de sécurité si le contrôleur est libéré sans tearDown(). if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) } … }`, dans une classe déclarée `@MainActor final class NotchWindowController` (ligne 7-8). AppDelegate.swift:191-197 — `private func rebuildWindows() { controllers.forEach { $0.tearDown() } … controllers = screens.map { … } }`, unique site de remplacement.
```



**Piste** : Soit supprimer le `deinit` et faire de « `tearDown()` avant toute libération » l'invariant explicite (un seul appelant, il est facile à tenir), soit, si on veut réellement un filet, capturer les deux jetons dans des variables locales et les retirer via `MainActor.assumeIsolated`/un hop main explicite — mais ne pas laisser un commentaire promettre une sûreté que trois lignes d'`if let` toujours nils ne fournissent pas.
</details>

### [minor] L'onboarding jette l'erreur de parking des règles deny alors qu'il a un emplacement pour l'afficher
**App/OnboardingView.swift:178**

syncDenyParking est @discardableResult et rend un message d'erreur destiné à l'affichage (« Renvoie un message d'erreur à afficher, nil si OK », App/HookInstaller.swift l. 73-75). Tous les appels de SettingsView le rangent dans denyParkingError ; celui de l'onboarding le jette, alors que la vue possède déjà hookError (l. 76, affiché l. 111-115). Si le parking ou la restitution des règles deny de l'utilisateur échoue à cet instant, personne ne l'apprend — sur un chemin qui réécrit ~/.claude/settings.json, juste après un écran qui promet « Vos hooks existants sont préservés ».

<details><summary>Preuve</summary>

```
App/OnboardingView.swift l. 168-179 : do { try HookInstaller.install() } catch { hookError = error.localizedDescription } ; hooksInstalled = HookInstaller.isInstalled ; HookInstaller.syncDenyParking(level: InteractionCenter.shared.autonomyLevel) — retour ignoré. À comparer à App/SettingsView.swift:627, 1031, 1083, 1091 : denyParkingError = HookInstaller.syncDenyParking(...).
```

**Repro** : Rouvrir « Bienvenue… » depuis le menu en niveau Rockstar, avec un ~/.claude/settings.json non inscriptible (ou un helper qui échoue) : l'installation des hooks affiche son erreur, l'échec de la (re)mise en parc des règles deny reste totalement muet.

**Piste** : Affecter le retour à hookError quand il est non nil (ou à une seconde ligne d'erreur), comme le fait SettingsView.
</details>

### [minor] reconcileNotes est figé au lancement — le rapport frais est recalculé puis jeté à chaque refresh()
**App/SkillReviewCenter.swift:60**

`reconcileNotes` (affiché en permanence dans Réglages › Apprentissage) n'est écrit QUE par `reconcileAndScan()`, appelé une seule fois au démarrage (AppDelegate.swift:142). `refresh()` recalcule pourtant le MÊME rapport ligne 68 et n'en garde que `userModified` — les trois notes (« Retirés (supprimés à la main) », « Dossiers atoll-* non gérés », « Modifiés par vous ») restent celles de l'instant du lancement pour toute la durée de vie du processus.

<details><summary>Preuve</summary>

```
SkillReviewCenter.swift:48-62 `func reconcileAndScan() { let report = store.reconcile(); … ; reconcileNotes = notes; refresh() }` — seul écrivain de `reconcileNotes` (grep : 2 occurrences hors déclaration, l'affectation l.60 et l'affichage SettingsView.swift:793 `ForEach(center.reconcileNotes, id: \.self)`). Et SkillReviewCenter.swift:68 `let userModified = Set(store.reconcile().userModified)` : le rapport complet est bien reproduit, puis les champs `removedFromManifest` et `unmanaged` sont abandonnés.
```

**Repro** : App ouverte. Supprimer à la main `~/.claude/skills/atoll-<slug>` d'un skill listé au manifeste, puis ouvrir Réglages › Apprentissage : la note « Retirés (supprimés à la main) » n'apparaît pas, alors que `reconcile()` vient de l'établir (et a même réécrit installed.json, LearnedSkillStore.swift:375-378). Symétriquement, une note « Dossiers atoll-* non gérés : atoll-foo » affichée au lancement reste visible après que l'utilisateur a rangé le dossier.

**Piste** : Faire de `refresh()` l'unique producteur : y appeler `store.reconcile()` UNE fois, en tirer `reconcileNotes` ET `userModified`, et réduire `reconcileAndScan()` à `refresh()`. Cela supprime au passage le double reconcile du lancement (cf. constat suivant).
</details>

### [minor] refresh(), appelé depuis .onAppear d'une vue, fait un scan disque complet et peut RÉÉCRIRE le manifeste
**App/SkillReviewCenter.swift:65**

`refresh()` porte un nom de lecture et est appelé depuis `.onAppear` de la fenêtre de revue (SkillReviewWindow.swift:96), après chaque décision, et à chaque fin de rétrospective (AppDelegate.swift:136-138). Or il exécute `store.reconcile()`, qui liste `~/.claude/skills`, calcule le SHA-256 de CHAQUE SKILL.md installé et peut écrire `installed.json` — plus `computeSimilarities` qui ouvre le catalogue (~260 fichiers, 75-145 ms mesurés d'après le commentaire l.130-133). Le tout sur le MainActor. Au lancement le travail est fait DEUX fois (`reconcileAndScan` l.49 puis `refresh` l.68).

<details><summary>Preuve</summary>

```
SkillReviewCenter.swift:65-79 `func refresh() { proposals = store.discoverProposals(); similarByProposal = computeSimilarities(for: proposals); let userModified = Set(store.reconcile().userModified); … }` — et côté store, LearnedSkillStore.swift:375-378 `if !removedFromManifest.isEmpty { manifest.skills = kept; try? writeManifest(manifest) }`. Le fichier documente pourtant explicitement la préoccupation MainActor (l.130-133 : « jamais dans le corps d'une vue : SkillCatalog.entries() ouvre ~260 fichiers, 75-145 ms »), mais seule la mise en cache des antériorités en a bénéficié — le reconcile, plus lourd, est resté sur le chemin chaud.
```

**Repro** : Ouvrir/fermer la fenêtre de revue en boucle avec une vingtaine de skills installés : chaque ouverture relit et hache tous les SKILL.md sur le thread principal. Au démarrage, instrumenter `LearnedSkillStore.reconcile()` : il est invoqué deux fois de suite (AppDelegate.swift:142 → reconcileAndScan → l.49 puis l.68).

**Piste** : Un seul `reconcile()` par cycle (cf. constat précédent) ; et sortir la partie coûteuse du chemin `.onAppear` — la revue n'a besoin que de `userModified`, qui pourrait être calculé à la demande pour le seul slug affiché.
</details>

### [minor] lastError est un slot unique partagé par deux écrans : l'échec d'un « Archiver » s'affiche sous la proposition en cours de revue
**App/SkillReviewCenter.swift:42**

`lastError` est écrit par `approve`, `reject` et `archiveInstalled`, et affiché à la fois dans la fenêtre de revue (sous les boutons de décision) et dans Réglages. Il n'est remis à nil qu'au succès de l'opération SUIVANTE, jamais à l'ouverture ou à la fermeture de la fenêtre. Une erreur venue d'un « Archiver » lancé depuis Réglages est donc présentée en rouge sous une proposition qu'elle ne concerne pas, au moment précis où l'utilisateur décide.

<details><summary>Preuve</summary>

```
SkillReviewCenter.swift:42 `private(set) var lastError: String?`, écrit l.89 (approve), l.101 (reject), l.111 (archiveInstalled). Affichage 1 : SkillReviewWindow.swift:220-222 `if let error = center.lastError { Text(error)…foregroundStyle(colors.warn) }`. Affichage 2 : SettingsView.swift:800-802 `if let error = center.lastError { Text(error)…foregroundStyle(.red) }`. Aucun `lastError = nil` dans `refresh()` (l.65-79) ni dans `.onAppear` (SkillReviewWindow.swift:96).
```

**Repro** : Dans Réglages › Apprentissage, cliquer « Archiver » sur un skill alors que le manifeste est illisible → `lastError` = « Manifeste des skills installés illisible — aucune suppression effectuée. ». Ouvrir ensuite la fenêtre de revue : ce message s'affiche sous les boutons REJETER/APPROUVER d'une proposition, comme si l'approbation avait échoué.

**Piste** : Effacer `lastError` en entrée de `refresh()` (ou à l'`.onAppear` de la fenêtre), ou attribuer l'erreur à son opération (`lastError: (scope, message)`) et ne l'afficher que dans l'écran correspondant.
</details>

### [minor] currentIndex n'est reclampé que par les décisions : un refresh() venu d'ailleurs peut faire dire « Aucune proposition en attente » alors qu'il en reste
**App/SkillReviewWindow.swift:63**

`current` renvoie nil dès que `currentIndex` sort des bornes, au lieu de reclamper ; et `clampIndex()` n'est appelé que depuis les gestionnaires REJETER/APPROUVER. Un `refresh()` déclenché hors de la fenêtre (AppDelegate.swift:136-138, callback `onProposalsChanged` de la rétrospective) qui ferait rétrécir la liste laisse la fenêtre sur l'état vide « Aucune proposition en attente » — sans bouton PRÉC/SUIV pour en sortir, puisque la barre de navigation est elle aussi dans `proposalView` — pendant que l'îlot et le menu continuent d'annoncer « ◆ Skill proposé (N) » via `pendingCount`. Seule la fermeture/réouverture de la fenêtre répare (show() reconstruit le contentView, donc le @State).

<details><summary>Preuve</summary>

```
SkillReviewWindow.swift:63-66 `private var current: SkillProposal? { guard center.proposals.indices.contains(currentIndex) else { return nil }; return center.proposals[currentIndex] }` ; l.75-91 la branche `else` affiche « Aucune proposition en attente. » ; l.238-240 `private func clampIndex() { currentIndex = min(currentIndex, max(0, center.proposals.count - 1)) }`, appelé uniquement l.201, l.214 et l.230. Aucun `.onChange(of: center.proposals.count)`. Le rétrécissement hors décision est possible : `reconcile()` termine les approbations interrompues en déplaçant `proposed/<slug>` (LearnedSkillStore.swift:247-250), et `refresh()` liste les propositions AVANT d'appeler `reconcile()` (SkillReviewCenter.swift:66 puis 68) — la liste en mémoire peut donc contenir un dossier que le reconcile de la même passe vient d'emporter, et la passe suivante la raccourcit.
```

**Repro** : Précondition : la liste rétrécit hors décision (approbation interrompue terminée par reconcile, ou dossier de `~/.atoll/learning/proposed/` retiré à la main, ou triggers debug approveSkill/rejectSkill qui agissent sur `proposals.first`). Ouvrir la revue avec 3 propositions, aller sur la 3e (currentIndex = 2), faire disparaître une proposition, laisser un `refresh()` passer : la fenêtre bascule sur l'état vide alors que `center.proposals.count` vaut 2 et que le menu affiche toujours « ◆ Skill proposé (2)… ».

**Piste** : Reclamper à la lecture plutôt que d'abandonner : `let i = min(currentIndex, center.proposals.count - 1); guard i >= 0 else { return nil }; return center.proposals[i]` — ou ancrer la sélection sur `SkillProposal.ID` (stable, c'est le nom de dossier) au lieu d'un index.
</details>

### [minor] drain() ne conserve aucun report entre deux lectures : un marqueur d'interruption à cheval sur deux écritures est perdu définitivement
**App/TranscriptTailer.swift:92**

L'offset avance de `data.count` à chaque événement, sans garder la queue partielle. Si la source d'événements se déclenche alors que Claude Code a écrit la moitié de la ligne (ou si la lecture tombe au milieu du marqueur), « [Request interrupted by user] » est coupé en deux et n'est JAMAIS revu — l'offset est déjà passé. C'est l'invariant crash-safe que `TranscriptLineSplitter` implémente (« une ligne sans saut final n'avance JAMAIS l'offset ») et que ce chemin-ci ne tient pas, alors que c'est le seul détecteur de l'interruption Échap (« aucun hook n'existe pour cet événement », l.7-8). Même cause pour le rafraîchissement branche/modèle : la dernière ligne du chunk est presque toujours partielle et son JSON est jeté (l.108-109).

<details><summary>Preuve</summary>

```
App/TranscriptTailer.swift:92-100 : `watch.offset += UInt64(data.count)` / `watches[sessionID] = watch` PUIS `let text = String(decoding: data, as: UTF8.self)` / `if Self.interruptMarkers.contains(where: { text.contains($0) })`. Aucun champ de report dans `struct Watch` (l.22-26 : `descriptor`, `source`, `offset` seulement). S'ajoute le saut l.84-86 `if fileSize - watch.offset > 1_048_576 { watch.offset = fileSize > 65_536 ? fileSize - 65_536 : 0 }`, dont le commentaire affirme « les marqueurs d'interruption sont toujours dans les dernières lignes » — faux dès qu'un gros résultat d'outil (>1 Mo) est écrit APRÈS l'interruption.
```

**Repro** : Écrire dans le transcript surveillé, en deux write() séparés, `…"text":"[Request interrup` puis `ted by user]"}…` : deux événements DispatchSource, deux drains, aucun `onInterrupt`. Idem si le fichier grossit de plus d'1 Mo entre deux drains avec le marqueur au début de la croissance.

**Piste** : Garder les ~256 derniers octets lus dans `Watch` et les préfixer au chunk suivant avant la recherche de marqueurs (longueur du plus long marqueur suffit), ou faire passer drain par `TranscriptLineSplitter`, qui existe déjà pour ça.
</details>

### [minor] Le garde « scan uniquement si les clés apparaissent » est vrai sur presque toute écriture : le chunk est re-désérialisé ligne à ligne sur le main thread
**App/TranscriptTailer.swift:105**

Le commentaire présente le test `text.contains("gitBranch")` comme un garde qui évite le scan. En pratique `gitBranch` figure sur la grande majorité des lignes du transcript, donc le garde est quasi toujours vrai : chaque événement d'écriture reparse en JSON tout le chunk (jusqu'à 1 Mo) sur la queue `.main`, et rappelle `onMeta` même quand rien n'a changé.

<details><summary>Preuve</summary>

```
App/TranscriptTailer.swift:105-118 : `if text.contains("gitBranch") || text.contains("\"model\"") { … for lineData in data.split(…) { JSONSerialization.jsonObject(…) } … onMeta?(…) }`, avec la source créée `queue: .main` (l.46) et une lecture bornée à 1 Mo (l.84-86). Commentaire l.103-104 : « Scan gardé : uniquement si les clés apparaissent dans le nouveau texte ».
```

**Repro** : Sur le plus gros transcript du projet : 11 879 lignes, `grep -c 'gitBranch'` → 8 357 (≈ 70 % des lignes). Toute tranche d'écriture contenant une ligne ordinaire déclenche donc le scan.

**Piste** : Ne scanner que si la valeur diffère de la dernière connue (mémoriser model/branch dans `Watch` et n'appeler `onMeta` que sur changement), ou déplacer le scan hors du main thread.
</details>

### [minor] Le repli entre clés d'enveloppe utilise le `??` que le même fichier documente 25 lignes plus bas comme neutralisant le repli (piège NSNull)
**AtollCore/Sources/AtollCore/AgentsSnapshot.swift:113**

`decodeOutcome` cherche le tableau enveloppé avec `wrapper["sessions"] ?? wrapper["agents"] ?? wrapper["data"]`. Sur un `[String: Any]` issu de JSONSerialization, une valeur JSON `null` devient `.some(NSNull())` : le `??` est satisfait, les clés suivantes ne sont JAMAIS consultées, le `as? [[String: Any]]` échoue et le décodage rend `.unrecognized`. Le fichier décrit ce piège mot pour mot pour `firstString` et conclut « une garde ne vaut que si elle couvre TOUS ses points » — puis le commet dans la branche voisine. Le repli d'enveloppe est donc neutralisé exactement dans le cas pour lequel il a été écrit.

<details><summary>Preuve</summary>

```
AgentsSnapshot.swift:112-115 —
```swift
} else if let wrapper = root as? [String: Any],
          let nested = (wrapper["sessions"] ?? wrapper["agents"] ?? wrapper["data"])
            as? [[String: Any]] {
    array = nested
```
Contre la doctrine écrite lignes 130-139 du MÊME fichier :
```swift
/// À écrire ainsi, et PAS `entry["a"] ?? entry["b"]` : sur un
/// `[String: Any]` venu de JSONSerialization, un `"sessionId": null` devient
/// `.some(NSNull())`. Le `??` est alors satisfait, la seconde clé n'est
/// JAMAIS consultée…
private static func firstString(_ entry: [String: Any], _ keys: String...) -> String? {
```
```

**Repro** : Un `claude agents --json` futur émettant `{"sessions": null, "agents": [ {…} ]}` : `wrapper["sessions"]` vaut `.some(NSNull())`, le `??` s'arrête là, le cast échoue → `.unrecognized` → App/FleetPoller.swift:77-82 publie `available: false` en boucle → la découverte bascule définitivement sur le repli par scan de processus, celui-là même que la Phase 8 a retiré parce que le daemon le rend non fiable.

**Piste** : Un helper jumeau de `firstString` : `for key in ["sessions", "agents", "data"] { if let nested = entry[key] as? [[String: Any]] { array = nested; break } }`, c'est-à-dire ne consulter la clé suivante que si la précédente n'a pas VRAIMENT porté un tableau. Un test avec `{"sessions": null, "agents": [...]}` échoue aujourd'hui.
</details>

### [minor] Le commentaire annonce une heuristique sur `startedAt` que le code n'implémente pas — division par 1000 inconditionnelle
**AtollCore/Sources/AtollCore/AgentsSnapshot.swift:173**

Le commentaire annonce « startedAt en millisecondes epoch (heuristique : > an 2001 en ms) », mais aucune heuristique n'est écrite : toute valeur numérique est divisée par 1000 et acceptée. La valeur alimente directement `firstSeenAt`, donc l'âge affiché de la session. C'est un parsing de JSON tiers fragile aux évolutions de schéma, doublé d'un commentaire qui affirme une garantie absente — sur un fichier dont l'en-tête revendique un décodage « 100 % DÉFENSIF ».

<details><summary>Preuve</summary>

```
AgentsSnapshot.swift:172-175 —
```swift
// startedAt en millisecondes epoch (heuristique : > an 2001 en ms).
let startedAt: Date? = (entry["startedAt"] as? NSNumber).map {
    Date(timeIntervalSince1970: $0.doubleValue / 1000)
}
```
Consommation sans re-validation, App/SessionStore.swift:926 : `firstSeenAt: info.startedAt ?? now,` puis App/SessionStore.swift:192 : `startedAt: tracked.firstSeenAt,`.
```

**Repro** : Un CLI qui émettrait `startedAt` en SECONDES (1 786 000 000) : 1786000000/1000 = 1 786 000 s → 1970-01-21, et l'îlot affiche une session démarrée il y a ~56 ans. Symétriquement, un `startedAt` en microsecondes donnerait une session née dans le futur, et tout `startedAt: 0` daterait la session de 1970.

**Piste** : Écrire l'heuristique que le commentaire décrit : n'accepter la valeur que si la date reconstruite tombe dans une fenêtre plausible (p. ex. > 2001-01-01 et < maintenant + 1 h), en essayant ms puis s, et rendre `nil` sinon — `nil` retombant déjà proprement sur `now` côté appelant.
</details>

### [minor] `hasJobDirectory` documente un comportement fail-open et est fail-CLOSED sur tous ses chemins de doute
**AtollCore/Sources/AtollCore/FleetLaunch.swift:59**

Le commentaire promet « Fail-open : au moindre doute (dossier illisible), on rend `true` ». Aucun chemin du code ne rend `true` en cas de doute : `fileExists(atPath:isDirectory:)` s'appuie sur stat(), qui échoue (EACCES) quand `~/.claude/jobs` n'est pas traversable, et rend alors `false` — indiscernable de « le dossier n'existe pas ». Le seul `return true` du corps exige une réponse POSITIVE et un booléen de répertoire vrai. L'invariant documenté est donc inversé, et le bouton ARRÊTER disparaît en silence au lieu d'échouer avec le stderr de la CLI — c'est précisément l'arbitrage que le commentaire dit avoir tranché dans l'autre sens.

<details><summary>Preuve</summary>

```
FleetLaunch.swift:51-61 —
```swift
/// Fail-open : au moindre doute (dossier illisible), on rend `true` — mieux
/// vaut un bouton qui échoue avec le stderr de la CLI qu'un bouton absent
/// alors que l'arrêt aurait marché.
public static func hasJobDirectory(for sessionID: String, jobsRoot: URL,
                                   fileManager: FileManager = .default) -> Bool {
    guard let identifier = jobIdentifier(for: sessionID) else { return false }
    var isDirectory: ObjCBool = false
    let path = jobsRoot.appendingPathComponent(identifier).path
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue
}
```
Aucun garde-fou côté appelant non plus — App/SessionDetailView.swift:19-21 :
```swift
private var canStop: Bool {
    FleetLaunch.hasJobDirectory(for: session.id, jobsRoot: BridgePaths.claudeJobsURL)
}
```
```

**Repro** : `~/.claude/jobs` présent mais non traversable (droits abîmés, volume monté sans exécution, dossier remplacé par un lien cassé) : stat échoue, `fileExists` rend false, `canStop` est false et le kill-switch n'est pas offert — y compris sur une session d'arrière-plan que `claude stop <préfixe>` arrêterait sans difficulté.

**Piste** : Séparer « absent » de « indéterminé » : tester d'abord la lisibilité de `jobsRoot` (`fileManager.isReadableFile(atPath: jobsRoot.path)` / `contentsOfDirectory` en `try`), et rendre `true` quand l'énumération ÉCHOUE, `false` seulement quand elle réussit sans contenir l'identifiant. Sinon corriger le commentaire, qui est aujourd'hui la seule source de l'invariant « fail-open » repris dans la documentation projet.
</details>

### [minor] IslandGeometry.wingWidth / pillWidth : « conservé pour compat » sans aucun appelant de production
**AtollCore/Sources/AtollCore/IslandGeometry.swift:49**

Ces deux constantes se présentent comme une API de compatibilité, mais AtollCore n'a qu'un seul consommateur (l'app) et aucune ligne de production ne les lit : les seuls appelants sont deux assertions de test. Elles sont de simples alias de `IslandWidth.medium`, donc elles n'ont pas de sens propre — c'est exactement le motif « fonction écrite, testée, jamais appelée » que la campagne cherche, sur une surface publique d'un dépôt public.

<details><summary>Preuve</summary>

```
AtollCore/Sources/AtollCore/IslandGeometry.swift:47-52 → `/// Largeur d'une aile de contenu (taille moyenne). Conservé pour compat ;\n/// préférer \`IslandWidth.wingWidth\` (réglable par écran).\npublic static let wingWidth: CGFloat = IslandWidth.medium.wingWidth` … `public static let pillWidth: CGFloat = IslandWidth.medium.pillWidth`
grep -rn "IslandGeometry.wingWidth|IslandGeometry.pillWidth" --include='*.swift' . → seulement AtollCore/Tests/AtollCoreTests/IslandGeometryTests.swift:32 et :38
```

**Repro** : grep -rn "IslandGeometry.wingWidth\|IslandGeometry.pillWidth" --include='*.swift' /Users/mehdiguiard/Desktop/Dynamic_Island — aucun résultat hors Tests/.

**Piste** : Retirer les deux constantes et réécrire IslandGeometryTests:32 et :38 avec `IslandWidth.medium.wingWidth` / `.pillWidth`, ce que le commentaire recommande déjà.
</details>

### [minor] Le clamp 0…1 du quota vit dans l'init mémberwise et le `Codable` synthétisé le contourne — le cache disque n'est jamais reborné
**AtollCore/Sources/AtollCore/Quota.swift:11**

`RateLimit.init` borne `usedFraction` à [0,1] et le commentaire l.6 documente « Fraction utilisée, 0…1 » comme un invariant du type. Mais `RateLimit` est `Codable` avec conformance SYNTHÉTISÉE : `init(from:)` affecte directement la propriété stockée sans passer par l'init validant. Le seul consommateur de ce décodage est le cache quota ajouté en v0.12.0 (`~/.atoll/quota-cache.json`), c'est-à-dire précisément la raison pour laquelle `Codable` a été ajouté. Un fichier hors bornes (édité, tronqué à mi-écriture puis complété par une autre version, écrit par un futur schéma) rend un `usedFraction` négatif ou > 1 que le gate d'apprentissage et les jauges consomment tel quel — la validation ne s'applique qu'aux valeurs venant de la statusline. Même trou pour `QuotaSnapshot` (aucune revalidation à la construction).

<details><summary>Preuve</summary>

```
Quota.swift:5 `public struct RateLimit: Equatable, Sendable, Codable` + Quota.swift:11-14 `public init(usedFraction: Double, resetsAt: Date?) { self.usedFraction = min(max(usedFraction, 0), 1) … }` — aucun `init(from decoder:)` explicite. Lecture du cache : App/SessionStore.swift:988-992 `guard let data = try? Data(contentsOf: BridgePaths.quotaCacheURL), let quota = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) else { return nil }` puis seuls `resetsAt` et `receivedAt` sont contrôlés, jamais `usedFraction`.
```

**Repro** : echo '{"fiveHour":{"usedFraction":-3},"sevenDay":{"usedFraction":9},"receivedAt":<epoch récent>}' > ~/.atoll/quota-cache.json (avec resetsAt futur) → loadCachedQuota rend un RateLimit à -3, alors que le même chiffre venu de la statusline aurait été ramené à 0.

**Piste** : Écrire un `init(from decoder:)` explicite qui délègue à `self.init(usedFraction:resetsAt:)` (deux lignes), ou reclamper dans `loadCachedQuota`. Le premier tient l'invariant pour tous les futurs lecteurs.
</details>

### [minor] `\` est traité comme échappement DANS des guillemets simples : la quote ne se referme jamais et tout le reste de la ligne devient UN seul segment
**AtollCore/Sources/AtollCore/ShellSplitter.swift:47**

La branche `c == "\\"` est testée AVANT la branche `if let open = quote`, donc un antislash est un échappement même à l'intérieur d'une chaîne entre apostrophes — ce qui est faux en shell (dans `'…'` l'antislash est littéral et n'empêche pas l'apostrophe de fermer). Quand l'antislash précède immédiatement l'apostrophe fermante, celle-ci est consommée comme caractère échappé, `quote` reste ouvert jusqu'à la fin de la ligne, et tous les `&&`, `;`, `|` suivants sont avalés. `SoundHookEditor.isSoundCommand` conclut alors « un seul segment » sur une commande COMPOSÉE, puis ne regarde plus que le premier mot : si c'est `afplay`/`say`, le hook entier de l'utilisateur est parqué — exactement le faux positif que le commentaire l.133-135 dit ne jamais vouloir (« un faux positif retirerait à l'utilisateur un hook qui fait autre chose »). Le doc du fichier (l.21-23) affirme traiter correctement « opérateurs hors chaîne […] et échappement par `\` » : la garantie n'est pas tenue dans les apostrophes.

<details><summary>Preuve</summary>

```
ShellSplitter.swift:47-49 `if c == "\\" { current.append(c); escaped = true; index += 1; continue }` placé AVANT `ShellSplitter.swift:50-54 if let open = quote { current.append(c); if c == open { quote = nil } … }`. Conséquence en aval : SoundHookEditor.swift:154 `guard ShellSplitter.meaningfulSegments(command).count == 1 else { return false }`, puis SoundHookEditor.swift:159-163 `let tokens = command.split(…); … if program == "afplay" || program == "say" { return true }`.
```

**Repro** : ShellSplitter.meaningfulSegments(#"afplay '/Volumes/Sons\'/done.wav ; ./deploy.sh"#) rend UN seul segment (l'apostrophe fermante est mangée par `escaped`) au lieu de deux → isSoundCommand rend true et le `./deploy.sh` de l'utilisateur part au parking avec le hook.

**Piste** : Déplacer le test de `quote` avant celui de `\`, et n'activer `escaped` que hors apostrophes : `if let open = quote { if open == "\"" && c == "\\" { current.append(c); escaped = true } else { current.append(c); if c == open { quote = nil } }; index += 1; continue }`. Ajouter un test `'…\'` à ShellSplitterTests (les tests actuels du splitter sont la seule couverture depuis le retrait d'AutoAcceptPolicy).
</details>

### [minor] `summarize` (et `summaryLength`) sont du code mort que l'échafaudage documenté ne couvre PAS
**AtollCore/Sources/AtollCore/TaskCompletion.swift:36**

L'en-tête du fichier justifie nommément DEUX choses et deux seulement : « `inputCap` est VIVANT : `HookEvent` s'en sert » et « `plainText` est la brique du rapport de retour prévu ». `summarize` n'est ni l'un ni l'autre : c'est l'ancien point d'entrée de l'annonce de fin de tâche, partie avec le cockpit le 2026-08-03, et il n'a plus aucun appelant hors tests. Il traîne avec sa constante `summaryLength` et son commentaire « Longueur visée pour le corps de la notification (au-delà, macOS tronque…) », qui décrit une notification macOS dont plus aucune ligne du dépôt n'existe (CLAUDE.md : « plus aucune ligne du dépôt n'importe UserNotifications »). C'est précisément le cas que la fiche de périmètre demande de distinguer : l'échafaudage documenté n'est pas un défaut, le résidu NON documenté à côté en est un — d'autant que le fichier se termine par « Si ce rapport n'est pas construit, ce fichier doit être supprimé », donc quelqu'un relira cette liste.

<details><summary>Preuve</summary>

```
Recherche des appelants sur tout le dépôt (hors build/) : `TaskCompletion.summarize` n'apparaît que dans AtollCore/Tests/AtollCoreTests/TaskCompletionTests.swift (l.129, 132, 135, 141, 147, 157, 169, 180). Les seules autres occurrences de « summarize( » sont `RecallJournal.summarize` (Bridge/main.swift:753) et `ParsedHookEvent.summarize` (HookEventTests.swift:68), sans rapport. Le seul symbole du fichier réellement consommé en production est `TaskCompletion.inputCap` (AtollCore/Sources/AtollCore/HookEvent.swift:114 : `.map { String($0.prefix(TaskCompletion.inputCap)) }`).
```

**Repro** : grep -rn "TaskCompletion.summarize" --include="*.swift" . | grep -v build/  → uniquement des lignes de TaskCompletionTests.swift.

**Piste** : Deux issues, aucune urgente : soit retirer `summarize` + `summaryLength` + les 8 tests qui ne testent qu'eux (le `maxLength` de `plainText` peut prendre une valeur explicite), soit — si le rapport de retour de docs/VISION-2026-08.md §4.1 en dépendra — ajouter `summarize` à la liste des raisons de garder le fichier et purger la mention « notification macOS », qui décrit une fonction supprimée.
</details>

### [minor] VS Code Insiders est nommé « Windsurf » dans toute l'interface
**AtollCore/Sources/AtollCore/TerminalTarget.swift:66**

displayName teste « cursor » puis « code » et fait retomber TOUT le reste sur « Windsurf ». Or vscodeFamilyCLIs (l. 76) mappe com.microsoft.VSCodeInsiders sur la CLI « code-insiders », qui n'égale ni l'un ni l'autre : un utilisateur de VS Code Insiders voit le nom d'un éditeur concurrent.

<details><summary>Preuve</summary>

```
l. 66 : case .vscodeFamily(let cli): return cli == "cursor" ? "Cursor" : (cli == "code" ? "VS Code" : "Windsurf"). l. 75-79 : vscodeFamilyCLIs = ["com.microsoft.VSCode": "code", "com.microsoft.VSCodeInsiders": "code-insiders", "com.todesktop.230313mzl4w4u92": "cursor", "com.exafunction.windsurf": "windsurf"].
```

**Repro** : Session lancée dans le terminal intégré de VS Code Insiders : l'ancre porte bundleID com.microsoft.VSCodeInsiders → TerminalResolver.resolve rend .vscodeFamily(cli: "code-insiders") → App/SessionDetailView.swift:149 affiche « OUVRIR DANS WINDSURF ↵ », et l'échec éventuel (App/TerminalJumpService.swift:84) dit « Impossible de focuser Windsurf. »

**Piste** : Faire du displayName un switch exhaustif sur les quatre CLIs connues (cursor / code / code-insiders / windsurf), défaut « éditeur ».
</details>

### [minor] La surcharge `isFailure(_: TranscriptLine.Fragment)` n'a aucun appelant
**AtollCore/Sources/AtollCore/TranscriptDigest.swift:272**

Fonction écrite et documentée (elle porte tout le raisonnement mesuré « 73 erreurs pour 13 réelles »), jamais appelée : les trois sites d'appel du fichier passent tous une `Entry`, et aucun appel `isFailure(` n'existe ailleurs dans le dépôt, tests compris. Deux surcharges qui peuvent diverger silencieusement.

<details><summary>Preuve</summary>

```
TranscriptDigest.swift:272 `static func isFailure(_ fragment: TranscriptLine.Fragment) -> Bool` vs l.278 `static func isFailure(_ entry: Entry) -> Bool`. Sites d'appel : l.245 `isKept = isFailure(entry)` (Entry), l.305 `return !isFailure(result)` (Entry issu de `resultsByID`), l.310 `return !isFailure(flat[next])` (Entry). `grep -rn --include='*.swift' "isFailure(" .` hors de ce fichier → aucun résultat (ni App/, ni Bridge/, ni AtollCore/Tests/).
```



**Piste** : Retirer la surcharge Fragment et déplacer son commentaire (qui est la vraie documentation de la règle) sur la surcharge Entry.
</details>

### [minor] L'élagage est quadratique : le total gardé par rôle est recalculé sur TOUTES les entrées à chaque candidat
**AtollCore/Sources/AtollCore/TranscriptDigest.swift:190**

Dans la passe 0, chaque index d'un rôle réservé déclenche un balayage complet de `selected.indices` (filter + reduce). Le coût est O(|entrées réservées| × |entrées|), sans borne autre que le plafond d'entrée de l'appelant. La mesure citée en tête de fichier (« 47 Mo → 148 828 caractères en 2 s ») est antérieure aux parts réservées et ne couvre donc pas ce chemin.

<details><summary>Preuve</summary>

```
TranscriptDigest.swift:190-194 : `let kept = selected.indices.filter { keep[$0] && selected[$0].role == role }.reduce(0) { $0 + blocks[$1].count }` — à l'intérieur de `for index in sacrificeOrder(for: selected)` (l.185), lui-même dans `for pass in 0..<2` (l.184). L'appelant autorise jusqu'à 200 000 lignes : App/RetrospectiveRunner.swift:738 `nonisolated private static let digestLineCap = 200_000` (et plusieurs fragments par ligne).
```



**Piste** : Tenir un `keptBytesByRole: [Role: Int]` initialisé une fois et décrémenté à chaque retrait, au lieu de recalculer ; le résultat est identique et le coût devient linéaire.
</details>
