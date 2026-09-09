# Revue du correctif v0.17.1 — tes quatre P2, plus la cause racine

Ta relecture d'aujourd'hui a produit une v0.17.1. **Relis le correctif lui-même**,
pas le code d'origine : dans ce projet, la revue d'un correctif a déjà trouvé une
régression DANS le correctif (v0.16.6, un créneau de quota non remboursé).

Le diff est dans l'arbre de travail — `git diff` (rien n'est committé).

## Ce que j'ai fait de chacun de tes constats

**B1 — `PostToolUse` retirait la mauvaise carte.** Filet **SUPPRIMÉ**, pas
raffiné. Ta règle du candidat unique compte les candidats APRÈS le retrait des
cartes tranchées : elle ne peut pas être réparée sans corrélation, et
`PermissionRequest` n'en offre aucune. Il n'apportait aucune garantie que les
autres autorités n'apportent déjà sur un fait CONSTATÉ — clic, retour explicite,
`SessionEnd`, tour clos, mort du helper, expiration serveur. Le commentaire
explique pourquoi, pour que personne ne le réintroduise.
**Question pour toi : ai-je retiré une garantie que je crois couverte et qui ne
l'est pas ?** C'est le point où j'ai le moins de recul.

**B2 — le filtrage ne gouvernait pas les cartes.** `CodexSessions.applyEvent`
rend `Applied(accepted:ended:closedTurn:)` ; `apply` reste une vue étroite au-
dessus (une seule logique, pour ne pas la voir diverger). `AppDelegate`
n'enregistre plus la carte si `accepted == false` et **rend la main** au helper
dans ce cas (fail-open : Codex demande lui-même). `Interrupt`/`Stop` nomment le
tour clos, et `CodexInteractionCenter.cancelAll(forSession:turn:)` retire ses
cartes — la carte porte maintenant son `turnID`.

**B3 — la passation.** Chemin **absolu** du contexte (les chemins se calculent
avant le script, plus après), exécutable **résolu** via `CodexExecutable`, et
`start` est devenu `async` : `.opened` n'est rendu qu'après le résultat réel de
`NSWorkspace.open`, un échec devient `.failed` avec le chemin du script prêt.

**B4 — la mémoire n'est pas étanche.** Mesuré : **1 051 messages Codex sur
70 685, dont 37 `user` et 92 `assistant`** — les rôles injectables. Je n'ai pas
ajouté de filtre : la mémoire commune est voulue. J'ai corrigé l'AFFIRMATION, au
README et dans le panneau de réglages (« l'étanchéité porte sur les décisions,
pas sur le corpus »).

**P3 — annulation du scan Codex.** `return (seen, false)`.

**P3 — texte du produit.** `SessionDetailView` dit maintenant ce qui est
constaté : carte présente dans l'îlot, ou à traiter dans Codex.

**Cause racine de l'appcast.** `Scripts/release.sh` repointe chaque URL vers le
tag de sa propre version après `generate_appcast`, et `check-docs.py` vérifie
l'invariant **sans réseau** (il n'était attrapé que par `--network`, donc jamais
par le préflight). Vérifié en rejouant le post-traitement sur l'appcast
réellement cassé de ce matin : **sortie identique à l'octet près** au correctif
manuel.

**Deux warnings de la v0.17.0**, dont un qui devenait une ERREUR en Swift 6
(`makeIterator` en contexte async) : fermés.

## Vérifications de mon côté

- **916 tests**, 1 ignoré, 0 échec ; build Debug app + helper **0 warning**.
- Nouveaux tests **validés par sabotage**, une propriété à la fois : chemin
  relatif restauré → 2 tests rouges ; exécutable ignoré → 2 rouges ; rejet
  déclaré accepté → 2 rouges ; tour clos non nommé → rouge ; tout événement
  clôturant → rouge. Le contrôle d'appcast saboté avec le vrai fichier cassé →
  2 erreurs, nommées.
- `check-docs --no-tests --preflight` : aucune dérive.

## Ce que je te demande

1. **Une régression dans le correctif** — c'est le but de cette passe.
2. **B1 : la suppression est-elle sûre ?** Nomme un scénario où une carte reste
   affichée alors que plus personne n'attend, et qu'aucune des autres autorités
   ne couvre.
3. **B2 : le `handBack` sur événement rejeté est-il le bon geste ?** Il ferme le
   fd sans répondre, donc Codex demande nativement. L'alternative — ne rien
   faire — laisse le helper attendre jusqu'à l'expiration.
4. **Ce qui reste hors périmètre de cette 0.17.1**, pour que je l'écrive sans le
   promettre.

Lecture seule. N'écris rien : rends ton avis, je corrige.
