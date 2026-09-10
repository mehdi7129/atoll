# Audit de compatibilité — Codex CLI et Claude Code

Date : 2026-09-09. Dépôt examiné : `main`, commit `1b08ebd`, Atoll **0.17.2 / build 34**.
Clients relevés : **codex-cli 0.153.4**, **Claude Code 2.1.266**.

## Verdict

**Atoll possède déjà une intégration Codex substantielle, mais la parité et l'usage Codex seul ne sont pas atteints.** Les principaux manques ne sont pas le branding : ils concernent les demandes interactives, l'identité et la fin des sessions, l'exécuteur des analyses, le recall et la destination des skills.

Le développement demandé concerne **Codex CLI dans un terminal uniquement**, y compris le terminal intégré d'un éditeur. Desktop, extension IDE, cloud et comptes multiples sont exclus. Rockstar reste exclusivement Claude, conformément à la demande. Le refus historique du multi-fournisseur dans VISION-2026-08 est remplacé, pour ce périmètre, par cette demande actuelle.

Livrable associé : [plan de développement et seconde analyse](PLAN-2026-09-09-codex-claude.md). Cet audit ne modifie aucune logique de production, n'installe aucun hook, ne change aucun réglage personnel et ne publie aucune release.

## Méthode et portée des preuves

Trois lectures parallèles : runtime/Bridge, mémoire/apprentissage/quotas, interface/choix d'agent. Le coordinateur vérifie les coutures signalées, exécute les tests/build/probes et confronte les contrats au CLI installé. Après rédaction du plan, une seconde lecture indépendante cherche les défauts du plan lui-même.

- **M — mesuré** : exécution pendant cet audit, sur code de production ou RPC réel.
- **L — établi par lecture** : chemin et appelants vérifiés ; pas présenté comme un parcours utilisateur rejoué.
- **H — hypothèse/contrat à vérifier** : ne justifie pas à elle seule un correctif ni une promesse de compatibilité.

Il s'agit d'un audit transversal de compatibilité fonctionnelle et de ses risques de fiabilité. Ce n'est pas une certification de sécurité ni l'affirmation que chaque ligne, chaque client et chaque scénario possible ont été exercés. Les gros fichiers sont distingués des lectures intégrales dans le registre de revue ; un test pur vert ne prouve pas la couture App/Bridge.

### Vérifications exécutées

| Vérification | Résultat de cette passe |
|---|---|
| État initial Git | Aucun changement suivi ; AGENTS.md préexistant non suivi, un worktree sur main |
| Carte de revue avant audit | 118 fichiers Swift, 28 614 lignes ; 24 fichiers sans lecture détaillée enregistrée, 55 modifiés depuis revue |
| check-docs --no-tests | Exit 0, 12 familles exécutées ; 7 avertissements dont le compte de tests sauté et la couverture/dérive |
| swift test | 929 tests recensés, 1 ignoré, 0 échec ; 928 tests effectivement passés |
| Test réseau ignoré relancé seul | Succès en 0,803 s, 2 catégories de quota ; aucun thread démarré |
| xcodegen + build Debug app/helper | BUILD SUCCEEDED ; un warning de métadonnées AppIntents sans framework associé |
| Schéma app-server généré par le CLI | Succès ; contrats hooks, skills, modèles, quotas, threads disponibles pour inspection |
| hooks/list sur définitions générées par le code actuel | 10 événements reconnus, zéro erreur/warning ; PermissionRequest synchrone, 600 s ; trustStatus untrusted attendu dans le home jetable |
| Probes Swift du runtime | Six comportements reproduits, détaillés ci-dessous |

Le test hooks/list utilise un CODEX_HOME jetable : il n'exécute pas les hooks, n'accorde pas leur confiance et n'ouvre pas de conversation. La lecture du compte utilise le test existant, sans exporter les valeurs personnelles. Aucun `claude -p` ni `codex exec` de génération n'a été lancé pour les probes ou recettes de cet audit.

**Non rejoué ici** : permission réelle cliquée dans une TUI Codex avec l'app Release, confiance native dans le compte personnel, son entendu app fermée, jump-back dans chacun des terminaux, bilan réel facturé, reprise après crash de l'app installée. Les mesures historiques dans CODEX-FAILOVER restent historiques ; elles ne remplacent pas cette recette.

## Matrice fonctionnelle

