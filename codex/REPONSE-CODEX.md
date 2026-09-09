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
