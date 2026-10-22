# Atoll — plan de recentrage sur l’îlot, les quotas et les skills

Proposition du 22 octobre 2026, **approuvée par Mehdi : « ok je valide »**.
Le texte ci-dessous conserve le plan présenté avant développement. L’état de son implémentation et les validations se trouvent dans HANDOFF.md et le rapport associé. Aucune publication ni installation n’est autorisée par cet accord.

## 1. Décision proposée

Garder un compagnon macOS qui montre les sessions et les quotas de Codex CLI et Claude Code, et propose des skills utiles à partir des sessions terminées. La création de propositions doit pouvoir être coupée sans désinstaller ni rendre inutilisables les skills existants.

Mehdi a confirmé pendant cette analyse :

- conserver l’îlot, son suivi visuel de l’activité et sa liste de sessions ;
- conserver Codex **et** Claude Code ;
- conserver les quotas et les skills ;
- ajouter une commande claire pour désactiver la création de skills ;
- retirer les autres fonctions, avec un plan à valider avant tout développement.

La recommandation est une **simplification réelle et progressive**, qui réutilise les collecteurs et le générateur qualifiés. Pas de réécriture générale.

## 2. Base exacte et niveau de preuve

L’app installée a été lue via son Info.plist : **0.18.7, build 42**. Le dossier du Bureau reste sur l’ancienne branche d’exploration, commit 65ce2b6 : ce n’est pas la base à modifier pour réaliser ce plan.

Les analyses portent sur le checkout local hors iCloud :

    /Users/mehdiguiard/Library/Caches/atoll-quota-days-20261022

Sa tête 751dd6809d9c85f2d6c1d1bc2530d1a43ec49ef5 correspond au main GitHub vérifié pendant cette session. Le tag 0.18.7 pointe sur 82b90725e17d434616ed48210711d955a034192f ; la différence entre ce tag et la tête analysée est documentaire, sans changement produit.

Trois lectures ciblées ont couvert séparément le générateur et ses données, les retraits/migrations, et les collecteurs/quotas/interface, puis trois contrelectures ont confronté ce plan à ces constats. Elles ont notamment corrigé l’ordre de bascule des hooks et de restitution des sons. Ce travail n’est pas une relecture ligne à ligne de tous les fichiers du dépôt. Mesure de cadrage : 61 fichiers de code App et 86 fichiers Core source ; les dépendances des fonctions conservées traversent ces deux ensembles.

Contrôles effectués : identité de branche et version, comparaison tag/tête, lecture des règles actives et du HANDOFF, vérification documentaire sans tests, lecture du plan de validation offline. Le contrôle documentaire passe, avec avertissements de couverture de revue ; il ne certifie pas l’absence de défaut produit.

Contrelecture finale des points corrigés : ordre des lots et bascule des permissions cohérents, fallback sonore désactivé avant restitution, fichiers protégés explicitement préservés. Aucun blocage de conception identifié dans les zones examinées ; cela ne remplace pas les tests d’implémentation prévus.

Lecture sélective des préférences actuelles : création des bilans active, rangement hebdomadaire actif, moteur d’analyse Codex et quota Codex actif. Le fichier de parking des anciens hooks sonores est présent. Leur contenu n’a pas été modifié. Aucune conversation privée n’a été analysée pour ce plan.

**Pas de build, recette GUI, campagne de tests produit ni nouvel appel génératif pendant cette analyse.** Les validations citées dans le HANDOFF sont historiques ; elles ne sont pas présentées comme rejouées aujourd’hui.

## 3. Deux solutions possibles

| Solution | Résultat | Limite |
|---|---|---|
| A — Interface allégée | Masquer les sections inutiles et clarifier le switch d’apprentissage | Les anciens services, appels et migrations restent à entretenir ; masquer seul ne désactive pas le fonctionnement |
| **B — Recentrage complet recommandé** | Retirer les services inutiles, conserver observation/quotas/skills et une petite couche de migration legacy | Demande plusieurs lots vérifiés, car données et hooks sont partagés |

La solution B est détaillée ci-dessous. Ses lots sont intégrables séparément, mais les étapes intermédiaires ne sont pas des versions à distribuer automatiquement.

## 4. Périmètre final

