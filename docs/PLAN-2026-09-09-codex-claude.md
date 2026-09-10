# Plan de développement — Atoll avec Codex CLI et Claude Code

Date : 2026-09-09. Base examinée : `1b08ebd`, Atoll 0.17.2, build 34.
Statut : **plan révisé après seconde analyse indépendante ; aucune fonction ci-dessous n'est déclarée livrée**.
Mise à jour du 10 septembre : développement autorisé et appliqué ; l'état du code,
les tests et les recettes restantes sont dans le [rapport de mise en œuvre](IMPLEMENTATION-2026-09-10-codex-claude.md).
Demande : compatibilité Codex CLI dans le terminal uniquement, choix Claude Code / Codex par bouton et couleurs distinctes ; Rockstar reste propre à Claude.

## 1. Résultat attendu

Atoll doit fonctionner sur un poste avec seulement Codex CLI installé, avec seulement Claude Code, ou avec les deux. Le suivi, les demandes, les sons, le quota, la mémoire et l'apprentissage ont un comportement explicite pour chaque agent. Une capacité absente du contrat du CLI est indiquée comme telle avec retour au terminal.

L'application Codex/ChatGPT, l'extension IDE, les sessions cloud, les comptes multiples et les autres fournisseurs sont hors périmètre. Un Codex CLI lancé **dans le terminal intégré de Cursor/VS Code** reste dans le périmètre.

Le bouton ne transforme pas une conversation existante en conversation de l'autre fournisseur. La passation de contexte reste une action distincte, volontaire.

## 2. Contrat du bouton et des couleurs

Deux boutons persistants `CLAUDE CODE` / `CODEX`, avec compte de sessions et indicateur de demande en attente. Le choix pilote la liste, le quota principal, les actions disponibles et la palette. Les deux collecteurs restent actifs pour les intégrations installées : regarder Codex ne fait pas disparaître une permission Claude.

Une demande déjà affichée reste épinglée par son fournisseur et son request ID : aucune arrivée ne la remplace automatiquement. L'utilisateur peut naviguer volontairement vers une autre demande sans annuler la première. Les autres attendent dans une file commune de présentation, ordonnée par arrivée. Les décisions passent toujours par leurs centres et sockets respectifs. Le changement de fournisseur pendant une carte change la préférence de vue, jamais le destinataire d'un clic ou d'un raccourci ; la requête est encore vérifiée au moment du geste.

La palette affichée est une valeur dérivée : celle de la carte visible lorsqu'une carte attend, sinon celle du fournisseur sélectionné. La préférence n'est jamais réécrite par un événement de hook. Après résolution, retour à l'espace choisi. Proposition visuelle à valider pendant le développement : accent orange Claude, accent cyan Codex, fond neutre commun. Rouge/orange d'alerte conservent un sens d'état ; un texte identifie toujours l'agent.

Rockstar conserve sa préférence Claude et son parking existants. En vue Codex, aucun bouton Rockstar, aucune couleur d'activité héritée de Rockstar. Si Rockstar Claude reste activé en arrière-plan, un indicateur explicite `CLAUDE · ROCKSTAR` reste **visible, y compris en compact et sans session Claude** ; le switch ne restaure ni ne suspend des règles silencieusement.

Le fournisseur qui paie les analyses internes est **un réglage séparé et explicite**. Le bouton d'affichage ne déclenche pas une dépense et ne réactive pas la lecture du quota désactivée par l'utilisateur. L'onboarding Codex seul propose Codex comme exécuteur avant activation de l'apprentissage, lorsque cette capacité et sa destination sont disponibles. Un moteur choisi explicitement ne retombe jamais silencieusement sur Claude. Un quota inconnu reste inconnu ; la bascule automatique exige une preuve fraîche et son propre opt-in.

Un job en file prend les préférences à son évaluation. Dès le début de sa préparation, avant le premier await, il fige origine, destination, exécuteur, modèle, home et configuration de résolution. Le chemin absolu est fixé à la résolution de l'exécutable dans cette même génération. Gate, lancement et journal consomment les mêmes faits ; revalider la fraîcheur du quota avant spawn peut reporter le job, pas changer son fournisseur. OFF, annulation explicite ou reprise invalident la génération jusqu'à l'écriture finale.

## 3. Architecture minimale

