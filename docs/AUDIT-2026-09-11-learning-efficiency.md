# Audit — rendement du générateur de skills et des analyses Atoll

**11 septembre 2026 · base `53c0a59fe28e40dd18d7a5b6fc0cea109cec37c3` (v0.18.2).**
Demandé par Mehdi pour identifier les pertes de tokens et de temps de revue.
Cette PR livre l'audit, ses reproductions et un plan ; elle ne modifie pas le
produit, ses préférences ni les skills installés. Aucun appel génératif Atoll
n'a été déclenché pendant cet audit.

## Décision proposée

Conserver l'apprentissage opt-in, mais traiter **la répétition et la fiabilité du
résultat avant de raccourcir encore les skills**. Le générateur actuel demande
déjà 0–2 skills, généralement 200–600 tokens, et refuse un corps de plus de
8 000 caractères. Ces protections ne démontrent ni la nouveauté ni l'utilité.

Trois priorités : récupérer les sorties après une erreur locale sans rappeler
le modèle ; éviter de payer deux fois pour la même matière ; mesurer les tokens
et les résultats réellement conservés. Une nouvelle couche d'agents ou un
pré-tri systématique par un autre modèle ajouterait un coût avant d'avoir prouvé
son intérêt.

Aucun emballement illimité démontré : opt-ins, quotas, cadence et budget commun
existent. Les défauts ci-dessous peuvent gaspiller les créneaux encore autorisés.
**La fréquence réelle des doublons et le taux d'utilité des skills restent inconnus.**

## Périmètre et protections existantes

| Parcours | Déclenchement / matière | Protections vérifiées | Angle mort utile à cet audit |
|---|---|---|---|
| Rétrospective → notes + propositions | Fin de session suivie, délai de 15 s, critères durée/taille/prompts ; digest préparé localement | Opt-in désactivé par défaut ; reprise de session annule ; digest vide bloquant ; sortie revalidée ; installation des skills après revue humaine | Croissance brute ≠ connaissance nouvelle ; résultats proposés ≠ fichiers écrits ≠ skills utilisés |
| Rangement des notes | Opt-in hebdomadaire indépendant ; vérification toutes les 15 min ; lancement manuel possible | Moins de 2 notes ou corpus trop grand : aucun appel ; corpus complet borné à 80 000 caractères ; staging/réparation et sources des notes contrôlés | Pas d'empreinte du corpus ; annulation non persistée dans la cadence ; stock trop grand peut rester sans rangement |
| Recherche IA de plugins | Option explicite de recherche ; recherche locale par défaut | Partage le budget des deux autres ; timeout 120 s ; budget Claude de 0,30 USD | Consommateur voisin du même budget ; ce n'est pas une analyse automatique de chaque session |

Le budget commun sérialise les analyses et fige moteur, modèle, destination et
quota avant les attentes. Par défaut : **2 lancements par fournisseur sur 5 h**,
seuil de quota à 70 % ; quota inconnu autorisé, mais au plus **1 lancement sur 5 h**.
Le journal illisible bloque la dépense. Un processus lancé puis interrompu reste
compté ; les erreurs de préparation ne sont pas assimilées à une génération.
Rétrospective et rangement ont un timeout de 600 s et passent un plafond de
1,50 USD à Claude. Codex utilise le modèle explicitement choisi, un workspace
temporaire, `--ephemeral`, sandbox read-only et schéma de sortie.

Ces bornes limitent les appels ; elles ne constituent pas un budget de tokens.
Le plafond de sortie Swift protège les artefacts après génération. Le rendu
du catalogue est borné ; la liste des noms de notes ne l'est pas. Le digest
est borné à 150 000 caractères, chaque fragment à 2 000 caractères ; la lecture
JSONL s'arrête à 64 Mio ou 200 000 lignes parsées retenues. Caractères, tokens et quota
d'abonnement sont des unités différentes.

Sources : [LearningSettings](../App/LearningSettings.swift),
[AnalysisExecution / AnalysisBudget](../App/AnalysisExecution.swift),
[LearningGate](../AtollCore/Sources/AtollCore/LearningGate.swift),
[RetrospectiveRunner](../App/RetrospectiveRunner.swift),
[NotesCurationService](../App/NotesCurationService.swift),
[PluginInventory](../App/PluginInventory.swift),
[CodexExecPlan](../AtollCore/Sources/AtollCore/CodexExecPlan.swift).

