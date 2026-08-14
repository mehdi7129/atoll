# HANDOFF — reprise du développement d'Atoll

> Document de continuité pour reprendre le dev après un compactage de conversation.
> **À lire en premier** avec `CLAUDE.md` (règles) et `PLAN.md` (plan produit).
> Dernière mise à jour : **2026-08-14**. **AUDIT COMPLET** —
> `docs/AUDIT-2026-08-14.md` : dix-huit défauts corrigés, six API mortes retirées,
> aucune fonction ajoutée, 691 tests verts, build sans warning. À savoir en
> reprenant :
>
> 1. **Le commit d'audit du 12 août n'était PAS dans `main`** — il vivait dans un
>    worktree (`session/stoic-finch-xf8q`). Fusionné en fast-forward au début de
>    cette session. Vérifier `git worktree list` avant de conclure que le dépôt est
>    propre : le HANDOFF du 11 août disait « aucun worktree », et c'était vrai ce
>    jour-là.
> 2. **Trois chemins destructeurs fermés** : la base mémoire se détruisait elle-même
>    en deux passages de 30 s ; les suppressions de skills suivaient un `dirName` non
>    validé (traversée de chemin PROUVÉE par exécution) ; la bascule des notes n'avait
>    aucune reprise après crash et le run suivant effaçait la dernière copie.
> 3. **Le son ne tenait plus sa promesse de la v0.15.1** : l'interrupteur général
>    n'appelait pas le setter qui republie `~/.atoll/sound-settings.json`, donc
>    « activer le son puis quitter Atoll » laissait le helper muet. Le setter existait,
>    son seul appelant était un trigger de debug — même motif que `byCoverage` et
>    `Recall.swift` : le savoir était dans le code, pas dans l'appel.
> 4. **Trois affirmations du dépôt étaient fausses** et sont corrigées : le README
>    annonçait « moins de 50 Mo de RAM » (mesuré : **66 Mo**, pic 116) ; la « perte en
>    cascade » de la statusline racontée le 12 août est inatteignable ; la
>    justification écrite pour faire refuser `park` est fausse deux fois.
> 5. **`dist/updates/` avait divergé du publié** (réparé) : le dossier persistant dont
>    dépend `generate_appcast` s'arrêtait à la 0.16.0, alors que 0.16.1 et 0.16.2 sont
>    en ligne. La prochaine release suivant la procédure aurait produit un appcast
>    amputé, sans delta pour les utilisateurs en 0.16.2. Les deux archives ont été
>    retéléchargées depuis GitHub et vérifiées (builds 26 et 27). Ce dossier n'est pas
>    versionné : **le vérifier avant chaque release**.
> 6. **Le gel est respecté** : aucune fonction ajoutée, le comportement du recall
>    proactif n'a pas bougé. Le rendez-vous du ~9 septembre garde sa base.
>
> Auparavant (2026-08-11), session de VEILLE : (1) **Spotify a publié Xirp le
> 10 août** — app macOS qui gère des sessions Claude Code en worktrees isolés ;
> **Mehdi l'a installée et elle lui plaît** ; (2) la mesure de la mémoire donne déjà
> un signal net — **86 % des extraits injectés n'apparient qu'un ou deux mots** du
> prompt, pour **110 ms** ajoutés à chaque frappe. Détail en §0.bis.
>
> Auparavant, app **v0.16.2** — la mémoire est mise SOUS
> INSTRUMENT. `~/.atoll/recall-journal.jsonl` enregistre chaque passage du hook,
> **injecté ou refusé avec sa raison**, et `atoll-bridge recall-stats` rend le
> rapport. But explicite : pouvoir SUPPRIMER le recall proactif s'il ne sert pas
> (`atoll-recall` n'a jamais été invoqué en 22 jours, le canal automatique injecte
> ~200 fois, personne ne sait si ça sert).
> **RENDEZ-VOUS ≈ 2026-09-09** — plan validé par Mehdi : il utilise l'app un mois,
> puis on lit `recall-stats` et on tranche ; ENSUITE seulement on regarde les deux
> autres pistes (voir les flottes d'arrière-plan via `~/.claude/jobs/`, et le rapport
> de retour de VISION §4). **NE RIEN AJOUTER D'ICI LÀ** : toucher au recall pendant
> la mesure invaliderait le mois.
>
> Auparavant **v0.16.1** (2026-08-09) — sept défauts corrigés,
> aucune fonction ajoutée. Deux chemins DESTRUCTEURS fermés : un `settings.json` de
> zéro octet était confondu avec un fichier absent (l'écriture reposait un fichier ne
> contenant que nos hooks — 19 hooks GSD, statusLine, `permissions`, `env`, `model`
> évaporés), et Rockstar SURVIVAIT à la fermeture d'Atoll (règles `deny` de
> l'utilisateur suspendues indéfiniment, sans îlot pour approuver). Deux fonctions
> écrites-testées-jamais-appelées branchées : `MemoryRanking.byCoverage` sur le recall
> proactif (le SEUL canal de mémoire vivant — `atoll-recall` n'a jamais été invoqué),
> et la distinction « aucune session » / « format inconnu » dans `AgentsSnapshot`
> (sans elle, un format futur clôturait toute la flotte en 4 à 12 s). Plus : la carte
> de permission n'est plus effacée par un sous-agent, le bouton ARRÊTER ne s'affiche
> que si un job existe, « EN ATTENTE DE TOI » ne se dit plus d'un état non confirmé.
> **La revue adversariale (19 agents, 14 allégués → 1 confirmé) a trouvé une
> régression DANS ce lot** — corrigée, avec trois tests vérifiés en neutralisant le
> correctif. Détail : `CLAUDE.md` § v0.16.1.
> Origine du lot : une question sur agent-orchestrator (9k étoiles). Conclusion —
> **rien à en reprendre côté produit** (un IDE qui fait travailler des agents, l'axe
> inverse ; 229 903 lignes de Go sans une seule recherche transversale) ; 5 des 7
> correctifs portent sur du code à nous.
>
> Auparavant **v0.16.0** (2026-08-03) — quatre lots, cadrés par
> `docs/VISION-2026-08.md` (Atoll SAIT, se SOUVIENT, APPELLE) : (1) la mémoire
> RÉPOND (recherche élargie quand le strict ne rend rien, tri par couverture,
> bandeau « RECHERCHE ÉLARGIE ») ; (2) elle cesse d'avaler le bruit (les enveloppes
> `<task-notification>` valaient 17 % du corpus `user`) ; (3) le niveau « Auto » est
> retiré — `claude auto-mode` le fait mieux, nativement ; (4) le cockpit ⌘N est
> retiré (jamais utilisé, lançait sans `-w`). Le bouton ARRÊTER, mort depuis la
> Phase 9, est réparé : `claude stop` veut le PRÉFIXE 8 hex, pas l'UUID.
> Auparavant v0.15.1 — le SON ne dépend plus de
> l'app (le helper le joue quand elle est fermée : elle avait parqué les hooks
> `afplay` de Mehdi puis était restée fermée deux jours, plus rien ne sonnait).
> Auparavant v0.15.0, Phase 14 « Arêtes
> franches » : coins hauts droits, contour refait au calibrage Apple MESURÉ,
> ouverture débarrassée de son contour fantôme (deux causes distinctes), badge
> « INPUT? » retiré. Détail et chiffres : `CLAUDE.md` § Phase 14.
> Auparavant v0.14.1 : audit complet PUIS revue adversariale des corrections
> elles-mêmes, 59 + 25 défauts corrigés (`docs/AUDIT-2026-07-27.md`).

