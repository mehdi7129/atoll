# Atoll — quelles améliorations méritent vraiment d’exister ?

Exploration du **23 septembre 2026**, sur `6c1f987` (v0.18.3 publiée).
**Propositions uniquement. Aucun changement de l’app, aucun accord d’implémentation.**
Les [maquettes interactives](mockups/2026-09-23-future/index.html) utilisent des
données fictives ; elles ne sont pas des captures de fonctions livrées.

## Mon avis

Je garderais l’apparence et l’organisation actuelles. Le prochain progrès utile
est de rendre Atoll **plus précis dans ce qu’il montre, plus facile à retrouver
quand on en a besoin et moins actif quand il n’a rien à faire**.

L’îlot, les permissions, le quota et le retour au terminal constituent un produit
cohérent. La mémoire commune est sa piste de différenciation la plus intéressante,
mais son utilité réelle reste moins démontrée que son fonctionnement technique.
Le générateur n’a pas besoin de produire davantage : il doit produire rarement,
avec une consommation compréhensible et des résultats qu’on réutilise.

Je commencerais par le journal lisible et quelques recettes ciblées. Je ne
lancerais pas simultanément les huit pistes ci-dessous. Une exploration peut
très bien conclure à conserver le produit tel quel sur plusieurs d’entre elles.

## Ce qui mérite d’être conservé

- Compact sur une ligne, activité à gauche, quota à droite, fournisseur par la
  couleur ; choix du CLI dans le panneau ouvert ; invisible au repos sans Rockstar.
- Huit onglets natifs et détails techniques repliés. La réorganisation v0.18.2
  répond déjà à la confusion entre intégration, analyses, mémoire et destination.
- Revue des skills : provenance, antériorité, texte complet, comparaison avec
  l’existant et décision explicite sont déjà présents.
- Analyses facultatives, filtrage des tâches banales, déduplication, résultats
  sauvegardés et reprise locale : v0.18.3 vient de traiter ces points.
- Hooks prioritaires, identité des processus, données inconnues explicites,
  séparation des permissions Claude/Codex et helper fail-open.

Les dernières mesures de génération restent celles du 22 septembre :
**28 988 → 8 894 tokens d’entrée sur deux cas**, et non une économie garantie
pour tout usage. [Mesures et limites](REVIEW-2026-09-22-generator-quality.md).

## Les pistes, classées

« Constat » désigne ici un chemin vérifié dans le code. Il ne signifie pas
qu’un problème a été reproduit sur le Mac de Mehdi. L’effort est relatif,
sans estimation artificielle en jours.

| Piste | Preuve disponible | Valeur attendue | Effort / risque | Décision proposée |
|---|---|---|---|---|
| A. Montrer consommation et résultat des analyses | Mesures persistées, absentes du journal UI | Comprendre ce que l’option consomme et produit | Moyen / sémantique des données | Premier chantier si analyses utilisées |
| B. Rendre les sessions masquées accessibles | Surplus sans sélection complète dans l’îlot | Retrouver une session en grande flotte | Petit à moyen / densité | Prototyper, adopter si besoin réel |
| C. Fiabiliser le trajet alerte → terminal | Recette GUI encore différée ; granularités connues | Réduire la recherche après le son | Recette petite ; intégration potentiellement lourde | Vérifier avant de développer |
| D. Préserver le détail lors d’un changement d’écran | Contrôleurs recréés lors d’un vrai changement | Continuité sur le poste multi-écrans | Moyen / focus et cartes | Reproduire puis corriger si gênant |
| E. Réduire sondes et publications au repos | Cadences et réécritures identifiées | Moins de réveils et d’I/O | Moyen / découverte et vieillissement | Mesurer avant d’optimiser |
| F. Présenter chaque quota selon sa validité | Asymétrie Claude 5 h / 7 j | Éviter un chiffre expiré présenté comme courant | Petit / cas d’horloge | Correction ciblée candidate |
| G. Chercher un souvenir sans solliciter un modèle | Moteur local existant ; pas de parcours GUI dédié | Accès direct à la mémoire commune | Moyen / pertinence et périmètre | Expérience, pas engagement |
| H. Retrouver le dernier retour après une absence | Son existant, historique de conclusion absent | Reprendre plus vite plusieurs travaux | Moyen / bruit et attribution | Attendre une gêne observée |

### A — Un journal utile, sans tableau de bord

