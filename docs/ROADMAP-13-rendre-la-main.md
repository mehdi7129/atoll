# Phase 13 — « Rendre la main »

> ⚠️ **DOCUMENT HISTORIQUE — lire l'avertissement avant le plan.** La phase a été
> livrée en v0.13.0, PUIS son volet **13a « fin de tâche annoncée » a été RETIRÉ**
> le 2026-08-03 avec le cockpit ⌘N : sa seule source était la fenêtre de lancement,
> qui n'a jamais lancé une tâche, donc l'annonce n'a jamais sonné. `LaunchedTask`,
> `TaskCompletionNotifier` et `FleetLauncherWindow` n'existent plus, et plus aucune
> ligne du dépôt n'importe `UserNotifications`. Tout ce qui suit décrit donc une
> INTENTION de juillet, pas l'état du code. Les volets sons et flotte-par-état,
> eux, sont bien vivants.
>
> Plan de développement validé avec Mehdi le 2026-07-27.
> Fil conducteur : **Atoll sait démarrer et surveiller ; il doit apprendre à
> rendre la main.** Quand une tâche finit, quand une décision est attendue,
> l'information doit venir CHERCHER l'utilisateur — au lieu qu'il ait à revenir
> regarder l'îlot.

## Pourquoi maintenant

Trois manques convergent vers le même défaut :

1. Le cockpit ambiant (Phase 9) lance une tâche `--bg` depuis le notch, mais
   **rien ne prévient à la fin** — demandé en Phase 9, jamais livré.
2. Les sons qui préviennent aujourd'hui **ne viennent pas d'Atoll** : ce sont
   deux hooks `afplay` dans le `settings.json` de Mehdi. Ils marchent, mais ils
   ne sont ni découvrables, ni réglables, ni liés à ce qu'Atoll sait de l'état
   réel des sessions.
3. L'îlot groupe par projet (v0.9.1) ; à partir de 4-5 sessions, la question
   n'est plus « quel projet ? » mais **« laquelle attend quelque chose de moi ? »**.

## Objectifs mesurables

| # | Objectif | Critère de réussite (vérifiable) |
|---|---|---|
| 13a | Une tâche lancée du notch prévient quand elle finit | Lancer une tâche `--bg` depuis le notch → notification macOS avec un résumé LISIBLE d'une ligne, ≤ 5 s après la fin ; clic = l'îlot s'ouvre sur la session |
| 13a | Zéro fausse alerte | Aucune notification pour une session interactive ou un `--bg` lancé hors du notch |
| 13a | Une seule annonce par tâche | Hook `Stop` PUIS disparition de la flotte = 1 notification, pas 2 |
| 13b | Deux sons distincts, pilotés par Atoll | Une carte de permission joue le son « décision » ; une fin de tour joue le son « terminé » |
| 13b | Personnalisation complète | 14 sons système + import d'un fichier (aiff/wav/mp3/m4a/caf) + volume par événement + écoute depuis les Réglages |
| 13b | Migration sans perte | Les 2 hooks `afplay` de Mehdi sont PARQUÉS (réversibles), et ses 2 mp3 repris tels quels : jour 1 identique à l'oreille |
| 13b | Réversibilité prouvée | Désactiver le réglage OU désinstaller Atoll restitue les hooks à l'identique dans `settings.json` |
| 13c | Voir la flotte par état | Bascule « par projet / par état » ; les sessions qui attendent une décision sont EN TÊTE |
| 13d | Produit fini | 0 warning, tests verts, revue adversariale sans confirmé, README/CLAUDE.md/HANDOFF à jour, release notarisée |

## 13a — Notification de fin de tâche `--bg`

**Portée (choix de Mehdi)** : uniquement les tâches lancées depuis le notch.
C'est la seule catégorie qu'Atoll connaît de PREMIÈRE MAIN (il les a lancées).
On ne se sert PAS de `AgentSessionInfo.Kind.background` : le code documente
qu'il n'est pas fiable (« vu : une session interactive rapportée `background` »).

**Surface (choix de Mehdi)** : notification macOS **et** marque dans le notch.

Chaîne : `FleetLauncher.launch` enregistre la tâche → hook `Stop` (porte
`last_assistant_message`) → résumé d'une ligne → `UNUserNotificationCenter` +
bannière dans l'îlot étendu.