---

## 0. TL;DR — REPRISE APRÈS COMPACTAGE (lire ceci d'abord)

Atoll est une « Dynamic Island » ASCII pour Claude Code sur macOS (Swift/SwiftUI,
GPL-3.0, repo PUBLIC `github.com/mehdi7129/atoll`).

### État EXACT au 2026-08-11 (fin de session)

| Quoi | Où |
|---|---|
| Version | **v0.16.2** — la mémoire sous instrument (PUBLIÉE : release GitHub, DMG et zip notarisés+agrafés, appcast poussé et ses **12 URL vérifiées 200**, GitHub Pages basculé) |
| Git | `main` poussé, **arbre propre**, et **une seule branche** (`main`) : les deux branches de travail ont été supprimées après fusion. Vérifier d'un coup : `git log --oneline -3 && git status --porcelain` (un hash écrit ici serait périmé dès le commit suivant) |
| Tests | **686 verts** (`cd AtollCore && swift test`, ~1 s), build **0 warning** |
| Phases | **1 à 14 livrées**, la **9 RETIRÉE** le 2026-08-03. Feuille de route « Atoll 2 » ÉPUISÉE ; le cadre en vigueur est `docs/VISION-2026-08.md`, décliné en `docs/PLAN-2026-08-court-terme.md` |
| Build installé | `~/Applications/Atoll.app` = **Release NOTARISÉE v0.16.2** (bundle 27), installée et vérifiée le 2026-08-10 : `spctl : accepted — Notarized Developer ID`, staple validé, helper signé, app relancée. **C'est ce qui rend la mesure d'un mois possible** : la 0.16.0 qui traînait jusque-là n'avait pas l'instrumentation. L'ancien bundle est conservé sous `~/Applications/Atoll-0.16.0-remplacee-*.app`. Pas de build Debug installé — pour reprendre la boucle de dev, l'installer en `~/Applications/Atoll-dev.app`, jamais `ditto` par-dessus la Release (`ditto` FUSIONNE, un `Atoll.debug.dylib` résiduel casse le sceau) |
| Mesure en cours | `~/.atoll/recall-journal.jsonl` — parti **vierge le 2026-08-10**, **42 passages au 2026-08-11**. Ne pas l'effacer, ne pas toucher au recall d'ici le rendez-vous |

**Rien n'est en cours, rien n'est à moitié fait** — sauf UNE chose qui court toute
seule : la mesure de la mémoire (voir juste dessous).

### 0.bis — CE QUE LA SESSION DU 2026-08-11 A APPRIS (veille, zéro code)

**PREMIERS CHIFFRES DE LA MESURE, après ~1 jour (42 passages)** — ils ne concluent pas,
mais ils orientent :

| Mesure | Valeur |
|---|---|
| Injections | 29 / 42 passages (69 %) |
| Refus « enveloppe machine » | 11 (26 %) — le filtre de la v0.16.0 travaille |
| Extraits n'appariant que **1 ou 2 mots** | **86 %** (41 % + 45 %) |
| Extraits appariant 3 mots ou plus | 14 % |
| Latence ajoutée à la frappe | **110 ms** médiane, **349 ms** au pire |