## Ce que les données locales permettent de dire

Lecture seule le 11 septembre, export par [observe.py](audit-support/2026-09-11-learning-efficiency/observe.py).
Seuls les [agrégats](audit-support/2026-09-11-learning-efficiency/local-aggregates.json)
sont versionnés ; aucun transcript, contenu de note/skill, chemin personnel ou
identifiant de session réelle n'est publié.

| Observation | Mesure | Limite d'interprétation |
|---|---:|---|
| Journal conservé | 100 décisions, du 24 août au 11 septembre | Historique borné, pas toute l'activité |
| Décisions de lancement | 24, dont 2 debug ; 20 issues succès, 3 échecs, 1 issue absente | Une décision `run` ne prouve pas un spawn |
| Coût communiqué par le CLI | 19 valeurs, somme 10,349361 USD, maximum 0,7860274 USD | Indicateur rapporté, **pas une facture**, ni le débit du forfait, ni une dépense complète ; échecs et champs absents non valorisés |
| Digest des 24 candidats | Médiane 146 039,5 caractères, maximum 149 989 | Taille du digest seul, pas du prompt complet ; pas une mesure de tokens |
| Résultats annoncés | 135 notes, 16 skills | Compteurs déclarés ; le constat E1 montre qu'ils peuvent surestimer les écritures |
| Stock observé | 160 notes ; scope Claude : aucune proposition en attente, 25 métadonnées archivées toutes `approved` ; aucun scope d'artefacts Codex présent dans ce dossier | Cohorte différente des 100 décisions ; pas de taux d'acceptation calculable ; aucun refus observé dans cet échantillon |
| Dernier rangement journalisé | Refus le 7 septembre : corpus de 109 545 caractères | État historique enregistré, au-delà du plafond courant de 80 000 ; pas une nouvelle génération pendant l'audit |

Le journal commun `analysis-jobs-v2.json` est absent de ce dossier au relevé.
Parmi les candidats, 22 n'ont pas de fournisseur explicite et 2 indiquent Claude ;
aucun n'est explicitement attribué à Codex. Aucun champ de tokens consommés.
**Ce relevé ne mesure donc pas la consommation Codex actuelle**, ni le rendement
du prompt concis livré le 10 septembre. Il justifie l'instrumentation et une
vérification de son alimentation dans la version réellement exécutée.

La [recette du 10 septembre](reviews/2026-09-10-skills-validation/generator/results.json)
reste une preuve limitée utile : quatre fixtures réelles Codex, modèle demandé
`gpt-6-astra`, donnent respectivement 0, 0, 1 et 0 skill ; le corps produit
contient 146 mots. Elle ne compare pas plusieurs modèles et ne mesure pas
l'utilisation future. Le parcours Claude authentifié reste indisponible sans
abonnement ; il n'a pas été relancé.

## Constats et contre-vérifications

Les priorités du plan indiquent l'ordre de travail, pas une gravité sécurité.
Les scénarios synthétiques prouvent une possibilité dans le code courant ;
ils ne donnent pas sa fréquence chez les utilisateurs.

### E1 — Une erreur d'écriture devient un succès et masque la perte

**Défaut reproduit sur le runner réel.** Des fichiers ordinaires placés aux
chemins temporaires `notes/` et `proposed/` provoquent de vraies erreurs d'écriture.
Le rapport contient 1 note et 1 skill valides. Aucun n'est écrit, aucun `noteSink`
n'est appelé ; pourtant le journal conserve `success(1n/1s)`, `notesWritten=1`,
`skillsProposed=1`. La session est marquée traitée ; une nouvelle évaluation du
même transcript donne `skip(alreadyProcessed)`. Le contrôle nominal écrit bien
les deux artefacts. Les fichiers obstacles sont préservés.

