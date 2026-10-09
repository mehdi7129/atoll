# CLAUDE.md — instructions projet Atoll

Ce fichier porte les règles actives. Lire ensuite [docs/HANDOFF.md](docs/HANDOFF.md)
pour l'état du travail, les preuves et les limites. L'[archive intégrale du
2026-10-08](docs/archive/CLAUDE-2026-10-08.md) conserve les incidents, versions et
arbitrages détaillés ; elle n'est pas un état courant.

Version publiée : **v0.18.5**, build 40. La [fiche de livraison](docs/releases/0.18.5.json)
distingue les artefacts distribués du code encore en développement.

## Produit et façon de travailler

- Atoll est une app macOS native Swift/SwiftUI, esthétique ASCII, autour du notch,
  pour suivre et piloter les sessions Claude Code et Codex. Licence GPL-3.0-or-later.
- Communiquer en français ; identifiants en anglais, commentaires en français.
- Lire [la vision](docs/VISION-2026-08.md) avant toute fonction nouvelle : soustraire
  avant d'ajouter. Pas de refonte générale ni de framework de services sans besoin
  concret. Préserver les usages, seuils, cadences, préférences et modèles existants
  hors changement explicitement demandé.
- Les deux modes sont **Manuel et Rockstar**, ce dernier exclusivement Claude.
  Le troisième mode « intelligent » a été écarté. La mémoire est commune aux
  fournisseurs ; événements, décisions, autorisations et destinations restent distincts.
- Îlot invisible au repos, sauf Rockstar ; compact ASCII, palette, onde, huit
  onglets et liste bornée « +N autres » restent les contrats. Le cockpit est retiré.
- Chaque correctif porte un test de non-régression **vérifié par sabotage causal** :
  réintroduire le défaut, compiler, constater l'échec à l'exécution de l'oracle
  attendu. Une compilation cassée n'est pas une détection. Revoir le correctif lui-même.
- Distinguer code relu, tests, app construite, aperçu, CLI authentifié et release.
  Un test simulé ne prouve pas une intégration réelle ; un build ne met pas à jour
  l'app installée. Ne pas refaire une campagne authentifiée déjà validée sans motif.
- Vérifier la branche, l'arbre et les autres travaux avant modification. Employer
  un worktree isolé si nécessaire. Pas de `rm -rf` : conserver les données utilisateur,
  utiliser la corbeille pour les artefacts identifiés. Les fixtures privées jetables
  peuvent être nettoyées par leur harness.
- Ne jamais remplacer `~/Applications/Atoll.app`. Aucun lancement de deux Atoll
  normaux. Rien ne se publie sans Mehdi ; respecter les autorisations déjà données.

## Intégrité des hooks et des données

1. **Fail-open absolu** du helper : rien d'installé par Atoll ne peut casser ni
   ralentir les CLI. Timeouts bornés, `exit 0` et abstention sur erreur, stdout
   réservé au protocole. Préserver le nominal autant que les pannes.
2. **`~/.claude/settings.json` est sacré** : merge chirurgical des entrées Atoll,
   backup avant première écriture, hooks tiers conservés, symlinks respectés,
   refus propre d'un fichier invalide ou illisible. Ne pas confondre absent et inconnu.
3. Trois interventions hors entrées Atoll, chacune avec original enregistré
   **avant** écriture et restitution à la désinstallation :
   - Rockstar suspend `permissions.deny` dans `rockstar-parked-deny.json`, à la
     demande de l'utilisateur, avec réconciliation au retour manuel et au démarrage.
   - Les sons reprennent les hooks `afplay` explicitement montrés et adoptés,
     dans `parked-sound-hooks.json`, avec restitution réversible.
   - La statusline chaîne la commande d'origine via un tee-wrapper ; elle ne la
     suspend pas. Respecter tout `refreshInterval` utilisateur existant.
   Toute autre intervention se discute avant implémentation. Ne jamais écrire
   directement dans `enabledPlugins` : les commandes plugins passent par le CLI.