Lecture : la mémoire **remplit du contexte plus qu'elle ne répond**, et ça se paie sur un
hook BLOQUANT. Cohérent avec le fait mesuré la veille : **79,5 % du texte indexé est du
`tool`/`tool_result`** (contre 3,2 % de messages `user`). Le journal mesure donc un canal
alimenté majoritairement de bruit — il conclura probablement « supprimer », et ce serait
juste sur une preuve faussée. D'où la piste à préparer (sans la livrer) : comparer avec le
corpus `~/.claude/projects/*/memory/*.md` qu'Anthropic écrit **gratuitement** — mesuré :
**123 fichiers, 349 774 caractères**, contre **11 notes / 10 503 caractères** produites par
la rétrospective d'Atoll en 24 jours. Rapport de 33 pour 1, et Anthropic ne les lit JAMAIS
transversalement (il n'injecte que le `MEMORY.md` du dépôt courant).

**SPOTIFY A PUBLIÉ XIRP LE 2026-08-10** — app macOS (bêta publique) qui gère des sessions
Claude Code / Codex / Gemini, **une par worktree git**, jusqu'à 50 en parallèle. 1 300
ingénieurs Spotify, 36 000 sessions internes. **Installée sur la machine de Mehdi
(`/Applications/Xirp.app`) et il l'apprécie.** Leur diagnostic, mot pour mot : *« That's not
a documentation problem. It's a retrieval problem. »* — soit exactement la conclusion à
laquelle cette session est arrivée sur la mémoire d'Atoll, par un chemin indépendant.
- Ce qui les sépare d'Atoll : Xirp exige un **compte**, c'est une **app à ouvrir**, il vise
  l'**organisation** (Backstage/Portal, ownership des services) et il **fait travailler**
  les agents. Atoll : zéro compte, ambiant, une machine, et il ne fait pas travailler.
  **Portal n'est PAS obligatoire** — Xirp gère aussi des sessions purement locales, donc le
  recouvrement est plus large que leur discours ne le dit.
- **À VÉRIFIER EN DEUX MINUTES quand une session Xirp tourne** : est-ce qu'Atoll la voit ?
  Les hooks vivent dans `~/.claude/settings.json` (donc toute session de la machine) et
  `agents --json` liste tout le daemon. La compatibilité est probablement DÉJÀ acquise,
  gratuitement. Si elle n'apparaît pas, c'est que Xirp isole sa config
  (`--setting-sources ""`) — c'est le seul point technique inconnu.

**ARBITRAGE RENDU — « Xirp + Rockstar pour être autonome » : NON.** Mehdi l'a proposé le
2026-08-11. Le raisonnement à conserver, parce que l'idée reviendra :
- **Rockstar ne décide rien.** Ce n'est pas une intelligence qui arbitre, c'est un
  interrupteur qui RETIRE des protections. Les six règles suspendues, relevées ce jour dans
  `~/.atoll/rockstar-parked-deny.json` : `Bash(rm -rf *)`, `Bash(sudo *)`,
  `Bash(curl * | bash)`, `Bash(wget * | bash)`, `Read(./.env)`, `Read(./.env.*)`.
- **Le worktree isole le DÉPÔT, pas le SYSTÈME.** Aucune de ces six règles ne parle du
  dépôt : elles parlent de la machine, des secrets et du réseau. Cinquante agents en
  worktrees isolés restent cinquante agents capables de lire `~/.aws` ou d'exécuter du code
  téléchargé.
- Rockstar a été conçu pour des sessions **surveillées** — c'est la raison pour laquelle
  l'îlot reste visible en permanence tant qu'il est actif (décision écrite dans CLAUDE.md).
  L'associer à de l'orchestration non surveillée en retourne le sens.
- **Limite architecturale à connaître** : le parking est GLOBAL, pas par session. On ne peut
  pas aujourd'hui dire « Rockstar pour mes sessions interactives, protections maintenues
  pour les agents Xirp ». C'est la bonne granularité, et c'est la seule évolution
  défendable de Rockstar — à poser APRÈS le 9 septembre.

**VEILLE — le fil de @Zoeillle (11 août, 4 138 vues) : « Vous utilisez quel RAG et quel
système de mémoire sur vos agents ? »** 10 réponses, analysées par 13 agents. Son outil
s'appelle **Écurie** (v4.0, code NON public : « reste de l'IP de ma boîte ») ; « Madeleine »
n'est pas l'outil mais **un agent nommé** parmi trois (Madeleine, Louisa, Navii).
**RIEN N'EST À REPRENDRE**, et chaque refus est mesuré — ne pas rouvrir sans élément neuf :
- **LEANN** : 438 Mo de modèle et ~2 s, contre 19 ms aujourd'hui. Troc à l'envers.
- **mem0** : leur propre papier donne 66,88 % contre 72,90 % pour le contexte complet ; et
  son prompt ordonne au modèle de SUPPRIMER un souvenir contredit, quand `NotesCuration`
  remonte les contradictions sans jamais trancher.
- **Qdrant / pgvector / sqlite-vec** : un scan cosinus brute force en Swift sur 40 504
  vecteurs prend **25 ms** ici — le problème qu'ils résolvent n'existe pas à cette échelle.
- **Embeddings Gemini** : enverrait ~15,7 Mo de transcripts de tous les projets à Google,
  plus un appel réseau dans un hook bloquant.
- **`NLContextualEmbedding`** (seule voie native admissible) : **mesuré mauvais sur ce
  corpus** — « notarisation Sparkle appcast » ressort plus proche de « drone Houdini
  trajectoire » (0,9116) que de « codesign xattr resource fork » (0,9059).
- **Porter `atoll-recall` en MCP** : le rendrait MOINS visible (un outil MCP ne charge que
  son nom, un skill charge sa description entière).
- **OpenTelemetry** : mesuré 7,24 s → 11,16 s vers un collecteur qui ne répond pas, et
  l'exportateur Prometheus se lie sur `*:9464` sans authentification.

**LES RÉSUMÉS DE COMPACTION NE SONT PAS INDEXÉS — gisement à examiner le 9 septembre**
(constaté le 2026-08-12). `ProactiveRecallHook.injectableRoles` déclare `summary` comme
rôle injectable, et `MemoryIndex` sait le stocker. Pourtant :