| Garder | Retirer du fonctionnement normal |
|---|---|
| Îlot ASCII, compact, panneau, thèmes, tailles par écran, onde et Reduce Motion | Cartes d’autorisation, réponses aux plans et aux questions |
| Activité et liste de sessions, regroupements existants, états observés | Rockstar et toute décision automatique |
| Informations utiles d’une session, en lecture seule | Arrêt d’une session, ouverture du terminal, passation Claude ↔ Codex |
| Choix du fournisseur affiché ; observation des deux CLI | Sons Atoll, préécoutes et fallbacks sonores |
| Quotas, resets, fraîcheur et inconnues explicites | Indexation/recherche mémoire, recall manuel et injection proactive |
| Création facultative, revue, approbation/rejet, mise à jour et archivage des skills | Création et rangement de notes, gestion/recommandation de plugins |
| Choix moteur/modèle et destination des skills, limites de dépense | Statistiques d’usage qui imposeraient de conserver l’index mémoire |
| Connexions, diagnostics indispensables, mises à jour, À propos | Réglages et onboarding des fonctions retirées |

Les données anciennes restent conservées sur disque : notes, base mémoire, archives, handoffs, sons, propositions et résultats sauvegardés. **Retirer une fonction n’autorise aucune purge de ces données.**

Les catalogues de capacités existantes restent utilisés pour éviter les skills doublons, y compris les capacités fournies par les plugins. Ce lecteur technique n’est pas le gestionnaire de plugins à retirer.

Le suivi conservé est celui déjà implémenté pour les **CLI**. Le code actuel ne garantit pas l’inventaire exhaustif des conversations de l’app Codex. Ce plan ne crée pas une nouvelle intégration desktop en parallèle.

## 5. Comportement précis du switch Skills

Libellé proposé : **« Créer automatiquement des propositions de skills »**.
Aide : « Analyse les sessions terminées pour proposer des procédures réutilisables. Utilise le quota du moteur choisi. Les skills existants restent disponibles quand cette option est désactivée. »

Réutiliser la clé existante learningRetrospectiveEnabled. Conserver son choix chez les utilisateurs existants, donc activé sur le poste de Mehdi. Rester désactivé par défaut pour une nouvelle installation. Ne pas créer un second interrupteur concurrent.

| Situation | Contrat proposé |
|---|---|
| ON | Seules les sessions éligibles alimentent le moteur existant ; zéro proposition reste un résultat normal |
| OFF avant une analyse | Pas de nouvelle collecte destinée à générer des skills, préparation coûteuse, réservation ni lancement de modèle ; vider la file et annuler le délai. Le suivi des sessions et des quotas continue |
| OFF pendant préparation | Invalider le run ; revérifier après chaque attente ; empêcher un lancement tardif |
| OFF pendant modèle | Demander l’arrêt immédiatement ; conserver SIGTERM puis escalade SIGKILL après 5 s et contrôle de l’identité des processus ; ne pas promettre un arrêt instantané ni l’annulation de tokens déjà consommés |
| OFF après une réponse sauvegardée | Conserver le résultat payé et sa provenance, suspendre sa livraison automatique ; aucune régénération |
| OFF avec skills existants | Revue, approbation/rejet et gestion manuelle disponibles ; skills installés inchangés et toujours utilisables dans les CLI |
| Retour ON | Accepter les prochains événements éligibles et reprendre les résultats déjà payés, même sans quota ou modèle disponible pour une nouvelle analyse ; pas de rattrapage massif des sessions passées pendant OFF |
| Redémarrage | Conserver le choix et les dépenses antérieures ; ne pas recréer un run ou une proposition déjà livré |

La réservation d’un processus annulé reste occupée tant que sa sortie effective n’est pas constatée : l’annulation ne doit pas permettre deux modèles concurrents. Ajouter une garde OFF avant la première capture/préparation/réservation du chemin skills, en plus des gardes après attente. La reprise d’un résultat payé précède le choix du modèle/payeur et ne réserve aucun nouveau créneau. Les fenêtres glissantes de budget de 5 h ne sont réinitialisées ni par OFF/ON, ni par redémarrage, ni par le reset du quota natif.

Dans la version finale, aucun appel de curation ou de recherche de plugins ne subsiste. OFF doit donc bien couper la seule fonction générative d’Atoll ; aujourd’hui, ce n’est pas vrai puisque le rangement possède son propre interrupteur.

