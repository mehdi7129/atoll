# Mise en œuvre du plan Codex CLI / Claude Code

Plan approuvé : [PLAN-2026-09-09-codex-claude.md](PLAN-2026-09-09-codex-claude.md).
Base : `1b08ebd`, Atoll 0.17.2, build 34. Relevé du **2026-09-10**.

**Les lots 0–6 sont implémentés.** Les tests automatiques, les contrats natifs
cités et les builds passent. La validation utilisateur complète reste ouverte :
macOS bloque l'accès/capture de la fenêtre de test. Aucun clic réel de carte,
film, contrôle VoiceOver ou parcours GUI Claude/Codex n'est déclaré réussi.
Aucune release publiée ; la copie stable et les configurations personnelles
n'ont pas été remplacées.

## État par lot

| Lot | Réalisation | Preuve exécutée | Reste |
|---|---|---|---|
| 0 — contrats | 28 captures natives expurgées, permissions Bash/patch/MCP/enfant, neuf schémas natifs conservés | CLI 0.153.4 ; rejeu Core des contrats | Pas de capture native de reprise enfant |
| 1 — fiabilité | Identité TUI PID/démarrage, registre, clôtures monotones, générations des scans/jobs, détails des permissions, file globale épinglée | Core, vrai centre App et vrais runners dans le harness, sabotage d'annulation | Clic/focus GUI et sons réellement entendus |
| 2 — installation | Onboarding choisi, Codex seul, home cohérent, migration des seules définitions Atoll, recall et diagnostic natif | Vrai helper installé deux fois puis retiré ; 12 hooks reconnus sans confiance accordée | Parcours onboarding graphique et revue /hooks par l'utilisateur |
| 3 — analyses | Trois consommateurs, moteur explicite, fallback OFF, modèle natif, budget commun, snapshot figé, journal, annulation jusqu'aux écritures | 40 scénarios runtime ; vrai CodexRun avec rapport structuré valide | Usage prolongé ; pas de promesse d'isolation de tous les skills globaux |
| 4 — interface | Boutons persistants, compteurs/demandes, palettes, quota choisi, défilement, marqueur Rockstar Claude, réglages/aide | Build Debug/Release, tests de projection et file ; aperçu isolé lancé | Recette visuelle, clavier, VoiceOver et film bloqués par macOS |
| 5 — mémoire/skills | Instructions distinctes, migration SQLite ciblée sauvegardée, provenance des notes, recall Codex manuel, destinations, manifest v2 séparé, catalogues natifs | Core, helper réel, vrais skills/list et plugin/list local, contre-revue des sauvegardes/collisions | Proactif Codex volontairement non branché ; ressources nouvelles hors revue refusées |
| 6 — écarts CLI | Sous-agents sans corruption du parent, métadonnées sourcées, diagnostics, passation dans les deux sens | Fixtures enfant natives, tests metadata/identités, exécution des scripts avec faux CLI | Passation Terminal.app authentifiée et recette finale des deux CLI |

La matrice utilisateur **pris en charge / natif / non mesuré** est dans
[CODEX-INTEGRATION.md](CODEX-INTEGRATION.md). Le bouton choisit une vue ; le
[moteur des analyses et la passation](CODEX-FAILOVER.md) restent distincts.
Rockstar reste propre à Claude. Questions, plans et interruption Codex restent
dans le terminal.

## Résultats mesurés

Référence avant modification : **929 tests Core, un ignoré, zéro échec**.

Relevé final de cette passe :

- **994 tests Core, un ignoré, zéro échec**. Le test réseau est opt-in ; il a
  été exercé séparément lors de l'audit avec deux catégories retournées.
- **40 scénarios runtime réussis**, en compilant les runners App et le centre
  de permissions avec des collaborateurs contrôlés. Trois consommateurs,
  deux moteurs ; cas nominaux, OFF, reprise, résultat tardif, budget partagé,
  incarnation des cartes, son dédupliqué et permission enfant précoce.
- **Sabotage détecté** : supprimer les gardes de génération sur des copies
  temporaires provoque l'écriture après annulation attendue par le test.
  Réintroduire l'effacement d'un quota Codex ancien est également détecté
  au passage capture → budget (`--sabotage-quota-projection`).
- **Builds Debug et Release réussis**, app et helper. Le warning connu
  AppIntents indique l'absence de dépendance à ce framework, pas un échec de
  compilation. Signature Release vérifiée par `codesign --verify --deep --strict`.
  Ce contrôle ne vaut ni notarisation ni recette GUI de la Release.