```
SELECT COUNT(*) FROM messages WHERE role='summary';   →  0
grep compact_boundary ~/.claude/projects/*/*.jsonl    →  9 compactions, 5 transcripts
```

**Zéro sur neuf.** Or c'est le contenu le plus dense de la machine. Exemple réel relevé
dans un transcript :

```
compactMetadata.trigger                  manual
compactMetadata.preTokens                969 937
compactMetadata.postTokens                13 544
compactMetadata.cumulativeDroppedTokens  956 393
compactMetadata.durationMs               133 888
compactMetadata.preservedSegment         headUuid + anchorUuid
```

Chaque résumé est donc **l'essence de ~970 000 jetons condensée en ~13 500** (72:1,
98,6 % écarté) — exactement le « ce qui a été appris » qui manque à un index composé à
**79,5 % de `tool`/`tool_result`**. À rapprocher du corpus `~/.claude/projects/*/memory/*.md`
(123 fichiers, 349 774 caractères) : deux gisements de conclusions déjà écrits, gratuits,
qu'Atoll n'exploite ni l'un ni l'autre.

**À VÉRIFIER AVANT DE CONCLURE À UN DÉFAUT** : le marqueur est une ligne
`type: "system"`, `subtype: "compact_boundary"` dont le champ `content` vaut
« Conversation compacted » — le texte du résumé lui-même n'est PAS dans cette ligne. Il
faut d'abord établir OÙ le CLI écrit le résumé (probablement le premier message de la
session suivante, ou le `preservedSegment`) avant de supposer que `TranscriptLineParser`
le rate. Ne pas coder avant d'avoir la réponse — et de toute façon pas avant le 9/09,
c'est une modification d'ingestion qui fausserait la mesure.

**DEUX PIÈGES DE MÉTHODE VÉCUS CE JOUR :**
- **TCC peut couper l'accès au Bureau EN COURS DE SESSION.** Signature exacte :
  `Operation not permitted` sur `~/Desktop`, `~/Documents` ET `~/Downloads` — les trois
  dossiers protégés — pendant que `~/.atoll` et `~/Applications` répondent normalement.
  L'app à ré-autoriser est **ClaudeCode.app**
  (`~/.local/share/claude/ClaudeCode.app`), dans Réglages Système › Confidentialité et
  sécurité › Fichiers et dossiers (ou Accès complet au disque). Aucun contournement
  possible en ligne de commande — et il ne faut pas en chercher.
- **Un répertoire courant devenu invalide bloque TOUT Bash**, y compris les commandes qui
  le corrigeraient (`cd`, `pwd`) : le garde-fou évalue le cwd AVANT d'exécuter. Sortie :
  `ExitWorktree`, qui repositionne la session. Cause ici : un `cd` vers le dossier du job
  pour compiler un utilitaire, resté actif.

### ⏳ LE SEUL RENDEZ-VOUS EN COURS — vers le 2026-09-09

Plan arrêté avec Mehdi le 2026-08-10 : **il utilise l'app un mois, puis on tranche sur
pièces.** Une seule commande le jour dit :

```sh
atoll-bridge recall-stats          # ou --json
```

Trois chiffres décident du sort du recall proactif : le **taux d'injection**, la
**répartition des couvertures** (part des extraits n'appariant qu'UN mot du prompt) et
la **latence médiane** des passages ayant cherché. Si la mémoire proactive remplit
surtout du contexte sans répondre, elle rejoint le cockpit et le niveau « Auto ».

**MAIS LA QUESTION DU JOUR DIT N'EST PEUT-ÊTRE PAS « GARDER OU SUPPRIMER ».** Le journal
mesure la qualité d'un CORPUS (les transcripts, 79,5 % de sorties d'outils) autant que
celle du mécanisme. Deux autres corpus, déjà écrits et gratuits, sont ignorés par Atoll :
les **123 fichiers `memory/`** d'Anthropic (349 774 caractères) et les **9 résumés de
compaction** (chacun l'essence de ~970 000 jetons). Poser les trois questions dans cet
ordre : (1) le mécanisme est-il bon ? (2) le corpus est-il le bon ? (3) faut-il supprimer,
ou changer de corpus ? Conclure « ça ne sert pas » sans avoir regardé (2) serait une
décision juste sur une preuve faussée — le mode de panne du bouton ARRÊTER.

**NE RIEN AJOUTER D'ICI LÀ**, et surtout ne pas toucher au recall ni au plancher de
pertinence : toute modification pendant la fenêtre invalide le mois. Les deux autres
pistes discutées attendent ce chiffre — (1) voir les flottes d'arrière-plan via
`~/.claude/jobs/<8hex>/state.json`, (2) le rapport de retour de `VISION §4`.

Le journal ne dit PAS si un souvenir a SERVI : pour l'utilité réelle, croiser le champ
`keys` avec `memory.db` et la réponse qui a suivi dans le transcript.

### v0.16.1 / v0.16.2 — ce que la session des 9-10 août apprend

Sept défauts corrigés puis la mémoire instrumentée. Les faits sont dans `CLAUDE.md` ;
voici ce qui se réutilise.

- **ANALYSER UN CONCURRENT SERT SURTOUT À RELIRE LE SIEN.** Point de départ : « que vaut
  agent-orchestrator, 9k étoiles ? ». Conclusion après 15 agents : **rien à en reprendre
  côté produit** (un IDE qui fait travailler des agents, l'axe inverse ; 229 903 lignes
  de Go sans une seule recherche transversale ; télémétrie par défaut ; loopback non
  authentifié écrit comme une règle à préserver). Mais **5 des 7 correctifs portent sur
  du code à nous**, trouvés parce qu'on revenait au nôtre avec un œil neuf. Le seul
  emprunt réel tient en une phrase de raisonnement.
- **VÉRIFIER QU'UNE FONCTION PUBLIQUE BIEN TESTÉE A DES APPELANTS HORS TESTS.** Le motif
  s'est répété DEUX fois dans le même lot : `MemoryRanking.byCoverage` (écrite, testée,
  documentée, jamais appelée par le canal de mémoire vivant) et la distinction
  « aucune session » / « format inconnu ». `grep <symbole>` en excluant `/Tests/` est un
  contrôle de dix secondes qui a rapporté deux des trois meilleurs correctifs.
