# Correctifs des constats sérieux — 2026-08-14

Les deux campagnes de relecture avaient laissé **13 constats sérieux ouverts**.
Sept sont traités ici, avec leurs tests. **719 tests**, contre 691 au matin.

Ce document existe surtout pour ce qu'il raconte de la MÉTHODE : sur sept
correctifs, **trois ont dû être corrigés à leur tour** — un par les tests
existants, un par une mesure que j'ai faite avant qu'on me la demande, un par la
revue adversariale. Aucun n'aurait été vu par relecture.

## Corrigé

- **La mesure qui doit trancher le 9 septembre était fausse.**
  `MemoryRanking.coverage` comparait des SOUS-CHAÎNES : « recalled » couvrait
  « recall », que l'index n'apparie pourtant pas (il tokenise, et
  `sanitizedMatchQuery` cite chaque terme). La couverture était surestimée.
- **L'îlot cessait d'alerter pendant qu'un helper était bloqué.** La v0.16.1
  avait protégé la CARTE d'être effacée par un sous-agent ; la PHASE ne l'était
  pas. Un événement d'outil de sous-agent — qui porte le `session_id` du parent —
  faisait passer `.waitingPermission` à `.busy`, et `needsAttention` ne regarde
  que la permission.
- **Un crash latent** : le second `sysctl` de `KERN_PROCARGS2` réécrit `size`, et
  `4..<Int(size)` est une plage invalide si elle retombe sous 4.
- **Un poller qui pouvait geler à vie** : `/usr/bin/security` peut ouvrir un
  dialogue du Trousseau et attendre indéfiniment, dans une continuation non
  annulable. Watchdog de 20 s.
- **Deux défauts de budget d'affichage** : la vue par ÉTAT dessinait « +N
  autres » sur une rangée hors budget (le panneau a une hauteur fixe : le quota
  sortait du cadre) ; et un dossier de projet déplié pouvait s'ouvrir sur rien.

## Extrait vers `AtollCore`

Le plan de rangées de la vue par projet vivait dans une `View` SwiftUI, donc hors
de portée de tout test. Les campagnes avaient chiffré la conséquence : **5,2
défauts par millier de lignes dans `App/` (0 test) contre 3,3 dans `AtollCore`
(700 tests)**, et deux des défauts sérieux étaient précisément dans ce calcul.

C'est une fonction pure de (groupes, budget, dossiers dépliés) : rien n'y
demandait SwiftUI. Elle vit dans `AtollCore/IslandRowPlan.swift`, avec 10 tests.

## Les trois correctifs qui ont dû être corrigés

C'est la partie utile de ce document.

**1. Réserver une rangée pour le pied recréait une régression connue** — et ce
sont les TESTS EXISTANTS qui l'ont attrapée, pas moi. Passer le budget de 4 à 3
empêche d'ouvrir deux groupes (un groupe non ouvert coûte 2 rangées) : le groupe
« en cours » disparaissait derrière « +N autres » quand des sessions dormantes
remplissaient le budget. Mot pour mot la régression de la v0.16.1 qu'
`allocationPriority` existe pour empêcher. Annulé ; la mention est désormais
portée par l'en-tête du dernier groupe, sans coûter de rangée.

**2. Ma mesure de couverture s'appuyait sur des guillemets français.** Première
version : compter les segments encadrés de `«…»` par FTS5 — la vérité de
l'appariement, en théorie. Mesuré avant de committer : **2 502 messages indexés
sur 45 302 (5,5 %) contiennent naturellement ces guillemets**. Les marqueurs y
sont indiscernables du texte. La mesure porte donc sur le MOT ENTIER, qui ne
dépend d'aucune convention de rendu.

**3. La revue adversariale a trouvé deux fautes dans mes correctifs**
(13 allégués → 2 confirmés, 11 réfutés) :

- **Le correctif de la phase ratait son propre scénario.** Je n'avais gardé que
  les événements de complétion ; `preToolUse` a son propre `case` et n'était pas
  gardé — or c'est l'événement de sous-agent le PLUS fréquent, et il arrive
  AVANT `postToolUse`. J'avais commis, dans le correctif qui prétendait fermer ce
  motif, exactement le motif : « appliqué à une partie seulement de ses points ».
- **Faire disparaître un projet est pire que de le montrer redondant.** Ma
  correction du « dossier ouvert sur rien » supprimait la rangée : le projet
  s'évaporait de l'îlot, son nom, son compte et son glyphe d'attention avec lui.
  Il est désormais dessiné REPLIÉ.

S'y ajoute une faute que la revue a vue et que j'aurais dû voir : mon commentaire
affirmait « même discriminant que la carte » alors que la phase comparait des
RÉSUMÉS (`Bash(git push)`, arguments compris) quand la carte compare des NOMS.
Deux appels du même outil n'ayant jamais le même résumé, **aucune sortie légitime
n'aurait fonctionné** et la session serait restée en alerte pour toujours. La
comparaison se fait sur le nom, extrait par une fonction posée à côté de celle
qui construit le résumé — pour qu'elles ne puissent pas diverger.