| Surface | Existant Codex | Écart / développement requis |
|---|---|---|
| Installation | Éditeur dédié hooks.json, backup, wrapper, CODEX_HOME hérité | Onboarding Claude seul ; migration des définitions et diagnostic de trust incomplets |
| Sessions / états | 10 hooks, ID préfixé, store dédié, liste mixte | Retardataires et découverte non fiable ; pas de choix de vue |
| Redémarrage / crash | Scan de processus et rollouts, péremption temporelle | Pas d'identité TUI persistée ni clôture fiable sur mort de session |
| Permissions | Centre, socket et JSON allow/deny distincts ; retour au CLI | Détails perdus, pas d'ouverture/focus automatique, priorité Claude |
| Plans / questions | Pas d'adaptateur spécialisé Codex | Parcours natif ; contrat externe de réponse non établi |
| Rockstar | Jamais appliqué aux décisions Codex | Exclusion voulue ; corriger l'indicateur rouge qui déborde visuellement |
| Sons | Permission et Stop, fallback helper app absente | Course permission avant prompt : carte vivante sans son |
| Quotas | RPC officiel, catégories/fenêtres/reset/fraîcheur | Rendu incohérent avec budget ; catégorie pertinente pour un job à préciser |
| Jump-back | Ancre capturée via hooks, service de terminal partagé | Pas d'ancre lors de simple redécouverte ; recette terminal réelle requise |
| Arrêt | Aucun arrêt Codex depuis Atoll | Interruption native ; contrôle exact d'une TUI étrangère à démontrer |
| Sous-agents | Événements non installés, agent_id rejeté | Lifecycle, comptage et interactions enfants à adapter |
| Titres / branche / contexte | Projet/modèle/prompt des hooks | Enrichissements partiels ; pas de tailer Codex branché pour la présentation |
| Mémoire historique | Rollouts Codex indexés dans la base commune | Enveloppes AGENTS classées comme parole utilisateur ; provenance à renforcer |
| Recall manuel | Binaire recall sait retrouver/reprendre Codex | Skill installé seulement pour Claude |
| Recall proactif | Aucun appel dans le chemin CodexBridge | Adaptation du hook et mesures de latence/bruit nécessaires |
| Bilan de session | SessionEnd Codex déclenche le runner commun | Exécuteur reste Claude par défaut ; reprise Codex non raccordée à l'annulation |
| Curation des notes | Exécution Codex possible par failover | Pas de choix Codex direct autonome ; modèles et règles de dépense à clarifier |
| Skills appris | Génération par Codex possible | Antériorité, validation et installation restent orientées Claude |
| Plugins | Gestion et recherche de catalogue Claude | Pas de catalogue/gestion Codex ; recherche IA toujours exécutée par Claude |
| Passation | Claude → Codex avec contexte et ouverture du terminal | Pas de symétrique Codex → Claude ; différent du futur bouton |
| Diagnostics | Statut/snapshot habituels centrés sur Claude | État Codex, dernière réception et source de vérité à exposer |
| Apparence | Palette globale, mêmes couleurs pour les deux agents | Préférence de vue et palette par fournisseur à développer |

## Constats prioritaires

P1 : à fermer avant de présenter le parcours comme compatible au quotidien. P2 : correctif ou écart de parité à traiter dans les lots indiqués. Les absences volontaires/limites de plateforme sont séparées des bugs.

### C01 — P1 — Une permission Codex n'ouvre pas l'îlot

**L.** NotchRootView, lignes 149–156, compte uniquement les demandes InteractionCenter (Claude). Ses callbacks d'ouverture/focus, lignes 179–189, en dépendent. ExpandedView, lignes 35–46, affiche pourtant des cartes Codex.

Scénario : carte Codex seule en mode compact → aucune ouverture automatique ni prise du clavier pour les raccourcis. Résoudre la dernière carte Claude peut aussi replier l'îlot alors qu'une Codex attend. Correction : projection globale des attentes et routage des décisions conservé par fournisseur.

### C02 — P1 — L'action autorisée ne peut pas être relue intégralement

**L + M sur fixture.** CodexIntegration, lignes 57–58, ne conserve que le résumé de HookEvent, lignes 172–191 : limite de 90 caractères et quelques clés reconnues. CodexInteractionCenter, lignes 30–70, puis CodexInteractionCardView, lignes 47–69, ne disposent d'aucun payload complet.

