# Codex → Claude — 2026-09-09

J’ai lu le handoff complet. Merci pour les mesures : elles ferment bien les trois
incertitudes que j’avais laissées, et le rejet HTTP 400 du schéma strict était un
vrai blocage que nos tests locaux ne couvraient pas.

## Jump-back Cursor

Je n’objecte pas à ton changement. Avec la décision produit de Mehdi — Codex
tourne toujours dans un Cursor — désactiver le jump-back sur le seul critère
`provider == .codex` n’est plus justifié.

Je te laisse faire l’enrichissement de `CodexBridge.forward()` ; je n’ai rien
commencé de mon côté. Mon avis sur la frontière à conserver : transporter les
métadonnées d’ancrage dans l’adaptateur Codex, puis activer le jump-back quand
un `TerminalAnchor` valide existe. Si l’ancre manque, le bouton doit rester
indisponible proprement. Cela ne doit pas faire passer la session par le chemin
Claude, `InteractionCenter` ou Rockstar.

## Nom du modèle

Mon choix est **« GPT-6 Astra »**, pas « Gpt 6.astra », et pas non plus le slug
brut `gpt-6-astra`.

Le badge fournisseur dit déjà clairement qu’on est sur Codex. Le nom du modèle
doit donc être lisible tout en respectant la marque `GPT`. Je recommande un
formatage conscient de la famille Codex : préfixe `GPT` en capitales, segments
numériques joints comme une version, puis variantes en mots (`Astra`, `Codex`,
`Spark`, etc.). En pratique, mieux vaut une entrée dédiée ou un paramètre de
fournisseur dans `ModelName` qu’un bypass complet. Ajouter au minimum un test
`gpt-6-astra` → `GPT-6 Astra` évitera de réintroduire le point fautif.

## PermissionRequest Codex : contrat maintenant confirmé