- **UNE REVUE ADVERSARIALE TROUVE LES RÉGRESSIONS DE SES PROPRES CORRECTIFS.** 19 agents,
  14 allégués, **1 confirmé** — et le confirmé était une régression que le lot venait
  d'introduire (la fusion des seaux évinçait la seule session active hors du panneau,
  cassant par l'intérieur l'invariant qu'`allocationPriority` protégeait). Le réfutateur
  ne l'a pas raisonnée : il a EXÉCUTÉ le vrai `SessionGrouping` et mesuré.
- **UN TEST DE RÉGRESSION DOIT ÊTRE VÉRIFIÉ EN NEUTRALISANT LE CORRECTIF.** Les trois
  tests ajoutés ont été confirmés par 4 échecs sans lui. Un test qui n'a jamais échoué
  ne prouve rien.
- **MESURER POUR DE VRAI RÉVÈLE CE QUE LA RELECTURE NE VOIT PAS.** En faisant tourner le
  helper : la médiane de latence portait sur TOUS les passages, or les refus du gate
  coûtent 0 ms et sont majoritaires — la médiane tombait à 0 et la ligne de latence
  **disparaissait du rapport**. Sur un mois, l'information qu'on veut lire se serait tue
  toute seule. Défaut invisible en relisant le code, évident en l'exécutant.
- **PIÈGE SPARKLE, VÉCU DEUX FOIS DE SUITE** : `generate_appcast --download-url-prefix`
  réécrit l'URL de TOUTES les entrées vers le tag courant. En v0.16.2, l'appcast
  référençait donc `v0.16.2/Atoll-0.16.1.zip` — il a fallu **réhéberger le ZIP de la
  version précédente dans la nouvelle release**, sinon 404 pour tous ceux qui viennent
  de 0.15.x. Vérifier systématiquement les URL après publication (script d'une boucle
  `curl -sI`, toutes doivent rendre 200).
- **`Scripts/release.sh` A UN SHEBANG `#!/bin/zsh`** et utilise un qualificateur de glob
  zsh (`*.delta(N)`). Lancé avec `bash`, il plante ligne 106 — APRÈS les deux
  notarisations, donc sans dégât mais après 8 minutes. `zsh Scripts/release.sh`.
- **UN WORKTREE NEUF N'A PAS `dist/updates/`** : `generate_appcast` n'y trouve aucune
  archive antérieure et produit un appcast sans historique ni delta. Copier les `.zip`
  du dépôt principal avant, sinon les utilisateurs téléchargent l'app entière.
- **LE README DÉRIVE EN CHANGELOG.** Refondu le 2026-08-10 (219 → 131 lignes visibles) :
  il avait accumulé un tableau de 20 « phases », l'historique de ce qui avait été retiré,
  et un numéro de version faux depuis trois releases. Règle éditoriale désormais dans
  `CLAUDE.md` — s'y tenir, la dérive est graduelle et invisible.

### v0.16.0 — quatre lots, et ce qu'ils apprennent

Cadre : `docs/VISION-2026-08.md`, né du constat de Mehdi qu'Anthropic livre
nativement de plus en plus de la surface d'Atoll (agent view, `auto-mode`,
`ultrareview`, remote-control, agent teams). Conséquence de méthode : **soustraire
avant d'ajouter**. Bilan net **−910 lignes**.

1. **La mémoire RÉPOND.** 8 135 messages « drone » indexés, et `recall` rendait
   « Aucun résultat » : en mode strict, tous les mots doivent tenir dans le MÊME
   fragment (404 caractères en moyenne). Le défaut n'était pas dans `MemoryIndex`
   mais dans son APPEL — le commentaire de `MatchMode` le disait déjà, la leçon
   n'avait été appliquée qu'au recall PROACTIF. Élargissement **seulement sur zéro
   résultat**, jamais sur « peu » (ça diluerait les recherches précises qui marchent).
   Contrepartie assumée : un OR de mots fréquents apparie jusqu'à 64 % de la base →
   trois ceintures NON optionnelles (bandeau « RECHERCHE ÉLARGIE », champ `relaxed`
   par objet JSON, tri par COUVERTURE) + une section du SKILL.md qui interdit d'en
   tirer un « on avait décidé X ».
2. **La mémoire cesse d'avaler le bruit** : 134 enveloppes `<task-notification>`
   valaient **17 % du corpus `user`**. Filtre STRUCTUREL (`origin.kind`, vérifié
   127/127 sur douze versions du CLI), jamais textuel — une conversation qui *parle*
   de ces balises n'en serait pas victime. **PIÈGE ÉVITÉ** : la purge ne passe PAS
   par `schemaVersion`, car toute valeur inattendue de `user_version` fait passer
   `migrateIfNeeded` par `recreateFromScratch`, qui SUPPRIME la base — et 548
   messages appartiennent à cinq transcripts disparus du disque. Compteur dans
   `PRAGMA application_id`.