## 6. Moteur de skills : conserver les garanties, supprimer les sorties notes

Chaîne cible :

    fin réelle de session → délai/gate → digest local borné
        → catalogue + antériorité des skills → modèle choisi
        → validation Swift → sauvegarde du résultat
        → proposition → revue manuelle → installation protégée

Conserver les seuils et limites actuels hors changement nécessaire : durée minimale, taille, nombre de prompts, délai de 15 s, une analyse à la fois, plafond par fenêtre et traitement du quota inconnu. Ne pas confondre Stop de fin de tour et fin de session ; une reprise doit encore annuler le candidat.

Conserver le moteur de paiement choisi et la destination indépendants du fournisseur affiché dans l’îlot. La source de session, le fournisseur qui paie et l’endroit où le skill est installé sont trois informations distinctes. Ne jamais basculer l’authentification vers une clé API.

Le failover des analyses est une décision de périmètre à rendre avec le reste du plan : proposition recommandée, conserver le payeur choisi et retirer la bascule automatique, qui ne fait pas partie du besoin exprimé. Une ancienne préférence de failover ne doit pas sélectionner silencieusement un autre abonnement après migration. Le quota inconnu garde la politique bornée existante tant qu’elle n’est pas explicitement changée.

Réutiliser RetrospectiveRunner, parseurs/digest, LearningGate, AnalysisBudget, gestion des processus et store. Les noms de types existants peuvent rester pendant le découplage ; renommer toute la chaîne n’est pas un objectif.

Modifier prompt, schéma et validation ensemble : procédures exécutées et vérifiées, étapes concrètes, pas de résumé de session ni de note de préférence. Ne pas forcer davantage de skills ni allonger leurs corps pour compenser le retrait des notes. Conserver catalogue, anti-doublon déterministe et historique des skills proposés/rejetés/approuvés/installés. Ne plus injecter l’historique des notes dans les nouveaux prompts. Préserver les marqueurs de résultat inconnu et de commande incomplète du digest, les contrôles de contenu suspect, et le refus tracé d’un corps trop long sans troncature.

Le chemin nouveau ne produit ni n’indexe de notes. Un champ notes inattendu doit être rejeté ou neutralisé explicitement par le parseur, sans perdre les skills valides ; le prompt seul ne garantit rien. Retirer le noteSink du chemin normal.

Conserver toutes les protections d’installation : quarantaine, provenance, catalogue valide, comparaison avec l’existant, confirmation en cas d’édition manuelle, archive du dossier complet, ressources préservées, staging et manifeste. Aucune activation automatique d’une proposition n’est ajoutée.

## 7. Migration : points qui ne doivent pas être simplifiés à tort

### 7.1 Une migration sélective, sans désinstallation générale

Les commandes uninstall et uninstall-codex appellent actuellement uninstallAll des skills appris. **Elles ne doivent jamais servir au recentrage.** Ne pas réutiliser non plus un constructeur ou lecteur de store qui migre/écrit implicitement les manifestes pour faire l’inventaire initial : cet inventaire doit rester une lecture brute contrôlée.

Écrire un petit migrateur versionné, idempotent et reprenable, avant les anciennes réconciliations de démarrage. Il remplace leurs points d’entrée ; le vieux démarrage ne doit plus réinstaller recall ni réarmer Rockstar/sons/curation.

Ordre proposé :

1. Suspendre les anciens producteurs ; journaliser l’état avant migration avec chemins, empreintes, version et étapes. Sauvegarder uniquement les configurations et artefacts concernés ; aucune copie d’authentification ni de tout le home Codex.
2. Désactiver durablement le fallback sonore Atoll et journaliser cette étape **avant** de restituer les hooks sonores adoptés, pour éviter un double son après interruption. Restaurer les permissions deny parquées et les hooks sonores avec les routines corrigées, en préservant les ajouts ultérieurs, groupes mixtes et métadonnées. Écrire les sauvegardes avant toute modification. Aucun réglage sonore Cursor n’est modifié automatiquement.
3. Désactiver les marqueurs persistants de recall ; migrer les entrées Atoll vers l’observation seule, en conservant le tee de statusline Claude. Cette bascule ne s’active qu’avec l’ensemble helper/serveur/callbacks/interface prêt et testé au lot 3 ; les préparations du lot 1 ne l’exécutent pas partiellement.
4. Retirer du catalogue actif uniquement l’infrastructure atoll-recall reconnue. Sauvegarder et traiter séparément les versions personnalisées ou munies de ressources ; aucune suppression par simple préfixe atoll-.
5. Neutraliser les anciennes préférences productrices, conserver tous les skills utiles et leurs manifestes, préparer la reprise des résultats payés.
6. Vérifier chaque étape sur le disque puis enregistrer son achèvement. En cas d’échec, garder les originaux et la preuve de reprise, afficher une erreur précise et permettre une nouvelle tentative.

