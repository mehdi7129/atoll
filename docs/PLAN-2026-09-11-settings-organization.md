# Réglages Atoll — audit des huit onglets et proposition d'organisation

11 septembre 2026 · **proposition validée, PR #4 fusionnée et v0.18.2/build 37 publiée**.
État de livraison courant dans [HANDOFF](HANDOFF.md).

## Périmètre et méthode

Parcours des huit onglets de l'app installée **0.18.1 / 36**, puis lecture des
vues et de leurs liaisons dans le travail local `codex/settings-ux`. Au moment de
l'audit, ce dernier contenait une première simplification encore non publiée.
L'audit distingue donc ce que montrait l'app et ce que corrigeait déjà la branche.
Les contrôles de l'app n'ont pas été modifiés ; la navigation est revenue à
l'onglet Alertes initial. Aucune analyse, importation, installation ou mise à
jour n'a été déclenchée pour ce parcours.

Sources principales : `App/SettingsView.swift`, `App/SoundSettingsView.swift`,
`App/CodexSettingsPane.swift`, `App/CodexCatalogSection.swift`,
`App/AnalysisSettingsSection.swift`, `App/CodexAnalysisModelPicker.swift`,
`App/LearningSettings.swift`, `App/SoundCenter.swift`, `App/AtollApp.swift` et
leurs types `AtollCore`. Les inventaires personnels lus dans l'app ne sont pas
recopiés dans la maquette : elle utilise des exemples.

## Constats et décisions proposées

| Constat vérifié | Conséquence | Proposition |
|---|---|---|
| L'indexation située dans Claude Code porte aussi les conversations Codex | Un réglage commun semble propre à un seul CLI | Déplacer indexation, état et reconstruction dans Apprentissage → Mémoire commune |
| Le rappel automatique est séparé de la mémoire qui le conditionne | Il faut chercher dans plusieurs sections | Le rapprocher de Mémoire commune, en le nommant explicitement « Rappel automatique · Claude Code » |
| Le choix du modèle Codex est caché dans la release ; le patch local l'affiche dans deux onglets | La première correction améliore l'accès mais conserve deux lieux d'édition | Une seule édition dans Apprentissage ; un état et un raccourci direct depuis Codex. Si le modèle manque, le raccourci « Choisir le modèle… » reste visible |
| Destination des skills et moteur sont deux choix indépendants | Le voisinage actuel suggère une liaison qui n'existe pas | Placer la destination près des skills proposés, dans Apprentissage |
| « Tes sons Claude Code » désigne une migration d'anciens hooks Claude | Cela semble exclure Codex des alertes | Sons communs clairement annoncés ; historique renommé « Anciens sons de Claude Code », en fin d'onglet |
| Sans hooks Claude, le panneau de migration dit qu'Atoll ne peut jouer aucun son | Faux pour une installation Codex fonctionnelle | Ne montrer ce prérequis que pour la reprise de sons Claude, jamais pour les alertes Codex |
| Le son « Décision attendue » cite permissions, questions et plans sans distinguer les CLI | Il promet trop à Codex | « Autorisations des deux CLI ; questions et plans pour Claude Code » |
| Autonomie ne nomme pas son périmètre dans sa section principale | Rockstar peut sembler concerner Codex | « Autonomie de Claude Code » + état explicite « Codex : réglé dans son terminal » |
| « Manuel : vous approuvez chaque demande » est trop absolu | Les autorisations déjà données au CLI continuent de s'appliquer | « Atoll n'approuve aucune demande automatiquement » |
| Les inventaires et le journal occupent une grande partie d'Apprentissage | Les réglages utiles et les blocages se perdent | Inventaires détaillés repliés ; propositions à revoir, erreurs et rangement bloqué restent visibles |
| Mises à jour ne contient pas de bouton de vérification manuelle | Le geste attendu nécessite de sortir des réglages | Réutiliser le bouton Sparkle du menu dans cet onglet |
| « Désactivé, Atoll ne contacte jamais le réseau » | Promesse fausse : quota et analyses ont leurs propres réglages | Décrire uniquement la vérification automatique des mises à jour |
| À propos explique des réglages présents ailleurs | Une fiche d'identité sert de mode d'emploi | Garder identité, version/build et licence ; replacer les explications près des réglages |

