# Exécuteur des analyses et passation entre CLI

État du code au **2026-09-10**, développé sur v0.17.2, **non publié**.
Le [rapport de correction](REVIEW-2026-09-10-pr2-corrections.md) distingue
tests exécutés et parcours encore à vérifier.

## Trois choix indépendants

| Choix | Où | Effet |
|---|---|---|
| Fournisseur affiché | Boutons Claude Code / Codex | Liste, quota, palette |
| Exécuteur des analyses | Réglages → Apprentissage ; modèle dans Réglages → Codex | Abonnement et modèle des dépenses Atoll |
| Destination des skills | Réglages → Apprentissage → Abonnement des analyses Atoll | Catalogue, proposition et installation Claude ou Codex |

Changer de vue ne change jamais l'exécuteur. L'origine d'un transcript reste
sa provenance, quel que soit l'agent qui l'analyse.

## Les trois consommateurs

Le bilan de fin de session, le rangement des notes et la recherche IA facultative
de plugins utilisent le même choix d'exécuteur et le même budget interne.
La recherche locale de plugins ne consomme rien ; le catalogue ciblé demeure
Claude même quand son classement IA est effectué par Codex.

Un poste Codex seul peut choisir Codex sans binaire ni quota Claude.
L'onboarding propose d'ouvrir les réglages du moteur ; installer un CLI ne
modifie jamais le moteur existant, même si sa clé n'avait pas encore été écrite.
L'apprentissage reste un choix distinct. Le modèle Codex doit être choisi dans le catalogue
natif et est revalidé avant chaque lancement.

Le failover vers l'autre abonnement est **désactivé par défaut**. Son activation
ne suffit pas : il faut une mesure fraîche et applicable prouvant l'épuisement
du moteur choisi et une mesure fraîche et disponible pour l'autre. Il peut aller
dans les deux sens. Un quota inconnu ou ambigu ne provoque jamais une bascule.
La fraîcheur maximale utilisée par défaut est 600 s pour Claude, 300 s pour
Codex, en accord avec le budget des analyses.

La tolérance historique « quota inconnu : une tentative interne par 5 h » est
affichée et désactivable. Elle porte seulement sur le moteur choisi. Le plafond
configurable connu est également une limite interne de cinq heures **par
abonnement**, partagée entre les trois consommateurs ; ce n'est pas une durée
contractuelle déduite pour Codex. Une seule analyse Atoll est préparée ou lancée
à la fois. Aucune moyenne ni maximum arbitraire ne mélange des catégories
indépendantes de quota. Sans correspondance fiable au modèle, la portée demeure
inconnue. Dans l'unique catégorie Codex applicable, une fenêtre haute dont le
reset reste futur conserve sa valeur comme minorant, même si la mesure vieillit
ou qu'une autre fenêtre a été réinitialisée. Ce minorant peut refuser le job,
jamais prouver de la disponibilité ni déclencher un failover.

## Préparation, annulation et comptabilité

Le job en file lit les préférences à son évaluation. Avant le premier await de
préparation, il fige origine, destination, exécuteur, modèle, home, configuration
de résolution et quota. Le binaire absolu est résolu dans cette génération.
Un changement de réglage ultérieur ne reroute pas le job. Une nouvelle
validation du quota peut le reporter, jamais changer silencieusement de moteur.

OFF, annulation ou reprise de session invalident le job pendant la résolution,
la préparation, l'exécution et jusqu'aux écritures finales. Une réponse tardive
ne produit ni note, ni proposition, ni remplacement des notes actives.
La désactivation du rangement automatique annule son cycle en cours ; un
rangement explicitement demandé reste distinct.

Le journal local `analysis-jobs-v2.json` distingue réservation, lancement et
résultat. Il contient moteur, modèle, type d'analyse, origine, destination et
snapshot du quota avec fraction, fraîcheur, reset, catégorie et raison lorsque
disponibles ; pas le contenu des prompts ni les secrets de connexion.
Un lancement impossible rend son créneau ; un processus lancé puis en échec
compte comme tentative. Au redémarrage, une simple préparation est libérée.
L’intention de spawn, persistée immédiatement avant `process.run()`, ou un
lancement confirmé sont comptés : le crash a pu survenir après une dépense.
Les refus de capture sont aussi journalisés dans `retrospectives.json` avec
leur cause ; les évaluations admises y conservent modèle et raison du quota inconnu.