Ne jamais restaurer intégralement le vieux backup pré-Atoll à la place de la configuration actuelle. Respecter symlinks, JSON vide/invalide/illisible et écritures concurrentes : relire avant écriture et abandonner si l’état a changé. Le contrôle existant est best effort ; ne pas le présenter comme un verrou atomique universel. **config.toml n’est jamais écrit**, les hooks étrangers sont préservés et aucune confiance native Codex n’est accordée automatiquement. Les tests comparent les fichiers protégés avant/après sans exposer leur contenu ; une modification concurrente étrangère est signalée, pas annulée.

Une migration incomplète ne doit jamais réactiver les fonctions retirées ou écraser un fichier inconnu. Les services conservés dont les prérequis sont sûrs peuvent fonctionner ; la création de skills reste suspendue si l’intégrité de ses propres données n’est pas établie.

### 7.2 Permissions : observation sans décision

Garder PermissionRequest comme événement de suivi : il permet notamment à Codex d’annoncer qu’une session attend une action. Enlever cartes, allow/deny, auto-approbation, attentes de réponse socket et message « Waiting for approval in Atoll ». L’utilisateur décide exclusivement dans son CLI.

Migrer ensemble déclaration de hook, wrapper/helper, serveur, callbacks et projection UI dans un même lot indivisible. Un ancien hook déjà chargé par une session doit être accepté en compatibilité, produire stdout vide/exit 0 et ne jamais attendre une décision invisible. La fermeture passive du socket ne signifie pas que l’autorisation native est résolue : conserver l’état d’attente jusqu’à un événement CLI probant. Ne pas réutiliser markAutoApproved pour rendre la main sans décision.

**Ne pas rendre tous les hooks async.** Stop Codex a historiquement perdu ses événements sous cette forme. Garder les événements de fin synchrones courts lorsqu’ils l’exigent ; qualifier la forme passive de PermissionRequest dans les fixtures puis une recette native isolée. Pas de longue attente pour les permissions.

### 7.3 Journaux, checkpoints et données legacy

Conserver un lecteur des anciennes valeurs retrospective/curation/pluginSearch dans le journal analysis-jobs-v2.json. Les supprimer de l’enum Codable sans migration rendrait l’historique illisible et bloquerait le budget des skills. Les dépenses de la fenêtre courante restent comptées ; ne pas remettre le compteur à zéro.

Les livraisons sauvegardées anciennes contiennent notes et skills. Leur critère isComplete attend aujourd’hui les deux. Prévoir une adaptation explicite et testée : original conservé, skills déjà livrés reconnus, skills restants reprenables après ON, notes conservées comme héritage **sans nouvelle écriture**, état « hors nouveau périmètre » distinct d’un succès d’écriture. Sinon une livraison resterait incomplète indéfiniment. Conserver les identités delivery_id/delivery_artifact, marqueurs started/completed et preuves d’archives : les recréer empêcherait de reconnaître un skill déjà approuvé, rejeté ou édité.

Une ancienne opération de rangement peut avoir été interrompue au milieu d’une bascule disque. Conserver la récupération transactionnelle strictement locale nécessaire pour retrouver un état cohérent, sans nouveau modèle et sans reprendre le calendrier de curation. Ne pas supprimer staging/checkpoints par ancienneté.

Préserver les manifestes v1/v2 et leurs portées Claude/Codex/home réel. Un home inaccessible n’est pas une collection de skills vide. Un manifeste illisible ou divergent est un problème à signaler, pas à réinitialiser.

### 7.4 Retour à une ancienne version