**Conserver les huit onglets et leur ordre.** Les palettes restent dans Général ;
les plugins restent dans leur onglet CLI, car leurs capacités sont différentes.
Autonomie reste accessible directement. La reprise des anciens sons reste dans
Alertes : c'est là que l'utilisateur cherche à résoudre un doublon sonore.
Pas de nouvel onglet, de recherche globale ni de panneau de diagnostic permanent.

## Inventaire exhaustif des contrôles et destination

Les plages et options ci-dessous décrivent l'existant. Les valeurs enregistrées
doivent être conservées, y compris lorsqu'un contrôle est déplacé ou replié.
Les valeurs de démonstration de la maquette ne sont pas des nouveaux défauts.

### 1. Général

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Largeur par écran | « Taille de l'îlot » : Petit / Moyen / Large pour chaque écran ; défaut Moyen ; seul le compact est concerné |
| Nom / écran principal / présence d'encoche | Garder les noms réels et une aide brève, pas un second réglage |
| Thème | Apparence : Auto (système) / Clair / Sombre |
| Palette Claude | Apparence : « Couleur de Claude Code » ; conserver toutes les palettes existantes |
| Palette Codex | Apparence : « Couleur de Codex » ; mêmes choix, préférence indépendante |
| Effets visuels | Interrupteur conservé ; explique verre et onde en une phrase |
| Intensité Liquid Glass | Sous « Ajuster les effets » : 0–100 %, pas de 5 %, macOS 26 uniquement ; grisé si effets désactivés |
| Réduire les animations | Information sur le réglage macOS ; aucun interrupteur Atoll supplémentaire ; ne promet pas l'arrêt de tous les fondus |
| Délai d'ouverture au survol | Comportement : 0–500 ms, pas de 50 ms ; valeur lisible à côté du curseur |
| Lancer au démarrage | Comportement : conserver le réglage macOS et le retour d'état en cas de refus |

Ordre proposé : Apparence → Taille par écran → Comportement. Les couleurs
continuent de distinguer les CLI dans l'îlot ; la barre compacte n'est pas modifiée.

### 2. Claude Code

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Hooks installés | « Intégration Atoll » : Installée / À installer ; éviter le jargon en titre |
| Réception / compteur | Diagnostic replié. `SessionStore.eventCount` est un compteur global : ne pas l'annoncer comme une preuve d'événements Claude uniquement |
| Installer les hooks | « Installer l'intégration Claude Code », visible si absente |
| Désinstaller les hooks | Dépannage ; conserver la confirmation et les conséquences sur skills appris, archives et restitution des anciens sons |
| Erreurs hooks / règles suspendues | Toujours visibles, même si Dépannage est fermé |
| Jauges par modèle | Quota : « Afficher le détail par modèle » ; retirer l'exemple Fable du libellé ; accès au trousseau expliqué à proximité |
| Indexer les sessions passées | Déplacé vers Apprentissage → Mémoire commune ; même clé et même action |
| État / volume de l'index | Même déplacement ; une seule présentation principale des statistiques |
| Reconstruire l'index | Apprentissage → Mémoire commune → Entretien ; confirmation de perte des messages dont le transcript source a disparu conservée |
| Plugins : inventaire, date, actifs, désactivés | « Plugins Claude Code » replié ; synthèse, date de lecture et liste après demande |
| Plugins cassés / doublons | Résumé d'erreur visible avant ouverture de la liste |
| Actualiser l'inventaire | Bouton dans le volet Plugins ; appel CLI existant |
| Coût en tokens | « Estimer le contexte des plugins » ; estimation et disponibilité affichées, aucune promesse de mesure exacte |
| Désactiver un plugin | À côté du plugin ; conservation de l'installation et indication du moyen de réactivation |
| Besoin / Chercher | Dans Plugins → Trouver un plugin ; champ et recherche locale existants |
| Affiner avec l'IA | Action secondaire explicite ; abonnement/moteur choisi dans Apprentissage ; conserver l'annulation |
| Résultats / Installer | Identifiant validé dans le catalogue et confirmation d'exécution de code tiers conservés |
| Rappel automatique / nombre 1–5 / projet courant | Déplacés ensemble vers Apprentissage → Mémoire commune, avec mention Claude Code ; aucune activation Codex ajoutée |
| Accès au moteur d'analyse | Raccourci vers Apprentissage ; ce n'est pas un deuxième choix de moteur |