Cause : `RetrospectiveRunner.apply` absorbe les erreurs locales (lignes 790–829),
mais les compteurs et l'issue viennent du rapport (743–780), puis `finish`
marque comme traitée une issue qui ne commence pas par `failed(` (843–844).
Le chemin Claude simulé est exercé ; l'application des artefacts est commune
aux deux moteurs. Une panne disque peut coûter une analyse et rendre son apport
introuvable tout en gonflant le bilan.

**À faire :** compter les écritures confirmées, tracer l'échec partiel et conserver
la sortie validée pour réappliquer localement, sans nouvelle génération.
La dépense et le traitement durable de la session doivent rester deux états distincts.
Limiter la conservation des sorties et réutiliser les mécanismes de staging
existants lorsque possible. Si le disque empêche aussi leur sauvegarde, afficher
l'échec : la récupération n'est garantie que pour un résultat effectivement conservé.

### E2 — Une croissance du JSONL peut repayer un digest identique

**Admission reproduite avec LearningGate + parseur Codex + digest réels.**
Ajouter une ligne `turn_context` filtrée fait passer le transcript de 146 319
à 206 418 octets (+60 099, seuil 50 000). Les deux digests sont identiques :
124 215 caractères et 103 entrées. La même session déjà traitée est réadmise.
Sans croissance : `alreadyProcessed` ; avec deux runs précédents : `windowCapReached`.

Cause : `LearningGate.decide` compare la taille brute (214–218).
`RetrospectiveRunner` relit le digest depuis le début (987–1010) et persiste
l'ID, la taille et la date, sans empreinte de matière analysée (969–975).
Le cap de lecture rend aussi possible une croissance hors du préfixe lu.

Le harness couvre la porte et le digest, pas un second spawn du runner.
Le coût supplémentaire nécessite une nouvelle fin de session et les autres
gardes disponibles : quota, budget commun, modèle et catalogue valides.
**À faire :** déduplication locale de la matière analysable ; versionner la
politique d'analyse et tenir compte de la destination et des antériorités utiles.
Un changement du JSONL brut seul ne doit pas suffire à autoriser une dépense.

### E3 — Le rangement repart après annulation ou à corpus inchangé

**Deux spawns évitables reproduits sur le service et le budget réels.**
Après annulation d'une curation due déjà lancée, `curation.json` reste inchangé.
Le résultat tardif est correctement ignoré et le budget garde la dépense.
Mais le callback `runIfDue()` suivant relance une curation si un créneau reste
disponible. Séparément, une curation réussie puis une nouvelle échéance provoquent
un appel supplémentaire alors que les SHA256 du corpus sont inchangés.

Cause : `runIfDue` ne vérifie que dates/backoff (118–123) ; l'annulation ne
passe pas par `finish`, qui persiste la cadence (148–169, 261–264, 599–610).
Aucune empreinte de corpus dans l'état (747–751). Couper l'option hebdomadaire
arrête bien le scheduler ; ce n'est pas la même action qu'annuler le run.
Le harness appelle directement `cancel()` : il n'existe pas de bouton Annuler
pour ce rangement. Les appelants actuels sont l'arrêt d'Atoll, la désactivation
du scheduler et le changement du home Codex. Le défaut de cadence est établi au
niveau du service ; fermeture/reprise réelle et changement de home suivi d'un
tick restent à exercer. Après désactivation, aucun tick n'est attendu.

**À faire :** mémoriser l'annulation d'un processus lancé et différer le prochain
automatisme ; comparer le corpus courant au corpus **après la dernière écriture
réussie**, pas à son entrée d'avant rangement. Un tick sans changement ne doit
consommer aucun appel. Une relance manuelle garde une intention explicite.

### E4 — L'antériorité des skills est incomplète

**Trou de catalogue Claude reproduit.** Une fixture contient un skill dans
`.claude/skills` et une commande témoin dans `.claude/commands` : le catalogue
ne trouve que la commande. `SkillCatalog.entries` compose les skills personnels,
les commandes et les plugins (208–210, 382–450). La génération et la comparaison
de revue n'ont donc pas ce skill du projet. Codex utilise son catalogue natif ;
le même défaut n'est pas établi pour lui.