Et mon test du « dossier ouvert sur rien » était CREUX : il bouclait sur les
rangées pour vérifier qu'aucun dossier n'était vide, et cette boucle ne
s'exécutait jamais puisque le plan ne contenait aucun dossier. Une assertion
jamais atteinte, présentée comme la preuve du correctif — le défaut même que
j'avais corrigé le matin dans `ProactiveRecallTests`. Réécrit : le plan est
asserté ligne par ligne, et il distingue les TROIS comportements (origine : 1
échec, ma première correction : 3 échecs, version actuelle : 0).

## Ce que ça change pour le rendez-vous du ~2026-09-09

Les couvertures déjà écrites dans `recall-journal.jsonl` sont **gonflées**. Elles
restent exploitables comme MAJORANT, et comme le relevé dépassait déjà le seuil
(45 % d'extraits n'appariant qu'un mot, pour un seuil à ~30 %), la conclusion
qu'il soutenait n'en est que renforcée : la réalité est pire, pas meilleure. Le
format injecté n'a pas bougé — le gel est respecté.

## Les six constats sérieux, traités

Tous corrigés le 2026-08-14, chacun avec son test de non-régression **vérifié par
sabotage** (le correctif neutralisé, le test doit rougir — sinon il ne prouve
rien) :

1. **Le contrat `knownIDs` de la recherche de plugins** était implicite :
   l'appelant reconstituait de son côté la liste des identifiants montrés au
   modèle, et les deux vues divergeaient dès qu'une ligne était tronquée.
   `PluginSnapshot.promptCatalog` rend désormais `(text, shownIDs)`, et
   `shownIDs` n'admet un identifiant **que s'il survit à la troncature** —
   la garde ne peut plus se croire informée d'une ligne coupée.
2. **La curation ne revalidait pas les bornes du schéma** : un modèle qui rend
   plus long que le contrat passait tel quel. `NotesCuration.Limit` + `capped()`,
   appliqués aux notes ET aux contradictions.
3. **La relecture d'inventaire était sautée après `enable`/`disable`** quand un
   rafraîchissement était déjà en vol : l'UI affichait l'état d'avant la
   mutation. `perform()` attend la fin du vol en cours avant son `refreshNow`.
4. **Les slash commands des plugins n'étaient pas inventoriées** — seules celles
   de l'utilisateur l'étaient, alors qu'elles partagent le même espace de noms.
   Le catalogue passe de 117 à 134 entrées sur cette machine. Balayage limité à
   `<version>/commands/` : les dossiers de même nom nichés ailleurs sont des
   GABARITS de dépôt, non invocables, et un catalogue qui invente est pire qu'un
   catalogue qui rate.
5. **Le repli de jump-back n'était posé que sur une des deux sorties** : le refus
   d'automatisation tombe tantôt au préflight, tantôt à l'exécution (`-1743`), et
   sur cette seconde sortie le bouton principal du détail de session ne faisait
   qu'avertir sans remonter la fenêtre.
6. **Les parts réservées du condensé sacrifiaient l'intention utilisateur** avant
   les sorties d'outils, exactement à l'envers de la priorité que la réserve sert
   (`sacrificeRank` classe `.tool` premier à partir, `.user` dernier). MESURÉ sur
   le scénario du test : 3 commandes survivaient pendant que 138 demandes étaient
   élaguées ; 0 après correctif.

## La revue adversariale de ces six correctifs

Trois lentilles (bornes, catalogue, concurrence) puis un réfutateur par constat
allégué, 14 agents : **11 allégués → 2 confirmés**, 9 réfutés. Les deux confirmés
décrivent le MÊME défaut, et il était à moi : le message d'échec du test du
correctif n° 6 portait `\\(commandes)` — un antislash échappé, pas une
interpolation. Le seul test qui prouve l'invariant rendait donc, le jour où il
rougit, un message sans aucun chiffre. Séquelle de mes heredocs Python ;
l'occurrence était unique dans tout le dépôt, vérifié.

Deux enseignements valent plus que le correctif :

- **Un agent a rapporté un « INCIDENT DE REVUE » critique** : avoir écrasé des
  fichiers du dépôt. Réfuté — sa preuve était un test INTERMITTENT, mesuré 20
  fois sur 21 comme passant. Vérification faite d'abord et indépendamment
  (`git status`, présence des six correctifs, suite verte) : le dépôt était
  intact. Une alerte d'intégrité se vérifie sur le disque, jamais sur le récit.
- **Une réfutation peut être juste sur son argument et fausse sur sa portée.**
  La collision « une command et un skill homonymes du même plugin se disputent
  un id » a été réfutée deux fois, au motif que `CatalogEntry.path` n'a aucun
  consommateur d'affichage. C'est exact — et hors sujet : le consommateur est
  `closestMatch`, la garde d'antériorité DÉTERMINISTE, qui note les propositions
  sur `"\(id) \(name) \(description)"` et rattrapait 5 des 6 vrais doublons de
  la machine. Une command sans front-matter masquant un skill lui retirait ses
  mots discriminants. Corrigé : à version égale le skill l'emporte, mais une
  command d'une version plus récente reste gagnante — sinon un skill périmé
  ressusciterait par-dessus elle. Les deux cas sont testés.
