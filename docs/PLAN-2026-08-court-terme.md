# PLAN — court terme (v0.16.0)

> Rédigé le 2026-08-03 après cartographie des cinq surfaces par agents, et
> vérification à la main de chaque chiffre. **À APPROUVER avant exécution.**
> Cadre : `docs/VISION-2026-08.md` — Atoll SAIT, se SOUVIENT, APPELLE.

Quatre chantiers, dans cet ordre. **Chacun est livrable et vérifiable seul.**
Les deux premiers AJOUTENT de la valeur, les deux derniers RETIRENT du passif.

---

## Lot 1 — La mémoire répond enfin (½ journée)

### Le défaut, mesuré

L'index contient **8 135 messages « drone »**, 2 128 « Houdini », 2 158
« Blender ». Et pourtant :

```
atoll-bridge recall "drone Houdini trajectoire"   →   Aucun résultat
```

Le défaut n'est PAS dans `MemoryIndex` : il est dans son **appel**.
`search(…)` a `mode: MatchMode = .all` par défaut (`MemoryIndex.swift:356`) et
`Bridge/Recall.swift:60-62` ne passe aucun mode. Les trois mots doivent donc
tenir dans **un seul fragment** (404 caractères en moyenne). Ligne 527 de
`sanitizedMatchQuery`, un seul caractère de séparation — l'espace ou ` OR ` —
sépare le mutisme de la réponse.

Le code **sait déjà** : le commentaire de `MatchMode` dit noir sur blanc qu'avec
plusieurs mots « le AND ne trouve JAMAIS rien ». La leçon a été appliquée au
recall proactif (`ProactiveRecallHook.swift:78`, `mode: .any`) et **jamais à la
recherche manuelle**.

### Le correctif

**Ne pas toucher à `search`** ni à ses 20 tests ni au recall proactif. Ajouter :

```
searchRelaxing(…) -> (hits, relaxed)
    hits = search(…, mode: .all)
    si hits est VIDE  →  hits = search(…, mode: .any) ; relaxed = true
    trier par COUVERTURE (nombre de termes trouvés) puis pertinence+récence
```

Repli **strictement sur zéro**, jamais sur « peu de résultats » : `recall
"notarisation appcast"` rend aujourd'hui 3 résultats exacts, et les diluer avec
5 extraits ne contenant qu'« appcast » dégraderait ce qui marche.

### Le risque, et les trois ceintures

**Après le correctif, `recall` ne rendra presque plus jamais « Aucun résultat ».**
Mesuré : un OR de 8 mots courants apparie **9 883 messages** ; de mots très
fréquents, **22 366** — 64 % de la base. Il y a *toujours* de quoi remplir huit
lignes. Le danger est que Claude lise ce bruit comme un souvenir et affirme
« on avait décidé X ».

Trois ceintures, **aucune optionnelle** :
1. bandeau explicite en tête de sortie — « recherche ÉLARGIE : aucun message ne
   contient tous les mots, voici ceux qui en contiennent au moins un » —
   dans `printText` ET champ `"relaxed": true` dans `printJSON` (sinon la sortie
   `--json` ment par omission) ;
2. tri par couverture, qui met en tête ce qui couvre le plus de termes ;
3. une ligne dans `RecallSkill.markdown` qui apprend à Claude à lire le bandeau.

### Performance

Aucun risque : `.any` coûte **12 ms** sur la requête réelle, 49-76 ms dans le
cas pathologique mesuré (22 366 messages appariés), contre 21 ms pour le CLI
entier aujourd'hui.

### Recette

- `recall "drone Houdini trajectoire"` rend des résultats du domaine drone,
  avec le bandeau « recherche élargie » ;
- `recall "notarisation appcast"` rend **exactement** les mêmes 3 résultats
  qu'aujourd'hui, **sans** bandeau ;
- nouveau test : le drapeau `relaxed` est FAUX quand le AND a répondu.

---

## Lot 2 — La mémoire cesse d'avaler le bruit (½ journée)

### Le défaut, mesuré