Réutiliser l'enum AgentProvider et les deux stores/centres existants. Ajouter une petite couche de préférences et de projection pour sélectionner sessions, quota et palette, ainsi qu'un arbitrage de présentation des demandes. Ne pas unifier les payloads de permissions, réécrire SessionStore, ni créer un framework générique multi-fournisseur.

Séparer trois données aujourd'hui confondues :

| Donnée | Exemple | Rôle |
|---|---|---|
| Origine | rollout Codex | Parsing, provenance, cycle de vie de la session |
| Exécuteur | Codex ou Claude choisi | Modèle, quota, lancement, annulation, journal de dépense |
| Destination | skill Codex ou Claude | Catalogue d'antériorité, rendu, installation et désinstallation |

La mémoire textuelle demeure commune, identifiée par projet et source. Les skills exécutables restent adaptés et installés pour une destination explicite. La désinstallation d'un agent ne supprime pas l'historique partagé.

## 4. Ordre des lots

### Lot 0 — Contrats et preuves reproductibles

Objectif : transformer les probes d'audit en fixtures et tests utiles au développement.

- Figer la version du CLI testée et les schémas utiles générés localement ; documenter le minimum de version réellement vérifié, sans supposer la compatibilité de toutes les versions antérieures.
- Fixtures expurgées : installation neuve/ancienne, hooks avant/après trust, prompt/outil/permission/Stop/Interrupt/SessionEnd, sous-agents, reprise d'un ancien rollout, deux terminaux dans un même dossier.
- Capturer la vraie forme de permission Bash, apply_patch et MCP ; ne pas considérer une fixture `exec_command.cmd` comme preuve du format émis par Codex.
- Prévoir des racines temporaires et une injection des services pour tester les coutures App/Bridge sans écrire les réglages personnels.

Sortie : harness relançable sans IA pour les courses et erreurs de protocole, fondé sur les captures déjà disponibles et un **spike réel minimal pour les contrats manquants dès ce lot**. La recette utilisateur complète reste finale. Inclure une permission de sous-agent : relais vérifié ou retour natif explicite. Les scripts de release ne sont pas exécutés dans ce lot.

### Lot 1 — Fiabilité des sessions et demandes Codex

Fichiers principaux : CodexIntegration, CodexSessionDiscovery, CodexSessionScanner, CodexService, CodexBridge, ProcessInspector, CodexInteractionCenter, NotchRootView, ExpandedView, CodexInteractionCardView.

- Rendre monotones la fin de session et la fin de tour sans ID **quand le tour courant est identifié**. Conserver une mémoire bornée des clôtures ; permettre une reprise explicite de la même session sans accepter les événements de son ancienne incarnation. Ces gardes valent aussi pour les scans async déjà en vol et l'adoption de leurs résultats. Sans aucun ID ni preuve d'ordre, conserver l'état inconnu ; un Stop anonyme retardataire ne doit pas fermer une carte du nouveau tour par supposition.
- Capturer l'identité de la **TUI** `(pid, startTime)`, son session ID, son rollout et son ancre au passage des hooks. Le PID du helper ou d'un app-server de quota n'est pas le PID de session.
- Retirer l'attribution d'un ancien UUID sur le seul cwd. Si l'identité n'est pas prouvable, afficher au besoin une activité non attribuée ; ne jamais lui fournir une permission, un arrêt ou un bilan attribués par supposition.
- Réconcilier la mort de processus exactement une fois ; retrouver une session après redémarrage d'Atoll sans scanner seulement les répertoires de dates d'aujourd'hui/hier. Le support d'une reprise ancienne doit être mesuré.
- Conserver un payload de permission borné, le cwd et les détails de commande/diff/MCP consultables. Résumé court dans la liste, détails suffisants avant autorisation ; retour au terminal si la demande ne peut pas être présentée fidèlement.
- Corriger ouverture/focus/fermeture de l'îlot pour les demandes Codex et la priorité fixe Claude ; préserver l'identité de la carte pendant les arrivées concurrentes.
- Sonner à l'enregistrement effectif d'une nouvelle carte, même si elle précède son prompt ; dédupliquer et conserver l'abstention des cartes mortes. Les demandes enfant sont relayées seulement sur contrat capturé, sinon rendues au CLI.
- Annuler le bilan sur reprise Codex et consulter sa liveness dès ce lot : la fonction existe déjà. Invalidation vérifiée après chaque préparation async, immédiatement avant spawn et avant application du rapport. Un résultat tardif ne peut pas écrire après OFF/reprise. L'escalade SIGKILL reste liée à l'identité du processus ; kill(pid, 0) seul ne protège pas du recyclage d'un PID.
- Corriger l'issue d'outil Codex dans le condensé avant toute recette IA : succès/échec/inconnu, sans interpréter le mot « error » d'un fichier lu comme un échec, ni l'absence de ce mot comme un succès. Adapter l'invariant du prompt commun ; conserver le signal Claude is_error.