Pièges identifiés AVANT de coder :
- `claude --bg` peut n'imprimer qu'un **préfixe** d'identifiant (8 hex) là où les
  hooks portent l'UUID complet → comparaison par préfixe, jamais par égalité.
- Si l'identifiant est illisible, rattrapage par **dossier + horodatage**
  (fenêtre 180 s, jamais une session démarrée avant le lancement).
- `UNUserNotificationCenter.delegate` est une référence **faible** → retenir le
  délégué, sinon les clics ne font rien.
- Le journal est **persisté** (`~/.atoll/launched-tasks.json`) : une tâche de
  fond survit à un redémarrage d'Atoll.

## 13b — Sons (le gros morceau)

### Ce qui existe aujourd'hui chez Mehdi

```
Notification → afplay -v 0.1 '~/.claude/song/need-human.mp3'    (74 Ko)
Stop         → afplay -v 0.1 '~/.claude/song/finish.mp3'       (210 Ko)
```

Le `-v 0.1` dit l'essentiel : **il les veut discrets**. Volume réglable, bas par
défaut.

### Conception

Deux événements, indépendants :

| Événement | Déclencheur dans Atoll | Défaut |
|---|---|---|
| `decisionNeeded` | une carte de permission / question / plan apparaît | son repris de `need-human.mp3` |
| `taskCompleted` | fin de tour d'une session suivie (hook `Stop`) | son repris de `finish.mp3` |

Chaque événement porte : un **choix** (silencieux · un des 14 sons système · un
fichier personnalisé), un **volume** (0–100 %, défaut 15 %), et un **essai** (▶).

Un fichier importé est **copié** dans `~/.atoll/sounds/` : si l'original est
déplacé ou supprimé, le son continue de marcher.

Portée du son « terminé » : toutes les sessions par défaut (= le comportement
actuel de Mehdi), restreignable aux tâches lancées depuis le notch.

**Anti-rafale** : trois sessions qui finissent en même temps ne doivent pas
empiler trois sons → intervalle minimum par événement.

### Migration des hooks — la partie délicate

La règle n° 2 du projet dit que `~/.claude/settings.json` est SACRÉ et que les
hooks non-Atoll de Mehdi doivent être préservés. Retirer ses hooks sonores est
donc une **exception encadrée**, sur sa demande explicite — le même régime que le
parking Rockstar :

1. détecter les hooks sonores non-Atoll (`afplay`, `/System/Library/Sounds`,
   fichiers audio) et **les montrer** dans les Réglages avant toute action ;
2. proposer d'**importer leurs fichiers audio** comme sons Atoll (jour 1
   identique à l'oreille) ;
3. écrire `~/.atoll/parked-sound-hooks.json` **AVANT** de toucher settings.json
   (crash-safe) ;
4. retirer les entrées, en préservant tout le reste (les hooks GSD, le
   command-validator, la statusline) ;
5. **restituer** à la désactivation du réglage, à la désinstallation d'Atoll, et
   par réconciliation au lancement si un parking traîne.

Jamais automatique : rien ne bouge sans un geste explicite dans les Réglages.

## 13c — Vue de la flotte par état

Bascule dans l'îlot étendu, en gardant le groupement par projet comme second
mode. Ordre imposé : **attente d'une décision** → en cours → au repos →
terminées. La v0.9.1 a montré que le regroupement adaptatif marche (1 session =
ligne directe, ≥ 2 = dossier pliable) : même idiome.

## 13d — « Produit fini »

- Audit + **revue adversariale multi-agents** (méthode HANDOFF §2) sur les trois
  volets, avec vérification de chaque trouvaille avant correction.
- Vérification VISUELLE obligatoire (captures sur le **2ᵉ écran** — Mehdi
  travaille sur le 1ᵉʳ).
- Tests d'écoute réels : les deux sons, les 14 système, un import.
- README + CLAUDE.md + HANDOFF + PLAN mis à jour, puis release notarisée via le
  skill `atoll-release-pipeline`.

## Règles que ce chantier ne doit pas enfreindre

- **Fail-open** : aucun son, aucune notification ne doit pouvoir ralentir ou
  casser le CLI `claude`. Tout se joue dans l'app, hors du chemin des hooks.
- **Zéro télémétrie**, aucune dépendance nouvelle (NSSound et
  UserNotifications sont dans le système).
- **Réversibilité** : ce qu'Atoll retire du `settings.json`, Atoll sait le
  remettre — et le prouve par un test.