Un échec de préparation ou de spawn du rangement applique un backoff de
30 minutes et persiste sa cause, y compris un refus de configuration ou de
budget. Moins de deux notes ou un corpus trop volumineux clôturent l'évaluation
pour la cadence normale ; ces refus ne bouclent plus toutes les 30 minutes.
Le bouton manuel reste possible.
Le minuteur des bilans recontrôle la tête de file après les awaits ; une autre
session terminée pendant la préparation ne reprend pas un délai périmé.

## Lancement contrôlé

Les exécutables sont résolus par chemin absolu, y compris depuis l'environnement
réduit d'une app macOS. Le shell de login est conservé pour l'authentification
par abonnement, avec stdin fermé. Le home Codex choisi est réimposé **après**
le profil de login. Les clés API héritées ne doivent pas remplacer l'abonnement
choisi par Atoll.

Les jobs travaillent dans un dossier temporaire contrôlé. Leur contexte est
fourni explicitement ; le projet analysé n'est pas leur cwd. Le marqueur
`ATOLL_RETROSPECTIVE=1` neutralise l'observation interne. Les sorties et rapports
sont bornés ; l'escalade des signaux recontrôle le PID et son instant de
démarrage. Pour Codex, le mot « error » dans une sortie ne devient pas un
verdict d'échec : l'issue reste inconnue. Le parseur Claude historique conserve
encore une heuristique textuelle lorsque `isError` manque ; voir le rapport.

Le schéma produit pour OpenAI est adapté au contrat strict : propriétés requises,
objets fermés et retrait des bornes non acceptées. La validation Swift reste
obligatoire après décodage. Le test réel du 10 septembre a exercé le runner App
avec un modèle présent dans le catalogue natif et obtenu un rapport valide.
Il a vérifié le home après un profil contradictoire, le retrait de la clé API,
stdin EOF et l'absence de rollout persistant. **Cela ne prouve pas l'absence
de toutes les instructions ou skills globaux du CLI.** Le dossier du projet est
isolé ; une isolation totale par `--ignore-user-config` n'est pas promise.

Le stockage et la recherche de mémoire sont locaux. Les extraits explicitement
fournis à une analyse ou rappelés dans une conversation sont traités par le
fournisseur de cette conversation ou de cette analyse.

## Continuer une session dans l'autre CLI

Les détails de session proposent **CONTINUER DANS CODEX** ou **CONTINUER DANS
CLAUDE** selon leur origine, indépendamment du réglage de failover, seulement
si le dossier et l’exécutable de destination existent. Les chemins sont
revalidés au clic, notamment après une désinstallation du CLI.

Atoll prépare un condensé dans un dossier unique de passation, avec fichiers
privés, puis ouvre un script de terminal. Ce script utilise un exécutable résolu,
fait `cd` dans le dossier source et demande de lire le chemin **absolu** du
contexte. Le home est explicite pour une destination Codex. Un chemin manquant,
un binaire absent ou un échec d'ouverture donnent une erreur visible.

« Terminal ouvert » décrit le résultat de l'ouverture par macOS. Cela ne prouve
ni que le CLI est authentifié, ni qu'il a lu le contexte, ni qu'il a repris le
travail. Atoll ne migre pas le thread existant et ne transmet pas une réponse
de permission d'un agent à l'autre.

## Preuves et limites

- Les vrais runners App et le centre de permissions sont compilés avec
  collaborateurs contrôlés par `Scripts/test-runtime.py` : trois consommateurs,
  deux moteurs, cas nominaux, quota, annulations et résultats tardifs.
- `--sabotage-cancellation` retire une garde sur des copies temporaires et
  vérifie que la suite détecte l'écriture après annulation.
- `--sabotage-quota-projection` réintroduit l'effacement des mesures Codex
  anciennes et vérifie le refus attendu par le test de capture du budget.
- `Scripts/test-codex-exec.py --live` vérifie le nouveau chemin réel Codex.
  Il consomme une génération ; il n'est pas lancé par la suite ordinaire.
- Les scripts de passation dans les deux sens ont été exécutés avec de faux
  CLI : chemin avec espaces/apostrophe, cwd, home et contexte absolu corrects.
- Les captures, la navigation native entre cartes, le brouillon et ⌘N ont été
  vérifiés en aperçu isolé. L'ouverture de Terminal.app avec un CLI authentifié,
  VoiceOver et la recette des deux TUI réelles restent à valider avant diffusion.
  Le [rapport de correction](REVIEW-2026-09-10-pr2-corrections.md) précise les preuves.

Le protocole d'installation, les capacités natives et la recette visuelle sont
dans [CODEX-INTEGRATION.md](CODEX-INTEGRATION.md).
