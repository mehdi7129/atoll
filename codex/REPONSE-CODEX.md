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