L'index contient **134 notifications de tâches** indexées comme messages
`user` — 748 070 caractères, soit **17 % de tout le corpus `user`**. Or il n'y a
que **792 messages `user`** dans l'index contre 12 990 `tool` : ce sont les plus
rares et les plus précieux (ils portent l'intention).

La boucle est fermée : **15 des 84 injections proactives observées répondent à
une notification, avec des extraits qui sont eux-mêmes des notifications.**

### Le correctif

Un seul point d'entrée : `TranscriptLineParser.userFragments` (ligne 80).
Discriminant **structurel**, vérifié **127/127 sur 12 versions du CLI**
(2.1.173 → 2.1.220) : `origin.kind == "task-notification"`.

> **NE PAS** élargir à `promptSource == "system"` : sur 1 513 transcripts, 129
> lignes le portent, dont **2 sont de vraies instructions**. Le filtre textuel
> « contient task » est également refusé — cette conversation elle-même en
> serait victime.

Il faut **les deux bouts**, sinon le correctif est un mensonge :
- **filtrer à l'indexation** — mais ce n'est PAS rétroactif : `files.offset` ne
  recule jamais, aucun transcript déjà lu n'est relu ;
- **purger les 134 déjà en base** (mesuré : 55 ms, `integrity-check` FTS vert).

### Le piège à ne pas commettre

**Ne JAMAIS déclencher la purge en incrémentant `schemaVersion`** : toute valeur
différente fait passer `migrateIfNeeded` par `recreateFromScratch`, qui supprime
la base. Or **548 messages appartiennent à 5 fichiers dont le JSONL n'existe
plus sur disque** — ils seraient perdus définitivement, ce que `markMissing` a
justement été écrit pour empêcher. Le compteur d'hygiène va dans
`PRAGMA application_id` (vérifié libre : 0), jamais dans `user_version`.

### Recette

- `SELECT COUNT(*) … LIKE '%<task-notification>%'` → **0** ;
- `storedSchemaVersion()` vaut toujours **2** après la purge ;
- 20 injections proactives consécutives sans un seul `tool-use-id` ;
- durcir `ProactiveRecall.shouldRecall` : ne rien injecter quand le prompt EST
  lui-même une notification.

---

## Lot 3 — Retirer le niveau « Auto » (½ journée)

### Pourquoi

`claude auto-mode` est first-party, actif par défaut, avec **35,5 Ko** de
politique `allow`/`soft_deny`/`hard_deny` et une commande qui fait critiquer vos
propres règles par une IA. Notre `AutoAcceptPolicy` est une allowlist Swift
corrigée **deux fois** pour des contournements, dont un critique
(`python3 -c'code'` collé). On ne peut pas gagner cette course, et on n'a pas à
la courir. Restent **Manuel** et **Rockstar**.

### Sûreté, vérifiée

Les **7 sites** qui décodent `autonomyLevel` retombent tous sur `.manual`
(`?? .manual`), **jamais** sur Rockstar. Un réglage `auto` orphelin rétrograde
donc vers le niveau le plus prudent. Le parking Rockstar est **totalement
indépendant** d'Auto (vérifié en vrai : 6 règles parquées, `permissions.deny`
vide dans ton settings.json).

### L'ordre est impératif

`ShellSplitter` — le découpage de commandes shell — est **partagé** avec
`SoundHookEditor`, et **n'a aucun test propre**. Les 22 tests
d'`AutoAcceptPolicy` sont sa seule couverture de `||` et de
`splitOnNewlines: false`.

> **Écrire `ShellSplitterTests` AVANT de supprimer `AutoAcceptPolicyTests`.**
> Sinon on retire, dans le même geste, la seule preuve qu'un composant encore
> utilisé fonctionne.

Ne pas supprimer `migrateAutonomyIfNeeded()` : sa branche `rockstar` et le
nettoyage des anciennes clés doivent survivre, sinon un utilisateur d'avant le
réglage à trois niveaux perd son Rockstar sans le savoir.

Ajouter `AutonomyLevel.resolve(_:)` — la logique de repli est aujourd'hui
recopiée à 5 endroits sans un seul test.

### Recette

- `resolve("auto") == .manual`, `resolve("rockstar") == .rockstar`,
  `allCases.count == 2` ;
- `ShellSplitterTests` couvre `||`, `&`, `;`, `|`, `2>&1`, `&>` et
  `splitOnNewlines: false` **avant** la suppression ;
- Rockstar toujours opérationnel : parking et restitution vérifiés en vrai.