- **RPC natifs réussis**, CLI 0.153.4 : hooks/list reconnaît les 12 définitions
  générées, zéro erreur/obsolescence et confiance non accordée ; skills/list
  découvre le skill de test au bon home malgré espaces/symlink ; plugin/list
  limité aux marketplaces locales. Aucun thread ni appel modèle.
- **Helpers Debug et Release réels** : installation répétée idempotente, hooks étrangers
  préservés, aucun fichier de configuration Claude créé ; recall partagé
  renvoyant les bonnes commandes `claude --resume` / `codex resume` et
  excluant les instructions ; retrait conservant hooks étrangers et index.
- **CodexRun App réel réussi**, modèle `gpt-6-astra` validé nativement,
  schéma strict accepté, rapport `ok=true`. Le profil de test exportait un
  mauvais home et une fausse clé API : home corrigé après profil, clé retirée,
  stdin fermé, marqueur interne présent, projet source exclu du cwd et aucun
  rollout persistant. Une génération a été consommée pour cette recette.
- **Contrôle documentaire complet réussi** (tests inclus, réseau exclu).
  Ses avertissements de couverture et API anciennes restent des candidats
  documentés, pas la preuve d'une relecture de tout le dépôt.

Les sorties privées volumineuses de build et de CLI ne sont pas versionnées.
Les recettes, fixtures et schémas relançables sont dans
[audit-support/2026-09-10](audit-support/2026-09-10/README.md).

## Relecture adversariale et correctifs vérifiés

La seconde analyse n'a pas consisté à relire le plan seulement. Des relecteurs
ont repris les implémentations et essayé de réfuter leurs invariants avec des
probes indépendantes. Les constats ci-dessous ont été mesurés, corrigés, puis
contre-vérifiés :

| Constat | Correction et preuve |
|---|---|
| Fin sans identité ou ancien scan refermant une session reprise | Identité exacte, tombstones et génération des scans ; nouvelle incarnation conservée |
| Permission avant SessionStart async | Inconnu distinct de clos ; carte vivante conservée |
| Ancienne fin supprimant une carte du nouveau processus | Nettoyage par session et identité ; vrai centre App testé |
| Navigation faisant perdre les réponses Claude | Brouillon attaché à la demande ; vérification graphique encore nécessaire |
| OFF ou reprise pendant résolution/run laissant écrire | Génération jusqu'au dernier effet ; harness nominal/annulé et sabotage |
| Minuteur utilisant la mauvaise tête après await | Réévaluation de file et délai minimal ; probe du vrai runner |
| Quota ancien/ambigu traité comme disponible | Fraîcheur, reset et catégorie applicables, inconnu explicite ; tests de gate/budget |
| Projection Codex effaçant la valeur haute dès qu'elle vieillit | Minorant conservé pour les fenêtres connues toujours actives, disponibilité inconnue ; capture → budget testée pour les trois consommateurs, quota ancien ou partiellement reset |
| Cycle de curation automatique écrivant après désactivation | Génération invalidée pour le cycle automatique, indépendamment du bouton manuel |
| Ressources ou fichier modifié entre revue et approbation | Snapshot complet de proposition, catalogue revalidé, refus des annexes non lues ; ressources installées préservées |
| Manifest malformé ou collision masquée | Erreur visible et refus d'adoption ; v1 séparé, conflit de downgrade explicite |
| Nettoyage de sauvegardes trop large | Noms gérés stricts avec UUID ; essai 7 sauvegardes gérées retirées, 4 fichiers étrangers conservés |
| Événement enfant utilisant le rollout ou le tour du parent | Projection enfant indépendante ; fixtures 13/16/19 donnent 1 → 1 → 0, parent intact |
| Stop enfant t1 retirant une permission t2 arrivée tôt | Nettoyage par enfant, tour et identité ; scénario conservé dans le harness |
| Stop enfant sans identité/tour interprété comme certain | État inconnu, carte conservée ; reprise explicite testée synthétiquement |
| Booléen JSON converti en mesure de tokens | Refus CFBoolean, tests true/false/string ; une mesure invalide efface l'ancienne |
| PID recyclé pouvant recevoir un signal | Vérification du démarrage avant signal ; un faux démarrage laisse vivant le processus de test |

Les scripts de passation ont aussi été réellement exécutés avec deux faux CLI :
dossier contenant espaces/apostrophe, contexte absolu et home Codex corrects.
Cela ne prouve pas l'ouverture de Terminal.app ni la lecture par un modèle.

### Portée de la revue

Balayage ciblé des sous-systèmes modifiés, **pas une nouvelle déclaration de
lecture intégrale de chaque fichier**. Le registre inscrit cette passe en
`sweep`. Les zones examinées sont :