La désinstallation n'est plus l'action la plus saillante d'une connexion saine.
L'installation et les erreurs restent immédiatement accessibles.

### 3. Codex

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| État de l'intégration | Garder la priorité erreur → absente → événement reçu → attente ; « Événement reçu » ne prouve pas la confiance de tous les hooks |
| Installer l'intégration | Visible si absente ; installation existante uniquement |
| Instructions / Copier `/hooks` | Visibles tant qu'aucun événement n'est reçu ; message et reprise `codex resume` seulement lorsqu'utiles |
| Projet / choisir le dossier | « Vérifier la connexion » replié. Dossier de travail ; ne filtre pas les sessions suivies |
| Vérifier avec Codex | « Vérifier les hooks » ; diagnostic de confiance, pas un lancement de conversation ni une génération |
| Dernier événement / résultat du diagnostic | Dans la vérification ; erreurs de configuration résumées hors du volet |
| Afficher le quota Codex | Conserver l'interrupteur et l'actualisation de 2 minutes |
| Catégories / fenêtres / remise à zéro | Rendre ce que Codex fournit ; ne pas imposer deux fenêtres 5 h / 7 j |
| Actualiser le quota | Action conservée ; quota absent ou périmé ne devient jamais 0 % |
| Contexte de la conversation | Une aide courte vers le détail de session ; aucun réglage global de contexte inventé |
| Modèle des analyses / actualiser la liste | Déplacés entièrement vers Apprentissage ; choix vide ou ancien conservé ; aucune sélection automatique |
| Moteur et modèle actuels | Petite synthèse + « Choisir le modèle… » si nécessaire, sinon « Régler les analyses… » ; navigation vers le contrôle concerné |
| Catalogue de skills et plugins | Volet replié, lecture explicite et recherche locale ; libellés plus simples |
| Choisir / changer de projet du catalogue | Disponible dans ce volet aussi ; partage la même sélection que le diagnostic |
| Skills activés, origine, chemins | Nom et activation dans la liste ; chemins et origine dans le détail secondaire |
| Plugins disponibles/installés/activés, restrictions | État exact conservé ; gestion dans `/plugins`, sans faux bouton d'installation Atoll |
| Recall manuel / usage non mesuré | Rappel manuel présenté avec Mémoire commune ; disponibilité native vérifiable dans le catalogue ; pas d'injection proactive Codex promise |
| CODEX_HOME et Appliquer | Dépannage ; vide = détection ; sauvegarde, conservation des personnalisations et ancien home inchangées |
| Home effectif / fichier des hooks | Détails techniques dans Dépannage |
| Chemin de l'exécutable et Appliquer | Dépannage ; vide = détection ; ne pas confondre avec le dossier du projet |
| Réparer / retirer l'intégration | Dépannage ; expliquer réparation et conséquences de retrait avant exécution ; ne jamais écrire `config.toml` |

### 4. Autonomie

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Niveau Manuel / Rockstar | « Autonomie de Claude Code » ; garder l'exclusivité et le mode enregistré |
| Description du mode Manuel | « Atoll n'approuve aucune demande automatiquement » ; les règles du CLI continuent de s'appliquer |
| Rockstar | Conséquences visibles avant et après activation : permissions, questions et plans traités automatiquement ; règles deny Claude suspendues |
| Confirmation d'activation | Gardée ; aucune validation précochée ni changement automatique lors d'une navigation |
| Nombre d'auto-approbations | Visible seulement si pertinent ; pas de faux compteur à zéro après une perte d'information |
| Règles suspendues / erreur de restauration | Alerte toujours visible, y compris hors Rockstar ; jamais enfermée dans un volet fermé |
| App fermée / sessions déjà ouvertes / hooks personnels | Explication structurée sous « Ce que change Rockstar » ; le résumé de risque reste apparent |
| Codex | Texte non interactif : « Les autorisations de Codex se règlent dans son terminal. Rockstar ne s'y applique pas. » |

