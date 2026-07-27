# HANDOFF — reprise du développement d'Atoll

> Document de continuité pour reprendre le dev après un compactage de conversation.
> **À lire en premier** avec `CLAUDE.md` (règles) et `PLAN.md` (plan produit).
> Dernière mise à jour : **2026-07-27**, app **v0.13.2** (Phase 13 « Rendre la main » :
> la fin d'une tâche vient te chercher, deux sons à toi, la flotte lisible par état).

---

## 0. TL;DR — REPRISE APRÈS COMPACTAGE (lire ceci d'abord)

Atoll est une « Dynamic Island » ASCII pour Claude Code sur macOS (Swift/SwiftUI,
GPL-3.0, repo PUBLIC `github.com/mehdi7129/atoll`).

### État EXACT au 2026-07-27 (fin de session)

| Quoi | Où |
|---|---|
| Version publiée | **v0.13.2** (DMG notarisé + appcast Sparkle) |
| Git | `main` poussé, **arbre propre** — vérifier d'un coup : `git log --oneline -3 && git status --porcelain` (un hash écrit ici serait périmé dès le commit suivant) |
| Tests | **596 verts** (`cd AtollCore && swift test`, ~0,7 s), build **0 warning** |
| Phases | **1 à 13 livrées**. La feuille de route « Atoll 2 » (milestones A/B/C) est ÉPUISÉE |
| Build installé | ⚠️ `~/Applications/Atoll.app` contient la **Release NOTARISÉE v0.13.2** (installée depuis le DMG en fin de session, pour que Mehdi ait le produit fini). Pour reprendre la boucle de dev : **DÉPLACER ce bundle** (`mv`) puis `ditto` le Debug — `ditto` fusionne et casserait le sceau |

**Rien n'est en cours, rien n'est à moitié fait.** Une reprise commence par choisir
un chantier au §1.

### Ce que fait Atoll aujourd'hui, de bout en bout

Îlot notch ASCII (thèmes, 4 palettes, largeur réglable par écran, Liquid Glass) ·
suivi temps réel des sessions (`claude agents --json` autorité + hooks) · réponses
depuis le notch (permissions ⌘Y/⌘N, plans, questions) · autonomie Manuel/Auto/
Rockstar · quota serveur exact · jump-back terminal · lancer/arrêter une tâche en
arrière-plan · mémoire FTS5 de tous les transcripts + skill `atoll-recall` ·
souvenirs proposés d'office (opt-in) · rétrospective qui produit VRAIMENT des
skills · curation des notes · inventaire et recherche de plugins · annonce de fin
de tâche (notification + bannière) · deux sons personnalisables · flotte par état.

### Les deux skills qu'Atoll s'est appris (et qui SERVENT)

`atoll-release-pipeline` et `atoll-adversarial-review-workflow-recovery`, approuvés
par Mehdi le 2026-07-27 et actifs dans `~/.claude/skills`. **La release v0.12.0 a été
publiée en suivant le premier** — c'est la boucle qui se referme, et la meilleure
façon de vérifier qu'elle marche : refaire une release en invoquant le skill.

### Phase 12 « Boucle fermée » — ce qu'il faut en retenir

Atoll ne produisait AUCUN skill (1 rétrospective lancée en 7 jours sur ~29 sessions).
Trois causes, toutes corrigées : le **quota ne vivait qu'en mémoire** (le gate refusait
« quota inconnu » après chaque redémarrage et pour toute session `--bg`) ; les
**transcripts de 9 à 47 Mo** étaient hors de portée du budget (le modèle en voyait 8 %) ;
le **prompt disait « en cas de doute, zéro skill »**. Résultat après réparation :
8 notes + 2 skills dès le premier run. Détail complet et pièges : CLAUDE.md « Phase 12 ».

---

## 0bis. AUDIT DU 2026-07-27 — LIRE `docs/AUDIT-2026-07-27.md`