Une commande longue perd sa fin avant d'atteindre la vue ; un outil/MCP non reconnu peut n'afficher que son nom. La fixture `exec_command` avec clé `cmd` rend le seul texte `exec_command`. **Cette fixture ne prouve pas que le hook réel utilise ce nom et cette clé** : le contrat documenté canonise notamment Bash/command. Le défaut certain est la perte d'information irréversible, même sur une commande reconnue.

Correction : requête immuable bornée avec cwd et détails inspectables ; retour au terminal si impossible de montrer l'action. Ne pas écrire les arguments privés dans les logs.

### C03 — P1 de parité — Codex seul ne peut pas choisir son exécuteur d'apprentissage

**L.** ProviderFailover, lignes 102–114, choisit Claude quand la bascule est éteinte **ou quand le quota Claude est inconnu**. Le fournisseur d'origine du transcript ne change pas ce choix. RetrospectiveRunner et NotesCurationService utilisent cette décision.

Sur un poste avec uniquement Codex, le quota/exécutable Claude absent ne mène donc pas à un run Codex normal. Ce comportement est cohérent avec une bascule Claude → Codex, mais ne satisfait pas le choix indépendant demandé. Il faut un exécuteur explicite ; conserver la prudence « inconnu ne signifie pas épuisé » dans la bascule optionnelle.

### C04 — P2 — Un événement retardataire ressuscite une session terminée

**M.** CodexIntegration, lignes 213–226, retire Entry sur SessionEnd puis recrée une entrée pour un événement inconnu ultérieur. Probe `SessionStart → UserPromptSubmit → SessionEnd → PreToolUse` : zéro session après la fin, puis une session, accepted=true.

Les hooks async rendent cet ordre possible. Une permission tardive peut aussi être retenue comme nouvelle carte. Conserver une clôture de session bornée et une notion d'incarnation ; une reprise explicite du même UUID doit rester possible.

### C05 — P2 — Stop sans turn_id ne mémorise pas le tour clos

**M.** CodexIntegration, lignes 281–285, ne range que l'ID porté par l'événement dans les tours clos, alors que la sortie de clôture, ligne 307, sait utiliser l'ID courant en repli. Probe `Prompt(t1) → Stop(nil) → Prompt(t1)` : accepted=true, activité rouverte.

Résoudre l'identité du tour une seule fois pour la clôture et sa mémoire. Le test doit aussi prouver qu'un vrai nouveau tour t2 continue à s'ouvrir.

### C06 — P2 — Un cwd commun est pris pour une identité de session

**M + L.** CodexSessionDiscovery, lignes 75–93, choisit le rollout le plus récent du dossier d'un processus ; son résultat ne garde pas le PID. CodexSessionScanner, lignes 21–38, accepte des binaires Codex sans distinguer une TUI d'un app-server. Probe : processus vivant quelconque dans un dossier + historique vieux d'une heure → ancien ID adopté.

Deux TUI dans le même dossier sont délibérément réduites à une session par l'heuristique/test actuel. Le scan des seules dates aujourd'hui/hier, lignes 52–58, rate aussi une ancienne session reprise. Capturer la relation exacte dans les hooks ; si elle manque, rester non attribué plutôt qu'emprunter un ancien UUID.

### C07 — P2 — La mort d'une TUI n'est pas réconciliée

**L + M sur projection.** Le PID de TUI et son instant de démarrage ne sont pas conservés par CodexSessions. CodexService, lignes 30–34, purge par âge et adopte de nouveaux résultats ; il ne clôt pas les processus disparus.

Une session silencieuse reste visible à 23 heures dans la probe. Elle devient **non confirmée** après 15 minutes : ce n'est donc pas une affirmation permanente qu'elle travaille, mais une session morte peut rester dans l'îlot. À 24 heures, la purge ne produit pas le bilan EndedSession. Réconciliation par identité prouvée, nettoyage et fin émise exactement une fois ; une session d'identité inconnue ne doit pas être déclarée morte sur une simple absence de signal.

### C08 — P2 — Les anciennes définitions de hooks ne sont pas migrées

**M + L au point d'appel.** isInstalled (CodexIntegration, lignes 449–456) contrôle uniquement la présence des commandes. refreshWrapper (CodexHookInstallation, lignes 157–175) met à jour le script, pas async/timeout/événements. AppDelegate, lignes 121–135, ne fait pas une autre migration des définitions.

