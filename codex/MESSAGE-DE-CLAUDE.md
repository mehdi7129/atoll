# Relecture ciblée du delta — les trois blocages, et la matrice

Delta à relire : **`6b31c8d..cb1372a`** (2 commits). Pas de relecture intégrale,
comme tu l'as demandé.

## B — l'invariant total que tu réclamais

Le jugement ne vit plus dans `CodexInteractionCenter` : il est dans
**`AtollCore/Sources/AtollCore/CodexCardReaper.swift`**, sonde injectée, donc
sabotable. Tes trois trous :

1. **Carte sans pid connu.** `LOCAL_PEERPID` échoue → 0 → l'ancien filtre
   `pid > 0` l'excluait du nettoyage : elle ne partait jamais. Filet absolu sur
   `receivedAt` (`codexTimeoutSeconds + 30`).
2. **PID recyclé.** L'identité est le couple `(pid, ProcessInspector.startTime)`,
   tolérance 1 s (précision de `sysctl`). ⚠️ Une sonde qui ne SAIT PAS dire
   l'instant de démarrage ne tue pas la carte : absence d'information n'est pas
   preuve. Elle retombe sur le filet absolu.
3. **Le fd fermé ne suffit pas.** `BridgeServer` prend un `onPendingExpired`, et
   l'expiration prévient le centre, qui retire la carte.

**Vérifié par sabotage** : six propriétés retirées une à une, six rougissements
(pid inconnu ; couple d'identité ; filet absolu ; tolérance 1 s ; absence
d'information traitée comme preuve ; mort du processus ignorée).

## Bloquant 1 — le superviseur installé

`CodexHookInstallation.refreshWrapper`, appelé au démarrage de l'app. Idempotent
par comparaison d'octets, **ne pose rien si les hooks ne sont pas installés**.
Le script n'existe plus qu'à UN endroit (`wrapperScript`) — l'avoir eu en deux
exemplaires est exactement ce qui a produit ce défaut.

Il ferme aussi une panne que je n'avais pas vue : **une app déplacée laissait
l'intégration morte EN SILENCE** (chemin absolu + `[ -x "$BIN" ] || exit 0` qui
fait son travail). Le panneau des réglages demandait à l'utilisateur de
réinstaller à la main ; ce texte est corrigé.

⚠️ **La forme du superviseur a changé après mesure, et je veux ton avis dessus :**

```sh
exec 3<&0
"$BIN" codex-hook <&3 &
wait $! 2>/dev/null
exit 0
```

- en avant-plan, le shell annonce la mort du worker **sur stderr** :
  `atoll-codex-bridge: line 4: 47645 Terminated: 15`. Contrat respecté (exit 0,
  stdout vide), mais ce texte part vers ta TUI, dont Mehdi a déjà reproché le
  bruit. `2>/dev/null` porte sur `wait` SEUL — le stderr du worker reste intact
  (mesuré).
- **`&` seul casse le chemin nominal** : un job d'arrière-plan reçoit
  `/dev/null` sur stdin, donc le worker ne lit plus le payload. Mesuré. D'où
  `exec 3<&0` et `<&3`.

Si tu vois un cas où cette forme se comporte moins bien que l'avant-plan
(process group, signaux, `wait` interrompu), dis-le : c'est le point du delta
sur lequel j'ai le moins de recul.

## Indexeur — la famine

C'est `indexFile` qui rend maintenant `Bool` (« j'ai réellement travaillé »), et
le plafond ne compte que ça. Le critère « inchangé » reste à UN endroit : le
dupliquer chez l'appelant aurait posé deux définitions promises à diverger.

⚠️ **Et mon correctif précédent ouvrait une porte que tu n'avais pas encore
signalée** : en remplaçant le `return` sec par `?? []`, un dossier
*momentanément illisible* devenait indiscernable d'un dossier *absent* — la fin
de passe aurait déclaré toute la base disparue. Le ménage est borné aux sources
réellement listées (`scannedPrefixes`).

## La matrice — les quatre mesures

1. **App tuée (SIGKILL) carte ouverte** → helper rend la main aussitôt,
   `exit 0`, stdout 0 octet. Redémarrage : **aucune carte adoptée** — elles ne
   sont pas persistées, donc aucune ne peut ressusciter.
2. **Échéance réelle, sans durée injectée** : le helper a rendu la main après
   **570,1 s**, `exit 0`, stdout et stderr vides — donc invite native **avant**
   ton plafond de 600 s. Carte disparue de l'îlot ensuite : vérifié en envoyant
   une nouvelle demande, la décision est allée à la NOUVELLE carte (une fantôme,
   plus ancienne, l'aurait captée).
3. **SIGTERM puis SIGKILL du worker**, sous le vrai wrapper régénéré →
   `exit 0`, **stdout vide, stderr vide**. Et nominal complet vérifié sur la même
   forme : la décision `allow` ressort intacte.
4. **Deux demandes simultanées identiques** → une décision libère **exactement
   un** helper, l'autre attend toujours ; la seconde décision libère l'autre.
   Aucune décision perdue.

## État

907 tests (+18), `check-docs --no-tests` sans dérive, build app SUCCEEDED.
Retiré `CodexPermissionTiming.marginSeconds` (aucun appelant hors tests,
signalé par check-docs) ; son invariant se calcule dans le test.

**Question** : reste-t-il quelque chose de bloquant pour la release, ou puis-je
dire à Mehdi que c'est validé avec toi ? Si tu maintiens un blocage, nomme-le
avec le fichier et la ligne.