Recette : événements permutés, Stop anonyme avec/sans ID courant, SessionEnd suivi de retardataires **ou du retour d'un scan ancien**, reprise même UUID, deux TUI même dossier, crash TUI/helper/app, deux permissions identiques, carte Codex seule, cartes mixtes, expiration puis clic tardif. Reprise pendant délai, digest, résolution et run : aucun bilan obsolète. Faux résolveur suspendu puis OFF : zéro spawn ; résultat tardif : zéro écriture. PID recyclé simulé : zéro signal à l'étranger. Résultat d'outil inconnu : aucun succès/échec inventé. Chaque correctif doit échouer avec sa régression réintroduite.

### Lot 2 — Installation autonome et migration

Fichiers principaux : CodexHookInstallation, CodexHookSettingsEditor (dans CodexIntegration), HookInstaller, AppDelegate, OnboardingView, CodexSettingsPane, BridgePaths, CodexPaths.

- Onboarding avec choix d'agent ; installer uniquement l'intégration choisie. Un poste Codex seul ne crée pas de configuration Claude.
- Distinguer exécutable absent, hooks absents, définitions obsolètes, hooks non approuvés/désactivés et réception effective d'événements. Le disque seul ne prouve pas la confiance native.
- Migrer les définitions gérées par Atoll, pas seulement le wrapper : async, timeout, événements et statusMessage. Préserver les hooks étrangers, faire le backup, refuser le JSON invalide ; aucune restauration globale d'un ancien fichier.
- Vérifier l'installation effective par hooks/list ; inviter à la revue native `/hooks` lorsqu'elle est nécessaire, sans contourner le trust.
- Rendre le CODEX_HOME utilisé visible et cohérent entre installation, CLI lancé, découverte et lecture. Le transmettre explicitement aux RPC/scanner et le réimposer après sourcing du profil de login avant exec ; invalider les caches liés lors d'un changement. Tester un profil qui exporte un autre home. Supporter un home alternatif explicitement choisi ; les homes simultanés restent hors périmètre.
- Migration depuis une installation Claude existante : conserver palettes, autonomie, hooks, sons et notes. Désinstallation Codex symétrique, sans affecter Claude.

Recette : Codex seul/Claude seul/les deux, chemin avec espaces, symlink, fichier vide/invalide, modification concurrente, app déplacée, ancien PermissionRequest async/3s, hook désactivé ou non approuvé. Deuxième passage sans changement : aucune écriture inutile.

### Lot 3 — Exécution des analyses avec l'un ou l'autre abonnement

Fichiers principaux : ProviderFailover, LearningSettings, LearningGate, RetrospectiveRunner, NotesCurationService, PluginInventory, CodexExecPlan, CodexRun, CodexQuota.