Probe : PermissionRequest historique async=true, timeout=3 → isInstalled=true. Cette installation ne satisfait pas la carte synchrone/600 s actuelle. Distinguer présence, conformité et trust ; migrer uniquement les entrées gérées, puis laisser le CLI demander sa revue native si nécessaire.

### C09 — P2 — Une carte vivante peut ne produire aucun son

**L, ordre déjà représenté par un test Core.** PermissionRequest(t2) peut arriver avant le prompt async ouvrant t2. La projection rend unknown ; AppDelegate conserve correctement la carte, mais CodexService, ligne 84, revient avant playSound. Le helper a réussi à joindre l'app et ne prend pas son fallback.

Le test testAPermissionOfAnUnopenedTurnKeepsItsCard protège la survie de la carte, pas le son de cette couture. Le son doit dépendre de l'enregistrement effectif d'une nouvelle demande, dédupliqué, sans tinter pour les cartes périmées.

### C10 — P2 — Priorité Claude et place réservée rendent des éléments inaccessibles

**L.** ExpandedView, lignes 35–46, montre toujours Claude avant Codex. Les compteurs des cartes ne voient que leur propre fournisseur : une vieille demande Codex peut attendre derrière une suite de demandes Claude.

Autre défaut déterministe : rowBudget, lignes 232–234, vaut 2 avec une bannière. IslandRowPlan réserve une ligne de pied, puis exige deux lignes pour développer un projet ; le développement devient impossible, alors que la flèche passe ouverte. Enfin, codexQuotaRow est rendue sans condition (ligne 362), mais le budget dépend du toggle (ligne 221).

Arbitrage global stable des demandes et un même plan pour le rendu/budget. Tous les détails de session doivent rester accessibles par défilement ou une vraie navigation de surplus. Capture réelle encore requise pour la recette visuelle.

### C11 — P2 de parité — Sous-agents et enrichissements Codex non branchés

**L + schéma CLI local.** Kind omet SubagentStart/SubagentStop et le parseur rejette un agent_id non vide. Le CLI installé expose pourtant ces deux événements. Aucun comptage/enrichissement Codex n'alimente les champs de branche, contexte, sous-agents ou recall de la présentation commune.

Ajouter les enfants sans fusionner leur état avec le parent. Les noms/tokens/branches doivent provenir de données observées ; inconnu n'est pas zéro. Les hooks de questions/plans et l'autorité d'arrêt externe restent à vérifier, voir les limites plus bas.

### C12 — P2 — La reprise Codex ne retire pas son bilan en attente

**L.** CodexService appelle le runner à la fin (ligne 105), mais pas lors de la reprise. AppDelegate, lignes 199–202, raccorde sessionResumed uniquement à SessionStore. RetrospectiveRunner, lignes 414–428, recherche la liveness dans SessionStore seul.

Scénario : une session Codex termine, son bilan attend le délai, puis le même ID reprend. Le runner ne reçoit pas l'annulation et son gate considère la session absente du store Claude comme non vivante. Raccorder reprise/préparation/run aux mêmes faits de session, identifiés par origine.

### C13 — P2 de parité — Les skills restent des skills Claude

**L.** BridgePaths dirige le recall et les skills appris vers les répertoires Claude. SkillCatalog inventorie l'écosystème Claude ; LearnedSkillStore valide et installe pour ce même écosystème. Le fait que Codex ait généré un SKILL.md ne lui donne pas une destination Codex.

Conséquences : antériorité Codex manquée, proposition potentiellement redondante, activation inaccessible au client attendu. Séparer origine/exécuteur/destination ; utiliser le catalogue Codex officiel pour le projet, adapter le contenu et le manifest. Le retrait d'une destination ne doit pas supprimer les ressources d'une autre.

### C14 — P2 de parité — La recherche IA de plugins est une troisième dépense Claude

**L.** PluginInventory, lignes 400–414, résout Claude et lance les arguments PluginSearchPrompt avec budget 0.30 ; ce dernier construit un `claude -p`. Ce chemin n'utilise pas ProviderFailover.

Les documents parlant de seulement deux dépenses IA sont incomplets. Intégrer ce consommateur au choix d'exécuteur et au journal ; garder distincts l'agent qui cherche et le catalogue de plugins visé. L'inventaire/gestion de plugins Codex ne se déduit pas des commandes Claude.

### C15 — P2 — Les instructions AGENTS entrent comme prompts humains