Pas de mode Auto Atoll réintroduit, pas de Rockstar Codex, pas de politique
d'approbation modifiée par cette réorganisation.

### 5. Alertes

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Jouer des sons | « Sons d'Atoll » ; aide visible : « Pour Claude Code et Codex » |
| Décision attendue | Son déclenché pour une autorisation des deux CLI ; questions et plans pour Claude uniquement |
| Tâche terminée | « Tour terminé » ou libellé existant avec aide « Quand le CLI termine sa réponse » ; ne pas annoncer la fermeture du processus |
| Choix du son, pour chaque événement | Silencieux, fichiers importés, sons système ; fichiers manquants signalés et sélection conservée |
| Volume, pour chaque événement | 0–100 %, pas de 5 % ; défaut 10 % inchangé |
| Écouter | À côté du son/volume ; grisé si silencieux ; comportement d'écoute conservé |
| Importer un son | Action secondaire par événement ; aiff/aif, wav, mp3, m4a, caf ; maximum 10 Mo ; erreurs près du contrôle |
| « Tes sons Claude Code » | Renommer « Anciens sons de Claude Code » ; placer après les deux sons communs |
| Anciens hooks détectés / commandes / confier | Synthèse + volet de détail avant adoption ; aucune adoption des hooks Codex inventée |
| Anciens hooks mis de côté / rendre | Statut et bouton « Restaurer les anciens sons Claude » visibles même avec les détails fermés |
| Parking illisible | Erreur visible, conservation des données ; parcours de dépannage sans suppression automatique |
| Hooks Claude absents | Expliquer uniquement que la reprise des anciens sons Claude nécessite l'intégration Claude ; les alertes Codex restent configurables |
| Aucune migration concernée | Ne pas afficher une section vide ni demander une installation Claude à un utilisateur Codex |

Choix recommandé : garder ce dernier bloc dans Alertes plutôt que le déplacer
dans Claude Code. Cela regroupe tout ce qui peut expliquer des sons doublés ou
absents. Son titre et son caractère conditionnel rendent son périmètre clair.
Les sons restent communs : pas de sélecteur Claude/Codex ni de volumes doublés.

### 6. Apprentissage

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Moteur Claude / Codex | Première section « Analyses d'Atoll » ; un seul choix pour bilans, rangement et recherche IA de plugins |
| Modèle Codex / catalogue / actualiser | Directement sous le moteur lorsqu'utilisé ou en repli ; choix explicite, ancien choix conservé, erreurs proches du sélecteur |
| Modèles Claude | Modèle de bilan, de rangement et de recherche ensemble quand Claude est utilisé ; Haiku/Sonnet/Opus/Fable existants, sans classement marketing ni nouveau choix par défaut |
| Plafond d'analyses | « Limites et second abonnement » replié : 1–10 par 5 h et par abonnement ; limite interne distincte du quota fournisseur |
| Quota utilisé maximum | Rejoindre les limites partagées : 50 / 60 / 70 / 80 % ; vérifier chaque consommateur lors de l'implémentation |
| Quota inconnu | Conserver l'option d'une tentative par 5 h ; ne permet pas une bascule sur quota inconnu |
| Second abonnement | Conserver l'opt-in et la condition de quotas connus/applicables ; afficher les modèles du second moteur si activé |
| Apprendre des sessions terminées | Section « Bilans de session » ; arrêt de ces bilans seulement, pas du rangement indépendant ni de la recherche manuelle |
| Indexer / statistiques / reconstruction | Bloc « Mémoire commune » déplacé de Claude ; index local, partagé ; reconstruction dans Entretien avec confirmation conservée |
| Recall à la demande | Aide unique Claude/Codex ; recherche locale, extraits ensuite traités par le fournisseur de la conversation |
| Rappel automatique Claude | Volet dans Mémoire commune ; interrupteur, 1–5 extraits, projet courant ; couper l'indexation le coupe aussi |
| Rangement hebdomadaire | « Notes et rangement » ; interrupteur indépendant des bilans |
| Ranger maintenant / état en cours | Action manuelle existante, indisponible si moins de deux notes ou opération en cours |
| Dernier passage / contradictions / corpus trop gros | Résumé toujours visible ; détails repliables ; la maquette ne prétend pas résoudre une limite de traitement |
| Notes récentes / projets / volume / Finder | Sous « Voir les notes » ; cinq notes récentes et volume conservés ; accès Finder nommé simplement |
| Destination des skills | Près des propositions : CLI de la session source / Claude Code / Codex CLI ; indépendance du moteur explicitée en une phrase |
| Skills proposés / Revoir | Nombre et action visibles quand une revue attend ; pas de mise en quarantaine enfouie |
| Skills appris / usage / modifiés / Archiver | Liste repliée avec nombre ; destination visible, usage Codex non mesuré, erreurs d'archive et de manifeste toujours visibles |
| Journal des analyses | En dernier, replié ; raisons d'abstention conservées ; erreur nécessitant un choix remontée près du réglage concerné |