- Choix explicite Claude / Codex pour les analyses ; bascule optionnelle distincte, désactivée par défaut. Codex doit fonctionner sans aucun quota Claude ni binaire Claude.
- Quota inconnu : conserver la possibilité historique d'une seule tentative interne par fenêtre si cette politique est affichée et activée ; elle concerne uniquement l'exécuteur choisi. Ne pas confondre cette tolérance avec une autorisation de failover ni une mesure de quota disponible.
- Inventorier **trois** consommateurs : bilan, curation, recherche IA de plugins. Une recherche sur un catalogue Claude peut être exécutée par Codex ; cela ne transforme pas ce catalogue en plugins Codex.
- Réutiliser la préparation/exécution bornée existante plutôt que dupliquer les runners. Modèle Codex explicite, validé parmi les modèles disponibles ; ne pas prétendre utiliser le choix personnel tout en ignorant config.toml.
- Quota applicable au job et modèle, fraîcheur et resets serveur ; aucun mélange arbitraire de catégories indépendantes. Si leur portée est ambiguë, état inconnu et politique conservatrice documentée.
- Conserver les garanties de génération/annulation établies au lot 1, sans reproduire les anciennes fenêtres de course des runners Claude.
- Distinguer tentative, lancement et succès : absence d'exécutable/refus de quota/spawn impossible ne consomment aucun créneau de dépense. Curation : backoff explicite sur panne avant lancement, plutôt qu'une semaine perdue ou une boucle immédiate.
- Journaliser origine/exécuteur/modèle/outcome et le **snapshot du quota réellement utilisé** : fraction, receivedAt, reset, catégorie limitante et raison, avec inconnu distinct de zéro. Aujourd'hui le bilan peut journaliser le quota Claude avec le provider Codex. Borner concurrence et retries, sans contenu privé.
- Réexaminer le compteur de dépenses partagé et la fenêtre fixe de cinq heures. Une limite interne conservatrice peut rester fixe, mais doit être nommée comme telle, sans être présentée comme une fenêtre contractuelle Codex.
- Vérifier l'isolation des jobs : `--ignore-user-config` ne promet pas l'absence d'AGENTS.md/skills. Dossier de travail contrôlé, contenu fourni explicitement, hooks internes neutralisés, stdin fermé ; mesurer le comportement réel.

Recette : Claude absent + Codex choisi, deux quotas disponibles, un épuisé, quota inconnu/périmé/reset, changement de modèle, reprise pendant délai/préparation/run, timeout/annulation, trois types de jobs avec faux CLI. Recette réelle bornée des schémas structurés et des réglages d'isolation après tests locaux.

### Lot 4 — Bouton, palettes et interface cohérente

Fichiers principaux : NotchViewModel, NotchRootView, CompactView, ExpandedView, SessionDetailView, SettingsView, ThemeColors, Palette, IslandRowPlan, IslandGeometry, SkillReviewWindow.

- Implémenter le contrat de la section 2 avec préférences persistantes et valeur de migration conservant l'usage Claude existant.
- Quota principal propre à la vue choisie ; fournisseur non configuré = action de configuration claire. Pas de quota Claude vide dans le parcours Codex seul.
- Rendu et calcul de hauteur doivent partager la même décision de visibilité. Le sélecteur ne doit pas rendre des sessions inaccessibles : liste à défilement borné ou accès effectif aux éléments masqués, en conservant le panneau compact.
- Réglages : sections communes (apparence, sons, mémoire) et sections par agent (intégration, capacités, modèles). Réviser onboarding, aide, diagnostics, About et texte d'automatisation.
- Distinguer « absent », « inconnu » et zéro pour les métadonnées non alimentées ; ne pas inventer de coût en dollars à partir d'un abonnement.

Recette visuelle : clair/sombre, encoche/pilule, fenêtre étroite, libellés longs, carte+switch+quota+bannière, groupes à plusieurs sessions, focus clavier, VoiceOver, réduction des animations. Captures lues et film des transitions ; pas seulement le preview statique existant.

### Lot 5 — Mémoire et skills utilisables par Codex

Fichiers principaux : CodexTranscriptParser, CodexRollout, MemoryIndexer, MemoryIndex, SkillCatalog, LearnedSkillStore, InstalledSkillsManifest, RecallSkill, ProactiveRecallHook, CodexBridge, LearningSettings, SkillReviewCenter.