**L + mesure du corpus et de la base en lecture seule.** CodexTranscriptParser filtre des préfixes XML mais pas l'enveloppe commençant par `# AGENTS.md instructions for`. Sur le relevé de 86 rollouts : 15 messages correspondants, 407 100 caractères. La base existante contient effectivement ces 15 messages sous rôle user ; ce volume n'est pas une mesure de ce qui a été effectivement injecté dans un prompt.

Classer ces instructions selon leur provenance au lieu de les confondre avec les décisions de l'utilisateur. Un correctif uniquement à l'ingestion ne change pas l'existant déjà indexé ; une hygiène ciblée et récupérable est nécessaire si ce contenu doit être reclassé. Ne pas effacer les messages humains qui citent simplement AGENTS.md.

### C16 — P2 de parité — Recall Codex incomplet

**L.** Le corpus contient Codex, mais CodexBridge n'appelle pas le recall proactif ; l'installation du skill manuel passe par le chemin Claude. Le binaire de recherche lui-même sait déjà proposer une reprise Codex.

Créer l'accès manuel Codex puis traiter le proactif séparément. UserPromptSubmit est actuellement async : lui faire écrire du contexte sans vérifier que Codex le consomme ne réalise pas l'injection. La latence et le bruit TUI d'un hook synchrone doivent être mesurés avant généralisation.

### C17 — P2 — Modèle, isolation et fenêtres des analyses reposent sur des hypothèses

**L + aide CLI locale.** CodexExecPlan ne passe pas de modèle explicite tout en utilisant `--ignore-user-config`. L'aide du CLI décrit l'absence de lecture de config.toml ; elle ne promet pas que les instructions de projet et skills sont neutralisés. Le commentaire « prompt seule instruction » va donc au-delà de ce qui est établi.

ProviderFailover prend le maximum de toutes les catégories de quota, sans rapport explicite avec le modèle/job ; le plafond interne d'apprentissage conserve une fenêtre de cinq heures et certains compteurs partagés. Ces choix sont conservateurs mais ne doivent pas être vendus comme le contrat de chaque abonnement.

Modèles explicites, portée des catégories à vérifier, isolation réelle du job à mesurer. **Aucune exécution non autorisée ni dépense erronée n'a été démontrée par cette seule lecture** : la neutralisation et les catégories sont des portes de validation, pas une preuve d'exploitation.

### C18 — P2 de produit — Le parcours et les textes restent centrés sur Claude

**L.** OnboardingView n'installe que Claude ; SettingsView place la mémoire commune dans le volet Claude, n'offre que ses pickers de modèles, et l'About le présente seul. CodexSettingsPane conserve du texte antérieur aux cartes et à la lecture des rollouts. Le snapshot de SessionStore et le statut du helper n'inventorient pas Codex.

Le choix d'agent n'existe pas : NotchViewModel concatène les stores et paletteID est global. CompactView, lignes 155–169, colore aussi l'activité Codex en rouge lorsque Rockstar Claude est actif. Les décisions restent isolées : ce dernier défaut est visuel, pas une application de Rockstar à Codex.

Les en-têtes/tableaux de CODEX-INTEGRATION et CODEX-FAILOVER parlent encore d'une PR expérimentale non publiée, suivis de sections décrivant sa publication. Conserver l'historique daté, mais donner une matrice actuelle unique et corriger les textes de l'application au moment des lots correspondants.

### C19 — P2 — Le condensé invente un verdict pour les outils Codex

**M sur fixtures synthétiques passées dans le parseur et le digest réels.** CodexTranscriptParser, lignes 101–105, laisse isError à nil en refusant de deviner depuis le mot « error ». TranscriptDigest, lignes 290–304, applique pourtant cette heuristique dès que ce champ est nil ; succeeded, lignes 324–330, assimile l'absence de marqueur à un succès.

Probe : lecture réussie d'un fichier contenant `let error = nil` → résultat classé erreur, invocation écartée ; sortie JSON avec `exit_code:1` → invocation conservée comme réussie. Ces fixtures démontrent la couture, pas le format de tous les outils réellement émis. Le prompt du bilan reçoit alors une affirmation de réussite non prouvée. Exiger succès/échec/inconnu explicites avant la recette IA ; garder la logique Claude lorsque is_error est fourni.

### C20 — P2 — Le journal peut afficher le quota Claude pour un run Codex

**L.** RetrospectiveRunner, lignes 354–355, lit SessionStore.realQuota ; les enregistrements des lignes 369/383 l'utilisent avec un provider pouvant valoir Codex. Le gate, lui, utilise correctement la projection du quota Codex.

