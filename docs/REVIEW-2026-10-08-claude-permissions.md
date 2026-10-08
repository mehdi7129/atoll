# Permissions Claude : garder la bonne demande

Correction A06 de l'audit du 8 octobre. Deux demandes Bash de la même session
peuvent coexister. Autoriser A puis recevoir sa fin d'outil ne retire plus B et
ne masque plus sa phase d'attente. Les noms d'outils, leurs résumés et un candidat
unique ne constituent pas une preuve de résolution.

## Comportement conservé et correction

`SessionStore` maintient l'attente tant qu'une carte réelle subsiste, y compris
après PreToolUse, PostToolUse, PostToolUseFailure, PermissionDenied et les événements
de sous-agent. Une décision explicite traite son identifiant de demande ; une
réponse de A ne libère pas la phase de B. Stop, SessionEnd et UserPromptSubmit
clôturent toujours les demandes du tour entier.

`BridgeServer` observe la sortie du processus client identifié par le socket
(`LOCAL_PEERPID`). Le half-close normal de l'écriture ne suffit jamais : le
helper reste vivant et attend sa réponse. Le watcher est annulé après réponse,
retrait, expiration ou arrêt du serveur. L'expiration notifie le centre de la
seule demande concernée, sans produire de décision pour le CLI.

La première recette a trouvé une course dans le correctif : un helper déjà sorti
pouvait rendre `ENOTCONN` pendant la lecture de son PID. Revenir silencieusement
laissait sa carte sans watcher. Ce seul code d'erreur prouve maintenant la
fermeture de la connexion ; les autres erreurs d'identification restent prudentes.
Les callbacks de création et d'expiration sont appliqués dans leur ordre sur la
main queue. Aucun nouveau signal n'est envoyé à un processus par le produit.

## Validation

Le harness `Scripts/test-claude-permissions.py` compile les véritables
`InteractionCenter`, `SessionStore`, `BridgeServer`, `TranscriptTailer` et
`ProcessInspector`. Chaque client est un processus privé utilisant à l'identique
le transport `sendToSocket` du helper produit, sur un socket privé. Le home
Foundation et Application Support sont contrôlés avant les premières actions ;
le mode d'autonomie utilise uniquement un domaine volatile de préférences.
Les sons, l'indexation et les collaborateurs Codex sont neutralisés.

- **30 scénarios runtime**, zéro échec : A/B homonymes, outils identiques,
  différents ou absents, cartes et phases contrôlées ensemble, réponse explicite,
  expiration retardée de A, mort du helper, timeout, clôture globale et Rockstar.
- Cinq clients quittent avant que la queue du serveur lise leur enveloppe :
  scénario déterministe d'une connexion déjà fermée, sans carte fantôme.
- Le timeout passe par le vrai chemin d'expiration via une extension privée au
  harness ; il ne nécessite pas d'attendre une journée ni de modifier le délai
  du produit. La sortie du client rend un résultat vide, jamais un allow inventé.
- **Quatre sabotages compilés détectés**, chacun précédé d'un nominal réussi :
  retrait global sur PostToolUse, suppression de la garde de phase, retrait du
  watcher de processus et ignorance d'ENOTCONN.

```sh
python3 Scripts/test-claude-permissions.py
python3 Scripts/test-claude-permissions.py --sabotage card
python3 Scripts/test-claude-permissions.py --sabotage phase
python3 Scripts/test-claude-permissions.py --sabotage helper-exit
python3 Scripts/test-claude-permissions.py --sabotage disconnected-helper
```

`--build-dir` permet de réutiliser les objets Core compilés. Les mutations sont
faites dans des copies privées, jamais dans les sources produit. Aucun CLI
Claude authentifié, configuration personnelle, socket de l'app installée ou
app graphique n'est utilisé. La recette valide le protocole et les trois
composants ensemble ; l'intégration Xcode et la suite Core complète se vérifient
sur l'arbre réunissant tous les lots. Ce rapport n'annonce aucune publication.