Conserver les sauvegardes et documenter le retour arrière par composant. Une vieille app ne connaît pas le nouveau marqueur de migration et peut réinstaller ses hooks ou ses préférences productrices : le plan ne prétend pas empêcher cela.

Tester ancien → nouveau → ancien → nouveau dans un home privé, sans deux apps normales en parallèle. En cas de retour demandé sur le poste réel, restaurer sélectivement les entrées appartenant à Atoll après vérification des changements intervenus ; jamais recopier aveuglément toute une ancienne configuration.

## 8. Îlot, quotas et réglages simplifiés

Conserver la géométrie, la typographie, les animations, les regroupements et la limite de lignes actuels. Le panneau montre sélection du fournisseur, sessions, propositions de skills et quotas. Un détail de session reste informatif ; les commandes supprimées disparaissent réellement.

Présentation des réglages proposée :

- **Général** : apparence/îlot/écrans/lancement, mises à jour et À propos dans une zone dédiée ;
- **Connexions** : Claude Code et Codex, chemins et état des hooks/quotas, diagnostics indispensables repliés ;
- **Skills** : interrupteur principal, modèle/payeur/destination, budget avancé, propositions et gestion existantes.

Il s’agit d’une proposition de regroupement, à vérifier par maquettes puis captures de la vraie UI. Conserver la fenêtre de revue spécialisée, avec provenance et comparaison. Le journal technique utile à la création reste replié ; on ne crée pas un tableau de bord supplémentaire.

Les erreurs de restitution deny/sons et de migration restent accessibles sous **Connexions → Diagnostics**, avec un réessai ciblé. Retirer les anciens onglets Autonomie/Alertes ne retire pas la possibilité de récupérer une migration échouée.

**Quota au repos :** le contrat actuel masque son contenu quand il n’y a ni session ni Rockstar. La solution minimale conserve ce comportement et n’ajoute pas de nouvelle option pendant le découplage. Si Mehdi veut le quota visible en permanence, le traiter comme un choix produit explicite dans la maquette, avec contrôle de largeur et d’absence d’animation inutile ; aucune décision silencieuse.

Quotas : garder le lecteur Codex à 120 s, ses contrôles de fraîcheur et son profil sans synchronisation plugins ; garder la statusline/tee/cache Claude et le lecteur optionnel par modèle. Ne pas harmoniser ces deux transports dans ce chantier. Préserver le label jours/heures/minutes corrigé en 0.18.7, tous les resets et l’état inconnu. Ne pas transformer une absence de mesure en 0 %.

## 9. Découpage de développement et conditions de passage

L’intégration part du main alors courant dans une branche isolée hors iCloud. Les lots dépendants sont exécutés **séquentiellement sur les précédents**, ou présentés comme PR empilées ; ils ne sont pas développés comme des branches indépendantes ignorant leurs prérequis. Les fichiers ci-dessous sont des zones de travail, pas une liste de suppressions aveugles. Une recherche des consommateurs précède tout retrait.

| Lot | Travail et fichiers principaux | Condition de passage |
|---|---|---|
| 0 — Référence | Inventaire brut des réglages/artefacts, fixture d’upgrade 0.18.7, captures de référence, baseline pertinente | Source et données cibles identifiées ; aucune dépense ni écriture personnelle |
| 1 — Compatibilité préparée | Migrateur et lecteurs legacy testés en homes privés, journal/parkings/anciens états ; préparer les points d’entrée AppDelegate et installateurs | Aucune activation partielle de migration en production ; skills/tiers intacts dans les fixtures |
| 2 — Switch et skills seuls | LearningSettings/Pane, RetrospectiveRunner/Prompt/Report/Delivery, AnalysisExecution, SkillReviewCenter | OFF exercé à toutes les phases ; génération/reprise/installation fiables sans notes/index/curation |
| 3 — Bascule indivisible | Réunir et activer migration, déclarations de hooks, wrappers, Bridge/main, CodexBridge, BridgeServer, callbacks et UI permissions ; désarmer les anciennes réconciliations | Autorisations exclusivement natives ; helpers bornés ; états et fin de session exacts ; reprise migration sans réinstallation legacy |
| 4 — Interface | ExpandedView, SessionDetailView, SettingsView et volets, onboarding, menu, aperçus | Périmètre demandé complet et captures validées ; aucune commande retirée encore accessible |
| 5 — Suppression ciblée | Mémoire/recall, curation, plugins de gestion, sons, autonomie, passation, jump-back ; entitlements, scripts et docs | Plus aucun consommateur produit inutile ; lecteurs/migrateurs legacy conservés ; tests toujours causaux |
| 6 — Intégration/livraison | Suite offline finale, builds, aperçus, petite recette native, revue et préparation de release | Résultat reviewable ; publication et installation seulement sur instruction de Mehdi |