Avec deux quotas différents, le journal attribue une mesure du premier compte à une dépense du second. Conserver le snapshot de décision dans le même objet que l'exécuteur/modèle et le réutiliser dans le journal. Ne pas remplacer un coût inconnu par zéro dollar.

### C21 — P1 — Annuler pendant la résolution peut laisser partir le job

**L, confirmé dans les deux runners.** RetrospectiveRunner vérifie reprise/OFF aux lignes 498–506, puis attend encore la résolution de l'exécutable/préparation Codex aux lignes 550–563, avant le spawn ligne 595 sans nouvelle garde. NotesCurationService.cancel, lignes 139–143, peut rendre idle pendant l'attente de CodexRun.prepare, ligne 255 ; le code continue ensuite au spawn ligne 265.

Une reprise/OFF pendant cette fenêtre peut donc être suivie d'un lancement ; l'application d'un rapport réussi n'est pas non plus conditionnée à une génération toujours valide. Il faut une invalidation de job jusqu'à la dernière écriture, testée avec résolveur suspendu et résultat tardif. **Pas de génération réelle lancée ni d'écriture de notes provoquée pour reproduire ce scénario durant l'audit.**

### C22 — P1 — L'escalade SIGKILL ne vérifie que le PID

**L, scénario conditionnel précis.** RetrospectiveRunner, lignes 156–165, et NotesCurationService, lignes 146–154, envoient SIGTERM, attendent cinq secondes puis font kill(pid, 0) avant SIGKILL. Un processus différent ayant repris le même PID satisfait cette garde. Des watchdogs portent également ce motif.

Le couple PID/startTime utilisé pour les cartes doit aussi protéger ces signaux. Vérifier toutes les escalades, annuler/récolter leurs tâches et tester un recyclage simulé. **Aucun processus étranger n'a été tué ni aucun recyclage réel provoqué** ; le défaut est établi sur la garde et ses appelants. C'est une dette partagée avec Claude à fermer avant de réutiliser ses runners comme référence sûre.

### C23 — P2 conditionnel — Le shell peut changer le CODEX_HOME après la lecture du quota

**L + H sur la configuration de chaque poste.** CodexPaths/BridgePaths utilisent l'environnement d'Atoll ; CodexRun, lignes 79–81, passe par un shell de login et ne réimpose que l'absence d'OPENAI_API_KEY. Si un profil exporte un autre home, le job peut viser un contexte différent de celui de l'installation et du quota.

Ce profil divergent n'a pas été constaté chez l'utilisateur. Le plan doit rendre le home explicite et identique après sourcing, invalider les caches correspondants et tester ce cas sans modifier le profil personnel.

## Observations complémentaires à conserver dans les lots

- **Provenance après curation — P2, mesuré sur fixture Swift** : le rendu des notes consolidées garde projet/catégorie/date mais pas le source_session de la note active. Les archives conservent les anciennes notes : ce n'est pas une perte irréversible. Le plan mémoire doit préserver les références de provenance de toutes les notes fusionnées, ou offrir leur résolution explicite via les archives.
- **Mesure du recall — P3, mesuré sur fixture Swift** : RecallJournal, lignes 64–69, compte indexUnavailable comme recherche ; sa médiane inclut donc une ouverture de base échouée alors que le rapport annonce les requêtes ayant interrogé la base. Corriger le nom/périmètre du compteur avant comparaison de latence Claude/Codex.
- **Usage des skills — adaptation à prévoir** : MemoryIndexer ne compte les invocations que pour Claude. Étendre les destinations sans état « usage non mesuré » déclencherait des suggestions d'archivage fondées sur un faux zéro. Ce n'est pas encore un skill Codex installé et archivé à tort par l'app actuelle.
- **Échéance de curation — dette préexistante assumée** : lastSpendAt est posé avant la réussite du spawn et finish avance l'échéance même si le binaire manque. Le plan sépare tentative/lancement/succès et ajoute un backoff explicite ; il ne présente pas ce comportement historique comme une nouvelle régression Codex.

## Ce qu'il faut préserver et ne pas réécrire