- Sessions/permissions : CodexIntegration, CodexSessionDiscovery,
  CodexSessionRegistry, CodexService, CodexSessionScanner, ProcessIdentity,
  ProcessInspector, CodexInteractionCenter, CodexInteractionCardView,
  InteractionCenter, InteractionPresentation et RequestPresentation.
- Installation/protocole : CodexHookInstallation, CodexPaths,
  CodexHookDiagnostics, CodexReadClient, CodexBridge, HookInstaller.
- Analyses : AnalysisExecution, ProviderFailover, LearningSettings,
  RetrospectiveRunner, NotesCurationService, PluginInventory, CodexRun,
  CodexExecPlan et BoundedProcessOutput.
- Mémoire/skills : CodexTranscriptParser, TranscriptDigest, MemoryIndex,
  MemoryIndexer, NoteProvenance, LearnedSkillStore, InstalledSkillsManifest,
  SkillDestination, SkillReviewCenter, SkillReviewWindow, CodexSkillCatalog,
  CodexPluginCatalog et CodexRecallSkill.
- Présentation/métadonnées/passation : ProviderPreferences, ProviderSelector,
  NotchViewModel, NotchRootView, ExpandedView, CompactView, SessionDetailView,
  CodexSessionMetadata, SessionHandoff, CodexHandoffService, CodexPreview et
  réglages associés.

Les avertissements « jamais relu ligne à ligne » restent donc honnêtes. On ne
remplit pas le registre automatiquement à partir d'une compilation ou d'un grep.

## Décisions conservatrices du plan

- **Recall Codex manuel** : l'injection depuis UserPromptSubmit async, son bruit
  et sa latence ne sont pas prouvés ; elle reste désactivée. La recherche et
  l'indexation partagées sont disponibles.
- **Usage non mesuré** : aucune suggestion d'archivage automatique fondée sur
  l'absence d'une observation Codex ou une couverture Claude partielle.
- **Nouvelles ressources de skill** : le producteur génère un SKILL.md et des
  métadonnées. Les annexes nouvelles, non affichées dans la revue, sont refusées ;
  une mise à jour conserve celles déjà présentes dans l'installation.
- **Isolation bornée** : cwd contrôlé, contexte explicite et hooks internes
  neutralisés ; pas de promesse d'absence de toute instruction globale Codex.
- **Contrôle natif** : aucun app-server neuf n'est utilisé pour prétendre
  interrompre une autre TUI ; pas de transposition des réponses Claude aux
  questions/plans Codex.
- **Un home Codex à la fois** : les caches et les stores sont rattachés au home
  sélectionné. Les fichiers des anciens homes ne sont pas supprimés par un switch.

## Recette restante avant publication

L'accès à l'app de test via Computer Use et la capture de sa fenêtre ont été
refusés/en attente d'autorisation macOS. Une demande a été transmise à Mehdi.
L'export interne essayé sur le cache AppKit omettait le contenu défilant ; il
a été retiré et **n'est pas utilisé comme preuve visuelle**. Une erreur des
préférences de preview a également été mesurée puis corrigée : un domaine
volatile arbitraire n'est pas consulté par UserDefaults, les valeurs de test
doivent être enregistrées dans le domaine de registration.

Quand l'accès est disponible, reprendre avec la copie Debug isolée décrite dans
CODEX-INTEGRATION, puis une seule app de test normale :

1. Lire les captures de fenêtre et filmer les transitions ; clair/sombre,
   encoche/pilule, compact/étendu, beaucoup de sessions et libellés longs.
2. Vérifier la liste entièrement accessible, les compteurs, carte+switch+quota,
   Rockstar Claude visible en vue Codex, la palette de la carte et le retour
   à la préférence après résolution.
3. Vérifier focus, raccourcis, VoiceOver, réduction des animations et brouillons
   Claude conservés en naviguant entre deux demandes.
4. Exercer une vraie TUI Codex avec hooks approuvés : permission cliquée,
   retour terminal, sons app ouverte/fermée, fin/reprise, sous-agent, mémoire et
   apprentissage. Refaire la recette avec une vraie TUI Claude.
5. Ouvrir les passations dans les deux sens et vérifier la lecture du contexte
   par le CLI destinataire authentifié.
6. Valider la Release signée dans ces parcours avant toute notarisation,
   installation stable ou publication.

Ces étapes dépendent de l'accès GUI ou d'une session utilisateur authentifiée ;
elles ne sont pas remplacées par les tests automatiques.