---

## Lot 4 — Retirer le cockpit (1 journée)

### Pourquoi

`~/.atoll/launched-tasks.json` = `{"tasks":[]}` — la fenêtre ⌘N n'a **jamais**
servi. Et `FleetLauncher.swift:80` lance `claude --bg` **sans `-w/--worktree`**,
alors que le drapeau existe : une tâche écrirait directement dans ton arbre de
travail pendant que tu édites, en Rockstar, sans permission.

### LE PIÈGE — à lire deux fois

`App/SessionStore.swift:418` joue `SoundCenter.shared.play(.taskCompleted)`
**dans le même bloc `if event.kind == .stop`** que l'appel au notifier
(413-415). Retirer le bloc, c'est **recasser exactement ce que la v0.15.1 vient
de réparer**. La ligne 418 et son commentaire RESTENT.

### Deux fichiers ne se suppriment pas

- `App/FleetLauncher.swift` porte le **bouton ARRÊTER** d'une session
  (`SessionDetailView:81,85`) — on élague `launch`, on garde `stop`.
- `AtollCore/FleetLaunch.swift` porte **`shellQuote`**, utilisé par la
  rétrospective, l'inventaire de plugins et la curation — on garde `shellQuote`
  et son test, on retire le reste.

### L'arbitrage que la cartographie m'a imposé

`docs/VISION-2026-08.md` classe le cockpit en « retirer » et la notification de
fin en « investir » — **or le premier est la seule source de la seconde**.
`TaskCompletionNotifier.register` n'a que deux appelants : `FleetLauncher:139`
et un `#if DEBUG`.

**Décision proposée** : on retire la machinerie propre au lanceur
(`LaunchedTask`, `LaunchedTaskLog`, `TaskCompletionNotifier`) et **on garde
`TaskCompletion`** — le résumeur markdown → une ligne, pur et couvert par 22
tests, dont `HookEvent` dépend déjà (`inputCap`) et dont la recette de fin aura
besoin. On perd donc l'annonce macOS de fin de tâche — **qui n'a jamais sonné
une seule fois** — et la recette la rebâtira sur une source réelle.

Ordre imposé : éditer `HookEvent.lastAssistantMessage` **avant ou avec** toute
suppression, sinon AtollCore — et donc le helper — ne compile plus.

### Recette

- le son de fin de tâche sonne toujours, app ouverte **et** app fermée
  (rejouer le test de la v0.15.1) ;
- le bouton ARRÊTER d'une session fonctionne (un `claude stop` réel) ;
- `xcodegen generate` puis build **0 warning** ;
- documents mis à jour : CLAUDE.md (phases, triggers debug `launcher` et
  `taskDone`, bloc Phase 9 et Phase 13a), README, PLAN.md, docs/HANDOFF.md,
  et `docs/ROADMAP-13-rendre-la-main.md` marqué PÉRIMÉ avec sa date plutôt que
  réécrit — c'est le journal d'une phase livrée.

---

## Ordre, coût, livraison

| Lot | Nature | Coût | Livrable seul |
|---|---|---|---|
| 1 · mémoire répond | ajout | ½ j | oui |
| 2 · mémoire propre | ajout + purge | ½ j | oui |
| 3 · retrait Auto | retrait | ½ j | oui |
| 4 · retrait cockpit | retrait | 1 j | oui |

**Les lots 1 et 2 d'abord** : ce sont eux qui rendent service, sur les 49
projets, dès le premier jour. Les retraits suivent — ils ne servent l'utilisateur
qu'indirectement (moins de surface, moins de risque, moins à maintenir).

Puis : revue adversariale du diff complet (règle du projet — une correction
mérite sa propre revue), documents, et **release v0.16.0**.

## Ce que ce plan NE fait pas

- pas de recette de fin de tâche (moyen terme) ;
- pas d'opérateurs nommés (moyen terme) ;
- pas de Mac mini, pas de multi-fournisseur, pas de routeur (écartés, cf. VISION §7) ;
- **on ne touche ni à l'îlot, ni à l'ASCII, ni au verre, ni au quota, ni au
  jump-back, ni à Rockstar, ni aux sons.** Le projet n'est pas dénaturé : il est
  débarrassé de ce qui n'a jamais été à lui.
