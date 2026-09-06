# Codex + Claude — plan révisé et protocole de test

État : **PR expérimentale, non publiée**, 2026-09-06.
Branche : `codex/codex-support-dual-quotas`, base `main` / v0.16.6.
Demande : utiliser Atoll avec Codex, distinguer les quotas des deux abonnements,
et faire relire/tester le changement avant toute intégration dans `main`.

## Décision après relecture

Une même interface, deux adaptateurs indépendants. Le suivi Claude existant
reste propriétaire de ses transcripts, de sa flotte, de ses décisions et de sa
mémoire. Codex est observé par ses hooks ; son quota vient de son app-server.
Il n'est pas traité comme « Claude avec un autre exécutable ».

La documentation officielle OpenAI a guidé trois choix :

- [Hooks Codex](https://learn.chatgpt.com/docs/hooks) : installation explicite,
  puis revue de confiance **par l'utilisateur dans `/hooks`**. Aucun contournement.
- [App-server](https://learn.chatgpt.com/docs/app-server) : quota par RPC officiel,
  fenêtres et catégories renvoyées par le serveur, pas d'estimation par tokens.
- Le serveur lancé pour lire le quota ne découvre pas magiquement les sessions
  actives d'un autre client. Aucune reprise de thread à des fins d'observation.

## Ce que cette PR implémente

| Fonction | Claude | Codex expérimental |
|---|---|---|
| Sessions / état | Suivi existant inchangé | Hooks reçus depuis le lancement d'Atoll |
| Identité | Identifiant existant | Identifiant préfixé `codex:` et badge fournisseur |
| Quota | Statusline et jauges optionnelles existantes | App-server du CLI connecté à ChatGPT, opt-in |
| Durées / reset | Comportement existant | Valeurs serveur, pas de durée supposée |
| Autorisations | Cartes Atoll existantes | Signal visuel ; décision dans Codex |
| Rockstar | Claude uniquement | Jamais appliqué |
| Jump-back / arrêt | Existant | Non disponible dans cette PR |
| Mémoire / skills / sons | Existant | Non branché dans cette PR |

Les quotas ne sont **jamais additionnés**. Un abonnement expiré, un compte API,
une erreur de réseau ou une donnée manquante ne deviennent pas un faux « 0 % ».
Le quota Claude n'est pas rendu plus autonome par cette PR : sa jauge principale
continue à dépendre de la statusline ; sans données récentes, elle peut manquer.

### Architecture et protections

- `AgentProvider` dans le modèle de présentation ; valeur Claude par défaut
  pour conserver les appelants et les identifiants historiques.
- `CodexHookEvent` / `CodexSessions` : projection dédiée, sans lecture des
  transcripts internes, sans réconciliation par PID de daemon.
- Socket Codex distinct : `/tmp/atoll-codex-<uid>.sock`. Un ancien Atoll
  Claude-only ne recevra pas ces payloads. Le helper vérifie l'UID du pair ;
  le serveur crée son socket en mode `0600`.
- Les enveloppes de fournisseurs inconnus ne passent jamais dans le parseur
  Claude ; le socket Codex refuse les enveloppes sans fournisseur Codex.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PermissionRequest`, `Stop`, `Interrupt`, `PreCompact`, `PostCompact`,
  `SessionEnd`. Les payloads de sous-agents sont ignorés pour ne pas faire
  terminer le parent par erreur. Pas de compteur de sous-agents inventé.
- Hooks synchrones courts (3 secondes maximum configurées), sans sortie ni
  décision. L'envoi socket a une deadline de 2 secondes ; app absente → exit 0.
- Pas de hook Codex `PermissionDenied` exploité : après 2 min sans événement,
  une attente devient **non confirmée**, pas une fausse demande permanente.
  Même principe après 15 min pour les autres activités ; purge après 24 h.
  Cela ne prouve pas qu'un outil long a fini : c'est une limite explicite du suivi.
- Installation dans le `hooks.json` utilisateur ; `CODEX_HOME` absolu hérité
  est respecté, sinon `~/.codex`. Le chemin réellement utilisé est montré.
  `config.toml`, hooks étrangers, choix de confiance et réglages Claude préservés.
- Merge idempotent, backup unique `hooks.json.atoll-backup`, liens symboliques
  conservés. JSON illisible/invalide → erreur, aucune reconstruction destructive.
  Détection des modifications concurrentes avant écriture (best effort, pas un CAS).
- Wrapper propre `~/.atoll/bin/atoll-codex-bridge`. Retenu après désinstallation
  pour les clients déjà ouverts ; bundle manquant → sortie silencieuse.
- Le lecteur de quota lance **son propre** `codex app-server --listen stdio://` :
  `initialize` → `initialized` → `account/read(refreshToken:false)` →
  `account/rateLimits/read`. Rien d'autre : ni thread, ni turn, ni login/logout.
  L'app-server gère sa propre authentification. Atoll ne lit pas `auth.json`,
  n'extrait pas de jeton et ne journalise pas email ou messages d'erreur bruts.
- Lecture au plus toutes les 2 min (hors actualisation manuelle), hors UI,
  deadline 20 s, sortie plafonnée à 2 Mo, enfant terminé et récolté.
  Désactivation → annulation ; pas de cache de compte persistant.
- Données masquées après 5 min ou après le reset de leur fenêtre ; toutes les
  catégories renvoyées par `rateLimitsByLimitId` sont consultables dans les réglages.
  L'îlot privilégie la catégorie `codex`, le compact nomme l'agent concerné.

## Tester sans toucher à la version installée

### 1. Tests automatisés et compilation

```sh
swift test --package-path AtollCore
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/atoll-codex-build build
```

Sur un Mac Intel, remplacer `arm64` par `x86_64`. Ne pas exécuter les commandes
de copie du README de production : **ne pas remplacer `~/Applications/Atoll.app`**.

La suite ordinaire utilise de faux serveurs et des dossiers temporaires, pas les
comptes ni les hooks personnels. Le test réel est désactivé par défaut :

```sh
ATOLL_CODEX_LIVE_TEST=1 swift test --package-path AtollCore \
  --filter CodexAccountClientTests.testLiveReadOnlyAccount
```

Il utilise `~/.local/bin/codex` ; `ATOLL_CODEX_EXECUTABLE` permet un autre chemin.
C'est une lecture de quota réelle, pas un message généré.

### 2. Aperçu visuel isolé

```sh
open -n /private/tmp/atoll-codex-build/Build/Products/Debug/Atoll.app \
  --args --codex-preview
```

Mode Debug uniquement, données **fictives et étiquetées**, fenêtre non interactive.
Pas de socket, pas de réparation des hooks, pas de login, pas de réseau, pas de
relecture/injection du journal de recall, réglages indisponibles. Cet aperçu peut
coexister avec l'Atoll stable. Quitter via son menu « Quitter l'aperçu ».

### 3. Essai fonctionnel explicite — à faire avant fusion

Ce n'est **pas** l'aperçu : le démarrage normal de l'app lance les services existants
et peut réparer les wrappers Claude. Ne pas lancer simultanément deux Atoll normaux
(même socket Claude / mêmes préférences). Pour une isolation complète des données,
utiliser un compte macOS de test. Sinon :

1. Quitter l'aperçu et la version stable, conserver le bundle stable intact.
2. Lancer le bundle de test **sans** `--codex-preview`.
3. Réglages → Codex : vérifier le chemin de configuration, installer les hooks.
4. Dans le CLI Codex récent, `/hooks` : relire et approuver les définitions Atoll ;
   démarrer une nouvelle session. La présence du fichier ne prouve pas sa confiance.
5. Vérifier prompt → outil → permission native → réponse → fin / interruption,
   puis fermeture de session. Le mode Rockstar Claude ne doit jamais décider pour Codex.
6. Activer la lecture du quota ; comparer les fenêtres / resets avec Codex.
   Vérifier aussi le cas sans compte, hors connexion et quota expiré.
7. Vérifier une session Claude réelle : permissions, statusline et affichage inchangés.
   **Ne pas injecter de faux prompts Claude** dans le journal de mesure de septembre.
8. Tester les deux modes de groupement, encoche/pilule, largeur petite, détail,
   longues chaînes de modèle/projet et une fenêtre de quota inconnue.

Retour stable : retirer les hooks Codex depuis le bundle de test, désactiver sa
lecture du quota, quitter cette app, relancer `~/Applications/Atoll.app` (sa
réparation normale rétablit son wrapper Claude). Ne pas restaurer un backup entier
par-dessus des changements personnels. Le wrapper Codex résiduel est inerte sans hooks.

## Plan de développement après cette PR

| Lot | Travail | Critère de sortie |
|---|---|---|
| 1 — cette PR | Identité fournisseur, suivi hooks, quotas, réglages, aperçu, tests | Build + tests verts, puis parcours réel relu avant fusion |
| 2 — fiabilité | Fixtures capturées avec consentement sur CLI/desktop/IDE, événements concurrents, reconnexions, meilleur diagnostic de confiance | Matrice de clients supportés publiée ; aucune session historique annoncée vivante |
| 3 — interactions | Adaptateur Codex dédié pour allow/deny, annulation, expiration, retour au client ; jump-back lorsque prouvable | Décisions conformes au schéma Codex, tests de course/timeout ; jamais de Rockstar implicite |
| 4 — mémoire partagée | Contrat neutre avec origine/projet, lecture opt-in, minimisation des données, adaptation des skills | Fin du gel recall et mesures de référence conservées ; aucun mélange silencieux Claude/Codex |
| 5 — passation entre agents | Notes de projet et rapports de revue liés au commit / PR ; éventuelle interface Atoll | Consentement avant envoi à un autre fournisseur, historique auditable, pas de boucle d'agents autonome |

Pas de chat/orchestrateur ajouté à l'îlot dans cette PR. GitHub et ce document
permettent déjà à Claude de relire le travail **si son client a encore l'accès et
l'authentification nécessaires**. Atoll ne réactive pas un abonnement terminé.
Une conversation automatique entre agents demanderait un travail distinct.

## Relevé de vérification — 2026-09-06

- Base : 737 tests existants passants avant l'ajout des tests Codex.
- Suite finale : 761 tests recensés, 760 exécutés avec succès et le test réseau
  ignoré par défaut ; ce dernier a été exécuté séparément avec succès.
- Nouveaux tests : contrat de fournisseur, transitions, événements d'ancien tour,
  péremption, merge/retrait/backup/liens symboliques, faux app-server JSON-RPC,
  compte API/déconnecté, timeout/annulation, sortie anticipée/SIGPIPE, multi-quotas.
- Lecture réelle du quota : réussie avec `codex-cli 0.153.4`, une catégorie
  retournée, aucun thread démarré. Aucun quota personnel publié dans ce document.
- Build Debug app + helper réussi ; aperçu visuel ouvert et inspecté.
- Aucun hook utilisateur installé, aucun bundle stable remplacé, aucune donnée
  de recall de production rejouée. Les parcours réels de hooks, permissions natives,
  clients desktop/IDE et changement de compte restent à valider avant fusion.

La PR doit rester en **brouillon** jusqu'à cette validation et à la revue du diff.