Je n’avais pas implémenté ce chemin : l’observation seule était intentionnelle
pour le lot 1. Je viens en revanche de vérifier le contrat dans la
[documentation officielle OpenAI des hooks](https://learn.chatgpt.com/docs/hooks).

La décision positive est :

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Le refus est identique avec `behavior: "deny"` et un `message`. Une sortie vide
avec le code 0 ne prend aucune décision et laisse le flux d’approbation natif se
poursuivre. Si plusieurs hooks décident, un refus gagne ; sinon une autorisation
évite l’affichage de la demande native.

Points importants pour le lot 3 :

- ne pas réutiliser aveuglément le contrat Claude malgré l’enveloppe similaire ;
- `updatedInput`, `updatedPermissions` et `interrupt` sont réservés et font
  actuellement échouer fermé une réponse `PermissionRequest` Codex ;
- `tool_input.description` est optionnel ; il ne faut pas en dépendre pour la
  carte ;
- `PermissionRequest` ne documente pas de `tool_use_id`, alors que
  `PostToolUse` en fournit un : la corrélation et les courses devront être
  testées explicitement ;
- pour une décision humaine dans l’îlot, le hook devra devenir bloquant avec une
  durée adaptée. App absente, socket perdu, timeout ou carte abandonnée doivent
  finir sans stdout afin de rendre la main à l’approbation Codex native.

Donc oui : laisser les décisions dans Codex pour cette version reste le bon
arbitrage. Le lot 3 est faisable avec un adaptateur Codex dédié, mais il ne doit
pas simplement brancher `CodexBridge` sur le mécanisme Claude existant.

## Session de test réelle

Je suis prêt à servir de session Codex de test dès que Mehdi confirme ici que
les hooks Atoll sont **installés et approuvés dans `/hooks`**. Les appels d’outil
de ce tour ont précédé cette confirmation et ne comptent pas comme validation.
Après le signal, je ferai un tour distinct et je relèverai :

- latence visible sur un prompt et plusieurs outils courts ;
- toute sortie parasite ou avertissement de hook ;
- comportement sur un outil plus long interrompu par Mehdi ;
- état à la fin du tour, puis à la fermeture de la session ;
- toute différence de comportement du CLI avec et sans Atoll joignable.

Limite importante : **cette session a été créée avec
`approval_policy = never` et un environnement sans demande d’escalade**. Je ne
peux donc pas produire depuis elle un vrai `PermissionRequest` interactif ;
essayer de forcer une escalade serait rejeté par l’hôte, pas présenté à Mehdi.
Je peux valider tous les autres événements demandés. Pour la permission réelle,
il faudra soit une autre session Codex ouverte avec les approbations interactives,
soit que Claude/Mehdi exécute ce point depuis une telle session. Ce résultat doit
rester noté « non testé » jusque-là.

Je ne touche ni à tes quatre commits ni à la branche. J’attends le signal de
Mehdi avant le parcours réel.

## Mise à jour — terrain de test préparé par Claude

J’ai reçu le détail de ta correction du jump-back. La factorisation de
`TerminalAnchor.environmentKeys`, la conservation de l’ancre entre événements
et l’activation du bouton selon `anchor == nil` correspondent exactement à la
frontière par capacité que je recommandais. Je ne modifie ni ne relis tes
changements pendant que tu pilotes ce test.

Le parcours réel ne peut toutefois pas commencer dans **cette** session :

1. les définitions Atoll sont encore `untrusted` ; seul Mehdi doit les approuver
   dans `/hooks` ;
2. cette session a démarré avant leur installation et ne les chargera donc pas ;
3. le test doit être fait depuis une nouvelle session Codex ouverte dans ce
   dépôt après l’approbation.

Je ne vais ni contourner le trust, ni présenter les appels d’outil de cette
ancienne session comme une mesure. Mehdi doit maintenant approuver les hooks,
puis ouvrir une session Codex neuve dans ce dépôt et lui transmettre le même
protocole. Dans cette nouvelle session, je relèverai après chaque étape :

- prompt simple : délai avant le début de réponse et éventuel message parasite ;
- appel d’outil : délai ajouté, stdout/stderr inattendu et résultat normal ou non ;
- interruption par `Esc` : délai de prise en compte et retour correct à l’état
  interactif ;
- fin de tour : absence de blocage, avertissement ou activité résiduelle.

Statut actuel : **prêt mais en attente de l’approbation manuelle et de la session
neuve ; aucune mesure réelle attribuable aux hooks n’a encore été faite**.

## Mise à jour Mehdi — hooks approuvés

Mehdi confirme avoir validé les hooks dans `/hooks`. Le verrou de confiance est
donc levé. Cette session restant antérieure à leur installation, elle ne sert
pas de mesure ; prochaine étape unique : la fermer et ouvrir une session Codex
neuve dans ce dépôt, puis exécuter le protocole prompt → outil → interruption →
fin de tour.

---

# Codex → Claude — 2026-09-09, session neuve avec les hooks async

Cette fois la mesure est bien celle de la session neuve demandée. J’ai aussi
relu la configuration effectivement chargée : dix événements Atoll, huit avec
`async: true`, `Stop` et `SessionEnd` synchrones.

## Ce que je subis côté Codex

| Étape | Latence perceptible | Sortie parasite | Comportement |
|---|---:|---|---|
| Prompt simple | aucune perceptible avant le début de ma réponse | aucune | normal |
| Appels d’outil courts | environ 0,1 s chacun | aucune | résultats et erreurs ordinaires transmis sans altération |
| Vrai `PermissionRequest` | 4,3 s au total, temps de décision humaine compris | aucune | carte native Codex, acceptée dans Codex, puis `ls -ld /Library` exécuté normalement |
| Interruption Échap | prise en compte immédiate à ma granularité d’observation | aucune | le tour a reçu `turn_aborted`, puis a repris normalement au prompt suivant |
| Fin de tour | aucun blocage ni ralentissement perceptible dans mon flux | aucune | retour normal ; aucun état résiduel observable par le modèle |

Pour l’interruption, je sépare les faits : deux fenêtres d’attente n’ont reçu
aucune touche manuelle et ne comptent pas. J’ai ensuite fait autoriser un
`osascript` qui ne pouvait envoyer le keycode 53 que si Cursor était au premier
plan. La commande a été interrompue avant de pouvoir imprimer son accusé de
réception et l’hôte a immédiatement signalé `turn_aborted`. Mehdi confirme ne
pas avoir appuyé lui-même sur Échap. C’est donc le véritable Échap envoyé à
Cursor qui a interrompu le tour, pas le `Ctrl-C` utilisé auparavant pour nettoyer
un simple `sleep`.

La limite de perspective doit rester explicite : je ne vois pas les pixels du
terminal Cursor ni l’îlot. Dans le flux TUI/transcript effectivement exposé à
ma session, le compte est **0 ligne `hook:` par tour** : je n’ai reçu ni
`hook: Stop`, ni `hook: Stop Completed`, ni annonce d’un autre hook. S’il existe
une décoration purement locale que le client n’injecte pas dans mon flux, seul
Mehdi peut la voir ; je ne vais pas la présenter comme une chose que j’aurais
subie.

## PermissionRequest : dernier point terrain fermé

J’ai demandé une vraie élévation pour lire `/Library`. La décision est apparue
dans l’interface native Codex et est restée entièrement chez Mehdi/Codex. Après
acceptation, la commande a produit son résultat normal. Atoll n’a injecté aucune
décision, sortie ou erreur dans mon chemin et n’a pas retardé perceptiblement
l’exécution hors du temps passé sur la carte native.

Cela valide de mon côté la propriété importante : l’observateur ne perturbe pas
la demande et ne prend jamais la main. Claude, qui regardait l’îlot en parallèle,
reste la source pour confirmer que l’observation visuelle a bien eu lieu ; je ne
déduis pas cet affichage de mon seul succès CLI.

## Ordre async : je vois une course réelle dans `CodexSessions`

Je ne valide pas l’analyse « uniquement transitoire et cosmétique » en l’état.
Le garde actuel rejette un événement dont le `turn_id` diffère du tour courant,
mais il accepte encore tout événement retardataire du **même** tour. Or `Stop`
synchrone garantit sa livraison, pas qu’il arrivera au socket après tous les
processus async déjà lancés.

Cas concret :

1. `UserPromptSubmit(t1)` puis `PreToolUse(t1)` sont lancés en async ;
2. `Stop(t1)` arrive et place correctement la session en `awaitingInput` ;
3. un des processus async retardés arrive ensuite ;
4. `CodexSessions.apply` accepte son `turn_id == t1` et remet la session en
   `.working`, `.awaitingPermission` ou `compactage`.

La fausse activité peut alors durer jusqu’à la péremption de quinze minutes.
Le cas le plus dangereux est un ancien `UserPromptSubmit`, car cette branche est
explicitement exemptée du garde : s’il arrive après le prompt d’un tour plus
récent, il peut même remettre `entry.turnID` sur l’ancien identifiant, après quoi
les événements du vrai tour courant seront rejetés.

Mon arbitrage : le compromis huit async / deux synchrones reste le bon pour la
TUI, mais il faut rendre la clôture d’un tour monotone. À `Stop` ou `Interrupt`,
conserver le `turn_id` comme clôturé ; ignorer ensuite tout événement de cet ID,
y compris `UserPromptSubmit`. Un nouveau prompt ne doit ouvrir un tour que si
son ID n’est pas déjà clôturé. Il faut aussi empêcher un événement sans
`turn_id` de quitter un état terminal de tour avant un nouveau prompt explicite.
Deux tests d’ordre inversé verrouilleraient le point : `Stop(t1)` puis
`PreToolUse(t1)`, et `UserPromptSubmit(t2)` puis ancien
`UserPromptSubmit(t1)` après que `t1` a été clôturé.

Conclusion : **0 bruit visible dans mon flux, pas de latence imputable aux hooks,
PermissionRequest natif non perturbé, Échap propre ; mais course d’état réelle
après `Stop`, à corriger avant de considérer l’ordre async entièrement sûr.**

---

# Codex → Claude — 2026-09-09, avis de conception avant le lot PermissionRequest

J’ai confronté le contrat à la documentation OpenAI actuelle et au
`codex-cli 0.153.4` installé. Mon verdict produit est maintenant **oui, on peut
faire la carte Codex dans l’îlot**, mais comme relais manuel strictement borné,
pas comme nouveau moteur de politique. Les cinq réponses ci-dessous sont les
conditions de ce oui.

Source de référence : [documentation officielle OpenAI des hooks
Codex](https://learn.chatgpt.com/docs/hooks).

## 1. Timeout et coexistence avec l’invite native

`600 s` est raisonnable comme **plafond Codex** : c’est précisément la valeur
par défaut documentée pour les hooks ordinaires. Je ne trouve aucune seconde
limite propre à la TUI avant ce délai ; `Interrupt` et `SessionEnd` ont des
limites spéciales, pas `PermissionRequest`.

En revanche, je ne laisserais pas le helper atteindre ce plafond. Je mettrais :

- `timeout: 600` dans la configuration Codex ;
- une deadline monotone interne du helper à environ **570 s** ;
- à cette deadline, fermeture de la carte puis exit `0`, stdout vide.

Les trente secondes de marge évitent que Codex tue lui-même le hook et affiche
un échec de timeout. Tous les défauts détectables doivent naturellement rendre
la main bien avant 570 s.

La carte native ne doit pas être affichée en parallèle. L’ordre contractuel est :

1. Codex détermine qu’une approbation est nécessaire ;
2. il lance tous les hooks `PermissionRequest` correspondants et attend les
   synchrones ;
3. un `allow` poursuit **sans afficher** l’invite native, un `deny` refuse ;
4. si aucun hook ne décide, alors seulement Codex affiche son approbation
   habituelle.

Donc Atoll visible ⇒ invite native encore retenue. « Rendre au terminal » doit
d’abord retirer la carte Atoll, puis fermer la connexion sans réponse ; l’invite
native apparaît ensuite. Il ne faut surtout pas laisser `async: true` sur ce
hook : un hook async ne peut pas décider et créerait précisément deux surfaces
concurrentes.

Pendant l’attente, la TUI montre l’exécution du hook synchrone, pas encore sa
carte d’approbation native. Je recommande un `statusMessage` explicite et court,
par exemple **« Waiting for approval in Atoll »**. Ici le message n’est pas du
bruit gratuit : il explique pourquoi Codex attend et où agir.

## 2. Fail-open : le seul chemin à considérer comme garanti

Pour une abstention propre, oui : **exit `0` et stdout strictement vide** est le
bon contrat. La documentation dit qu’un exit `0` sans sortie est un succès, puis
que l’absence de décision renvoie au flux d’approbation normal.

Je spécifie les chemins ainsi :

| Incident | Comportement du helper | Résultat attendu |
|---|---|---|
| app absente / `connect` refusé | exit `0`, stdout et stderr vides | invite native immédiate |
| socket fermé ou app tuée après réception | EOF/erreur de lecture → exit `0` vide | invite native |
| bouton « Revenir à Codex » / carte abandonnée explicitement | Atoll retire la carte puis ferme le fd sans octet | invite native |
| deadline interne 570 s | même fermeture silencieuse | invite native avant le timeout Codex |
| réponse partielle, trop grande ou JSON invalide | ne rien relayer, exit `0` vide | invite native |

Je n’utiliserais **jamais** un exit non nul comme mécanisme normal de repli, et
jamais l’exit `2` : ce dernier est documenté comme décision bloquante pour
d’autres événements, pas comme abstention de `PermissionRequest`.

Un `SIGKILL` est le seul cas qu’un helper seul ne peut pas convertir en exit `0`.
Le comportement silencieux n’est pas garanti par la documentation : Codex voit
une exécution de hook échouée et peut afficher l’échec. L’agrégation devrait
ensuite n’avoir reçu aucune décision et tomber sur le natif, mais je ne
transformerais pas ce « devrait » en contrat produit sans injection de faute
sur 0.153.4.

Pour satisfaire réellement l’exigence « helper tué », je changerais le wrapper :
pas d’`exec` direct du binaire. Un petit superviseur reste le processus connu de
Codex, lance le worker, recueille une réponse complète, la valide, puis :

- worker tué / crashé ⇒ superviseur exit `0`, aucune sortie ;
- réponse valide ⇒ un seul petit `write` atomique vers stdout, puis exit `0`.

Si le superviseur lui-même ou tout son groupe reçoit `SIGKILL`, aucun code
utilisateur ne peut promettre le silence. Ce cas doit être testé et documenté
comme fail-open fonctionnel éventuel, pas comme chemin silencieux garanti.

Autre piège du transport actuel : `shutdown(fd, SHUT_WR)` sert d’EOF de trame.
Une fois cet EOF consommé, `BridgeServer` ne sait plus distinguer « helper
toujours vivant et en attente » de « helper mort » sans tenter une écriture.
Pour Codex PermissionRequest, je préfère une enveloppe **framed** (taille + JSON)
sans half-close : la source reste armée et un vrai EOF/HUP retire immédiatement
la carte fantôme. Le socket Codex séparé permet cette évolution sans toucher au
protocole Claude.

## 3. Corrélation : la connexion est l’identité

Il n’existe pas de meilleur champ public caché : le schéma officiel de
`PermissionRequest` donne `session_id`, `turn_id`, `tool_name` et `tool_input`,
mais pas `tool_use_id`. `PostToolUse`, lui, possède bien `tool_use_id`.

Heureusement, il ne faut pas corréler la **décision** avec un événement futur.
Chaque invocation synchrone possède déjà une identité parfaite : son processus
de helper et sa connexion socket encore ouverte. À la réception :

1. Atoll crée un UUID local `requestID` ;
2. il l’associe au fd exact et à la carte exacte ;
3. le clic sur cette carte répond uniquement sur ce fd ;
4. EOF/HUP, `Stop`, `Interrupt` ou `SessionEnd` annulent les fd concernés.

Deux demandes parallèles, même `session_id`, même outil et même input restent
ainsi distinctes. Il faut accepter plusieurs cartes pendantes par session ou les
mettre en file sans perdre leurs connexions ; surtout, ne jamais les fusionner.

Pour nettoyer sur un `PostToolUse`, le meilleur discriminant disponible est un
fingerprint canonique `(turn_id, tool_name, tool_input)`, mais il n’est pas une
identité : deux appels identiques peuvent coexister. Mon choix est donc le même
que côté Claude, en plus strict : **l’ambiguïté ne referme rien**. En pratique,
la carte doit déjà disparaître au clic, au hand-back ou à la mort de sa propre
connexion ; `PostToolUse` ne doit être qu’un filet de nettoyage d’un candidat
unique, jamais l’autorité de corrélation.

## 4. Champs réservés : « fail closed » signifie bien action refusée

La nuance est tranchée par la documentation : renvoyer `updatedInput`,
`updatedPermissions` ou `interrupt` pour `PermissionRequest` entraîne le
**refus de la requête**. Ce n’est pas « réponse du hook invalide puis invite
native ». L’action est refusée par sécurité.

C’est pourquoi le helper Codex ne doit jamais relayer aveuglément les octets de
l’app. Il doit parser puis ré-encoder une allowlist minuscule :

- `hookSpecificOutput.hookEventName == "PermissionRequest"` ;
- `decision.behavior` exactement `allow` ou `deny` ;
- `message` seulement pour `deny`, chaîne bornée ;
- aucune autre clé.

Tout JSON inconnu, incomplet, surdimensionné ou venant d’une version future
devient une abstention silencieuse. Je garderais un constructeur
`CodexPermissionDecision` distinct de `PermissionDecision` Claude, même si les
formes se ressemblent aujourd’hui. L’isolation fournisseur qui a protégé les
événements doit aussi protéger les décisions.

Une autre règle importante : si plusieurs hooks correspondants décident, le
moindre `deny` gagne. Un clic « Autoriser » dans Atoll signifie donc « Atoll a
autorisé », pas « l’outil s’est forcément exécuté ». L’UI ne doit confirmer
l’exécution qu’après le vrai événement suivant.

## 5. Arbitrage produit

Je ne maintiens plus mon « laisser les décisions dans Codex pour cette version »
comme veto. Il était juste quand le contrat, le fail-open et la session réelle
n’étaient pas prouvés. Avec la parité désormais mesurée et la décision explicite
de Mehdi, **je recommande de faire le lot 3**.

Mais je limiterais cette première livraison à la parité manuelle :

- carte clairement marquée **Codex** ;
- boutons Autoriser / Refuser pour cette demande ;
- bouton explicite **« Décider dans Codex »** qui ferme sans stdout ;
- aucune auto-approbation Codex héritée implicitement de Rockstar dans ce lot ;
- aucun bouton « toujours autoriser » : le contrat du hook ne promet qu’une
  décision pour la demande courante, pas une modification persistante de la
  politique Codex.

Une fois la matrice de faute ci-dessous verte, je l’activerais normalement avec
l’intégration Codex, pas derrière un prototype caché :

1. app absente avant connexion ;
2. app tuée avec carte ouverte ;
3. hand-back explicite ;
4. deadline interne avant 600 s ;
5. worker `SIGTERM` puis `SIGKILL` sous superviseur ;
6. réponse vide, partielle, malformée, surdimensionnée et avec chacun des trois
   champs réservés — toutes doivent ouvrir le natif, jamais refuser l’action ;
7. deux demandes simultanées strictement identiques, résolution d’une seule ;
8. Échap pendant l’attente, sans carte fantôme ;
9. autre hook concurrent qui renvoie `deny`, sans faux succès Atoll ;
10. allow et deny nominaux, avec exactement une interface visible à la fois.

En bref : **600 s côté Codex, 570 s côté helper ; exit 0 vide comme unique
abstention ; corrélation par fd/UUID, jamais par nom d’outil ; validation stricte
des deux seules décisions ; carte manuelle oui, moteur d’autonomie Codex non dans
ce lot.**
