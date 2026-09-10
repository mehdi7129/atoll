# Passation Claude → Codex — relecture de la PR #2 (choix Claude Code / Codex CLI)

Date : 2026-09-10. Branche `codex/claude-codex-compatibility`, un seul commit
`f25fee6` sur la base `1b08ebd` (Atoll 0.17.2, build 34). PR #2 en brouillon.

**Verdict : la PR n'est pas fusionnable en l'état.** Tout ce que tu as annoncé
comme vérifié se reproduit (tests, harnais, recettes CLI, build). Ce que tu n'as
pas pu voir, faute de capture d'écran, contient un défaut bloquant : le panneau
déployé est VIDE dans la configuration par défaut. Ce document te donne chaque
constat avec fichier:ligne, scénario, preuve, direction de correctif, test
attendu, et la méthode de recette visuelle qui marche maintenant.

Lis d'abord `CLAUDE.md` (règles critiques, arbitrages RENDUS, pièges de build),
puis `docs/IMPLEMENTATION-2026-09-10-codex-claude.md` (ton rapport), puis ce
document. Les captures citées sont dans `/private/tmp/atoll-pr2-captures/`
(disparaît au redémarrage ; Claude peut les refaire) :

| Fichier | Ce qu'il montre |
|---|---|
| `R01-liste-vide-sous-onde.png` | vue Codex, 12 sessions annoncées, corps noir |
| `R01-liste-rendue-mouvement-reduit.png` | même fenêtre, case cochée, liste rendue |
| `R01-carte-vide-sous-onde.png` | 2 demandes en pied, aucune carte dessinée |
| `R01-detail-vide-sous-onde.png` | détail d'une session cliquée, corps noir |
| `R01-variante-maxHeight250-toujours-vide.png` | build avec `maxHeight: 250`, toujours noir |
| `R02-encoche-au-repos-visible.png` | encoche, zéro session, Manuel : ailes visibles |
| `R03-carte-codex-boutons-sous-le-pli.png` | carte apply_patch sans ses boutons |
| `R03-carte-plan-claude-rendue.png` | carte plan Claude, boutons visibles |
| `R04-liste-claude-sans-plus-N-autres.png` | 6 rangées sur 12, aucun surplus annoncé |
| `R05-rockstar-compact-sans-quota.png` | pilule Rockstar, quota absent |
| `marqueur-rockstar-vue-codex.png` | `[ CLAUDE ROCKSTAR ]` en vue Codex |
| `compact-activite-sans-nom-de-session.png` | pilule avec activité, aucun nom |

Le dossier contient aussi `winid.swift` (section 2). Tu peux toutes les
REFAIRE avec la méthode de la section 2.

## 0. Règles du jeu pour cette passe

