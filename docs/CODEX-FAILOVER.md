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
- **798 tests verts** (761 avant ce lot), 1 test réseau ignoré par défaut.
  Les propriétés de `ProviderFailover` ont été **vérifiées par sabotage**, une à
  une : l'ignorance qui bascule, `min` au lieu de `max`, le seuil rendu
  exclusif, la fenêtre expirée toujours crue. Quatre sabotages, quatre échecs.

### À mesurer avant de fusionner

1. **Un `codex exec` qui va au bout, avec `--output-schema`.** Le seul essai
   réel s'est arrêté sur le quota épuisé : le chemin est prouvé jusqu'à l'appel,
   **pas au-delà**. Il reste à vérifier que Codex écrit bien un JSON conforme
   dans le fichier de `--output-last-message`, et que
   `RetrospectiveReport.parse(codexOutput:)` le lit. Tant que ce n'est pas fait,
   ne pas annoncer le lot A comme fonctionnel.
2. **Un handoff réel** : le bouton « CONTINUER DANS CODEX », le `.command`
   ouvert par Terminal.app, et Codex qui lit `contexte.md`.
3. **Le parcours de hooks réel** de la PR #1, toujours en attente (approbation
   dans `/hooks`, puis une vraie session).

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