**Propositions et décisions absentes du prompt : mécanisme vérifié par lecture.**
`SkillDestination.catalog` retourne les capacités installées ; le runner transmet
ce catalogue et les noms de notes (582–601). Les propositions en attente et les
refus archivés ne sont pas ajoutés. Un retour similaire du modèle crée un nouveau
dossier `slug-UUID` (807–824). La fixture montre seulement que ces fichiers
d'antériorité ne changent pas le catalogue ; elle ne simule pas deux générations
de même contenu. Le stock Claude observé ne comporte ni attente ni refus ; aucun
scope d'artefacts Codex n'est présent dans le dossier d'apprentissage observé.

**À faire :** compléter les scopes Claude selon son contrat, et fournir une
antériorité compacte des propositions et décisions, par destination. Regrouper
les doublons exacts localement ; un refus ancien ne doit pas bannir définitivement
une procédure qui a changé. Ne pas injecter tous les corps archivés dans le prompt.

### E5 — Le journal ne permet pas de piloter les tokens et l'utilité

**Limite de mesure vérifiée.** `AnalysisBudget.Record` conserve moteur, modèle,
quota, préparation/lancement et issue ; pas de tokens d'entrée/sortie/cache, ni
durée terminée. Le journal rétrospectif ajoute taille du digest et coût Claude
sur une sortie exploitable. Codex ne garde que le JSON final dans ce parcours ;
son absence de montant USD ne signifie pas absence de consommation de forfait.
Les tokens natifs ne sont pas conservés dans ces journaux, pour aucun des moteurs.

Le format CLI Codex local propose `exec --json` ; Atoll ne l'active pas ici.
Avant d'en faire un contrat, capturer et tester les événements d'usage disponibles,
y compris échec/annulation et variations de version. Ne pas inventer un chiffre
absent, ni additionner deux fois les compteurs cumulés. `--ignore-user-config`
n'est pas la preuve d'un contexte natif entièrement vide ; la surcharge effective
d'instructions/skills éventuels n'a pas été mesurée.

**À faire :** instrumentation commune légère, incluant inconnues, temps écoulé,
taille du prompt complet et résultats persistés. Relier proposition → décision
de revue sans contenu privé dans le bilan. L'usage Codex des skills n'étant pas
mesuré, installation et réutilisation doivent rester distinctes. Commencer par
un bilan local ; aucun besoin démontré d'un dashboard ou d'un service distant.

### E6 — Des preuves peuvent disparaître du digest sans indicateur dédié

**Comportement reproduit, contrat actuel respecté.** Un fragment assistant de
2 659 caractères dont la preuve finale est en queue donne un digest de
2 012 caractères, marqueur `[…]` présent, preuve absente et `truncated=false`.
Ce flag signifie explicitement « entrées entières élaguées », et ne compte pas
la coupe systématique des fragments (`TranscriptDigest`, 75–79, 104, 337–340).
Il serait inexact de présenter le flag comme contraire à sa spécification.

Le journal ne distingue donc pas fragments raccourcis, entrées retirées et
lecture JSONL arrêtée. La perte de la preuve peut nuire à un skill ; son effet
sur la qualité réelle reste à mesurer. **À faire :** exposer ces trois compteurs
et comparer une sélection conservant conclusions/commandes vérifiées. Une coupe
tête+fin n'est pas à généraliser sans tester les commandes et leurs résultats.

### E7 — Les notes croissent, mais leur déduplication reste faible

**Limite de conception ; blocage historique observé.** `existingNoteSlugs`
énumère tous les noms sans borne (runner, 1012–1023) ; le prompt les injecte,
sans contenu permettant de reconnaître le même fait sous un autre nom.
`deduplicatedFilename` évite l'écrasement en suffixant ; il ne fusionne pas le sens.
Les doublons internes à un rapport sont déjà éliminés.

Le rangement refuse un corpus au-delà de 80 000 caractères, ce qui est arrivé
dans le relevé local. Le refus est déjà affiché sous « Dernier passage » ; volume
et pourcentage du budget sont également disponibles dans Apprentissage.
Relever le plafond déplacerait le problème vers une génération plus coûteuse.
**À faire :** déduplication exacte locale, antériorité pertinente bornée et
conservation de ce signal existant ; aucune lacune UX n'est démontrée ici.
Évaluer ensuite si une stratégie bornée de sélection suffit. Un rangement par
lots multiplie les appels et doit compter dans un budget global ; il n'est pas
proposé comme première correction. Aucune suppression automatique des souvenirs.