- **Aucune fonction nouvelle.** Que des correctifs, dans l'esprit de
  `docs/VISION-2026-08.md` (« soustraire avant d'ajouter »).
- **Chaque correctif porte un test de non-régression VÉRIFIÉ PAR SABOTAGE** :
  réintroduis le défaut, le test doit rougir. Un test qui n'a jamais échoué ne
  prouve rien (règle du projet, appliquée depuis l'audit du 2026-08-14).
- **Les arbitrages RENDUS de `CLAUDE.md` priment sur le plan.** Quand ta PR les
  contredit, ce n'est pas à toi de trancher : la question est posée à Mehdi
  (section 6). En attendant sa réponse, le code doit respecter l'arbitrage
  écrit.
- **Ne lance jamais deux Atoll normaux** (mêmes sockets, mêmes hooks). Ne
  remplace pas la copie stable `~/Applications/Atoll.app` (v0.17.2). Ne publie
  rien. Ne lance jamais le produit de build directement : `ditto` une copie.
- **Vérification VISUELLE obligatoire après tout changement d'UI**
  (`CLAUDE.md:464`). La section 2 explique comment.
- Passe documentaire à la fin : `Scripts/check-docs.py` vert, entrée dans
  `docs/reviews.json`, `CLAUDE.md` et `README.md` cohérents avec le code
  (section 7). `docs/HANDOFF.md` mis à jour.
- Pas de `rm -rf` dans les commandes, un hook local les bloque.

## 1. Ce que Claude a reproduit (ne pas refaire)

| Preuve | Résultat |
|---|---|
| `swift test` (AtollCore) | 994 tests, 1 ignoré, 0 échec |
| `Scripts/test-runtime.py` | 40 scénarios verts |
| `--sabotage-cancellation`, `--sabotage-quota-projection` | les deux détectés |
| `Scripts/test-codex-catalog.py` (codex-cli 0.153.4 réel) | 12 hooks reconnus, skills/list, plugin/list OK |
| `Scripts/test-codex-install-recall.py <helper Debug>` | installation ×2, recall, retrait OK |
| Build Debug de la branche (`xcodegen` + `xcodebuild`) | réussi |
| `Scripts/check-docs.py --no-tests` | 12 familles, 0 dérive, 18 avertissements |

Les 18 avertissements comptent : deux API mortes (`refreshWrapper`,
`discover`) et 29 fichiers jamais relus ligne à ligne, dont les gros fichiers
modifiés par la PR (`RetrospectiveRunner` +628 lignes, `CodexService` +283,
`MemoryIndexer` +370, `CodexInteractionCenter` +278).

Cinq relectures adversariales bornées ont ensuite été menées (chemins
destructeurs ; dépenses et quotas ; sessions, permissions et helper ; interface ;
mémoire, skills, docs), puis leurs constats graves ont été contre-vérifiés dans
le code, et l'interface a été MESURÉE en captures.

## 2. Recette visuelle : elle marche, voici comment

Ta recette `--codex-preview` est bonne et étanche (retour anticipé dans
`applicationDidFinishLaunching`, préférences non écrites). Ce qui te manquait,
c'est la permission macOS « Enregistrement de l'écran » pour le processus qui
appelle `screencapture`. Mesuré le 2026-09-10 : tu tournes sous
`/Applications/ChatGPT.app` (processus `ChatGPT.app/Contents/Resources/codex`).
**Mehdi a accordé « Enregistrement de l'écran » à ChatGPT le 2026-09-10 et a
relancé l'app.** Vérifie-le en premier, avant toute recette :

```sh
/usr/sbin/screencapture -x -R 0,0,20,20 /tmp/probe.png && ls -la /tmp/probe.png
```

Si la sonde échoue (« could not create image »), la permission ne t'atteint
pas : demande à Mehdi de la vérifier dans Réglages Système › Confidentialité et
sécurité › Enregistrement de l'écran, ou fais-toi lancer en CLI depuis le
terminal intégré de Cursor, qui l'a déjà, ou produis les builds et laisse
Claude capturer. Sans permission, TOUTES les formes de `screencapture`
échouent, y compris `-l` sur une fenêtre.

Une copie prête à lancer, construite depuis `f25fee6` le 2026-09-10 à 15 h 26,
est déjà posée en `/private/tmp/Atoll-preview.app`, et le produit de
`~/Library/Developer/Atoll-PR2-DerivedData` correspond au même commit. Dès que
tu modifies du code, reconstruis et refais la copie. Procédure exacte, telle
qu'exécutée aujourd'hui :

```sh
DD="$HOME/Library/Developer/Atoll-PR2-DerivedData"      # hors du Bureau iCloud
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath "$DD" build
ditto "$DD/Build/Products/Debug/Atoll.app" /private/tmp/Atoll-preview.app
open -n /private/tmp/Atoll-preview.app --args --codex-preview --preview-many
swift winid.swift            # imprime l'id de la fenêtre « Atoll — recette isolée »
/usr/sbin/screencapture -x -o -l <id> capture.png    # fenêtre seule, 1560×1224 px
pkill -f "Atoll-preview.app/Contents/MacOS/Atoll"    # une instance à la fois
```

Options combinables après `--codex-preview` : `--preview-many` (24 sessions,
12 par fournisseur), `--preview-cards` (une carte plan Claude + une carte
apply_patch Codex), `--preview-claude` (vue Claude, sinon Codex),
`--preview-compact`, `--preview-empty`, `--preview-light`, `--preview-rockstar`,
`--preview-notch` (encoche 180×32, sinon pilule).

La fenêtre s'ouvre sur l'écran 2 (`NSScreen.screens.dropFirst().first`), 780×612
points avec sa barre de titre, à une origine fixe que `winid.swift` imprime
(aujourd'hui X 4483, Y 1722). Pour cliquer sans souris : `cliclick -r c:X,Y`
(`/opt/homebrew/bin/cliclick`, `-r` remet le pointeur en place). Positions
RELATIVES au coin haut gauche de la fenêtre, barre de titre comprise, en points :

| Élément | (x, y) relatif |
|---|---|
| case « Mouvement réduit » | (456, 98) |
| bouton « Rejouer les cartes » | (334, 98) |
| bouton « [ DEMANDE → ] » | (619, 478) |
| première rangée de session | (290, 258) |

Attends 1,5 à 2,5 s après un clic avant de capturer (`python3 -c "import time;
time.sleep(2)"`, pas `sleep`). Heuristique utile sans regarder l'image : un
panneau déployé VIDE pèse 130 à 146 Ko en PNG, un panneau rendu 175 à 240 Ko.

`winid.swift`, à recréer tel quel :

```swift
import CoreGraphics
import Foundation
let deadline = Date().addingTimeInterval(20)
while Date() < deadline {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let name = w[kCGWindowName as String] as? String ?? ""
        let id = w[kCGWindowNumber as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        if owner.contains("Atoll") && name.contains("recette") {
            print("\(id)\t\(owner)\t\(name)\t\(b)")
            exit(0)
        }
    }
    usleep(250_000)
}
print("NOT FOUND")
exit(1)
```

Limite connue de la recette : la case « Mouvement réduit » n'a pas toujours
pris mon clic (deux fois sur neuf). Vérifie sur la capture que la case est
cochée avant de conclure.

## 3. Constats bloquants (P1)

### R01 — P1 — Le panneau déployé est vide : liste, carte et détail ne se dessinent pas

**Code.** `App/ExpandedView.swift:39-48` met la carte dans
`ScrollView { … }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`,
`:66-70` met le détail de session dans `ScrollView { SessionDetailView … }`,
`:72-73` met la liste dans `ScrollView { sessionList }` avec le même `.frame`,
et `:120` transforme `sessionList` en `LazyVStack`. Tout ce contenu est sous
`.expansionRipple(trigger:active: visualEffects && !reduceMotion)`
(`App/NotchRootView.swift:296-297`). Ce modifier
(`App/IslandVisuals.swift:114-160`) attache EN PERMANENCE
`keyframeAnimator` → `visualEffect` → `layerEffect` au contenu ; `isEnabled` ne
coupe que le shader, pas le passage par la couche.

**Mesuré, même fenêtre, même build.** Vue Codex, 24 sessions : en-tête,
sélecteur et quota visibles, corps NOIR. Case « Mouvement réduit » cochée (le
modifier n'est plus attaché) : la liste apparaît avec ses rangées
`[ WORKING ]` / `[ APPROVE? ]` et sa barre de défilement. Décochée : corps noir
à nouveau. Même résultat pour la carte (vue vide avec « 2 demandes · Claude /
Codex » en pied) et pour le détail d'une session cliquée. Variante compilée
avec `maxHeight: 250` à la place de `.infinity` sur les deux `ScrollView` :
toujours noir. Donc borner la hauteur NE suffit PAS.

**Conditions.** Effets visuels actifs (`@AppStorage("visualEffects") = true`
par défaut, `App/NotchRootView.swift:13`) et « Réduire les animations »
désactivé. C'est la configuration de Mehdi et de tout utilisateur par défaut.
Aucun des 994 tests ni des 40 scénarios ne pouvait le voir.

**Fait utile.** Avant la PR, la carte Claude contenait déjà deux `ScrollView`
bornés (`git show 1b08ebd:App/InteractionCardView.swift`, lignes 126-133 et
177-184, `maxHeight: 150` et `210`) et les cartes plan s'affichent en
production v0.17.2, donc sous l'onde. Ce qui casse est le `ScrollView` posé au
niveau du corps d'`ExpandedView`. Je n'ai pas isolé le mécanisme exact dans
SwiftUI (couche rasterisée par `layerEffect` contre `NSScrollView`, ou
proposition de taille sous `visualEffect`) : ne le suppose pas, MESURE chaque
variante avec la recette de la section 2, effets actifs et mouvement réduit
DÉCOCHÉ.

**Directions.** (A) Revenir à la structure d'avant la PR pour le corps : liste
bornée par `IslandRowBudget` avec surplus annoncé « +N autres », cartes en
ligne avec leurs `ScrollView` internes bornés, détail en ligne. C'est aussi ce
que l'arbitrage de `CLAUDE.md:1158` exige, et cela ferme R04 en même temps.
(B) Garder le défilement mais sortir le sous-arbre défilant de l'onde :
appliquer `expansionRipple` au chrome ou à l'en-tête, au sélecteur et au pied
seulement. (C) Toute autre idée passe par une capture sous l'onde avant d'être
retenue.

**Critère de sortie.** Trois captures, effets actifs, mouvement réduit
décoché : liste avec 12 sessions rendues ; carte Codex avec ses boutons
visibles ; détail d'une session. Plus la carte plan Claude.

### R02 — P1 — L'îlot n'est plus jamais invisible au repos : arbitrage rompu

**Code.** `App/NotchViewModel.swift:149-157` : `islandSize(rockstar:)` passe
`hasActivity: true` en dur (avant : `hasActivity || rockstar`). Le paramètre
`rockstar` n'a plus d'effet, la propriété `hasActivity` (`:127`) n'a plus de
lecteur, et le commentaire des lignes 136-148 décrit un arbitrage que le code
n'implémente plus. `App/CompactView.swift:12-24` a perdu la garde
`if viewModel.hasActivity || rockstar` : le HStack (sélecteur `CL 0 / CX 0`,
« · au repos », quota) est rendu inconditionnellement.

**Mesuré.** `--preview-notch --preview-empty --preview-compact`, mode Manuel,
zéro session : bande noire avec ailes affichant « CL 0 · CX 0 · au repos » à
gauche et « CX 5h 18% » à droite. Sur pilule (sans encoche), idem.

**Arbitrage écrit.** `CLAUDE.md:649` (« ARBITRAGE RENDU — l'îlot au repos ») :
l'invisibilité l'emporte pour tout ce qui est seulement EN ATTENTE, et ne cède
que pour Rockstar seul. Ton README (`README.md:241-243`) redit cette règle
alors que le code fait l'inverse. `check-docs.py` ne peut pas le voir.

**Direction.** Rétablir `hasActivity || rockstar` aux deux endroits. Le
sélecteur compact n'apparaît qu'avec de l'activité ou en Rockstar ; au repos
l'îlot épouse l'encoche. Si Mehdi veut un contrôle permanent dans la barre des
menus, c'est une DÉCISION à lui (section 6), à écrire ensuite dans `CLAUDE.md`
comme nouvel arbitrage, jamais en silence.

**Critère de sortie.** Capture `--preview-notch --preview-empty
--preview-compact` sans Rockstar : rien d'autre que le cache noir de l'encoche
(180×32). Même chose avec `--preview-rockstar` : marqueur visible. Test unitaire
sur `IslandGeometry.compactSize(hasActivity:)` via `islandSize` si tu peux
l'extraire, sinon test du modèle.

## 4. Constats sérieux (P2)

### R03 — Interface — Les boutons REFUSER / AUTORISER de la carte Codex sont sous le pli

`App/CodexInteractionCardView.swift:65-73` : bloc de détails dans un
`ScrollView([.vertical, .horizontal])` de **140 pt fixes** ; boutons `:82-97`.
Dans le `ScrollView` externe de `ExpandedView:39-48`, la carte dépasse la
fenêtre visible. Mesuré (mouvement réduit coché, carte apply_patch de la
recette) : en-tête, outil, cwd, pavé JSON avec ses deux barres, puis « Codex
attend ta décision. » et PLUS RIEN ; les trois boutons sont hors champ, aucune
suite n'est signalée. ⌘Y / ⌘N restent liés (`:108-111`), d'où P2 et non P1.
Même mécanique, moins marquée, pour la carte plan Claude
(`App/InteractionCardView.swift:129-136`, `maxHeight: 150` plus champ de
feedback).

Direction : la carte doit tenir dans le panneau à hauteur fixe. Borne le pavé
par un `maxHeight` calculé comme pour la carte Claude, donne la priorité de
mise en page aux boutons, et supprime le `ScrollView` externe (voir R01 A).
Critère : capture de la carte apply_patch avec REFUSER, AUTORISER et DÉCIDER
DANS CODEX visibles sans défilement.

### R04 — Interface — Le budget de rangées est neutralisé, « +N autres » est inatteignable

`App/ExpandedView.swift:257-261` : `rowBudget = max(3, sessions.count * 2 + 3)`,
toujours supérieur au nombre de rangées, donc `hidden` vaut 0 et l'annonce du
surplus ne se déclenche plus jamais. `IslandRowBudget.rows(bannerShown:codexQuotaShown:)`
(`AtollCore/Sources/AtollCore/IslandRowPlan.swift`) n'a plus d'appelant dans
`App/`. `CLAUDE.md:1158` affirme toujours « BORNÉ par `IslandRowBudget.rows` …
le surplus est ANNONCÉ, jamais tronqué en silence ». Mesuré : vue Claude, 12
sessions, 6 visibles, aucun « +6 autres ». Le plan autorisait « liste à
défilement borné OU accès effectif aux éléments masqués », mais l'arbitrage de
`CLAUDE.md` demande l'annonce. Direction : R01 A. Si le défilement est
conservé après décision de Mehdi, le surplus doit rester annoncé (« +N plus
bas ») et la barre visible. Test : `IslandRowPlan` avec 9 sessions et bannière
→ surplus non nul.

### R05 — Interface — En Rockstar, le marqueur remplace le quota compact

`App/CompactView.swift:55-78` : `rightSide` est `if rockstar { CLAUDE / ◆
ROCKSTAR } else { quota }`. Avant la PR, Rockstar colorait le glyphe et laissait
« 5h 42 % ». Mesuré : pilule Rockstar → « CLAUDE ◆ ROCKSTAR », aucun quota. Le
mode où Mehdi surveille le moins est celui où il perd la seule lecture de quota
sans ouvrir l'îlot. Direction : les deux informations, ou alternance ; à
soumettre à Mehdi (section 6) si la place manque.

### R06 — Analyses — Une capture qui échoue jette la fin de session sans trace, et l'onboarding la provoque

`App/RetrospectiveRunner.swift:345-352` : `AnalysisExecution.capture` lève →
`lastOutcome = …; phase = .idle; scheduleNext(); return`. Aucun
`AttemptRecord`, aucun `finish`, le job a déjà été retiré de la file (`:332`).
`capture` lève dans trois cas : aucun fournisseur (`bothExhausted`,
`codexUnknown`), Codex choisi avec `codexModel` vide (défaut `""`,
`App/LearningSettings.swift:98`), `CodexPaths.validatedHome()` en erreur. Avant
la PR, l'absence de fournisseur produisait un `skip(...)` journalisé : c'est le
trou que le journal de la Phase 12 existait pour fermer.

Enchaînement : `App/OnboardingView.swift:182-186` écrit
`analysisProvider = <fournisseur choisi>` dès que la clé est absente, et elle
est absente chez TOUS les utilisateurs existants (clé nouvelle). `:153-158`
présélectionne CODEX si `codex` est sur le PATH et que les hooks Claude ne sont
pas détectés. Mehdi ouvre « Bienvenue… », choisit CODEX → ses bilans passent
sur Codex sans modèle → chaque fin de session disparaît en silence.

Direction : journaliser un `skip(<raison>)` pour chaque échec de `capture`
(fournisseur absent, modèle manquant, home invalide) ; l'onboarding ne réécrit
jamais le moteur d'analyse d'un utilisateur qui a déjà des tentatives ou
l'apprentissage actif, il PROPOSE ; « Codex sans modèle » devient un refus
explicite affiché dans Réglages › Apprentissage. Tests : capture en échec →
enregistrement présent avec la raison ; onboarding avec `analysisProvider`
absent mais historique existant → clé inchangée.

### R07 — Analyses — Quitter Atoll pendant la préparation brûle un créneau jamais dépensé

`App/AnalysisExecution.swift:180-183` : au chargement, tout enregistrement
`preparing` ou `running` devient `interrupted` avec
`launchedAt = launchedAt ?? preparedAt`, donc compte dans la fenêtre 5 h. Or
`begin()` (`App/RetrospectiveRunner.swift:475`) précède le condensé, le
catalogue Codex (`app-server`, jusqu'à 20 s), la validation du modèle
(`readModels`, jusqu'à 20 s) et la résolution par shell de login : jusqu'à
~45 s sans spawn. `applicationWillTerminate` (`App/AppDelegate.swift:247`) ne
peut rien signaler (pas de pid) et le `defer { AnalysisBudget.finish }` de
`run()` ne joue jamais. En mode « quota inconnu » (un run par fenêtre), la
première rétrospective après relancement est refusée `windowCapReached`. Le
texte des réglages (`App/AnalysisSettingsSection.swift:30`, « Un lancement
impossible ne dépense pas de créneau ») devient faux. Même classe que la
régression v0.16.6.

Direction : un enregistrement `preparing` sans `launchedAt` devient
`interrupted` SANS `launchedAt` (non compté) ; seul `running` compte. Test :
fichier d'état avec un `preparing` → `refusalReason == nil` pour un nouveau job.

### R08 — Sessions — Après une fin, tout événement sans identité est `.closed`, jamais `.unknown`

`AtollCore/Sources/AtollCore/CodexIntegration.swift:289-297` :
`newerProcess = event.process.map { … } ?? false`, puis
`return Applied(turn: newerProcess ? .unknown : .closed)`. Sans identité de
processus (`process == nil`), TOUT événement est `.closed`, `SessionStart`
compris, et `.closed` est le seul verdict qui détruit une carte
(`App/AppDelegate.swift:171-173` → `handBack`). C'est l'inverse de la règle
écrite lignes 229-230 du même fichier et de la leçon v0.17.1 (« le doute et la
certitude n'appellent pas le même geste »).

Quand l'identité manque : le helper ne la pose que si `findCodexTUIAncestor`
réussit (`Shared/ProcessInspector.swift`), ce qui exige un TTY et
`CodexProcessKind.isInteractive`, laquelle rend `false` sur TOUTE option
inconnue (`CodexProcessKind.swift:21`). Donc : pas de TTY, ou n'importe quel
drapeau ajouté par une future version de `codex` → zéro identité sur toute la
session.

Scénario : session S sans identité → `SessionEnd` → `closedSessions[S]`.
`codex resume S` (même `session_id`) → `SessionStart(process: nil)` → `.closed`
→ jamais d'entrée ; `PermissionRequest` → carte détruite, invite native SANS
son (app jointe donc helper muet, événement refusé donc app muette).
`closedSessions` n'expire qu'au-delà de 256 entrées (`:176-179`) : jusqu'au
redémarrage d'Atoll. Le test
`AtollCore/Tests/AtollCoreTests/CodexReliabilityTests.swift:12-21` verrouille ce
comportement avec des événements sans identité : il grave le défaut.

Symptôme frère : `sessions()` (`:472`) garde une entrée sans processus 24 h et
`reconcile` l'ignore (`:525`) : une TUI sans identité tuée sans `SessionEnd`
reste « EN COURS » un jour.

Direction : après une fin, un événement sans identité rend `.unknown` (état
inchangé, carte conservée) ; seule une identité PLUS ANCIENNE ou un
`observedAt < closed.at` justifie `.closed`. Ajouter une expiration temporelle
à `closedSessions`. Adapter le test 12-21, en ajoutant le cas « reprise sans
identité conserve sa carte ».

### R09 — Installation — `hooks.json` est réimposé à chaque lancement contre une édition de l'utilisateur

`AtollCore/Sources/AtollCore/CodexHookInstallation.swift:192-204` :
`migrateIfInstalled` se déclenche dès qu'UN handler Atoll subsiste
(`hasManagedHooks`), puis `apply(install: true)` → `edit(install: true)`
retire tous les handlers Atoll et en ré-appose un sur les 12 événements avec
`timeout`, `async`, `statusMessage` et position à la valeur d'Atoll
(`CodexIntegration.swift`, `edit`, vers 583-620). Scénario : l'utilisateur
supprime à la main le hook Atoll de `Stop` (le synchrone bruyant) ou monte le
timeout de `PermissionRequest` ; au lancement suivant, réécriture silencieuse
(log `info` non persisté) et `hooks.json.atoll-backup` n'est PAS rafraîchi
(`O_EXCL`, `:22-35`). L'ancien `refreshWrapper` exigeait `isInstalled` (les 10
événements) et ne touchait que le lanceur : changement de contrat. Les hooks
étrangers et les clés inconnues sont bien préservés.

Direction : ne réécrire que quand `needsMigration` détecte une définition
gérée OBSOLÈTE (chemin du lanceur, async, timeout périmés), jamais parce qu'un
événement géré est simplement absent ; ou rendre le retrait manuel collant. Au
minimum : journal persistant et sauvegarde datée avant réécriture. Politique à
confirmer par Mehdi (section 6). Test : `hooks.json` avec 11 des 12 handlers →
aucune écriture.

### R10 — Interface — « CONTINUER DANS CODEX » sur toute session Claude, Codex absent ou non

`App/SessionDetailView.swift:26-27` : `canHandOff = session.cwd != nil`, à la
place de `isFailoverEnabled && CodexExecutable.resolveCheap() != nil`. Le bouton
(`:193-199`) apparaît pour toute session Claude avec dossier ; sans `codex`,
le clic (`:291-292`) mène à un échec. Le commentaire `:20-25` justifiait la
stabilité du bouton sous condition d'existence du CLI, pas son affichage
universel. Direction : condition = dossier connu ET exécutable de destination
résolvable (`CodexExecutable.resolveCheap()` / `ClaudeExecutable`), stable dans
le temps. Test sur la condition.

### R11 — Mémoire — 432 enveloppes machine restent au rôle `user`, la migration ne les voit pas

`AtollCore/Sources/AtollCore/CodexTranscriptParser.swift:40-43` et `:148-174` :
le discriminant est l'égalité de la PREMIÈRE LIGNE avec l'un de six tags
(`machineEnvelopePrefixes` : `<environment_context>`, `<skills_instructions>`,
`<user_instructions>`, `<plan_mode>`, `<system-reminder>`,
`<recommended_plugins>`) ou l'en-tête `# AGENTS.md instructions for /`. Le
commentaire `:31-33` le dit « structurel » : il est TEXTUEL.

Mesuré deux fois sur les rollouts de la machine (106 fichiers sous
`~/.codex/sessions` et `archived_sessions`, messages `role: user`) : **432
lignes** commencent par `<task-notification>` (280), `<command-name>` (76),
`<local-command-stdout>` (72) ou `<realtime_delegation>` (4), soit ≈ 35 % du
corpus `user` Codex. Elles viennent de 41 rollouts dont
`session_meta.originator = "Codex Desktop"` ; `payload.originator` n'est jamais
lu (`:62-71`) alors que `docs/CODEX-INTEGRATION.md:8-10` déclare l'application
« non prise en charge » (non prise en charge n'est pas non indexée).

Conséquence : le corpus est partagé, `user` est un rôle injectable par le
recall proactif Claude ; une `<task-notification>` Codex peut être injectée
dans un prompt de Mehdi. C'est la boucle fermée en v0.16.0 côté Claude par
`origin.kind` (structurel), rouverte par l'autre porte. Le défaut préexiste,
mais CETTE PR écrit l'invariant (`docs/CODEX-INTEGRATION.md:45,125-126`) et
calibre la migration `codex-instructions-v1` (`MemoryIndex.swift:314-336`) sur
la même liste. `atoll_content_migrations.last_id` est écrit (`:343`) et lu
nulle part.

Direction : chercher un discriminant STRUCTUREL. Piste mesurée : 1 099 des
1 209 fragments `user` ont un jumeau `event_msg/user_message` ; les 110 sans
jumeau contiennent les transferts « ## My request for Codex: ». À MESURER
avant d'adopter : les 432 enveloppes sont-elles dépourvues de jumeau ? Sinon,
étendre la liste et renommer la migration (`codex-instructions-v2`) pour que
l'hygiène repasse. Conserver les citations humaines (2 messages humains citant
un tag en milieu de texte sont aujourd'hui correctement `user`). Tests :
fixtures pour chaque enveloppe → `instruction` ; texte humain les citant →
`user` ; migration idempotente.

## 5. Constats mineurs (P3), par zone

**Interface**
- `App/CompactView.swift:94-100` : le glyphe « + » d'un skill proposé a disparu du compact (`SkillReviewCenter.shared.pendingCount` plus lu). Documenté en Phase 7c comme l'un des trois signaux.
- `App/CompactView.swift:16,27,32` : deux `Button` dans l'aile compacte, mais le survol déploie l'îlot après `hoverDelay` 0,15 s : le sélecteur compact est pratiquement inatteignable ; libellés « CL »/« CX » expliqués seulement par un `.help`.
- `App/CompactView.swift:84-88` : libellé `"CX \(window.label) NN%"` ; avec le repli `principale`/`secondaire` de `CodexQuota.swift:47-52` → 18 caractères ≈ 100 pt, déborde les ailes small (76) et medium (96). `:86` cherche `buckets.first { $0.id == "codex" }` sans le repli `?? buckets.first` de `CodexQuota.primaryBucket`.
- Pilule small (154 pt utiles) : sélecteur + nom + quota > 154 → `ViewThatFits` supprime le nom de session (mesuré : « CL 1 · CX 1 · CX 5h 18% », aucun nom).
- `App/InteractionCardView.swift` : la carte plan Claude ne nomme pas son agent (« PLAN ─ atoll ») alors que la carte Codex affiche « CODEX » en tête ; en vue Codex avec palette dérivée orange, l'utilisateur doit déduire l'agent de la couleur. Le plan demandait « un texte identifie toujours l'agent ».
- `App/SkillReviewWindow.swift:66-69,100-103` : après une décision, la revue revient à la proposition 1 (`?? proposals.first`) ; `:60` recopie la clé `"codexPaletteID"` en littéral au lieu de `ProviderPreferences.codexPaletteKey`.
- `App/SettingsView.swift:681` et `App/CodexSettingsPane.swift` (~99) instancient tous deux `AnalysisSettingsSection()` : configuration éclatée sur deux onglets. Libellés à dé-jargonner : « Le trust et config.toml restent gérés par Codex », « Dernière mesure du rollout ».
- `App/CodexPreview.swift:30-41` : `.defaultAppStorage(defaults)` écrit tout `@AppStorage` modifié pendant la recette dans `~/Library/Preferences/dev.mehdiguiard.atoll.preview.<pid>.plist` ; `removePersistentDomain` ne tourne qu'au `onDisappear` → plists orphelins sur ⌃C. `allowsHitTesting(false)` retiré : les cartes semées sont cliquables sur le VRAI `InteractionCenter`. La date `receivedAt: 1970` de la carte semée affiche « il y a 29 817 140 min ».

**Analyses et dépenses**
- `App/AnalysisExecution.swift:114-135` vs `:164-199` : `refusalReason` évalué sur un budget non chargé au premier passage (`load()` privé, appelé par `begin()` seulement) → journal `decision: run` puis `failed(preparation)` au lieu de `skip(windowCapReached)`. Aucune dépense, libellé faux.
- `App/NotesCurationService.swift:592-613` : backoff 30 min présent, mais « moins de deux notes » (`:189`) et « corpus trop volumineux » (`:193`, refus ASSUMÉ) rebouclent toutes les 30 min pour toujours ; docstring `:592-597` désormais faux ; un refus de `begin()` (`:207-211`) ne persiste pas `lastOutcome`.
- `App/RetrospectiveRunner.swift:93,139,513` : `resumedDuringPreparation` écrit, jamais lu ; commentaire `:132-139` faux. `:981-993` `recordAttempt`/`refundAttempt` : `loadHistory` rend `runTimestamps: []` (`:977`) → comptabilité fantôme ; le bloc `:842-860` décrit une liste de remboursement qui n'existe plus (la règle est `!runLaunched`).
- `App/CodexRun.swift:39-41,78-80` : `prepare(workingDirectory:)` ignore son paramètre (`--cd` reçoit toujours `workspace.path`) ; l'appelant `RetrospectiveRunner.swift:622` passe `job.snapshot.cwd` pour rien. Comportement correct, signature mensongère.
- `App/CodexRun.swift:48-54,114-128` : `readModels` rend `[]` sur tout échec → « Modèle Codex non validé » alors que le catalogue est illisible ; chaque analyse Codex paie un `codex app-server` (jusqu'à 20 s) verrou tenu.
- `App/RetrospectiveRunner.swift:171-178`, `App/NotesCurationService.swift:170-177`, `App/ClaudeExecutable.swift:79`, `App/CodexExecutable.swift:108` : `guard let identity … else { return }` → si `proc_pidinfo` échoue sur un enfant vivant, plus aucun SIGTERM/SIGKILL (l'ancien code repliait sur `process.terminate()`).
- `AttemptRecord` : pas de champ `model` (Codex : modèle seulement dans `analysis-jobs-v2.json`) ; `quotaFraction` = minorant même quand `unknownReason != nil`, sans la raison.
- Trois fraîcheurs pour la même mesure : `ProviderFailover.swift:50` (900 s), `AnalysisExecution.swift:128,143` (600 s / 300 s codés en dur).
- `AnalysisExecution.swift:164-199` : journal corrompu → `loadError` collant jusqu'au redémarrage, message sans chemin (`~/.atoll/learning/analysis-jobs-v2.json`).
- `RetrospectiveRunner.swift:314-326` : `phase = .waiting(…)` réaffecté chaque seconde jusqu'à 10 min (notification `@Observable` à chaque set).

**Sessions, permissions, helper**
- `App/CodexService.swift:96-99` + `App/AppDelegate.swift:147-151` : `accepts` refuse en silence : ni carte, ni son (helper muet car app jointe), ni journal. Après un changement de home dans les réglages sans réinstallation, tout est refusé et c'est indiscernable d'un helper mort. Un `log.info` au refus.
- `App/CodexService.swift:212-216` + `App/CodexInteractionCenter.swift:183-187` : un `Interrupt` parent ne retire pas les cartes ENFANT (tours distincts, vérifié sur `event-13/16/19` vs `event-21`). Fenêtre bornée par le reaper.
- `CodexIntegration.swift:306-313` : un événement anonyme capturé après le démarrage d'une reprise est attribué à l'incarnation vivante (PLAUSIBLE, rare).
- Après résolution d'une carte épinglée par un tiers, `RequestPresentation.current` retombe sur la plus ancienne et ⌘Y/⌘N visent le nouvel id sans délai de grâce (`RequestPresentation.swift:32-35`). Inhérent au design ; à décider en connaissance de cause.
- `App/CodexInteractionCenter.swift:77-81` : son `decisionNeeded` joué pour une demande que l'îlot ne peut pas afficher (`permission == nil`).
- `CLAUDE.md:48` dit que `CodexSessionScanner` écarte les pids marqués ; l'exclusion vit désormais dans `findCodexTUIAncestor` côté helper. Phrase périmée.

**Chemins destructeurs et fichiers**
- `MemoryIndex.swift` (~350-372, `snapshotBeforeCodexHygiene`) : un snapshot ÉCHOUÉ (SQLITE_FULL, `journal_mode`) laisse un fichier partiel `memory-before-codex-hygiene-<UUID>.sqlite`, sous nom géré, et `MemoryIndexer.swift:652-657` relance à chaque lancement → une copie partielle de 108 Mo par lancement, seul nettoyage `destroyDatabase()`. Retirer la copie incomplète comme le fait `CodexHookInstallation.swift:32`.
- `CodexHookInstallation.swift:22-35` : la « sauvegarde pré-Atoll » peut être créée depuis un fichier déjà géré (première installation sans `hooks.json`, hooks ajoutés ensuite, lancement suivant) ; aucun chemin ne la lit, alors que `CodexSettingsPane.swift:65` la présente comme garantie.
- `LearnedSkillStore.swift:597-604` + `Bridge/main.swift:519` : `installed.json` v1 abîmé (zéro octet, > 2 Mio, slug dupliqué) → `manifestUnreadable` permanent, `uninstall` Claude silencieux (`try?`, préexistant). Impasse que seule une chirurgie de fichier lève.
- `LearnedSkillStore.swift:178-180` : un `.DS_Store` dans `~/.atoll/learning/proposed/<slug>/` interdit l'approbation (« annexes non affichées ») ; aucun « Révéler dans le Finder ».
- `LearnedSkillStore.swift:192-194` : entrée de manifeste dont `managedDirectory` ≠ cible → message « illisible — aucune suppression effectuée » sur une APPROBATION.
- `LearnedSkillStore.swift:121-133` + `Bridge/CodexBridge.swift:112-113` : manifeste haché par home ; après changement de home, `uninstall-codex` ne voit que le nouveau : skills et `atoll-recall` de l'ancien home restent. Assumé, mais silencieux.
- `Bridge/CodexBridge.swift:110` : `atoll-bridge install-codex` tapé par nom nu depuis un terminal grave `<cwd>/atoll-bridge` dans le SKILL.md ; auto-réparé au prochain lancement de l'app.

**Mémoire, skills, catalogues**
- `CodexTranscriptParser.swift:166-169` : une enveloppe non refermée (balise fermante hors ligne seule, `:176-195`) avale la consigne humaine qui suit. 0 cas dans le corpus actuel.
- `TranscriptDigest.swift:291-302` : pour Claude, avec `isError == nil`, le mot « error » redevient un verdict d'échec ; `docs/CODEX-FAILOVER.md:89-90` l'énonce sans restriction. Côté Codex, `.unknown` partout (sain).
- `TranscriptDigest.swift:324-333` + `RetrospectivePrompt.swift:131` : une session d'ORIGINE Codex ne peut jamais fournir de « preuve de succès » ; la matrice ne le dit pas. `:260` conserve tous les `toolResult` Codex, là où Claude ne garde que les échecs.
- `NotesCuration.swift:307-312` : une seule note sans `sources` refuse tout le rangement ; le schéma n'impose aucun `minItems` (`NotesCurationPrompt.swift:222`) et le filtre OpenAI le retirerait.
- `App/SkillReviewCenter.swift:78` : antériorité Codex absente de la fenêtre de revue jusqu'au premier clic d'approbation (`:108-116`).
- `App/SkillReviewCenter.swift:18-23` : `suggestedForArchive` rend `false` inconditionnellement ; `App/SettingsView.swift:799` colore encore dessus ; le retrait n'est documenté que pour Codex.
- `App/SkillDestination.swift:32-35` : un skill tiers cassé (`catalog.errors` non vide) bloque toutes les approbations Codex. Conforme à la doc, à connaître.

**API mortes signalées par `check-docs`**
- `CodexHookInstallation.refreshWrapper` (`:168`) : plus appelé (remplacé par `migrateIfInstalled`) ; `CLAUDE.md:182` le cite encore « au démarrage ».
- `CodexSessionDiscovery.discover` (`:77`) : plus appelé hors tests.
- `IslandRowBudget.rows` : plus appelé dans `App/` (voir R04).

## 6. Décisions réservées à Mehdi

Pose-les lui explicitement avant de coder ce qui en dépend :

1. **Îlot au repos** (R02) : rétablir l'invisibilité, sélecteur visible seulement avec activité ou Rockstar. C'est l'arbitrage écrit ; le changer demande une décision et une ligne dans `CLAUDE.md`.
2. **Liste bornée et surplus annoncé, ou défilement** (R01, R04) : recommandation, revenir au borné (c'est aussi le correctif le plus sûr du P1).
3. **Rockstar en compact** (R05) : marqueur ET quota, ou alternance.
4. **Politique de `hooks.json`** (R09) : Atoll répare ses définitions obsolètes, ou Atoll réimpose ses 12 handlers à chaque lancement.
5. **Onboarding et moteur d'analyse** (R06) : proposer, ne jamais réécrire un réglage existant.

## 7. Hors PR, mais à traiter

- **`AGENTS.md` a été neutralisé le 2026-09-10.** Le fichier non suivi trouvé à la racine (1 590 lignes, daté du 9 septembre) était une copie de `CLAUDE.md` où « Claude » avait été remplacé par « Codex » mécaniquement, et affirmait des choses fausses : « mémoires de projet de Codex (`~/.Codex/projects/*/memory/*.md`) », « si je n'ai plus de quota sur Codex, j'aimerais que ça passe sur mon compte Codex », « Atoll … pour suivre et piloter les sessions Codex », « ne doit JAMAIS pouvoir casser le CLI `Codex` ». Il est remplacé par un court renvoi vers `CLAUDE.md` et vers ce document ; l'original est conservé chez Claude. Si tu retrouves un `AGENTS.md` long, c'est la copie fausse : ne t'y fie pas. Le nouveau fichier n'est pas encore committé ; Mehdi décide s'il l'est.
- **`CLAUDE.md` n'est pas mis à jour par la PR** alors qu'il est la mémoire du projet : lignes 48 (`CodexSessionScanner`), 182 (`refreshWrapper`), 649 (arbitrage au repos, si Mehdi le change), 1158 (budget de rangées). Une section « v0.18 » avec les pièges appris (dont R01 : « un ScrollView au niveau du corps sous l'onde ne se dessine pas ») est attendue AVANT toute release, pas après.
- **README** : le bandeau « Développement du 10 septembre 2026, non publié » et « Dans la version en développement » contredisent la règle éditoriale de `CLAUDE.md` (vitrine, pas journal de bord). À retirer à la release, avec les mentions correspondantes.
- **`docs/reviews.json`** : ton entrée `sweep` du 2026-09-10 est honnête ; ajoute une entrée pour cette passe de correctifs, `sweep` aussi, sauf lecture intégrale réelle.

## 8. Vérifié sain : ne le refais pas

- Fail-open du helper : abstention `ATOLL_RETROSPECTIVE` avant lecture de stdin (`Bridge/CodexBridge.swift:28-29`), stdout réservé à une décision décodée par allowlist (`:79-83`), `exit(0)` inconditionnel (`Bridge/main.swift:822-824`), `LOCAL_PEERCRED` conservé, deadline helper 570 s < timeout 600 s.
- `handBack` libère le descripteur (`App/BridgeServer.swift:82-88`) ; sémantique `.unknown` / `.closed` respectée hors R08 ; `Stop` anonyme → `.named`/`.unnamed` ; nettoyage enfant par (agent, tour, identité) ; scans anciens refusés (`adopt` contre `closedSessions`).
- Identité `(pid, startTime)` partout où un signal part (`ProcessIdentity.send`, `:38-41`) ; le reaper sonde sans signaler.
- Palette : `monoCyan` ne diffère de `monoOrange` que par l'accent ; `Palette.Variant.dim` intact ; aucun chemin de hook ne réécrit la préférence de vue ; préférence stockée d'un `@Observable` (redessin OK) ; défaut `.claude` pour un utilisateur existant ; ASCII ≤ 79 ; `DENY ⌘N` / `ALLOW ⌘Y` intacts ; aucun nouveau `if` sur le chemin compact↔déployé ; pied de quota HORS du défilement.
- Dépenses : remboursement structurel (un `Record` sans `launchedAt` ne compte pas, `launched()` seulement après `process.run()`), plafond PAR fournisseur, failover OFF par défaut et jamais de retombée silencieuse sur Claude, garde de génération après chaque await jusqu'à l'application du rapport (harnais + sabotage), `standardInput = .nullDevice`, `ATOLL_RETROSPECTIVE=1`, `CODEX_HOME` réimposé après le profil, chemins absolus vérifiés, `PluginInventory.install` jamais via Codex, aucun écrivain de `enabledPlugins`.
- Chemins destructeurs : la migration mémoire ne touche pas `user_version` (une app v0.17.2 ne détruira pas la base au downgrade), snapshot `sqlite3_backup` contrôlé avant transaction, balayage des sauvegardes strict (préfixe + UUID) et seulement sur destruction explicite ; `LearnedSkillStore` : suppressions derrière `managedDirectory` (slug validé, destination égale), propositions derrière `owns()`, manifeste v2 séparé, `installed.json` jamais réécrit ; `hooks.json` : zéro octet ≠ absent, hooks étrangers préservés, backup `O_EXCL`, idempotence par octets, `config.toml` jamais écrit ; `CodexRecallSkill` : gardes symlink, reçu par hash, idempotent.
- Passation : chemin absolu, exécutable résolu, `.opened` après le résultat réel, `defer`, quoting POSIX, test distinguant `./contexte.md` du chemin absolu.
- `CodexReadClient` : allowlist sans thread ni modèle, watchdog 20 s, `CODEX_HOME` explicite, marqueur interne, plafond 8 Mio, `codex` absent → `.unavailable`.
- Affirmations des docs tenues : 12 définitions, `config.toml` non écrit, recall proactif Codex désactivé, failover OFF, Rockstar absent du chemin Codex, manifeste v2, `--ignore-user-config` sans promesse d'isolation totale, stdin fermé partout, sources de notes résolubles jusque dans les archives, annexes nouvelles refusées.

## 9. Non relu par cette passe

`PluginInventory` hors `search`/`run`/`install` ; `CodexExecPlan.openAISchema` ;
`CodexReadClient` après la ligne 100 ; `CodexAccountClient` ; `NotesCurationPlanner`
(archives, `untraceableSources`) ; `RetrospectiveRunner` lignes 180-300 et triggers
`retroCodex*` ; `CodexService` (cadence du quota, `changeHome`) ; `NotchWindowController`
(moniteur de clic contre boutons compacts) ; `CodexHandoffService` chemin « codex
introuvable » ; `CodexSessionMetadata`, `CodexHookDiagnostics`, `CodexPermissionRequest`
(parseur) ; `CodexPermissionDecision.decode` au-delà de l'allowlist ;
`CodexPaths.validatedHome()` contre `homeURL` ; `SkillReviewCenter.target(for:)` ;
`LearningArtifacts` ; `Scripts/runtime-tests/` ; aucune capture des Réglages ni de
l'onboarding ; aucun film des transitions ; ni clavier ni VoiceOver.

## 10. Ordre de travail proposé et critères de sortie

1. R01 puis R04 puis R03 (un seul chantier : le corps du panneau), captures sous l'onde.
2. R02 dès la réponse de Mehdi ; en attendant, rétablir l'arbitrage écrit.
3. R06 et R07 (journal et créneaux), avec tests par sabotage.
4. R08 (sans identité → `.unknown`), R09 (politique validée), R10.
5. R11 après la mesure du jumeau `event_msg`.
6. P3 par zone, en commençant par les API mortes et les phrases périmées.
7. Passe docs : `CLAUDE.md`, `README.md`, `docs/HANDOFF.md`, `docs/reviews.json`,
   `docs/IMPLEMENTATION-2026-09-10-codex-claude.md` (ajouter cette passe et ses
   preuves), puis `Scripts/check-docs.py` (avec tests) et `Scripts/review-map.py`.

Sortie attendue : suite Core verte, harnais et sabotages verts, recettes CLI
vertes, build Debug ET Release, et un jeu de captures sous l'onde (effets
actifs, mouvement réduit décoché) : liste 12 sessions, carte Claude, carte
Codex avec ses trois boutons, détail de session, compact au repos avec encoche
(rien de visible sans Rockstar), compact avec activité, Rockstar avec marqueur,
mode clair. Rien n'est publié, la copie stable n'est pas remplacée, et le
rapport dit ce qui reste non vérifié.