Aujourd’hui, `LearningPane` montre les dernières tentatives de rétrospective :
volume du transcript, quota, sortie et éventuel coût. Le journal commun conserve
déjà fournisseur, type d’analyse, durée et usage natif des trois consommateurs,
mais ces mesures ne remontent pas dans ce panneau.
Sources : [LearningSettingsPane](../App/LearningSettingsPane.swift#L242),
[AnalysisExecution](../App/AnalysisExecution.swift#L68),
[AnalysisUsage](../AtollCore/Sources/AtollCore/AnalysisUsage.swift#L4).

**Proposition :** remplacer le contenu du journal replié par des lignes simples :
« Bilan · Codex · 1 note écrite, 1 proposition créée », avec entrée/sortie et
durée de l’opération (préparation comprise) au même endroit. Détail à la demande pour le modèle, le cache,
les inconnues et les incidents. Garder les évaluations ignorées consultables.
Ne pas déplacer les modèles, ajouter un onglet ni imposer des graphiques.

**Contrat de développement :** une projection en lecture seule du journal commun,
sans initialiser un budget ni modifier un reçu. Les tentatives ignorées restent
distinctes ; ne pas les raccorder aux analyses par proximité de date ou par
identifiant supposé. Le journal est borné : afficher « dernières analyses
conservées », pas une semaine prétendument exhaustive.

Codex inclut le cache lu dans ses entrées ; Claude l’expose séparément. Ne pas
additionner naïvement ces champs, convertir les caractères en tokens, ni
présenter les tokens comme pourcentage d’abonnement ou facture. « Non mesuré »
n’est pas zéro. Une proposition n’est pas un skill installé ; une installation
n’est pas une utilité prouvée. Le compteur de propositions créées ne donne pas
leur statut actuel. Des notes réécrites par le rangement ne représentent pas
autant de connaissances nouvelles. Un échec ou résultat en attente d’écriture doit
rester distinct d’un succès.

**Validation future :** fixtures des deux fournisseurs, anciens journaux,
mesure partielle, run interrompu, livraison différée et reprise du même reçu.
Après plusieurs reprises locales : consommation comptée une fois, livraison mise à
jour séparément. Lecture UI sans écriture, sans nouvelle génération ni réservation de quota.
Critère : comprendre quel service a consommé et ce qu’il a effectivement écrit,
en ouvrant un seul volet.

### B — Donner une destination au « +N autres »

Le bornage protège le panneau et a été explicitement accepté. En revanche, le
surplus en mode projet est un `Text`. Le mode état renvoie au mode projet,
également borné. Certaines sessions d’une grande flotte ne sont donc pas
sélectionnables dans l’îlot à état constant.
Sources : [ExpandedView](../App/ExpandedView.swift#L173),
[plan de lignes](../AtollCore/Sources/AtollCore/IslandRowPlan.swift#L101).

**Proposition :** rendre le surplus actionnable et ouvrir une liste complète,
bornée en hauteur et défilante, seulement sur demande. Les décisions en attente
gardent leur priorité. La maquette explore cette navigation ; son écran séparé
n’impose pas encore le choix SwiftUI entre popover et vue secondaire.

**Ne rien changer si** le surplus est rare et personne ne cherche les sessions
masquées. **Validation future :** huit projets, plusieurs sessions d’un même
projet, retrait pendant la sélection, navigation clavier/VoiceOver ; chacune
reste joignable sans grandir le compact ni réintroduire le scroll global sous l’onde.

### C — Mesurer le retour au bon terminal

Le bouton existe. Terminal/iTerm peuvent rechercher un TTY ; Cursor/VS Code
reçoivent une ouverture du workspace dans une fenêtre, pas la sélection garantie
de son onglet terminal. Le repli est explicite. Aucun échec GUI n’est établi :
la recette visible est encore différée dans le handoff.
Sources : [TerminalJumpService](../App/TerminalJumpService.swift#L63),
[détail et granularité](../App/SessionDetailView.swift#L262).

**Proposition :** vérifier deux projets, deux terminaux du même projet, ancre
absente et fenêtre fermée. Relever le temps son → bon terminal et la granularité
réellement atteinte. Améliorer l’ancrage uniquement si une API durable le permet
et si le gain est réel. Ne pas promettre « onglet exact » avec un focus de fenêtre.

Le doublon sonore récent venait de la cloche de Cursor ; il a déjà été réglé
localement. Une aide de dépannage courte peut éviter sa répétition, sans modifier
automatiquement les réglages sonores de l’éditeur ou du CLI.

### D — Garder sa place quand les écrans changent

Le debounce et la comparaison de configuration existent déjà. Lors d’un vrai
changement, Atoll recrée néanmoins tous les contrôleurs ; détail sélectionné,
ouverture et épinglage repartent de leur état initial. La signature compare
UUID/frame/notch, alors que densité et hauteur de menu sont fixées à la création.
Sources : [AppDelegate](../App/AppDelegate.swift#L263),
[signature](../App/AppDelegate.swift#L595), [NotchViewModel](../App/NotchViewModel.swift#L20).

**Proposition :** reproduire débranchement, réveil et changement de scaling,
avec détail puis permission ouverts. Restaurer uniquement l’état encore valide
des écrans survivants si la perte est gênante. Pas de refonte multi-écrans :
préserver le propriétaire unique du focus et les préférences par écran.
L’UUID seul n’est pas une identité suffisante pour deux écrans identiques.

### E — Être plus silencieux sur la machine

La découverte Claude démarre indépendamment du fournisseur affiché, avec une
attente de 2 s en activité ou 6 s au repos entre sondes. C’est nécessaire à la
coexistence des CLI, mais peut représenter du travail inutile après de longues
séries vides. L’indexeur balaie toutes les 30 s, avec cache de fichiers et nudges
déjà présents. Codex republie aussi périodiquement ses projections et programme
un snapshot ; sa sérialisation complète et écriture atomique sont sur le MainActor.
Sources : [FleetPoller](../App/FleetPoller.swift#L40),
[MemoryIndexer](../App/MemoryIndexer.swift#L53),
[CodexService](../App/CodexService.swift#L40),
[snapshot](../App/SessionStore.swift#L969).

**Hypothèses à mesurer**, pas preuves de lenteur : backoff des sondes réellement
vides, déduplication des publications identiques, découverte complète moins
fréquente que la lecture des fichiers actifs. Le chemin Claude évite déjà
plusieurs mises à jour sans effet : généraliser ce principe avant une refonte.

**Protocole futur :** trois séquences de 10 min, répétées avant/après sur le même
poste : aucune session, Codex seul, deux CLI actifs. Séparer démarrage/backfill et
régime stabilisé ; garder corpus, réglages et écrans identiques. Compter spawns, réveils,
CPU, I/O, écritures de snapshot et durée sur le fil principal ; mesurer en
parallèle délai de découverte et délai des cartes. Ne pas annoncer de gain
d’autonomie depuis le seul nombre de timers.

Pièges : la clôture Claude compte actuellement des passes manquantes ; ralentir
uniformément allongerait les sessions fantômes. Codex doit aussi faire vieillir
les états sans événement (120/900 s). Conserver ces transitions, la découverte
des deux CLI et le heartbeat nécessaire aux diagnostics. Sources :
[réconciliation](../App/SessionStore.swift#L861),
[vieillissement Codex](../AtollCore/Sources/AtollCore/CodexIntegration.swift#L476).

### F — Une dernière mesure n’est pas toujours une mesure actuelle

Codex vérifie la validité par fenêtre. Le chemin Claude retire une valeur 5 h
expirée, mais conserve sa fraction 7 j sans vérifier son propre reset ; le panneau
la dessine encore, avec l’âge du relevé. Chemin confirmé statiquement, incident
non reproduit ; faible fréquence attendue tant que Claude n’est pas utilisé.
Sources : [SessionStore](../App/SessionStore.swift#L217),
[jauge Claude](../App/ExpandedView.swift#L375),
[contrat Codex](../AtollCore/Sources/AtollCore/CodexQuota.swift#L11).

**Proposition :** afficher une donnée expirée comme dernière mesure dans le
diagnostic, pas comme quota courant. Test à horloge injectée : reset 5 h seul,
reset 7 j, recul d’horloge puis nouveau relevé. Aucun besoin d’abonnement pour
vérifier cette logique ; ne pas fusionner les contrats des deux fournisseurs.
Le correctif porte sur la présentation : conserver le relevé brut et son usage
comme minorant dans les gates d’apprentissage.

### G — Une mémoire qu’on peut consulter soi-même

La recherche plein texte, les filtres de projet, les sources et le repli annoncé
sur une recherche élargie existent. Le parcours est surtout un skill/une commande ;
le panneau montre l’index et les notes, sans recherche de conversation.
Sources : [RecallCLI](../Bridge/Recall.swift#L30),
[searchRelaxing](../AtollCore/Sources/AtollCore/MemoryIndex.swift#L606),
[MemorySettingsSection](../App/MemorySettingsSection.swift#L18).

La commande directe cherche déjà sans modèle : la nouveauté serait un accès
humain hors conversation, pas une nouvelle recherche « gratuite ».

**Expérience proposée :** une fenêtre légère « Retrouver un souvenir », accessible
à la demande, qui réutilise le moteur local. Projet, date, rôle et extrait cité ;
copie explicite du passage retenu. Pas de nouvelle conversation IA, de résumé
automatique ni de nouveau moteur d’embeddings. L’îlot garde son rôle d’état.
Les résultats peuvent inclure des outils ou du thinking : rôle très visible,
recherche élargie annoncée et contexte suffisant pour repérer une décision
corrigée sont nécessaires, même si cela augmente l’effort de présentation.

**Validation avant investissement :** dix recherches connues avec réponses de
référence, mêlant les deux CLI, sources anciennes et décisions corrigées.
Distinguer retrouver/citer soi-même une source et demander à l’agent
d’interpréter une décision ; la fenêtre vise d’abord le premier besoin. Puis
comparer au parcours `$atoll-recall`. Mesure principale : temps pour retrouver
et copier une source suffisante. Vérifier la pertinence des trois premiers
résultats comme garde-fou, pas comme gain attendu d’une UI sur le même moteur. Un matching lexical
exact ne prouve ni la vérité ni la validité actuelle d’une décision.

Le moteur devra rester borné, hors du fil principal, en lecture seule et tolérer
base absente/verrouillée. Conserver le caviardage des extraits. Une fenêtre qui
recopie tout le transcript apporterait peu. Le contrôle du périmètre indexé peut
être étudié séparément si un besoin apparaît : désactiver l’indexation n’efface
pas les souvenirs existants et les transcripts disparus sont intentionnellement
conservés dans l’index. [Comportement](../App/MemoryIndexer.swift#L323).

### H — Un retour récent, uniquement si l’absence pose problème

Le dernier message d’assistant Claude est décodé, mais le détail ne montre pas
de conclusion du dernier tour. La fin d’un tour et la fin du processus sont
distinctes ; la session terminée n’est pas un historique de tâches. Le contrat du dernier message Claude ne prouve pas son
équivalent Codex : vérifier la source et l’attribution au tour pour chaque CLI.
Sources : [HookEvent](../AtollCore/Sources/AtollCore/HookEvent.swift#L116),
[détail](../App/SessionDetailView.swift#L315),
[fin de session](../App/SessionStore.swift#L563).

Observer d’abord dix retours après absence. Si retrouver la conclusion coûte
régulièrement du temps, essayer une liste récente, courte et volontairement
ouverte, avec texte **attribué à l’agent**, heure et retour au terminal. Sans
appel IA, relance de tests, nouveau son ni ouverture automatique. Fixer avant
l’essai un nombre et une durée de conservation ; aucun compteur non lu ou badge
persistant. « L’agent dit
que les tests passent » ne devient jamais « Atoll a vérifié les tests ».

## Comment savoir si l’apprentissage sert vraiment ?

La bonne mesure ne se limite plus à la taille du prompt. Séparer :

1. **Consommation rapportée** : tokens natifs, cache selon le fournisseur,
   couverture et inconnues. Les trois consommateurs d’analyses comptent.
2. **Livraison confirmée** : notes écrites, propositions créées, reprises locales.
3. **Adoption** : proposition acceptée/refusée, skill installé/modifié/archivé.
4. **Usage observé**, puis **utilité évaluée** : ce sont encore deux choses distinctes.

Le journal proactif mesure déjà recherche, injection, couverture et latence ;
il dit explicitement qu’il ne prouve pas l’utilité. L’usage des skills Codex
reste non mesuré, et l’absence de signal ne doit jamais déclencher leur archivage.
Sources : [RecallJournal](../AtollCore/Sources/AtollCore/RecallJournal.swift#L276),
[SkillReviewCenter](../App/SkillReviewCenter.swift#L16).

Je proposerais un bilan ponctuel sur les résultats existants, à la demande,
avant toute nouvelle instrumentation. Une évaluation de pertinence peut être
manuelle sur un petit échantillon ; pas un nouvel agent payant chargé de noter
toutes les réponses. Si l’usage n’est pas démontré, garder l’option désactivée
est une issue acceptable. Aucun chiffre d’économie future n’est promis ici.

## Ce que je n’ajouterais pas

- Un cockpit de lancement, un kanban ou un orchestrateur multi-agents.
- Une nouvelle refonte des réglages, des badges permanents ou plus d’animations.
- Le recall automatique Codex sans contrat vérifié, ou un modèle chargé de
  produire systématiquement des résumés pour habiller l’îlot.
- Une synchronisation réseau des permissions, une flotte distante ou un nouveau
  fournisseur sans besoin concret. Les conditions de sûreté changeraient beaucoup.
- Un score de productivité, une estimation d’argent « économisé » ou des tokens
  « évités » calculés sans contre-factuel comparable.
- Un archivage automatique sur « zéro usage » ou une simplification générale
  des machines à états. Leur prudence est une partie de la valeur du produit.

## Repositionner la vision sans inventer un avantage

La [vision d’août](VISION-2026-08.md) reste une bonne discipline de soustraction,
mais contient des choix dépassés, notamment le refus du multi-fournisseur. Elle
reste historique ; cette exploration ne remplace pas les décisions validées.

Vérification documentaire du 23 septembre, après consultation des CLI installés
(`codex-cli 0.156.1`, Claude Code `2.1.267`) : Codex documente notifications TUI,
`notify` et reprise de sessions ; Claude documente aussi des notifications par
hooks. Le son seul et la reprise seule ne sont donc pas des exclusivités d’Atoll.
Sources officielles : [Codex notifications](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications),
[Codex CLI](https://learn.chatgpt.com/docs/codex/cli),
[Claude hooks](https://code.claude.com/docs/en/hooks#notification).

La documentation Claude distingue mémoire automatique par dépôt et instructions
utilisateur communes à tous les projets. La phrase du README « mémoire native
par dépôt » gagnerait donc à préciser **mémoire automatique**, sans laisser
entendre que Claude ne sait rien partager entre projets.
[Source officielle](https://code.claude.com/docs/en/memory).

L’avantage proposé d’Atoll est plus précis : un point d’attention commun aux
sessions locales des deux CLI, et une recherche locale dans leur historique
commun. Il faut mesurer si ces raccourcis font gagner du temps. Cette lecture
des documentations ne constitue pas une certification de compatibilité avec
toutes les versions natives.

## Ordre de travail si Mehdi choisit de poursuivre

**Lot 1 — clarté, petit périmètre.** Journal des analyses (A) si l’option est
utilisée et la consommation difficile à comprendre ; sinon, commencer par la
recette du terminal (C). Puis recette de
fraîcheur des quotas (F). Zéro génération nécessaire
pour les fixtures et contrôles. Traiter seulement les problèmes établis.

**Lot 2 — usage réel du poste.** Scénarios multi-écrans (D), grande flotte (B),
profilage au repos (E). Choisir ensuite le gain le plus net. Mesurer une référence
avant de modifier une cadence ; abandonner une optimisation non significative.

**Lot 3 — une seule expérience produit.** Tester la recherche mémoire (G). Si
elle n’améliore pas les recherches par rapport au skill, ne pas la livrer. Le
retour récent (H) attend sa propre preuve de besoin.

Chaque lot de code futur : test pertinent, sabotage du correctif, recette
visuelle des états concernés, PR distincte et validation avant fusion/release.
La présente PR ne lance aucun de ces lots.

## Méthode et limites

Balayage ciblé des parcours, de la mémoire/analyses, de la découverte et des
écrans, avec deux lectures indépendantes ; comparaison aux captures SwiftUI
déjà validées, aux mesures PR #5 et aux contrats natifs documentés. Le registre
ne doit créditer qu’un **sweep**, jamais une relecture ligne à ligne complète.

Pas d’analyse de transcripts personnels, de profilage CPU, de nouvel appel
génératif depuis Atoll, ni de test GUI de l’app pendant cette exploration.
Les défauts de chemins statiques, les hypothèses de coût et les idées produit
sont séparés ci-dessus. L’absence de test actuel n’annule pas les validations
précédentes ; elle limite seulement ce que ce document peut affirmer.

La seconde lecture critique et la validation des maquettes sont consignées
dans le [dossier de validation](reviews/2026-09-23-future/README.md).