- Nettoyer les enveloppes d'instructions Codex reconnues et séparer leur provenance des prompts humains ; conserver les citations humaines qui parlent d'AGENTS.md. Conserver l'état d'issue d'outil explicite établi au lot 1 et vérifier les marqueurs de compaction sur fixtures réelles.
- Si des messages déjà indexés doivent être corrigés, migration ciblée/versionnée, sauvegarde et transaction ; aucune reconstruction globale de la base. Les transcripts purgés restent récupérables dans l'index.
- Conserver la provenance des notes fusionnées par la curation, actuellement absente du texte actif après consolidation : références aux sources résolubles, y compris si les anciennes notes ne vivent plus que dans les archives.
- Installer le recall manuel pour Codex avec chemins et instructions adaptés. Privilégier le catalogue officiel skills/list pour le projet courant : scope, enablement, plugin et erreurs de lecture. Ne pas reconstituer à la main toutes les règles de découverte du CLI.
- Rendre catalogue d'antériorité, proposition, validation et installation des skills sensibles à la **destination**, indépendante de l'exécuteur. Provenance et manifest par destination ; préserver ressources, collisions et désinstallation sûre. Revalider l'antériorité à l'approbation si le catalogue a changé.
- Migrer les entrées du manifest v1 explicitement vers Claude, sans déplacer les dossiers. Identité `(destination, slug)` pour propositions, archives et installations ; destination fixée dans la proposition, inchangée par le switch pendant la revue. Tester le même slug dans les deux destinations, une interruption de migration et un retour à une ancienne app. Le lecteur actuel ignore la version : utiliser un stockage v2 distinct pour empêcher une ancienne app de le réécrire en v1 en perdant les destinations ; réconcilier explicitement toute dérive des anciennes entrées Claude.
- Usage d'un skill Codex non instrumenté = **non mesuré**, jamais inutilisé. Même distinction pour les statistiques indisponibles, une couverture partielle ou une date inconnue côté Claude. Ne pas suggérer l'archivage après trente jours sur un faux zéro ; ne pas déduire une invocation de la simple lecture d'un SKILL.md.
- Pour les plugins Codex, inventorier les capacités effectivement exposées par le CLI. Utiliser le gestionnaire natif pour les mutations non couvertes par un contrat vérifié ; ne jamais installer un plugin Claude en le renommant Codex.
- Privilégier d'abord une recherche locale sur le catalogue ; garder la recherche IA optionnelle si elle apporte quelque chose. L'interface nomme le catalogue visé et ses mutations restent routées vers son gestionnaire, quel que soit l'exécuteur de la recherche.
- Brancher le recall proactif seulement après le nettoyage du corpus et la mesure du hook UserPromptSubmit. Un retour additionnel ne peut pas être supposé consommé depuis un hook async. Mesurer bruit TUI, latence, budget, attribution des injections et abstention app absente ; s'il coûte trop, garder le recall manuel explicite.
- Pour cette comparaison, séparer tentative d'ouverture et recherche réellement exécutée dans le journal ; indexUnavailable ne doit pas alimenter une médiane annoncée comme latence de recherche.

Recette : skill uniquement Codex détecté avant proposition, plugin désactivé, même nom dans deux scopes, projet avec symlink, création/approbation/rejet/retrait pour chaque agent, conflit sans écrasement. Recall via Codex seul ; aucun prompt machine injecté comme décision humaine. Mesurer avant/après sur un corpus constant.

### Lot 6 — Derniers écarts CLI et validation de la parité

- Sous-agents : ajouter lifecycle et comptage par agent_id avec liens au parent, sans faire terminer le parent ni écraser son outil. Les permissions des enfants suivent le contrat réellement émis, jamais une traduction aveugle.
- Enrichissements utiles : titre/projet/branche/modèle et contexte seulement quand une source fiable existe. Le parsing des rollouts est un enrichissement défensif, pas une condition de vie des hooks.
- Questions et plans : conserver le traitement natif tant qu'aucun protocole de réponse externe n'a été capturé. Ne pas réutiliser le JSON AskUserQuestion/ExitPlanMode de Claude. Documenter la différence utilisateur.
- Arrêt : étude courte du contrôle de la **TUI déjà ouverte**. L'existence de turn/interrupt dans un autre app-server ne prouve pas son autorité. Sans contrôle exact prouvé, bouton retour au terminal et interruption native ; aucun kill fondé sur le cwd.
- Passation Codex → Claude : évolution distincte de Claude → Codex existante, contexte absolu, destination affichée, ouverture vérifiée ; pas une migration transparente du thread.
- Diagnostic commun avec fournisseur, source et fraîcheur de la session ; compléter l'état exporté et le statut helper aujourd'hui centrés sur Claude.

Sortie : matrice finale « pris en charge / natif / indisponible », version du CLI et preuves pour chaque parcours. Les parcours natifs sont présentés comme des différences explicites, pas comme des boutons Atoll déjà disponibles.

## 5. Validation et livraisons

