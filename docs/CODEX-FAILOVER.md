# Bascule Claude → Codex

État : **travail expérimental, non publié**, 2026-09-06.
Branche : `codex/codex-support-dual-quotas`, empilé sur la PR #1.
Demande de Mehdi : « si je n'ai plus de quota sur Claude, j'aimerais que ça
passe sur mon compte Codex ».

## Ce qui bascule, et ce qui ne peut pas basculer

La PR #1 **observe** Codex et **lit** son quota. Elle ne bascule rien. Ce
document décrit ce qui a été ajouté par-dessus.

| | État | Pourquoi |
|---|---|---|
| **A — les deux dépenses d'Atoll** (bilan de fin de session, rangement des notes) | ✅ bascule **automatique** | Atoll lance lui-même ces `claude -p`. Il contrôle le processus de bout en bout, donc il peut le lancer ailleurs. |
| **B — la session interactive** | ⚠️ **geste**, pas bascule | Bouton « CONTINUER DANS CODEX » : ouvre un terminal sur Codex dans le même dossier, avec un condensé de la session à côté. |
| **B′ — bascule interactive automatique** | ❌ **impossible** | Atoll **observe** le CLI `claude`, il ne le pilote pas. Aucun hook, aucun réglage ne transforme une session en cours en session Codex. Ne pas le promettre. |

Le point B′ est la limite structurelle de tout ce dossier. Elle mérite d'être
répétée parce que le titre « bascule » laisse croire l'inverse : ce qui passe
sur Codex, ce sont les analyses qu'**Atoll** paie, pas le travail de Mehdi.

## Ordre des portes, et pourquoi il est impératif

```
ProviderFailover.choose  →  quel abonnement paie ?
        ↓ (le fournisseur retenu)
LearningGate.decide      →  cette dépense vaut-elle la peine, sur CE quota ?
        ↓
CodexRun.prepare / ClaudeExecutable.resolve
```

Choisir d'abord évite d'évaluer un plafond de fenêtre sur un compte qu'on ne va
pas débiter — et donc de refuser un run que le second abonnement pouvait payer.
`LearningGate` n'a pas été modifié : il reçoit simplement les faits de quota du
fournisseur retenu, via `ProviderFailover.quotaFacts(of:)`. C'est ce qui garantit
qu'une dépense Codex est arbitrée avec **exactement** les mêmes règles (seuil,
fraîcheur, plafond par fenêtre) qu'une dépense Claude.

### ⚠️ Le garde-fou qu'il ne faut pas retirer

Quand aucun fournisseur ne peut payer, l'appelant **saute avant** `LearningGate`.
Ce n'est pas de la coquetterie : « quota inconnu » n'est pas un refus sec chez
lui — il accorde `unknownQuotaMaxPerWindow` run(s) à l'aveugle. Sans ce
court-circuit, il dirait `.run`, et ce run partirait sur le Claude qu'on vient
justement de mesurer plein. C'est le motif exact de la régression trouvée dans le
correctif de la v0.16.6 : la bonne décision prise, puis dépensée quand même faute
d'une ligne dans la porte suivante.

## Les invariants de `ProviderFailover`

- **OFF par défaut.** Dépenser un second abonnement est un choix explicite.
- **Une donnée absente n'est pas un quota épuisé.** Un quota Claude INCONNU ou
  périmé ne déclenche **pas** la bascule. C'est la règle la plus contre-intuitive
  du module et la plus importante : sans mesure fraîche, « épuisé » est une
  supposition, et une supposition ne doit pas débiter l'autre compte.
- **Basculer vers un compte dont on ne sait rien, c'est remplacer un échec connu
  par un échec inconnu** : quota Codex absent ou périmé ⇒ on ne lance rien.