3. **Niveau « Auto » retiré** (`claude auto-mode` est first-party, actif par défaut,
   35,5 Ko de politique ; notre allowlist avait dû être corrigée deux fois pour des
   contournements). Tout réglage inconnu retombe sur `.manual`, le plus prudent.
4. **Cockpit ⌘N retiré** : jamais utilisé (`launched-tasks.json` = `{"tasks":[]}`) et
   il lançait `claude --bg` **sans `-w/--worktree`**.

**LES DEUX LEÇONS DE MÉTHODE, qui valent au-delà de ces lots :**

- **Écrire les tests du code PARTAGÉ avant de supprimer son autre appelant.**
  `ShellSplitter` est partagé avec `SoundHookEditor` et n'avait aucun test propre :
  les 22 tests d'`AutoAcceptPolicy` étaient sa seule couverture. `ShellSplitterTests`,
  écrit AVANT la suppression, a trouvé aussitôt un vrai défaut — **`\r\n` est UN SEUL
  `Character` en Swift**, le `switch` ne testait que `\n` et `\r`.
- **Retirer du code fait MONTER la surface de documentation fausse.** La revue a
  confirmé 5 défauts documentaires contre 1 seul de code : le README public vendait
  encore le cockpit ⌘N et la notification de fin de tâche au présent, et la liste de
  triggers de `CLAUDE.md` se disait « exhaustive » en omettant `retroBig`, `plugins`
  et `pluginSearch`. La passe docs fait partie du retrait, pas d'après.

### Le bouton ARRÊTER n'avait JAMAIS fonctionné (corrigé le 2026-08-03)

Trouvé par la revue adversariale du diff, et plus vieux que ces lots — il datait de
la Phase 9. `claude stop` liste `~/.claude/jobs/`, ne garde que les entrées appariant
`^[a-f0-9]{8}$`, puis retient celles dont le NOM **commence par** l'argument reçu. Un
dossier de 8 caractères ne peut pas commencer par une chaîne de 36 : Atoll passait
`session.id` en entier, donc EXIT=1 systématique. L'utilisateur validait une
confirmation destructrice pour lire « L'arrêt a échoué ».

MESURÉ sur le job MORT `1b6e885d` (aucune session vivante touchée) :

```
claude stop 1b6e885d                              → « stopped 1b6e885d »,  EXIT=0
claude stop 1b6e885d-60ff-4bfa-bd56-353e6f4ba7c8  → « No job matching »,   EXIT=1
```

`FleetLaunch.jobIdentifier` (AtollCore, 6 tests) rend le préfixe ou `nil` — jamais un
argument normalisé, car `stop` agit sur la PREMIÈRE correspondance et un préfixe
inventé pourrait désigner une AUTRE session. Le jeu `[a-f0-9]` est écrit en toutes
lettres, pas délégué à `Character.isHexDigit` (plus large : majuscules, chiffres
pleine chasse, chiffres arabes). `FleetLauncher.stop` REMONTE désormais le stderr de
la CLI au lieu d'inventer une cause.

> **LA LEÇON, et c'est la plus transférable du lot** : le fait « `claude --bg`
> n'imprime parfois qu'un PRÉFIXE de 8 hex alors que les hooks portent l'UUID
> complet » était **déjà écrit dans `CLAUDE.md` depuis la Phase 13**. Il avait été
> rangé sous « notifications » et n'a protégé qu'elles. Une connaissance classée sous
> un seul titre ne généralise pas toute seule à ses voisines.

> **CE QUI N'A PAS ÉTÉ VÉRIFIÉ** : le bouton n'a pas été CLIQUÉ dans l'app sur une
> session vivante — ça l'aurait tuée. Le correctif est prouvé par ses deux bouts (le
> test unitaire rend `1b6e885d`, la CLI l'accepte), pas par le geste complet.

### Ce que fait Atoll aujourd'hui, de bout en bout

Îlot notch ASCII (thèmes, 4 palettes, largeur réglable par écran, Liquid Glass) ·
suivi temps réel des sessions (`claude agents --json` autorité + hooks) · réponses
depuis le notch (permissions ⌘Y/⌘N, plans, questions) · autonomie Manuel ou
Rockstar · quota serveur exact · jump-back terminal · arrêter une session ·
mémoire FTS5 de tous les transcripts + skill `atoll-recall` (recherche élargie
quand le strict ne rend rien) · souvenirs proposés d'office (opt-in) ·
rétrospective qui produit VRAIMENT des skills · curation des notes · inventaire
et recherche de plugins · deux sons personnalisables **qui sonnent même quand
Atoll est fermée** · flotte par état.

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

La revue adversariale des CORRECTIONS a ensuite trouvé **25 régressions** —
dont un contournement critique de l'auto-accept, qui se rouvrait en retirant une
espace (`python3 -c'…'`). Toutes corrigées. Leçon générale : corriger un défaut
de sécurité demande une seconde passe adversariale sur la correction elle-même.

L'arbitrage « îlot au repos » est RENDU (fin du document) : invisible pour ce qui
attend, visible pour Rockstar seul — ce mode suspend les règles `permissions.deny`.

## 1. CE QU'IL RESTE À FAIRE

**Aucun chantier n'est en cours.** Les phases sont livrées, la feuille de route
« Atoll 2 » est épuisée, et les quatre lots de la v0.16.0 sont publiés. La suite se
décide AVEC Mehdi. Ce qui suit est la liste réelle de ce qui reste, avec le contexte
de décision — pas une liste de vœux.