| Constats de l'audit | Lot responsable |
|---|---|
| C01, C02, C04–C07, C09, C12, C19, C21, C22 | 1 — sessions, demandes, cycle de vie et condensé fiable |
| C08, C23 et installation de C18 | 2 — installation, migration et home |
| C03, C14, C17, C20 | 3 — exécuteur, quotas, modèles et journal |
| C10 et interface/couleurs de C18 | 4 — switch, file de présentation et espace disponible |
| C13, C15, C16 et observations de provenance/usage/mesure | 5 — mémoire, recall, skills et catalogue |
| C11 et diagnostics de C18 | 6 — sous-agents, enrichissements et limites natives |

Les permissions enfant sont capturées dès le lot 0 et rendues au natif ou relayées correctement dès le lot 1 ; le lot 6 ajoute leur présentation et comptage complets.

Les lots 0–2 constituent la première livraison de fiabilité ; le lot 3 permet de choisir effectivement l'exécuteur avant le switch du lot 4 ; le lot 5 complète la destination Codex des skills et le recall ; le lot 6 ferme les écarts restants vérifiables. Chaque livraison reste utilisable et conserve Claude. Les fonctions encore orientées Claude restent explicitement indisponibles en Codex seul jusqu'à leur adaptation : aucune activation fictive pour donner l'impression d'une parité déjà acquise.

Les tests portent sur les invariants et les coutures, pas sur les seuls helpers purs. `swift test` et build Debug sont nécessaires, puis une vraie TUI Codex : hooks approuvés, demande relue/cliquée, retour terminal, son app ouverte/fermée, fin/reprise, mémoire et apprentissage. Refaire la même recette Claude après chaque modification d'une couture partagée.

Avant publication : revue adversariale des correctifs, documentation confrontée au code, Release signée testée et procédure de release habituelle. Pas de publication documentaire seule. Le résultat de l'audit n'autorise pas à présenter les parcours futurs comme vérifiés.

## 6. Seconde analyse du plan

Trois relecteurs ont repris le plan initial et croisé des constats hors de leur premier périmètre. Les demandes Codex sans focus/détails, la reprise non raccordée et la destination Claude des skills ont été confirmées indépendamment. Les ajustements suivants sont intégrés dans cette version :

| Faiblesse du premier plan | Décision après seconde analyse |
|---|---|
| Switch livré avant choix d'exécuteur | Exécution au lot 3, switch au lot 4 ; disponibilité par capacité à chaque jalon |
| Capture de contrat demandée tôt mais recette réelle renvoyée à la fin | Spike minimal au lot 0, recette Release complète à la fin |
| Tombstones appliquées seulement aux hooks | Génération et clôtures aussi vérifiées au retour d'un scan async |
| « Clôture anonyme monotone » trop absolue | Fallback du tour connu ; inconnu explicite quand l'ordre n'est pas prouvable |
| Annulation/reprise reportées à la nouvelle politique d'exécution | Correctif dès lot 1, valide jusqu'au spawn et à l'écriture finale |
| Reprise des garanties Claude supposées suffisantes | PID/startTime pour escalade ; gardes après les awaits qui suivent les anciennes vérifications |
| Simple gel du provider « au lancement » | Préférences figées avant préparation, résolution dans la même génération, quota revalidé sans reroutage silencieux |
| Manifest « par destination » trop vague | Migration v1 vers Claude et namespace des propositions/archives/installations |
| Ancienne app ignorant les champs/version du nouveau manifest | Stockage v2 distinct et recette downgrade, aucune réécriture silencieuse de destinations |
| Usage Codex manquant assimilable à zéro | État non mesuré et aucune suggestion d'abandon sur absence de télémétrie |
| Vérifier les résultats d'outils sans contrat de verdict | Succès/échec/inconnu explicites avant recette IA du bilan |
| Deux files sans navigation précisément définie | Carte non préemptée par événements, navigation manuelle autorisée et routage revalidé |
| Recherche IA de plugins portait toute l'adaptation | Catalogue/actions séparés de l'exécuteur ; recherche locale d'abord |

Les propositions qui auraient élargi le projet à desktop, à un daemon d'orchestration ou à un framework universel des transports sont écartées. Aucun contrôle de TUI extérieure par un app-server neuf n'est promis. Le plan peut être développé par lots ; les recettes de contrat qui restent à exécuter sont des critères d'entrée/sortie, pas des résultats acquis.