- **Un `resetsAt` passé rend la valeur muette**, des deux côtés (même piège que
  `StatusLinePayload` : un cache d'avant la réinitialisation).
- **Seuil distinct de celui du gate** (95 % contre 70 %). Le seuil du gate dit
  « pas assez de marge pour me permettre ça » ; celui-ci dit « il n'y a plus
  rien ». Basculer au premier ferait payer Codex alors que Claude peut encore
  servir Mehdi pour son propre travail.
- **La fenêtre Codex retenue est la PLUS CONTRAIGNANTE** (`max`), jamais la
  moyenne ni la plus favorable — voir la mesure ci-dessous, qui l'a tranché.

## Trois comportements hérités, assumés et nommés

1. **`lastSpendAt` de la curation est PARTAGÉ entre les deux abonnements.** Une
   dépense Claude il y a deux heures bloque donc une dépense Codex dans la même
   fenêtre, même si le compte Codex est vierge. C'est conservateur, et sans
   effet pratique : le rangement des notes est hebdomadaire. À revoir seulement
   si un troisième consommateur apparaît.
2. **Côté curation, `finish` avance `lastRunAt` même sur échec** — donc un
   « codex introuvable » repousse le rangement automatique d'une semaine, comme
   le fait déjà un « claude introuvable ». Ce n'est pas un oubli : le
   commentaire de `finish` le veut ainsi, pour ne pas relancer un cycle toutes
   les six heures sur une panne de configuration. Le bouton « Ranger
   maintenant » reste disponible. Défaut préexistant, déjà signalé dans
   `CLAUDE.md` comme à trancher hors gel ; ce lot ne l'élargit pas au-delà de
   son chemin jumeau.
3. **La fenêtre de 5 h est supposée commune.** `quotaRefusal` borne la dépense
   sur `LearningGate.runWindowSeconds` (5 h, la fenêtre Anthropic) ; la fenêtre
   principale de Codex mesure 300 min, soit la même durée. C'est une COÏNCIDENCE
   vérifiée le 2026-09-06, pas un contrat : si Codex change de fenêtre, c'est
   `ProviderFailover.quotaFacts(of:)` qui portera la vérité (il lit `resetsAt`
   du serveur), mais le plafond par fenêtre, lui, restera calé sur 5 h.

## Ce qui a été mesuré, et ce qui reste à mesurer

### Mesuré le 2026-09-06

- **Format des hooks Codex validé sur pièces**, ce que le handoff de la PR #1
  listait comme non fait. Le `hooks.json` écrit par `CodexHookSettingsEditor` a
  été soumis au RPC `hooks/list` d'un `codex app-server` lancé sur un
  `CODEX_HOME` jetable : **les 10 événements sont reconnus** (`preToolUse`,
  `permissionRequest`, `postToolUse`, `preCompact`, `postCompact`,
  `sessionStart`, `sessionEnd`, `stop`, `interrupt`, `userPromptSubmit`),
  `timeout: 3` devient `timeoutSec: 3`, et `trustStatus: "untrusted"` confirme
  qu'une approbation dans `/hooks` reste nécessaire. **Un événement inconnu est
  ignoré sans invalider le fichier** : si OpenAI renomme un événement, Atoll ne
  casse pas la configuration Codex de l'utilisateur.
- **Le quota Codex de Mehdi était épuisé au moment du test** :
  `codex/primary` (fenêtre 300 min) à **100 %**, `codex/secondary`
  (10 080 min) à **16 %**. `codex exec` a répondu « You've hit your usage
  limit » et sorti en 1.
  **C'est ce relevé qui a tranché `max` contre `min`** : en retenant la fenêtre
  la moins chargée, Atoll aurait lu 16 %, jugé Codex disponible, lancé un run
  condamné, et brûlé un créneau de sa propre fenêtre pour un `failed(exit 1)`.
  Le cas est figé dans `ProviderFailoverTests` avec ses valeurs réelles.
- **`codex exec` LIT STDIN même quand le prompt est en argument.** Sans
  `/dev/null`, il imprime « Reading additional input from stdin... » et attend
  EOF — soit, depuis Atoll, dix minutes de watchdog par run. Les deux lanceurs
  posent `standardInput = .nullDevice` ; le commentaire est au point de spawn.
- **806 tests verts** (761 avant ce lot), 1 test réseau ignoré par défaut.
  Les propriétés de `ProviderFailover` ont été **vérifiées par sabotage**, une à
  une : l'ignorance qui bascule, `min` au lieu de `max`, le seuil rendu
  exclusif, la fenêtre expirée toujours crue. Quatre sabotages, quatre échecs.

### Mesuré le 2026-09-07 — les deux points bloquants

**1. LE SCHÉMA D'ATOLL EST REFUSÉ PAR OPENAI.** Premier vrai `codex exec` :
HTTP 400, `invalid_json_schema`, aucun fichier produit —

> `'required' is required to be supplied and to be an array including every key
> in properties. Missing 'confidence'.`

Anthropic tolère un `required` partiel ; OpenAI l'interdit en sortie structurée
stricte, et refuse aussi `pattern`, `maxLength`, `maxItems`. **Le lot A ne
pouvait donc RIEN produire**, et aucun test unitaire ne l'aurait dit : il fallait
le vrai appel. D'où `CodexExecPlan.openAISchema(from:)`, qui traduit le schéma
Anthropic — `required` complet, champs jadis facultatifs rendus **nullables**
(forcer `similar_existing` pousserait le modèle à inventer une antériorité, soit
l'inverse du but), mots-clés non supportés retirés.

Retirer ces bornes est **sans danger, et c'est une propriété du code existant** :
`RetrospectiveReport` et `NotesCurationOutput` revalident tout en Swift
« indépendamment du `--json-schema` du CLI ». Le schéma guide le modèle ; il n'a
jamais été ce qui protège Atoll. Cinq sabotages de la conversion, cinq échecs.

**Après correctif — la chaîne complète tourne** :

| Run | Résultat |
|---|---|
| Bilan (`retro.json`) | **exit 0, 7 s**, rapport conforme dans le fichier de sortie |
| Rangement des notes (`curation.json`) | **exit 0**, deux notes fusionnées avec leurs `sources` |

Les deux rapports RÉELS sont figés verbatim dans `CodexExecPlanTests` : un test
sur un payload fabriqué à la main n'aurait pas vu le refus du schéma.

**2. LES PAYLOADS DE HOOKS CODEX SONT CONFORMES À CE QUE LIT LA PR #1.** Capture
des payloads bruts dans un `CODEX_HOME` jetable (hooks factices,
`--dangerously-bypass-hook-trust`, aucune config personnelle touchée). Six
événements dans un run simple, la chaîne entière :

```
SessionStart    cwd hook_event_name model permission_mode session_id source transcript_path
UserPromptSubmit  … prompt turn_id
PreToolUse        … tool_input tool_name tool_use_id turn_id
PostToolUse       … tool_response …
Stop              … last_assistant_message stop_hook_active turn_id
SessionEnd      cwd hook_event_name reason session_id transcript_path
```

`cwd`, `turn_id`, `model`, `prompt`, `tool_name`, `tool_input`, `session_id`
sont tous là : `CodexIntegration` nommera bien le projet et filtrera bien les
événements d'un tour périmé. **Les strings du binaire ne le disaient pas** — on
n'y trouvait ni `cwd` ni `turn_id` près des champs de hook, et j'en avais déduit
à tort un risque. C'est la capture qui tranche, pas l'inspection.

Note : `SessionEnd` ne porte PAS de `turn_id`. Sans effet — `CodexSessions.apply`
traite ce cas en premier, avant le garde de tour.

### À mesurer avant de fusionner

1. **Un handoff réel** : le bouton « CONTINUER DANS CODEX », le `.command`
   ouvert par Terminal.app, et Codex qui lit `contexte.md`.
2. **Le parcours de hooks de bout en bout dans l'app** : hooks installés depuis
   les Réglages, approuvés dans `/hooks`, et les sessions qui apparaissent
   vraiment dans l'îlot. Les payloads sont prouvés ; le trajet
   helper → socket → `CodexService` ne l'est pas encore.
3. **Un run déclenché par l'app elle-même** (trigger `retroCodex`), et non par
   un `codex exec` lancé à la main.

## Ce qui n'a PAS été touché

Rien du chemin Claude : statusline, permissions, flotte, jump-back, mémoire,
sons, rétrospective. Le fournisseur ne change **qu'un seul point** dans chaque
runner — la commande lancée et l'endroit où lire le rapport. Tout le reste
(condensé, prompt, antériorité, revalidation Swift, écriture des fichiers) est
commun : **Atoll écrit toujours lui-même, après ses propres contrôles, quel que
soit le modèle qui a répondu.** C'est cette propriété qui rend la bascule sûre.

Le journal du recall n'a pas été touché non plus — le gel de septembre tient.

## Fichiers

| Fichier | Rôle |
|---|---|
| `AtollCore/ProviderFailover.swift` | La porte : quel abonnement paie, et pourquoi. Pur, testé, saboté. |
| `AtollCore/CodexExecPlan.swift` | Traduction des deux jobs vers `codex exec`. Ce qui ne se traduit pas y est nommé. |
| `AtollCore/SessionHandoff.swift` | Contexte + script `.command` d'une reprise. Pur, testé. |
| `App/CodexExecutable.swift` | Chemin absolu de `codex` — jumelle de `ClaudeExecutable`, même piège. |
| `App/CodexRun.swift` | Fichiers temporaires et commande shell d'une dépense Codex. |
| `App/CodexHandoffService.swift` | Écrit la passation, ouvre Terminal.app (sans AppleScript, donc sans TCC). |
| `App/RetrospectiveRunner.swift` | Choix du fournisseur, gate sur SON quota, lancement, lecture du rapport. |
| `App/NotesCurationService.swift` | Idem ; `spawnClaude` scindé en `spawnShell`, partagé. |
| `App/CodexSettingsPane.swift` | Réglage de la bascule et de son seuil. |