Un audit multi-agents (234 agents, 18 dimensions, double vérification
adversariale) a trouvé **59 défauts distincts**, tous corrigés : 4 de sécurité
(dont deux contournements de l'auto-accept), 8 de perte de données, 12 de
logique, 15 d'affichage, 5 symboles morts. 628 tests verts, build sans warning.
Le détail, les scénarios et les pièges de méthode sont dans ce document — ne pas
refaire l'audit sans l'avoir lu.

**Une question reste ouverte pour Mehdi** (voir la fin du document) : au repos et
sans session, l'îlot n'affiche NI le losange Rockstar NI le « + » d'un skill
proposé. Or Rockstar suspend ses règles `permissions.deny`. Deux intentions
documentées s'opposent ; c'est son arbitrage.

## 1. CE QU'IL RESTE À FAIRE

**Aucun chantier n'est en cours.** Les phases 1 à 13 sont livrées et la feuille de
route « Atoll 2 » est épuisée : la suite se décide AVEC Mehdi. Ce qui suit est la
liste réelle de ce qui reste, avec le contexte de décision — pas une liste de vœux.

> ⚠️ **SI TU FAIS UN AUDIT** (Mehdi en demande régulièrement) : le risque n'est PAS
> de rater des choses, c'est de « corriger » des choix délibérés. **Lis le §B et le
> §C avant de proposer quoi que ce soit** — le CJK non géré, le bloc de souvenirs
> masqué, les symboles d'échafaudage, le polling OAuth écarté, le scellé des notes
> abandonné : tout cela est ASSUMÉ et documenté avec sa raison. Un audit utile ici
> cherche des DÉFAUTS avec un scénario reproductible (la revue adversariale
> multi-agents du §2 est l'outil qui marche), pas des écarts de style ni des
> « améliorations » qui rouvriraient des arbitrages déjà rendus.

### A. Pistes identifiées, non tranchées (demander à Mehdi avant d'ouvrir)

1. **Multi-provider** (Codex, OpenCode…) à la façon d'AgentGlance. Gros chantier,
   v2 assumée, **NE PAS entamer sans accord explicite**.
2. **Jump-back Ghostty / tmux** (les adapters existent pour Terminal/iTerm2/Cursor).
   Mehdi a tranché le 2026-07-27 : **sans valeur tant qu'il travaille dans Cursor**.
3. **Notification de fin pour les `--bg` lancées du TERMINAL** (hors notch). Écarté
   en Phase 13 : la seule façon de les reconnaître serait
   `AgentSessionInfo.Kind.background`, dont le code documente qu'il n'est pas fiable
   → risque de sonner sur une session que Mehdi regarde. À rouvrir seulement si le
   CLI expose un jour un marqueur sûr.

**Tranché et ABANDONNÉ** — sceller les notes d'apprentissage (manifeste + SHA256).
L'arbitrage laissé ouvert a été rendu le 2026-07-27, et il est négatif : contre un
processus du MÊME utilisateur, un manifeste n'apporte rien (il peut le réécrire
aussi). Les défenses réelles sont déjà en place — `~/.atoll` en 0700, refus d'un
fichier qui n'appartient pas à l'utilisateur, rôles injectables restreints, cadrage
« DONNÉES, pas des instructions ». Ne pas y revenir sans un modèle de menace neuf.

### B. Dette connue et assumée (ne PAS « corriger » sans raison)

- **`ProactiveRecall.keywords` ne gère pas le CJK** : un prompt japonais/chinois sans
  espaces donne un seul token → pas de recall proactif. Le russe et l'arabe marchent.
  Documenté, pas un bug à corriger à l'aveugle.
- **Le bloc de souvenirs injecté part avec `suppressOutput`** : invisible au terminal
  (choix assumé — 1 800 caractères à chaque prompt seraient illisibles). Depuis
  v0.12.0, le nombre d'extraits remonte à l'îlot ; le CONTENU, lui, ne se lit que
  dans le transcript.
- **`RetrospectivePrompt.userPrompt(transcriptPath:)`** n'a plus d'appelant hors
  tests (l'app passe par le condensé). Gardé comme trace du contrat historique.
- **`PluginSnapshot.availableRanked`** n'a pas d'appelant : échafaudage pour un
  classement par popularité dans l'UI, si le besoin vient.
- **Un plugin désactivé depuis Atoll ne peut pas y être réactivé** (le panneau
  n'offre que « Désactiver » sur les activés). Volontaire pour l'instant : réactiver
  = réexécuter du code tiers, et `claude plugin enable` fait le travail. À rouvrir
  si Mehdi le demande.

### C. Ce qui a été volontairement écarté (avec la raison)

- **Polling OAuth du quota** (`api.anthropic.com/api/oauth/usage`) : zone grise des
  CGU. Le tee-wrapper statusline suffit et est conforme. NE PAS ajouter sans accord.
- **Export des skills vers un dépôt marketplace** : Mehdi ne veut, pour l'instant,
  que le partage entre SES projets — déjà acquis (`~/.claude/skills` est global).
- **Jump-back pane-level VS Code/Cursor** (extension `.vsix`) : le focus fenêtre via
  `cursor -r` suffit ; l'extension est un chantier à part entière.
- **API privées CGS/SkyLight** (écran verrouillé) : pas un besoin.
- **CI GitHub Actions** pour la release : optionnel, jamais fait — la release locale
  prend ~10 min et le skill `atoll-release-pipeline` la décrit intégralement.

### D. Référence — publier une version (LIVRÉE, ce n'est PAS du travail restant)

Le skill `atoll-release-pipeline` décrit la procédure complète et à jour ; ce qui suit
en est le résumé, gardé ici au cas où le skill serait absent de la machine.

#### Publier une version (routine, ~10 min)
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

---

## 1bis. TRAVAILLER AVEC MEHDI — règles apprises À LA DURE (session du 2026-07-27)

Ces points ne sont écrits nulle part ailleurs et coûtent cher à redécouvrir.

### Écrans et captures — IMPÉRATIF
- Mehdi a **deux écrans** : le MacBook (écran 1, `-D 1`, avec encoche, principal) où
  **il travaille**, et un 4K externe (écran 2, `-D 2`, 3840×2160). Consigne explicite :
  **toutes les captures se font sur l'écran 2**, jamais sur le 1.
  → `screencapture -x -D 2 fichier.png` puis `sips -c H W --cropOffset TOP LEFT` et
  **REGARDER l'image** (l'outil Read lit les PNG).
- **Les fenêtres SwiftUI s'ouvrent sur l'écran PRINCIPAL** (donc devant lui). Il faut
  les déplacer TOUT DE SUITE sur l'écran 2 :
  ```sh
  osascript -e 'tell application "System Events" to tell (first process whose bundle identifier is "dev.mehdiguiard.atoll") to repeat with w in windows
    try
      if (item 1 of (size of w)) > 400 then set position of w to {200, -1040}
    end try
  end repeat'
  ```
  (l'écran 2 vit en coordonnées **y négatives** : il est AU-DESSUS dans l'espace global.)
- **INCIDENT VÉCU, à ne pas répéter** : une proposition de skill FACTICE, créée pour
  tester la détection de doublon, s'est ouverte dans la fenêtre de revue sur son écran
  pendant qu'il validait ses vrais skills — il l'a approuvée sans le vouloir. Il a fallu
  la désinstaller proprement (archive + manifeste). **Ne jamais fabriquer d'artefact de
  test qui puisse apparaître dans SON flux de décision.**
- Le trigger `debug.settings` est **intermittent** : parfois la fenêtre ne s'ouvre pas.
  Réessayer, et vérifier la présence de la fenêtre par AppleScript (`size of w`) avant
  de conclure quoi que ce soit d'une capture vide.
- L'îlot se **replie tout seul** quelques secondes après `debug.expand`, MAIS capturer
  immédiatement attrape l'**animation d'expansion en vol** — on croit alors à un
  panneau tronqué et on part corriger un bug qui n'existe pas (vécu deux fois).
  Recette qui marche : trigger → `sleep 1` → trigger à nouveau (il est déjà ouvert,
  donc pleine taille) → `sleep 1` → capture.
- L'AppleScript de déplacement cible les fenêtres de largeur > 400 : **le panneau de
  l'îlot fait 600 de large** et entrerait dans le filtre. En pratique il n'est pas
  exposé comme fenêtre AppKit ordinaire, mais préférer un filtre par NOM de fenêtre.
- Une invite d'autorisation TCC (« contrôler Finder ») déclenchée par un AppleScript
  **BLOQUE tous les Apple Events suivants** tant qu'elle n'est pas fermée : si
  `osascript` ne répond plus, c'est probablement ça — regarder l'écran avant de
  conclure à un bug.

### Ce que Mehdi attend (observé, pas supposé)
- **Vérifier en vrai**, jamais « ça compile donc ça marche ». Il demande explicitement
  les captures et les tests intensifs.
- **Utiliser beaucoup d'agents** en parallèle (il l'a redemandé deux fois) : modules
  AtollCore indépendants confiés à un agent chacun, revues adversariales par dimension.
- **Un plan avec des objectifs mesurables** avant les gros chantiers
  (`docs/ROADMAP-12-boucle-fermee.md` en est le modèle : chaque jalon a un CHIFFRE).
- Il tranche vite quand on lui pose une vraie question fermée (AskUserQuestion avec
  une recommandation en premier). Ne pas lui demander ce qu'on peut décider soi-même.

### Notifications macOS — pièges qui coûtent une demi-journée (Phase 13)
- **Un build signé « adhoc » (= toute la boucle de dev Debug) ne peut PAS notifier.**
  `requestAuthorization` échoue avec « Notifications are not allowed for this
  application ». Ce n'est pas le code : c'est la signature. Ne pas chercher un bug
  dans `TaskCompletionNotifier` à partir de ce symptôme.
- **C'est l'appel à `requestAuthorization` qui INSCRIT l'app** auprès du centre de
  notifications. Tant qu'il n'a pas eu lieu, Atoll n'apparaît pas dans Réglages
  système › Notifications et `getNotificationSettings` répond `denied` (pas
  `notDetermined`, contre-intuitif). Vérifier l'inscription :
  `plutil -p ~/Library/Preferences/com.apple.ncprefs.plist | grep -c atoll`.
- **`ditto` FUSIONNE, il ne remplace pas.** Recopier un build Release par-dessus un
  Debug laisse `Atoll.debug.dylib` dans le bundle → sceau invalide
  (`spctl -a -vv` : « a sealed resource is missing or invalid ») → tout comportement
  système devient erratique. Déplacer l'ancien bundle AVANT (`mv`), puis `ditto`.
  (`rm -rf` est refusé par un hook de cette session : utiliser `mv` ou `trash`.)
- `spctl -a -vv` sur un build Release non notarisé répond « rejected — Unnotarized
  Developer ID » : c'est NORMAL et sans rapport avec le sceau, qui lui doit être
  intact.
- **VÉRIFIÉ DE BOUT EN BOUT le 2026-07-27** sur le build NOTARISÉ (`spctl` :
  *accepted — Notarized Developer ID*), après que Mehdi a accordé l'autorisation :
  `getNotificationSettings` répond **`granted`**, et une vraie fin de tâche a été
  livrée sans erreur (bannière capturée, notification reçue). Le chemin exercé est
  la **réconciliation avec la flotte**, pas un raccourci de debug.
- **`com.apple.ncprefs.plist` N'EST PAS la source de vérité** de l'autorisation :
  il est resté SANS entrée `atoll` alors que le statut était `granted`. J'ai perdu
  du temps à le fouiller — la seule autorité est `getNotificationSettings`. Pour
  lire le statut sans DEBUG : mettre `notifyOnTaskCompletion` à `false`, relancer,
  et lire la ligne « autorisation de notification : … » en `log stream` (la voie
  « demande » ne journalise QUE les échecs, donc son silence signifie succès).
- **Recette pour éprouver la chaîne sans lancer de vraie tâche** : app arrêtée,
  écrire dans `~/.atoll/launched-tasks.json` une tâche avec `seenAlive: true`, un
  `sessionID` inexistant et un `launchedAt` au-delà du délai de grâce — au premier
  poll de flotte, la réconciliation la clôt et notifie. Vider le fichier après.

### Faits VÉRIFIÉS sur le CLI (2026-07-27, claude 2.1.220) — ne pas re-tester à l'aveugle
- **`--safe-mode` convoque `claude-sonnet-5` EN PLUS du `--model` demandé**, et c'est lui
  qui domine la facture : deux runs identiques, l'un en sonnet l'autre en haiku, ont
  coûté **0,864 $ et 0,873 $**. Le réglage de modèle paraît donc sans effet si on ne
  ventile pas — d'où `RetrospectiveReport.modelCosts` et l'affichage du modèle dominant.
- Les alias `haiku` / `sonnet` / `opus` / `fable` sont **tous reconnus** par `--model`
  (vérifiés un par un : `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`,
  `claude-fable-5`).
- **`hookSpecificOutput.additionalContext` fonctionne** pour UserPromptSubmit : le CLI
  l'écrit dans le transcript comme un attachment **`hook_additional_context`**. C'EST LA
  SIGNATURE À CHERCHER pour prouver une injection — **ne jamais croire le modèle sur
  parole** (haiku a répondu « NON » alors que son propre thinking citait les extraits).
- **`claude plugin details` accepte l'id COMPLET `nom@marketplace`** — l'utiliser, sinon
  la CLI répond pour un homonyme d'un autre marketplace (5 cas sur cette machine).
- `claude plugin list --json` rend un **tableau nu** ; `--available --json` rend
  `{installed, available}` et **touche le réseau** (watchdog obligatoire).

### Pièges Swift/macOS payés cette session
- **Ajouter un champ à un JSON persisté CASSE la lecture des anciens fichiers** : la
  synthèse `Decodable` lève `keyNotFound` au lieu d'utiliser la valeur par défaut. Ça a
  **effacé l'historique d'apprentissage** une fois. Tout type persisté qui gagne un champ
  doit avoir un `init(from:)` explicite avec `decodeIfPresent`.
- `.glassEffect(.regular)` **réfracte toujours**, même sous un scrim opaque à 100 % : le
  bas du curseur ne rendait jamais un fond plein. Sous un plancher (6 %), ne pas poser
  de verre du tout.
- Les tuples ne conforment pas à `Equatable` : un champ `[(a: String, b: Double)]` casse
  la synthèse d'un type `Equatable`. Struct nommée obligatoire.
- Lire deux pipes **en série** (stdout puis stderr) peut interbloquer un sous-processus
  dont stderr sature. `async let` sur les deux.
- **`Task.detached` pour écrire un fichier d'état = régression de données.** Deux
  sauvegardes rapprochées partent en parallèle et l'ordre des `rename` atomiques n'est
  pas garanti : le PLUS ANCIEN état peut gagner. Ici ça reperdait le drapeau
  « déjà notifié » → double annonce au redémarrage. Le projet écrit ses états
  **synchronement sur le MainActor** (`SessionStore.writeSnapshot`) — s'y tenir.
- **Une regex « tout ce qui est entre deux chevrons » réécrit la prose.** `<[^>]{1,200}>`
  transformait « la condition i < n && n > 0 » en « la condition i 0 » et
  « remplacé Array<String> » en « remplacé Array » : un résumé grammaticalement correct
  qui dit le CONTRAIRE du vrai. Distinguer par la CASSE (balises HTML minuscules vs
  génériques Swift capitalisés), et en cas de doute GARDER le texte.
- **Quantificateurs non bornés = O(k·n).** `\[([^\]]*)\]\([^)]*\)` repart de chaque `[`
  et balaie jusqu'au bout : **3,2 s mesurés** sur 20 000 crochets non appariés, sur le
  MainActor. Borner (`{0,200}`) en plus du plafond d'entrée.
- **Le cache d'un `NSSound` doit être indexé par USAGE, pas par fichier.** Deux
  événements qui pointent le même son partageaient une instance : le premier son était
  coupé net par le second et rejoué à son volume.
- **Une scène `Settings` produit une fenêtre NON redimensionnable**, et
  `.windowResizability(.contentMinSize)` n'y change rien. Symptôme à reconnaître : le
  bouton zoom (pastille verte) reste ÉTEINT. Le seul remède est d'insérer
  `.resizable` dans le `styleMask` de la fenêtre elle-même (`ResizableWindow`,
  un `NSViewRepresentable` posé en `.background`). Corollaire de méthode : la
  couleur des pastilles est un test visuel fiable, et écrire le cadre de fenêtre
  dans `defaults` n'en est PAS un — SwiftUI l'ignore.
- **`fixedSize(vertical: true)` sur un volet d'onglets fait rétrécir la FENÊTRE** à
  la hauteur du volet le plus court. Pour une taille stable d'un onglet à l'autre :
  bornes sur le conteneur, `maxWidth/maxHeight: .infinity` sur chaque volet.
- **Une revue adversariale multi-agents sur du code qui touche la config utilisateur en
  vaut la peine** : 3 agents ont trouvé 6 + 7 + 10 défauts réels sur du code qui
  compilait, passait ses tests et « marchait » en démonstration. Les plus graves
  (perte silencieuse de hooks tiers) n'auraient jamais été vus autrement.

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

cd AtollCore && swift test              # 492 tests

# Debug runtime
/usr/bin/log stream --predicate 'subsystem == "dev.mehdiguiard.atoll"' --level debug
cat ~/Library/"Application Support"/Atoll/state.json                  # sessions + pending + autonomy
```

### Triggers de debug (`notifyutil -p <nom>`) — seuls `.expand`/`.compact` existent en Release
- `dev.mehdiguiard.atoll.debug.expand` / `.compact` — étend+épingle / replie l'îlot
- `.select` — sélectionne la 1re session (vue détail)
- `.allow` / `.deny` — résout la 1re carte en attente
- `.jump` — jump-back de la 1re session à ancre résolvable
- `.retro` / `.curation` — rétrospective sur la dernière session terminée / curation
  des notes (les deux consomment du quota : `#if DEBUG` uniquement)
- **`.retroBig`** — rétrospective sur le PLUS GROS transcript du projet, sans passer par
  le gate. **C'est LE trigger qui a permis de prouver la boucle d'apprentissage** sans
  attendre qu'une vraie session substantielle se termine. ~0,87 $ le run.
- **`.plugins`** — interroge `claude plugin list --json` et journalise l'inventaire
  (catégorie de log `plugins`).
- **`.pluginSearch`** — recherche un plugin pour un besoin en dur (consomme du quota).
- `.launcher` / `.seedSkill` / `.skillReview` / `.approveSkill` / `.rejectSkill`

### Vérifier l'apprentissage sans relire le code
```sh
python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.atoll/learning/retrospectives.json')));
[print({k:v for k,v in a.items() if v is not None}) for a in d.get('attempts',[])[-5:]]"
ls ~/.atoll/learning/proposed/          # skills en quarantaine (en attente de revue)
ls ~/.claude/skills/ | grep atoll-      # skills appris ACTIFS + atoll-recall (infra)
cat ~/.atoll/learning/installed.json    # manifeste des skills posés par Atoll
sqlite3 ~/.atoll/memory.db "SELECT COUNT(*) FROM messages;"
```

### Piloter le vrai helper
```sh
~/.atoll/bin/atoll-bridge status        # JSON : hooks, wrapper, socket, deny parqués,
                                        # skill, index mémoire, skills appris, recall proactif
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

### Sous-processus `claude` (leçons du chat RETIRÉ, toujours valables)
Le chat intégré n'existe plus (retiré le 2026-07-19), mais `RetrospectiveRunner` et
`NotesCurationService` spawnent des `claude -p` : ces pièges restent d'actualité.
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
- `MemoryIndex` (+ `MemoryRanking`) — index FTS5, dédup inter-fichiers, récence.
- `ProactiveRecall` / `NotesCurationPrompt` / `LearningInventory` — recall proactif,
  curation des notes, inventaire du tableau de bord (Phase 11).

### `App/` (fenêtre, IPC, vues — @MainActor)
- `AtollApp` / `AppDelegate` — @main, MenuBarExtra, démarrage (bridge server, store,
  migration autonomie, warmUp claude), triggers debug, reconstruction des fenêtres par écran.
- `NotchPanel` / `NotchWindowController` / `NotchViewModel` / `NotchRootView` /
  `NotchShape` / `NSScreen+Notch` — la coquille notch (NSPanel par écran, focus, géométrie).
- `CompactView` / `ExpandedView` / `SessionDetailView` / `InteractionCardView` /
  — les vues ASCII (priorité d'affichage étendu : carte > détail > liste).
- `BridgeServer` — socket Unix BSD, reçoit les enveloppes du helper (events + statusline),
  garde les fd des PermissionRequest ouverts (`reply`/`cancelPending`).
- `SessionStore` (singleton @Observable) — source de vérité des sessions : reducer, kqueue
  NOTE_EXIT, réconciliation `ps`, tail transcript, quota réel, ancres terminal, snapshot.
- `InteractionCenter` (singleton) — cartes en attente + décisions + auto-approbation.
- `RetrospectiveRunner` / `NotesCurationService` — les deux `claude -p` internes
  (rétrospective de fin de session, curation périodique des notes).
- `TerminalJumpService` + `AutomationPermission` — jump-back (hors main + timeout).
- `HookInstaller` — façade d'installation (tout passe par le helper `atoll-bridge`).
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
- MacBook 14" à encoche (écran 1, principal, résolution « More Space » 1800×1169, barre
  de menus masquée) **+ un écran externe 4K (écran 2, 3840×2160, en y NÉGATIF)**. Il
  travaille sur le 1 → **toutes les captures se font sur le 2** (voir §1bis).
- **Ses sessions claude tournent dans le terminal intégré de Cursor**
  (`__CFBundleIdentifier=com.todesktop.230313mzl4w4u92`, `TERM_PROGRAM=vscode`) → le jump-back
  vise Cursor en priorité.
- Il a des hooks GSD + sons `afplay` + statusline `bun` custom dans `~/.claude/settings.json`
  → **préservés** (vérifié). Détails de config locale : voir la mémoire projet (repo public).
- node est via nvm mais aussi `/usr/local/bin/node` (donc trouvable par le PATH augmenté).

---

## 7. PROCHAINE ACTION CONCRÈTE

La feuille de route « Atoll 2 » (milestones A, B, C) est **entièrement livrée**, et la
phase 12 « Boucle fermée » aussi — il n'y a plus de prochaine étape écrite d'avance.
**Demander à Mehdi la direction** avant d'ouvrir un chantier ; les pistes non tranchées,
la dette assumée et ce qui a été écarté sont listés au **§1**.

Si la reprise doit commencer par quelque chose d'utile sans rien décider : **refaire une
release en invoquant le skill `atoll-release-pipeline`** — c'est le meilleur test de bout
en bout de la boucle d'apprentissage (le skill vient d'Atoll lui-même), et ça revérifie
signature, notarisation et appcast d'un coup.

Quel que soit le chantier, la routine de fin ne change pas :
1. AtollCore + tests d'abord, coutures App/Bridge ensuite.
2. **Vérifier en vrai** (app lancée, sessions réelles, screenshots LUS).
3. **Revue adversariale multi-agents** par dimension, ne corriger que les constats
   confirmés par la lecture du code.
4. Release notarisée (`Scripts/release.sh`) + `gh release create` + deltas + push.
5. Mettre à jour `README.md`, `CLAUDE.md`, ce fichier, `PLAN.md` §5 et la mémoire projet.