Lots 1 et 2 sont les plus délicats pour les données. Le lot 3 porte le risque de blocage des CLI. Le lot 4 ne doit pas commencer par une refonte graphique. Le lot 5 ne retire pas les bibliothèques partagées encore nécessaires : parsers, ShellSplitter, résolution d’exécutables, catalogue de capacités, budget et installation protégée.

Préparer des PR cohérentes avec leurs preuves. Pas de publication automatique à chaque lot, ni de nombre de jours garanti sans avoir qualifié les migrations. Garder les garanties du produit à chaque état intégrable.

## 10. Validation à exécuter après accord

| Domaine | Scénarios indispensables | Preuve attendue |
|---|---|---|
| Switch OFF | Avant événement, délai, digest, catalogue, préparation CLI, modèle, retour réponse, redémarrage | Aucun lancement tardif, aucune nouvelle livraison automatique, données déjà produites préservées |
| Retour ON | Sessions OFF, résultats payés sans quota/modèle disponible, proposition déjà approuvée/rejetée | Pas de rattrapage massif, reprise locale prioritaire sans modèle, pas de double analyse ni double proposition |
| Générateur | Procédure utile, banal, doublon existant, erreur de schéma, digest tronqué | Qualité préservée, zéro skill accepté pour le banal/doublon, commandes non vérifiées jamais présentées comme prouvées |
| Disque | Ressources, édition manuelle, collision étrangère, archive ratée, manifeste invalide/inaccessible | Dossiers et manifestes conservés ; aucun effacement sur doute |
| Legacy | Journaux avec curation/pluginSearch ; résultats notes-only, skills-only, mixtes, partiels | Budgets lisibles et conservés ; reprise locale sans modèle ; aucune boucle de checkpoint incomplet |
| Upgrade | Parkings valides/corrompus, groupes mixtes, symlink, JSON vide, écritures concurrentes, crash entre étapes | config.toml inchangé par Atoll, confiance native préservée, hooks tiers intacts, migration idempotente et réessayable |
| Permissions | Demande/choix native, vieux hook encore chargé, app absente/déplacée, helper tué | Jamais de réponse allow/deny Atoll ni attente invisible ; sortie fail-open |
| Sessions | Deux CLI, projets/sous-agents, Stop, interruption, reprise, mort PID, redémarrage | Suivi fidèle et génération déclenchée une seule fois au bon moment |
| Quotas | Sans session Codex, erreur/auth, reset, date future, cache ancien, changement home/exécutable | Fraîcheur et inconnues correctes, pas de mélange de comptes ou polls concurrents ; Claude toujours alimenté par le tee |
| UI | Notch/sans notch, trois tailles, clair/sombre, onde/Reduce Motion, grande liste, propositions, OFF/erreurs | Captures de copie protégée regardées ; aucun scroll/champ disparu sous layerEffect ni quota hors cadre |
| Fonctions retirées | Redémarrages répétés et hooks legacy | Aucun appel curation/pluginSearch, indexation, recall injecté, afplay Atoll ni auto-approbation |
| Coût technique | Référence vs final, mêmes conditions repos/CLI actifs | Comparer processus enfants, appels réseau, écritures et délais ; aucun gain RAM/batterie annoncé sans mesure |

Réutiliser les harnesses du dépôt : validate-offline, learning-retrospective, analysis-processes, skill-review, installation/hooks, quota-poller, génération en prepare-only, tests Core de livraison/digest/manifestes/archives. Ajouter les cas de migration et OFF aux services réels injectés. Les tests des fonctions retirées deviennent des tests de migration ou sont retirés avec justification ; ne pas les laisser tester uniquement un stub.

Chaque correctif significatif garde un sabotage causal compilé qui fait échouer l’oracle attendu. La CI standard doit être mise à jour avec la nouvelle liste de harnesses, sans masquer un échec ancien ni supprimer les scénarios de récupération encore nécessaires.

