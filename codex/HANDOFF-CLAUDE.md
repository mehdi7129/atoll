# Revue demandée à Claude — intégration Codex d'Atoll

## Mission

Relire la [PR #1](https://github.com/mehdi7129/atoll/pull/1), signaler les défauts
avant fusion et proposer les correctifs minimaux sur
`codex/codex-support-dual-quotas`. Garder la PR en brouillon tant que le parcours
réel des hooks n'est pas validé.

Commencer par vérifier l'état :

```sh
git status --short --branch
git log --oneline --decorate -5
git diff main...HEAD --stat
gh pr view 1 --repo mehdi7129/atoll
```

Préserver les changements locaux. Ne pas fusionner, publier de release, changer
la version, remplacer `~/Applications/Atoll.app`, installer des hooks personnels
ou écrire dans le journal recall sans accord explicite de Mehdi.

## Intention et invariants

Atoll présente Claude et Codex dans une interface commune, avec deux adaptateurs
indépendants :

- quotas séparés, jamais additionnés ; absence ou erreur ≠ 0 % ;
- suivi Codex par hooks opt-in ;
- quota Codex via l'app-server du CLI connecté à ChatGPT ;
- aucune reprise de thread et aucune génération pour observer ou lire le quota ;
- permissions Codex traitées dans Codex dans cette première version ;
- Rockstar strictement Claude ;
- aucune mémoire, skill, rétrospective ou son Claude appliqué à Codex ;
- pas de chat ni d'orchestration automatique entre agents dans cette PR.

Contrats officiels à revérifier avant toute modification du protocole :
[hooks Codex](https://learn.chatgpt.com/docs/hooks) et
[app-server Codex](https://learn.chatgpt.com/docs/app-server).

## Carte du changement

### Frontière fournisseur et sessions

- `SessionModel.swift` : `AgentProvider`, Claude par défaut pour la compatibilité.
- `CodexIntegration.swift` : parseur des hooks et projection des sessions.
- `HookEvent.swift` : refuse les fournisseurs étrangers au chemin Claude.
- `NotchViewModel.swift`, `ExpandedView.swift`, `CompactView.swift` et
  `SessionDetailView.swift` : agrégation et étiquetage de présentation.

### Hooks

- `CodexPaths.swift` : `CODEX_HOME` absolu ou `~/.codex`, socket séparé
  `/tmp/atoll-codex-<uid>.sock`.
- `CodexHookInstallation.swift` : merge/retrait, backup et wrapper testables.
- `Bridge/CodexBridge.swift` : enveloppe `provider=codex`, observation fail-open,
  aucune réponse de permission.
- `Bridge/main.swift` : `codex-hook`, `install-codex`, `uninstall-codex`.
- `BridgeServer.swift` et `AppDelegate.swift` : second socket et routage avant
  tout mécanisme Claude.

Les hooks sont synchrones et bornés à 3 secondes pour garder leur ordre. L'envoi
local a une deadline de 2 secondes et ne produit aucune sortie. La confiance doit
être accordée manuellement via `/hooks` dans Codex ; l'installateur ne la contourne
pas.

### Quota

- `CodexAccountClient.swift` : processus court
  `codex app-server --listen stdio://`.
- `CodexQuota.swift` : fenêtres dynamiques et `rateLimitsByLimitId`.
- `CodexService.swift` : poll opt-in, annulation, fraîcheur et état UI.
- `CodexSettingsPane.swift` : activation, chemin et diagnostic sans secrets.

Seule séquence RPC autorisée au lecteur :

```text
initialize
initialized
account/read { refreshToken: false }
account/rateLimits/read
fin du processus
```

Ne pas lui ajouter `thread/list`, `thread/read`, `thread/resume`, `turn/start`,
login, logout ou refresh forcé.

### Aperçu

`CodexPreview.swift` et `--codex-preview` fournissent un rendu Debug avec données
fictives : pas de services, socket, hooks, réseau, login ou recall.

## Revue prioritaire

1. **Isolation** : aucun `PermissionRequest` Codex ne doit atteindre
   `InteractionCenter` ou Claude/Rockstar.
2. **App-server** : pas de blocage UI ; enfant terminé/récolté ; I/O bornées ;
   annulation réelle ; aucune fuite de stderr, email ou jeton.
3. **Configuration** : JSON invalide refusé, hooks tiers et symlinks préservés,
   backup `0600`, idempotence et modifications concurrentes.
4. **État** : ancien `turn_id`, interruption, absence de `PermissionDenied`,
   événements concurrents et silence. Un timeout donne « non confirmé », jamais
   une fausse certitude de fin.
5. **Quota** : booléens/NaN/hors limites, resets passés, fenêtres inconnues,
   catégories multiples, comptes API/déconnectés et changement de compte.
6. **UI** : encoche/pilule, petite largeur, footer, groupements, longues valeurs,
   VoiceOver, contraste et localisation.
7. **Claude** : statusline, permissions, flotte, jump-back, mémoire, sons et
   rétrospectives doivent rester inchangés.

Limites assumées : aucun inventaire historique Codex, compatibilité desktop/IDE
non prouvée, pas de jump-back/arrêt Codex, compteur de sous-agents ou interaction
Codex dans l'îlot.

## Vérifications déjà faites

- Base : 737 tests existants passants.
- Suite : 761 tests recensés, 760 passants et 1 test réseau ignoré par défaut.
- Test réseau opt-in passé avec `codex-cli 0.153.4` : quota lu, aucun thread lancé.
- Build Debug macOS arm64 app + helper réussi.
- Aperçu isolé ouvert, inspecté et fermé.
- Aucun hook personnel installé, bundle stable remplacé ou événement injecté dans
  le journal recall.

Tests ajoutés : `CodexIntegrationTests`, `CodexQuotaTests`,
`CodexAccountClientTests`, `CodexHookInstallationTests`.

Reproduction sûre :

```sh
swift test --package-path AtollCore
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/atoll-codex-build build
open -n /private/tmp/atoll-codex-build/Build/Products/Debug/Atoll.app \
  --args --codex-preview
```

Test réel du quota, uniquement avec consentement :

```sh
ATOLL_CODEX_LIVE_TEST=1 swift test --package-path AtollCore \
  --filter CodexAccountClientTests.testLiveReadOnlyAccount
```

## Format attendu de la revue

Pour chaque constat : gravité, fichier/ligne, scénario reproductible, invariant
violé et correction minimale. Distinguer les blocages des améliorations futures.
Après correction, ajouter le test qui échoue sans elle et rejouer la suite.

Conclure dans la PR par : verdict (`bloquant`, `prêt pour test réel` ou `prêt à
fusionner`), tests exécutés/non exécutés, risques résiduels, et confirmation que
`main`, l'app stable et le recall de production n'ont pas été modifiés.