> 📌 **LE CADRE EN VIGUEUR est `docs/VISION-2026-08.md`** (Atoll SAIT, se SOUVIENT,
> APPELLE), décliné en `docs/PLAN-2026-08-court-terme.md`. Il part d'une inquiétude
> que Mehdi a formulée lui-même : Cursor et Claude Code évoluent si vite qu'Atoll
> pourrait ne plus servir à rien. La réponse retenue n'est pas d'ajouter des
> fonctions, c'est de **soustraire tout ce qu'Anthropic fait mieux nativement** et de
> ne garder que ce qu'Atoll est seul à faire. Lire ces deux documents AVANT de
> proposer un chantier — plusieurs idées séduisantes y sont déjà écartées, avec la
> raison.

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
3. **« Rapport de retour » de fin de session** (`docs/VISION-2026-08.md` §4.1) — la
   seule piste de cette liste qui soit vraiment ouverte. Contexte : l'annonce de fin
   de tâche de la Phase 13 a été SUPPRIMÉE avec le cockpit, parce que sa seule source
   était la fenêtre ⌘N et qu'elle n'a donc jamais sonné une seule fois. Si le sujet
   se rouvre, il faudra une source RÉELLE, et c'est le point dur : reconnaître une
   `--bg` lancée du terminal passerait par `AgentSessionInfo.Kind.background`, dont
   le code documente qu'il n'est pas fiable (une session interactive a déjà été
   rapportée `background`) → risque de sonner sur une session que Mehdi regarde.
   Le hook `Stop` et son `last_assistant_message` restent le bon signal.
   **`AtollCore/TaskCompletion` est CONSERVÉ exprès pour ça**, documenté comme
   échafaudage : `inputCap` est vivant (`HookEvent` borne `last_assistant_message`
   avec) et `plainText` est la brique du rapport. Aplatir du Markdown sans avaler la
   prose d'un projet Swift a coûté plusieurs revues et 22 tests. **Si ce rapport
   n'est pas construit, ce fichier doit être SUPPRIMÉ** — c'est écrit dans son
   en-tête, ne pas le laisser pourrir indéfiniment.

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

- **UN TROISIÈME MODE D'AUTONOMIE « qui décide intelligemment »** — proposé par Mehdi
  le 2026-08-04, **écarté par LUI le même jour, sur mesure**. On garde Manuel et
  Rockstar, on n'ajoute rien. L'idée : entre « tu décides tout » et « je ne te demande
  rien », un mode où un second Claude répondrait aux `AskUserQuestion` à sa place.
  MESURÉ sur **41 décisions réelles** extraites de ses transcripts (questions qu'il a
  tranchées lui-même, latence > 3 s) :

  | | justesse | IC 95 % |
  |---|---|---|
  | hasard (2,9 options en moyenne) | 37 % | — |
  | référence — ce que fait Rockstar aujourd'hui (« toujours la 1re option ») | **54 %** | [38–69] |
  | un Claude qui lit la question, SANS mémoire | 63 % | [49–78] |
  | un Claude qui lit la question, AVEC son historique | 66 % | [51–80] |

  **Les deux résultats qui tranchent :**
  1. **La mémoire n'apporte rien.** Elle n'a changé la réponse que sur 4 décisions
     sur 41 (2 corrigées, 1 dégradée) — p ≈ 1,00. Le gain vient de LIRE la question,
     pas de l'historique. C'était le contraire de l'hypothèse de départ (« la valeur
     d'un second Claude, c'est son information différente, pas son raisonnement »).
  2. **Le gain n'est pas significatif** : référence → avec mémoire donne 12 gagnées
     contre 7 perdues, **p ≈ 0,36**, intervalles largement chevauchants. Une tendance
     de +9 à +12 points, pas une preuve.

  Et même à 66 %, **une décision sur trois reste fausse** — ce tiers-là étant presque
  entièrement composé de choix de GOÛT (quelle variante de figure, quelle palette),
  pour lesquels la réponse n'existe nulle part avant que Mehdi la formule. Aucune
  quantité de mémoire n'y change quoi que ce soit.

  BIAIS CONNU DE LA MESURE, à réappliquer si on refait l'expérience : le jeu de test
  était trié par date, donc un agent pouvait voir les questions POSTÉRIEURES et en
  déduire les réponses antérieures (constaté dans les justifications : « le globe v2
  cité plus tard »). Ça biaise les deux bras également — la comparaison reste valide —
  mais 63 % et 66 % sont OPTIMISTES par rapport à un vrai déploiement. La référence à
  54 %, elle, n'est pas affectée.

  **NE PAS ROUVRIR sans nouvelles données.** Ce qui pourrait légitimement le rouvrir :
  un jeu de test bien plus grand (41 ne suffit pas), ou une mesure débiaisée. Ce qui ne
  suffit PAS : l'intuition que « ça devrait marcher ». Ce qui reste vrai et n'a pas été
  mesuré : Rockstar tranche **45 %** des questions (44 sur 96), toujours par la 1re
  option, et cette 1re option ne coïncide avec le choix de Mehdi que dans ~54 % des cas.
  Il le sait et l'assume — Rockstar est le mode « aucune protection », c'est son contrat.

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

### ⛔️ Notifications macOS — RETIRÉES le 2026-08-03, faits conservés (Phase 13)

> `TaskCompletionNotifier` est SUPPRIMÉ avec le cockpit : sa seule source était la
> fenêtre ⌘N, qui n'a jamais lancé une tâche — l'annonce n'a donc jamais sonné une
> seule fois. Plus aucune ligne du dépôt n'importe `UserNotifications`. Les faits
> ci-dessous ont coûté une demi-journée et restent VRAIS : les garder évite de les
> repayer si le « rapport de retour » de `docs/VISION-2026-08.md` §4.1 les rouvre.
> La recette qui suit ne s'exécute plus (`~/.atoll/launched-tasks.json` n'est plus
> ni lu ni écrit).
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