### 7. Mises à jour

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Vérifier automatiquement | Même opt-in Sparkle ; aide « Vérifie chaque jour si une version est disponible » |
| Vérification manuelle du menu | Réutiliser `UpdaterModel.checkForUpdates()` ici avec `canCheckForUpdates` ; pas de nouveau client réseau |
| Version installée | Version et build réels ; ne jamais présenter « À jour » sans résultat de vérification |
| Mise à jour disponible | Réutiliser l'état Sparkle existant ; laisser Sparkle gérer téléchargement, consentements et installation |
| Confidentialité / réseau | Texte exact : désactiver arrête les vérifications automatiques de mises à jour ; les autres fonctions gardent leurs réglages |

Le bouton manuel est un déplacement d'accès à une fonction existante, pas une
nouvelle mécanique de mise à jour. La dernière date de vérification n'est pas
inventée : ne l'ajouter que si elle est obtenue de Sparkle.

### 8. À propos

| Réglage ou information actuelle | Proposition et paramètres conservés |
|---|---|
| Version | Version et build, mêmes données que dans Mises à jour |
| Licence | GPL-3.0-or-later |
| Description | « La Dynamic Island pour Claude Code et Codex CLI » |
| Texte sur les boutons / palettes / moteur | Déplacé vers Général et Apprentissage, au plus près des choix |
| Texte Rockstar | Autonomie, avec sa portée Claude explicite |

Pas de nouveaux compteurs, crédits inventés, liens promotionnels ni réglages dans
cette fiche d'identité.

## Règles de présentation

- Garder la barre d'onglets et les groupes natifs macOS. Aucun nouveau thème
  de produit ; titres, contrôles et textes alignés à gauche, actions alignées
  avec leur réglage.
- Un titre court, une aide de une ou deux phrases, puis les détails à la demande.
  Espacement régulier ; la ligne du volet repliable reste entièrement cliquable.
- Une action requise, une erreur, une restitution de données ou un risque de
  Rockstar reste visible sans ouvrir un volet.
- Les cases déjà cochées, modèles, sons, volumes et dossiers restent inchangés.
  Les choix masqués par un changement de moteur ne sont pas effacés.
- Fenêtre stable d'un onglet à l'autre ; aucun texte tronqué à 640 × 520.
  Vérifier les huit labels de navigation au minimum de largeur avant de figer
  la disposition. La maquette adapte la barre aux petites surfaces de lecture ;
  le rendu final doit être vérifié avec les contrôles SwiftUI natifs.
- Couleurs de fournisseurs accompagnées de leurs noms dans les réglages.
  Clavier et VoiceOver conservent noms, valeurs et états des volets.

## Plan de réalisation validé

1. **Structure et mémoire.** Extraire les composants mémoire et rappel sans
   changer leurs liaisons ; déplacer vers Apprentissage ; garder désactivation,
   erreurs et confirmations. Déplacer la destination des skills près de la revue.
2. **Analyses et navigation.** Centraliser l'édition des modèles, ajouter les
   raccourcis ciblés depuis les CLI, grouper les limites. Conserver les modèles
   retirés, les erreurs de catalogue et les conditions du second abonnement.