En fin d’intégration : exécuter le profil standard actualisé une fois, les sabotages ciblés, les builds Debug/Release et les recettes UI. Ne pas relancer des suites complètes à chaque petit changement sans raison. Une courte recette générative authentifiée sera utile si prompt/schéma changent : la limiter aux cas utiles/banal/doublon, journaliser la consommation et préserver ses preuves. Aucune campagne répétitive de dix appels.

La recette Claude authentifiée nécessite un abonnement disponible : ne pas déclarer ce chemin qualifié sur la seule base de fixtures, ni remplacer l’abonnement absent par une facturation API. Les lectures quota natives et les contrôles des effets de stockage restent séparés de la génération.

## 11. Résultat attendu pour considérer le travail terminé

1. L’îlot conserve les sessions Claude et Codex et des quotas honnêtes, sans permettre de piloter les CLI.
2. Les propositions de skills gardent leur qualité, leur revue et leur installation protégée.
3. Le switch OFF a un effet réel et persistant, sans détruire ni désactiver les skills installés.
4. Aucune autre fonction ne continue discrètement à générer, indexer, injecter ou jouer des sons.
5. Tous les skills, ressources et données personnelles préexistants sont préservés ; les modifications de configuration sont sélectives, sauvegardées et récupérables.
6. Les preuves couvrent séparément logique, processus, migration, rendu, CLI authentifié et distribution. La documentation décrit le nouveau périmètre.

## 12. Références de code de l’analyse

Toutes les références suivantes concernent le commit 751dd680, pas les fichiers anciens du dossier du Bureau.

- Switch et préférences : App/LearningSettings.swift, lignes 16–46 et 48–153 ; App/LearningSettingsPane.swift, lignes 21–26 et 142–150.
- Annulation, processus et gardes après attente : App/RetrospectiveRunner.swift, lignes 131–211, 592, 645, 701 et 761.
- Fin de session, seuils, catalogue, notes et livraison : App/RetrospectiveRunner.swift, lignes 116–128, 338–447, 637–662, 782–825 et 879–944 ; LearningGate.swift, lignes 191–218.
- Compatibilité des anciens résultats : AtollCore/Sources/AtollCore/RetrospectiveDelivery.swift, ligne 38 et lignes 93–194.
- Journal/budget : App/AnalysisExecution.swift, lignes 6, 55–70 et 131–176.
- Préservation des skills : AtollCore/Sources/AtollCore/LearnedSkillStore.swift, lignes 122–139, 184–313, 340–368 et 630–648.
- Désinstallateurs impropres à une migration : Bridge/main.swift, lignes 513–524 ; Bridge/CodexBridge.swift, lignes 117–119.
- Permissions et livraison de Stop : Bridge/CodexBridge.swift, lignes 62–83 ; BridgeServer.swift, lignes 280–335 ; HookSettingsEditor.swift, ligne 54 ; CodexIntegration.swift, lignes 557–625.
- Démarrage legacy : App/AppDelegate.swift, lignes 41–52, 121–133 et 194–225.
- Quotas/sessions : App/CodexService.swift, lignes 37–67 et 299–349 ; App/SessionStore.swift, lignes 491–511 ; CodexReadClient.swift, lignes 11–16 et 53–54 ; CodexQuota.swift, lignes 14–35.
- Îlot et identité CLI : App/NotchViewModel.swift, lignes 97–160 ; App/ExpandedView.swift, lignes 44–94 et 252–264 ; Shared/ProcessInspector.swift, lignes 197–203.
- Contrats de recette : docs/VALIDATION.md ; Scripts/validate-offline.py ; .github/workflows/validation.yml.

## 13. Accord demandé

Valider la solution B, son périmètre et son développement par lots. Les choix activité/liste de sessions et Codex + Claude sont déjà confirmés.

Deux précisions de produit accompagnent cette proposition : retrait recommandé du failover automatique des analyses ; maintien du comportement actuel au repos, sauf si Mehdi préfère un quota toujours visible. Ces points sont à trancher avant de coder leur partie.

L’accord sur ce plan autorisera son implémentation dans une branche isolée ; il ne vaut pas publication ni remplacement de l’app stable. Le document présent reste un livrable d’analyse.