4. Pour Codex : sauvegarder `hooks.json`, préserver les hooks étrangers et les
   personnalisations ; **ne jamais écrire `config.toml`**. La migration au démarrage
   ne réinstalle pas les événements retirés. « Réparer » reste le geste explicite.
   Voir [l'intégration](docs/CODEX-INTEGRATION.md) et [la bascule](docs/CODEX-FAILOVER.md).
5. Tout fichier généré hors du bundle doit avoir un chemin d'actualisation et une
   vérification de l'artefact réellement installé. Le lanceur de hooks est un
   superviseur : conserver le stdin via `exec 3<&0`, `<&3 &`, puis `wait $! 2>/dev/null`.
   Un simple `exec` ou un `&` sans cette redirection casse un des contrats.
6. Les décisions se corrèlent à leur demande. Un outil de même nom, même candidat
   unique restant, ne prouve pas quelle permission vient de finir. Une clôture
   inconnue conserve la carte ; une clôture certaine peut l'annuler. Un EOF ne
   prouve pas la mort du helper, qui fait normalement `shutdown(SHUT_WR)`.
7. Un PID seul n'est pas une identité : vérifier PID et instant de naissance avant
   **chaque** signal. Les drains stdout/stderr, la résolution et le processus
   doivent tous être bornés. Ne jamais bloquer MainActor avec leur attente.
8. Apprentissage : conserver les opt-in et budgets communs. `preparing` n'est pas
   une dépense ; `launching` est persisté juste avant le spawn, sans `await` entre
   autorisation et lancement. Les résultats payés sont sauvegardés avant livraison,
   puis repris localement sans nouveau modèle. Aucun effacement avant archive
   confirmée, aucune purge sur accès incertain, aucune erreur déguisée en succès.
9. Le JSONL est un flux : n'acquitter que les lignes complètes réellement traitées.
   Markdown est un document remplaçable : contenu vide, contenu inchangé et erreur
   de lecture ont des sens distincts. L'historique de recherche survit au ménage des
   transcripts. Les formats internes CLI sont parsés défensivement.

## Architecture et pièges OS

- `App/` : fenêtres, vues, services système et façades observables.
- `AtollCore/` : contrats et logique testables sans AppKit, avec leurs tests.
- `Bridge/` : helper embarqué, hooks, transport et commandes d'installation.
- `Shared/` : petit socle utilisant les API système partagé par app et helper.
- [docs/research](docs/research) : contrats étudiés et pièges des intégrations ;
  vérifier les versions avant d'en déduire un comportement actuel.

macOS 14+, Swift 5 language mode, sandbox OFF, Hardened Runtime ON. Pas d'Electron,
dépendance lourde ou télémétrie. Attribution des composants réutilisés ; ne pas
embarquer SF Mono ni Berkeley Mono.

Avec l'installeur natif Claude, `proc_name` peut être un numéro de version :
reconnaître le chemin d'exécutable avec `ProcessInspector.isClaudeProcess`.
Les sessions de flotte ne se jugent pas sur le PID de leur daemon. Respecter les
autorités existantes de découverte et de liveness.

Sockets Unix BSD avec DispatchSource et fd non bloquants : ne pas remplacer par
NWListener (connexions acceptées mais non livrées observées sous macOS 26).
Conserver les contrôles de propriétaire/peer et les permissions des sockets.

Résoudre les CLI en chemin absolu. Un shell login non interactif ne lit pas
`.zshrc` ; tester l'environnement d'une app GUI, pas seulement celui du terminal.
Conserver le profil de login nécessaire à l'auth. `codex exec` lit stdin même avec
un prompt en argument : conserver `.nullDevice`. Les schémas guident le modèle ;
les résultats restent revalidés en Swift avant toute écriture.

AppleScript de jump-back s'exécute dans l'app, hors MainActor, pour l'attribution
TCC. Le helper ne demande pas d'autorisation d'automatisation. Un succès doit
annoncer seulement la granularité prouvée, avec repli d'activation sans TCC.

## Build, validation et aperçu

DerivedData et les worktrees de validation restent hors du Bureau iCloud.
Ne **jamais lancer le produit de build** : la provenance macOS peut ensuite casser
sa signature. Utiliser `Scripts/prepare-preview.py`, qui fait le `ditto`, attribue
un bundle ID privé et marque `AtollPreviewOnly`. Ainsi l'aperçu reste protégé même
si un outil le rouvre sans arguments. Utiliser un chemin neuf directement sous
`/private/tmp`, et garder l'app stable intacte.

```sh
xcodegen generate
ATOLL_DD="$HOME/Library/Caches/atoll-validation-dd"
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -derivedDataPath "$ATOLL_DD" build
ATOLL_PREVIEW_APP="/private/tmp/Atoll-preview-$(uuidgen).app"
python3 Scripts/prepare-preview.py "$ATOLL_DD/Build/Products/Debug/Atoll.app" "$ATOLL_PREVIEW_APP"
open "$ATOLL_PREVIEW_APP"
swift test --package-path AtollCore
python3 Scripts/check-docs.py --no-tests
python3 Scripts/review-map.py
```

XcodeGen produit le projet Xcode ; ne pas le versionner. Xcode 26 exige le composant
Metal Toolchain pour `App/ExpansionRipple.metal`. Employer `/usr/bin/xattr` : un shim
local homonyme peut être incorrect.

Après changement UI, **regarder une capture** de la copie protégée, ciblée par son
CGWindowID. Pour une animation, filmer et analyser les frames. Un moniteur global
de clic peut replier l'îlot avant la capture ; `expand` l'épingle. Sans second écran,
capturer la fenêtre, pas le premier écran par défaut. Les échecs de `screencapture`
peuvent provenir de la permission d'enregistrement d'écran ; ne pas contourner TCC.
Méthode détaillée : `codex/MESSAGE-DE-CLAUDE.md`, section 2.

Les groupes sous `layerEffect` doivent rester dessinables : ScrollView, champs
AppKit et cartes ont déjà disparu sous l'onde. La compilation seule ne suffit pas.
Pour le son et le focus terminal, distinguer simulation, écoute et recette réelle.

Logs : `/usr/bin/log stream --predicate 'subsystem == "dev.mehdiguiard.atoll"' --level debug`.
Les niveaux info/debug ne sont pas persistés. État de diagnostic dans
`~/Library/Application Support/Atoll/state.json`.

## Documentation, revue et distribution

Lancer `Scripts/check-docs.py --no-tests` **avant de croire un document et après
édition**. Le script confronte les faits vérifiables au code ; intentions et
arbitrages se datent et se relisent. Ne pas recopier un ancien nombre de tests ou
de fichiers relus comme s'il décrivait le présent.

`Scripts/review-map.py` indique les priorités par couverture documentée et dérive.
`docs/reviews.json` n'enregistre que les relectures effectivement attestées par un
rapport. Préserver ses entrées. Un graphe de dépendances n'est pas une preuve de
correction, et une lecture de fichier n'est pas automatiquement une revue.

Le README reste une vitrine pour quelqu'un qui découvre Atoll : savoir, se souvenir,
appeler ; détails secondaires repliés, partie visible autour de 130 lignes. Pas de
journal de phases, chiffres internes ou changelog dans la présentation. ASCII et
captures doivent correspondre aux libellés actuels. Ne pas référencer une image
absente ; ne publier aucun projet client ni secret dans les preuves.

À chaque release, augmenter **MARKETING_VERSION et CURRENT_PROJECT_VERSION**.
Préserver les archives Sparkle déjà référencées. Le générateur d'appcast peut
repointer les anciennes entrées vers le nouveau tag : vérifier toutes les URL,
publier les assets avant le nouvel appcast, puis contrôler le flux réellement servi.
Voir [RELEASE-VALIDATION](docs/RELEASE-VALIDATION.md) pour architectures, signatures
imbriquées, notarisation, archive/delta et octets publics. Ne pas remplacer le Debug
quotidien ni l'app installée pour effectuer ces contrôles.

## Triggers et recettes sensibles

Triggers debug (`notifyutil -p dev.mehdiguiard.atoll.debug.<x>`) — liste exhaustive,
tenue à jour avec `App/AppDelegate.swift` :
- TOUJOURS enregistrés (release comprise, aucun pouvoir de décision) :
  `expand` / `compact` (étend+épingle / replie l'îlot).
- `#if DEBUG` UNIQUEMENT (ils décident, dépensent du quota ou écrivent) :
  `allow` / `deny` (1re carte), `select` (1re session), `jump` (jump-back),
  `settings`, `onboarding`, `retro` (rétrospective sur la dernière session terminée),
  `retroBig` (rétrospective sur le PLUS GROS transcript du projet, sans passer par
  le gate — ~0,87 $ le run ; c'est LUI qui a prouvé la boucle d'apprentissage),
  `retroCodex` (LE MÊME run, mais payé par l'abonnement Codex : prouve le chemin
  `codex exec` → schéma → fichier de sortie → revalidation, sans attendre que le
  quota Claude soit réellement épuisé),
  `retroCodexRollout` (bilan sur le plus gros ROLLOUT Codex : prouve l'autre
  moitié — rollout → parseur Codex → condensé → notes —, sans attendre qu'une
  vraie session Codex longue se termine),
  `codexAllow` / `codexDeny` / `codexHandBack` (résolvent la première carte
  d'autorisation CODEX par les mêmes chemins que les boutons — pendant de
  `allow`/`deny`, et seul moyen de valider la matrice de fautes sans souris),
  `curation` (curation des notes),
  `plugins` (inventaire réel via `claude plugin list --json`, catégorie de log
  `plugins`) / `pluginSearch` (recherche d'un plugin — consomme du quota),
  `seedSkill` / `skillReview` / `approveSkill` / `rejectSkill` (curation des skills),
  `seedPlugins` (inventaire de plugins factice, pour travailler l'UI sans réseau),
  `adoptSounds` / `restoreSounds` (reprise et restitution des hooks sonores —
  ÉCRIVENT dans settings.json), `playSounds` (écoute des deux sons),
  (`launcher` et `taskDone` retirés avec le cockpit, 2026-08-03).

Debug des interactions : les triggers de décision, génération et écriture ne
sont utilisables que dans le périmètre autorisé. Les fixtures offline et aperçus
protégés n'exécutent aucun CLI génératif authentifié ni écriture de préférences réelles.

Deux hooks peuvent bloquer : `PermissionRequest` (timeout 86400) et
`UserPromptSubmit` quand le recall proactif est activé (timeout 5). Le reste est
async ; une sortie de hook async n'est pas lue et ne peut injecter des souvenirs.
La liste effective vit dans `HookSettingsEditor.managedEvents`.