cd AtollCore && swift test              # 691 tests (2026-08-14)
Scripts/check-docs.py --no-tests        # ce document ment-il ? (quelques secondes)

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
- `.seedSkill` / `.skillReview` / `.approveSkill` / `.rejectSkill`

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
  lanceurs `npx/bunx/dlx` vérifient le **paquet réel** (`npx rimraf` bloqué).
  ⛔️ `AutoAcceptPolicy` et ses 22 tests de bypass ont été SUPPRIMÉS le 2026-08-03
  avec le niveau « Auto » : `claude auto-mode` est first-party, actif par défaut et
  porte 35,5 Ko de politique. Le raisonnement ci-dessus reste la référence si l'on
  devait un jour rejuger une commande nous-mêmes — il avait dû être corrigé DEUX
  fois pour des contournements, ce qui est précisément l'argument du retrait.
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
- `AutonomyLevel` — niveau exclusif **Manuel ou Rockstar** (`resolve` normalise le
  décodage et fait retomber tout inconnu — « auto » compris — sur `.manual`).
  ⛔️ `AutoAcceptPolicy` est SUPPRIMÉE depuis le 2026-08-03.
- `ShellSplitter` — découpe une ligne de commande en segments. **PARTAGÉ** avec
  `SoundHookEditor` : il touche les hooks de l'UTILISATEUR, ne pas y toucher sans
  faire tourner `ShellSplitterTests`.
- `FleetLaunch` — `shellQuote` (bilan, plugins, curation) et `jobIdentifier` (le
  préfixe 8 hex que `claude stop` sait résoudre). Tout ce qui lançait a été retiré.
- `TaskCompletion` — ÉCHAFAUDAGE ASSUMÉ, pas du code vivant : `inputCap` sert à
  `HookEvent`, `plainText` attend le rapport de retour (§1.A.3). À supprimer si ce
  chantier ne se fait pas.
- `Quota` (`StatusLinePayload`, `QuotaSnapshot`) — parse le payload statusline.
- `TerminalTarget` (`TerminalResolver`, `WorkspaceRoot`, `IDECommandLine`) /
  `TerminalScripts` — résolution du terminal + AppleScript (jump-back).
- `MemoryIndex` (+ `MemoryRanking`) — index FTS5, dédup inter-fichiers, récence.
  Depuis v0.16.0 : `searchRelaxing` (strict, puis élargi SEULEMENT sur zéro résultat)
  et `runHygieneIfNeeded` (purge unique des enveloppes machine, compteur dans
  `PRAGMA application_id` — **jamais `user_version`**, qui déclencherait
  `recreateFromScratch` et supprimerait la base).
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
- `FleetLauncher` — ne lance plus rien depuis le 2026-08-03 : il ne porte que
  `stop` (le bouton ARRÊTER du détail de session, avec confirmation). Le nom est
  resté trompeur ; le renommer casserait l'historique `git blame` pour peu de gain.
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

La feuille de route « Atoll 2 » est entièrement livrée, et les quatre lots de la
v0.16.0 sont publiés — **il n'y a plus de prochaine étape écrite d'avance.**
**Demander à Mehdi la direction** avant d'ouvrir un chantier. Lire d'abord
`docs/VISION-2026-08.md` et `docs/PLAN-2026-08-court-terme.md` (le cadre en vigueur),
puis le **§1** pour les pistes non tranchées, la dette assumée et ce qui a été écarté.

Si la reprise doit commencer par quelque chose d'utile sans rien décider, par ordre
de valeur :

1. **Laisser vivre la v0.16.0 quelques jours, puis MESURER.** Deux choses viennent
   d'être réglées sur la base de chiffres, et elles méritent d'être revérifiées sur
   des chiffres : la recherche mémoire rend-elle des résultats UTILES (et à quelle
   fréquence tombe-t-elle en « RECHERCHE ÉLARGIE » ?), et le corpus `user` a-t-il
   cessé de se remplir d'enveloppes machine ? `sqlite3 ~/.atoll/memory.db` répond aux
   deux. C'est le seul chantier qui n'engage rien et qui informe tout le reste.
2. **Demander à Mehdi ce que la recherche élargie lui rend en pratique.** Le
   compromis (élargir seulement sur zéro résultat, jamais sur « peu ») a été tranché
   par raisonnement, pas par son usage. C'est un réglage, il peut se rediscuter.
3. **Refaire une release en invoquant le skill `atoll-release-pipeline`** — test de
   bout en bout de la boucle d'apprentissage (le skill vient d'Atoll lui-même), et ça
   revérifie signature, notarisation et appcast d'un coup.

⚠️ **Ce qu'il ne faut PAS faire spontanément** : ajouter une fonction. Le cadre en
vigueur dit l'inverse, et la v0.16.0 vient de retirer 910 lignes nettes pour cette
raison. Une idée d'ajout se propose à Mehdi, elle ne se code pas d'initiative.

Quel que soit le chantier, la routine de fin ne change pas :
1. AtollCore + tests d'abord, coutures App/Bridge ensuite.
2. **Vérifier en vrai** (app lancée, sessions réelles, screenshots LUS).
3. **Revue adversariale multi-agents** par dimension, ne corriger que les constats
   confirmés par la lecture du code.
4. Release notarisée (`Scripts/release.sh`) + `gh release create` + deltas + push.
5. Mettre à jour `README.md`, `CLAUDE.md`, ce fichier, `PLAN.md` §5 et la mémoire projet.