## Plan de développement proposé

Chaque lot est une future modification produit avec test de non-régression et
sabotage qui fait échouer ce test pour la bonne raison. Les changements d'UI
restent soumis à captures. Cette PR n'implémente aucun de ces lots.

| Ordre | Livrable minimal | Validation et critère de sortie |
|---|---|---|
| 1 — Fiabilité de la dépense (E1, E3) | Résultat sauvegardé récupérable ; compteurs d'écriture exacts ; cadence d'annulation via champs existants | Erreurs note seule, skill seul, checkpoint impossible, crash et reprise : aucun faux succès ; sortie sauvegardée réappliquée sans second spawn ; arrêt/reprise, désactivation et changement de home ne relancent pas aussitôt la curation payée |
| 2 — Éviter le travail inchangé (E2, E3) | Empreintes versionnées du digest et du corpus après succès ; pas de nouvelle option par défaut | Croissance filtrée, préfixe de 64 Mio inchangé, redémarrage, changement réel et corpus après curation : zéro appel sur les cas identiques, vrai changement admissible ; budget/quotas préservés |
| 3 — Mesure commune minimale (E5, E6) | Durée, usage natif si disponible, taille du prompt complet, motifs de skip, sorties écrites/reprises ; inconnue explicite | Fixtures JSONL pour chaque moteur, compteurs cumulés/cache, erreurs et annulations ; absence de données ≠ zéro ; pas de prompt ou secret dans les métriques |
| 4 — Nouveauté avant volume (E4, E7) | Scopes Claude complets ; antériorité bornée propositions/décisions ; doublons exacts regroupés ; signal existant de corpus trop grand conservé | Skill de projet, installation concurrente, mêmes propositions, refus ancien puis procédure différente, destinations Claude/Codex ; aucun écrasement ni suppression de note |
| 5 — Qualité à coût borné (E6, E7) | Benchmark annoté et comparaison du digest courant avec une sélection plus courte qui garde les preuves | Cas routine, déjà couvert, vrai piège, correction finale, commande longue, session reprise, erreur sans verdict ; vérifier absence de faux skill, nouveauté, commandes exactes et temps de revue |

Les lots 1–2 n'attendent pas un benchmark payant : leurs dépenses évitables sont
reproductibles hors ligne. Le lot 3 précède toute comparaison live de prompts
ou modèles. Le lot 4 ne nécessite pas un classifieur LLM supplémentaire.

Pour le lot 2, une empreinte ne doit pas effacer les conditions de réanalyse :
séparer nouveauté de matière, version du prompt/parseur, destination et catalogue
pertinent. Les notes créées, propositions puis installations issues de la dernière
analyse ne doivent jamais rendre automatiquement son propre digest « nouveau ».
Une modification de catalogue seule ne déclenche pas de réanalyse automatique ;
elle est prise en compte lors d'une analyse autrement justifiée. Changer de modèle
seul ne doit pas provoquer un rattrapage automatique
de tout l'historique. Définir une relance manuelle explicite ; migrer sans lancer
massivement les sessions anciennes. Après erreur de stockage, privilégier E1 et
sa sortie récupérable plutôt qu'une réanalyse autorisée par un simple échec.

Le benchmark commence hors ligne avec les sorties attendues « aucun skill ».
S'il faut des générations réelles, annoncer le nombre maximal d'appels et les
modèles avant exécution ; comparer les mêmes fixtures avec le prompt livré.
Mesurer tokens effectivement rapportés, durée, propositions acceptables,
doublons, preuves conservées et effort de revue. Pas de pourcentage d'économie
promis sans mesure. Un skill accepté n'est pas automatiquement un skill réutilisé.

L'UX cible reste simple : choix du moteur/modèle, opt-ins et un bilan compréhensible
« analysé / évité / à revoir / échec à récupérer ». Les empreintes, seuils internes
et paramètres de prompt ne justifient pas de nouveaux réglages utilisateur.
Après mesure, une analyse qui coûte plus qu'elle n'apporte peut être rendue
manuelle ou supprimée ; ajouter un automatisme n'est pas un objectif en soi.