3. **Alertes et Autonomie.** Corriger les portées, raccourcir les aides, rendre
   la migration sonore conditionnelle sans cacher une restitution ou une erreur.
   Clarifier Manuel/Rockstar ; conserver intégralement les protections existantes.
4. **Général, plugins, mise à jour, À propos.** Achever les regroupements,
   inventaires repliés, raccourci Sparkle et textes précis. Pas de modification
   de la barre compacte ni des intégrations CLI.
5. **Recette et seconde relecture.** Captures des huit onglets, clairs/sombres,
   640 × 520 et grandes fenêtres ; navigation au clavier ; scénarios ci-dessous.
   Relire plan, maquette et comportement final ensemble avant une release.

Tests ciblés : conservation de chaque préférence déplacée ; accès au modèle
manquant depuis Codex ; moteur principal et second abonnement ; indexation off
→ rappel automatique off ; alertes Codex sans hooks Claude ; migration détectée,
restituable, illisible ou absente ; fichier son perdu ; erreurs visibles dans les
volets fermés ; confirmation Rockstar ; accès au bouton Sparkle sans faux état
« à jour ». Saboter ces comportements pour prouver les assertions utiles.
Exécuter les tests Core/runtime appropriés et `Scripts/check-docs.py --no-tests`.

## Seconde lecture de la proposition

- Déplacer toutes les fonctions propres à Claude dans Claude Code ferait perdre
  l'accès direct à Autonomie et disperserait les sons. Retenu : conserver les
  huit onglets, déplacer uniquement les réglages réellement communs.
- Supprimer tout accès aux modèles dans Codex recréerait le problème de choix
  introuvable. Retenu : un raccourci visible et ciblé avec état « À choisir » ;
  une seule édition, dans Apprentissage.
- Replier toutes les listes cacherait les skills à revoir et les blocages de
  rangement. Retenu : synthèses et actions urgentes visibles, contenu long replié.
- Remplacer « Claude Code » par « Claude Code et Codex » partout créerait des
  promesses fausses sur reprise sonore, questions/plans et Rockstar. Retenu :
  portée vérifiée fonction par fonction.
- Ajouter recherche globale, panneaux latéraux ou nouveaux réglages de sons
  agrandirait le produit. Retenu : rangements, libellés et accès existants.
- Les confirmations utiles (Rockstar, reconstruction, installation de plugins,
  retrait Claude avec skills appris) sont conservées. Les actions réversibles
  existantes ne doivent pas recevoir un nouveau dialogue de confirmation par
  simple effet de la réorganisation.

## Vérification de la maquette

- Les huit onglets ont été parcourus visuellement dans un navigateur local.
  Général a aussi été vérifié en clair et sombre à 640 px, puis à 320 px pour
  la lecture dans la conversation ; Alertes a été revu à 640 px en clair.
- Interactions vérifiées : raccourci Codex vers le modèle, conservation du
  modèle après actualisation, modèles du second abonnement, dépendance du
  rappel automatique à l'indexation, annulation de Rockstar et volets de plugins.
- Structure contrôlée : huit onglets reliés à huit panneaux, identifiants
  uniques, JavaScript syntaxiquement valide ; aucun appel réseau ni écriture
  de préférences dans la maquette.
- Les actions métier sont simulées. Cette recette ne valide pas encore leur
  future implémentation SwiftUI, VoiceOver ni les scénarios de panne natifs.
- Comparaison avec l'état de travail au début de cet audit : aucun fichier
  de l'app ou de ses tests n'a changé. La fiche de reprise signale explicitement
  que cette nouvelle organisation attend une validation.

## Livrable à examiner

La maquette `docs/mockups/2026-09-11-settings/atoll-reglages.html` couvre les huit
onglets avec leurs volets dépliables et interactions simulées. Elle ne change
aucun réglage réel. Le moteur, le modèle et les états d'exemple servent à lire
la proposition, pas à recommander un abonnement ou un modèle.

**Mehdi a validé la proposition et demandé son application, le commit, le push et une PR.**
Après relecture, **Mehdi a demandé la fusion et la release**. La PR #4 est fusionnée ;
la v0.18.2/build 37 est publiée. Les preuves sont liées dans [HANDOFF](HANDOFF.md).