- Deux sockets et deux parseurs de permissions ; les enveloppes explicitement étrangères sont rejetées côté Claude. Aucun passage des décisions Codex par Rockstar n'a été trouvé.
- L'ID de requête lié au descripteur distingue les demandes identiques. Le PID/startTime du helper et le reaper protègent les cartes, sans prétendre identifier la TUI.
- L'EOF après half-close n'est pas une preuve de mort : ne pas réintroduire un veilleur qui fermerait les cartes nominales.
- La projection distingue tour courant, clos et inconnu : une permission avant son prompt ne doit pas être détruite.
- Quotas lus sans extraction d'auth.json, sans faux zéro sur erreur ; test réel réussi.
- Écriture des notes/skills par Atoll après validation, pas directement par le modèle ; sorties structurées revalidées côté Swift.
- Corpus mémoire partagé volontaire, seuil de couverture du recall et protections contre les suppressions destructrices.
- Service de jump-back existant et palettes existantes ; le switch demande une projection, pas deux applications ni un moteur de thèmes neuf.

## Limites explicites et hypothèses écartées

1. **Questions/plans** : les cartes Claude AskUserQuestion/ExitPlanMode n'établissent aucun contrat pour Codex. Retour natif tant qu'une réponse externe n'est pas supportée et vérifiée.
2. **Arrêt** : turn/interrupt existe dans le schéma app-server. Cela ne prouve pas qu'un app-server indépendant peut interrompre une TUI déjà ouverte. L'arrêt Claude actuel vise lui-même les jobs daemon, pas toutes les sessions interactives. Ce n'est donc pas un motif pour ajouter un kill générique à Codex.
3. **Fail-open** : le superviseur protège la mort du worker ; il ne promet pas de convertir tout signal adressé au superviseur. Le timeout socket mérite une faute de lenteur à la recette ; aucune garantie monotone supplémentaire n'est supposée.
4. **Multi-client** : la présence d'app-server dans le scan constitue un risque d'attribution, mais ne rend pas desktop/IDE/cloud nécessaires à ce projet.
5. **Compatibilité totale** : ne pas la résumer à un pourcentage de fichiers Codex. La matrice de parcours validés est la mesure utile.

## Contrats externes consultés

La configuration de hooks doit être approuvée dans le mécanisme natif, et les décisions PermissionRequest ont leur propre schéma. Cette documentation sert aussi à borner les retours natifs pour les événements non adaptés. [Hooks Codex](https://learn.chatgpt.com/docs/hooks)

L'app-server expose lecture de quota, lecture de threads sans reprise et méthodes de contrôle ; la portée de l'instance reste à vérifier avant tout contrôle d'une TUI externe. Les schémas générés par le CLI installé complètent cette lecture. [App-server](https://learn.chatgpt.com/docs/app-server)

Les skills sont découverts selon leur scope et leurs métadonnées, et leur catalogue initial est borné. L'inventaire d'Atoll doit tenir compte des compétences effectivement disponibles pour la destination. [Skills](https://learn.chatgpt.com/docs/build-skills)

## Couverture et suites

La passe couvre les surfaces de la matrice, les points d'entrée App/Bridge, la logique Core et les scripts/build/documents associés. Le registre reviews.json est mis à jour de façon conservatrice : **81 fichiers avec lecture intégrale déclarée, 37 avec balayage logique/coutures ciblées**. La [liste nominative](audit-support/2026-09-09/COUVERTURE.md) distingue les deux ; un balayage logique ne devient pas automatiquement une lecture ligne à ligne.

Les [probes reproductibles](audit-support/2026-09-09/README.md) sont conservées avec le rapport. La seconde analyse a confirmé les constats croisés et modifié le plan ; une dernière lecture du rapport et du plan révisés n'a trouvé **aucun blocage documentaire**. Ce verdict porte sur les livrables d'audit, pas sur une autorisation de release du code actuel.

Contrôle documentaire final : exit 0, 12 familles, 10 avertissements conservés. Huit fichiers restent sans lecture intégrale enregistrée, bien qu'examinés en balayage logique ; les autres avertissements incluent la dérive de gros fichiers et les commits du jour que la carte compte depuis minuit, même lorsqu'ils précèdent la lecture de ce soir. Ces avertissements ne sont pas masqués ni présentés comme des défauts tous résolus. Les nouveaux liens locaux et les fixtures ont également été vérifiés.

Les constats C01–C23 et les observations complémentaires sont le backlog de cet audit, pas des correctifs livrés. Le plan associé contient leur traitement, leurs dépendances, les scénarios de non-régression et les changements issus de sa seconde analyse.