## Preuves et limites de validation

```sh
swift test --package-path AtollCore --filter 'LearningGateTests|TranscriptDigestTests|RetrospectivePromptTests|RetrospectiveReportTests|NotesCurationPromptTests|NotesCurationTests|SkillCatalogTests|CodexExecPlanTests|SkillProposalTests'
python3 docs/audit-support/2026-09-11-learning-efficiency/run.py
python3 Scripts/check-docs.py --no-tests
```

**165 tests Core ciblés, zéro échec.** Les reproductions supplémentaires
compilent les sources de production sans transformation ; leurs
[résultats](audit-support/2026-09-11-learning-efficiency/results.json) contiennent
les SHA256 des fichiers. Les scripts créent exclusivement des fixtures dans
un dossier temporaire et compilent AtollCore ; ils ne lancent pas l'app.

Pour E1/E3, les collaborateurs viennent des stubs runtime du dépôt : chemins
isolés, catalogue fictif, quota frais et faux CLI Python. Le budget commun et
les services sont réels ; maximum réglé à 2. `ProcessInspector` simulé ne tue
pas le faux processus afin d'exercer le retour tardif après annulation.
Le fichier de cadence fictif est daté de huit jours avant l'initialisation,
puis le vrai `runIfDue()` est appelé : aucune attente d'une semaine et aucun
remplacement de `Date()`. Le cas corpus inchangé conserve les notes d'un premier
cycle nominal ; leurs empreintes sont comparées entre les deux processus.

Pour E2/E4/E6, compilation des types Core réels avec racines temporaires.
La preuve d'antériorité omise est limitée au catalogue et à la lecture de son
appelant ; ce n'est pas une mesure de répétitions générées. Ces harnesses sont
des **diagnostics du comportement actuel**, pas des tests affirmant que les
défauts sont souhaitables. Les futures corrections devront inverser les attentes
concernées dans de vrais tests de régression, avec sabotage.

Pas de build/distribution/UI rejoué pour une PR documentaire sans changement
produit. Pas de vérification authentifiée Claude. Pas d'estimation par conversion
arbitraire caractères → tokens, ni de mesure d'économie inventée.

## Couverture et seconde lecture

Lecture intégrale déclarée pour : `App/AnalysisExecution.swift`,
`App/LearningSettings.swift`, `App/CodexRun.swift`, `App/SkillDestination.swift`,
`AtollCore/Sources/AtollCore/CodexExecPlan.swift`, `RetrospectivePrompt.swift`,
`CodexSkillCatalog.swift`, `TranscriptLine.swift`, `LearningGate.swift`,
`CodexTranscriptParser.swift` (ces derniers noms sous le même dossier Core).

Lecture ciblée des déclencheurs et chemins pertinents : `RetrospectiveRunner`,
`NotesCurationService`, `PluginInventory`, `SkillReviewCenter`, `TranscriptDigest`,
`RetrospectiveReport`, `SkillCatalog`, `LearningArtifacts`, `LearnedSkillStore`,
`NotesCurationPrompt`, `NotesCuration` et tests associés. Repérage des appelants
dans `AppDelegate`. Le registre retient prudemment un **sweep**, et ne transforme
pas ces lectures ciblées en audit intégral de tous les fichiers.

Seconde lecture indépendante terminée avant ouverture de la PR : sources des
harnesses et résultats conservés examinés, sans prétendre à une seconde exécution
indépendante. Corrections retenues : distinguer le stock Claude des scopes Codex
dans l'observation ; préciser les appelants réels de l'annulation ; conserver le
signal de corpus trop grand déjà présent ; empêcher qu'une empreinte soit invalidée
par les propres sorties de l'analyse ; préciser le cap de lignes parsées.

Le plan conserve son ordre, avec une récupération limitée aux sorties effectivement
sauvegardées et une cadence réparée via les champs existants. E2 reste une preuve
d'admission conditionnelle, E4 ne prouve pas une fréquence de doublons, E6 reste
une limite de mesure conforme au contrat actuel. Aucun pourcentage d'économie
ni nouveau réglage utilisateur n'a été ajouté pour combler ces inconnues.
