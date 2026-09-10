# Dernière passe PR #2 et générateur de skills

Demande de Mehdi du 10 septembre 2026 : terminer les recettes CLI, VoiceOver et
les P3, puis faire produire au générateur des skills courts, précis et utiles.
Base : `32f034a`. Les cinq arbitrages précédents restent acquis.

> **Mise à jour de livraison :** après la seconde analyse et les recettes,
> Mehdi a autorisé la fusion et la release v0.18.0. Sons confirmés ; abonnement
> Claude désormais absent. Les recettes Claude authentifiée et retour GUI au
> terminal restent différées. Voir [HANDOFF.md](HANDOFF.md) pour l'état courant.

## 1. Générateur : soustraire avant d'ajouter

- Partir de la note `atoll-generation-guidance.md` du projet `skills-question`
  et des skills effectivement allégés. Ne pas réécrire les skills installés.
- Remplacer l'incitation à proposer dès qu'une tâche réussit par un critère de
  valeur : procédure réussie, réutilisable, connaissance non évidente qui
  change les décisions d'un agent compétent. Une tâche triviale donne zéro skill.
- Description discriminante, cible 80–140 caractères ; corps généralement
  200–600 tokens. Conserver commandes vérifiées, invariants et contrôles utiles,
  supprimer tutoriels, redites, narration et exigences de workflow inventées.
  Ces cibles ne justifient pas de tronquer une procédure fragile.
- Garder l'inventaire natif et l'approbation humaine. Une proximité avec un
  skill existant est signalée ; aucune opération d'update fictive ou écrasement.
- Remplacer la troncature du corps par un refus explicite des sorties au-delà
  de la borne technique. Conserver les notes valides et la trace de ce refus.
- Vérifier sur fixtures puis générations bornées avec les deux CLI : tâche
  triviale, procédure déjà couverte, piège opérationnel précis, directive injectée.
  Mesurer longueur
  et préservation des invariants ; un texte court n'est pas une preuve de qualité.

## 2. P3 : correctifs et décisions conservatrices

- CodexRun : retirer le paramètre de cwd ignoré ; distinguer catalogue illisible
  et modèle absent. Garder la revalidation avant dépense.
- Revue des skills : conserver la position après décision, précharger le
  catalogue de la sélection avec rejet des réponses périmées, faciliter la
  comparaison à l'installation existante.
- Interface : rendre le sélecteur compact cliquable malgré le survol ; traiter
  le changement de cible clavier après résolution externe ; contrôler les
  libellés VoiceOver et les différents gabarits.
- Supervision : retenter de manière bornée une lecture d'identité indisponible,
  sans jamais signaler un PID non vérifié. Tester sortie, annulation et PID recyclé.
- Fichiers : rendre visible l'échec du retrait d'un manifest illisible ; nettoyer
  les seuls domaines de recette possédés. Aucun rétablissement destructif implicite.
- Préserver les protections justifiées : sources de notes obligatoires,
  catalogues corrompus bloquants, événements anonymes incertains, archivage
  sans preuve d'usage désactivé. Ne pas transformer le doute en succès.

## 3. Recette native et accessibilité

- Utiliser des copies, des données et des préférences de test. Une seule instance
  normale d'Atoll à la fois ; stable non remplacée. Vérifier puis restaurer
  chaque état temporairement nécessaire à la recette.
- Claude et Codex authentifiés : permission autorisée/refusée/renvoyée au CLI,
  sons, interruption, reprise, retour au bon terminal. Appels de test courts,
  sans action de production ni nouveau traitement en arrière-plan.
- VoiceOver activé temporairement : parcours réel de la carte et du sélecteur,
  focus, annonces et navigation. Restaurer son état initial.
- Captures de fenêtre et films : tailles, encoche/pilule, clair/sombre,
  mouvement réduit. Lire les images, ne pas confondre OCR et accessibilité.

## 4. Sortie vérifiable

Tests ciblés et sabotages pour chaque correction de comportement, suite Core
et runtime, builds Debug/Release, vérifications CLI/GUI, contrôle documentaire.
Relire le plan contre les résultats, corriger les écarts, documenter toute
limite effective. Commit/push sur la PR #2, qui reste à faire valider par Mehdi ;
aucune fusion ni release automatique.

État initial : dépôt propre, Codex CLI 0.154.0 connecté via ChatGPT,
Claude Code 2.1.267 connecté via claude.ai. Les détails d'authentification ne
sont pas exportés dans les preuves.

## 5. Résultat et seconde analyse du plan

Le [rapport de validation](REVIEW-2026-09-10-skills-validation.md) porte les
mesures et preuves. Cette seconde lecture confronte les hypothèses du plan aux
chemins de production et aux recettes, sans déclarer l'ensemble du dépôt relu
ligne par ligne.

| Lot | État observé |
|---|---|
| Générateur | Consignes partagées actives et legacy, borne technique sans troncature, refus journalisé. Codex : 0 / 0 / 1 / 0 skills pour les quatre cas ; procédure utile de 146 mots. Claude : appel de test refusé par un 403 d'accès abonnement ; contexte de connexion à vérifier |
| P3 actionnables | Position et antériorité des skills, comparaison, sélecteur compact, délai clavier, catalogue modèle, identité du processus et diagnostic de retrait corrigés et testés |
| VoiceOver / visuel | Annonces et action VoiceOver réelles vérifiées, paramètres restaurés ; 24 variantes relues, quatre transitions filmées. L'OCR n'est pas une preuve de voix ni un substitut à la lecture visuelle |
| CLI natifs | Codex : permettre, refuser, rendre la décision au CLI, interrompre et reprendre vérifiés avec le helper du build. Sons entendus, confirmation ultérieure de Mehdi. Claude et retour à un panneau de terminal visible restent à valider |
| Publication | Commit/push réalisés ; Mehdi a ensuite autorisé la fusion et la release, avec les deux recettes différées consignées |

La relecture a amélioré le plan sur six points concrets :

1. **Concision et valeur sont deux contrôles distincts.** La première génération
   opérationnelle ne proposait rien : l'ancienne consigne système interdisait
   implicitement de distiller une procédure. La contradiction a été retirée,
   puis le cas utile et un cas d'injection ont été rejoués. Ne pas compenser par
   davantage de texte ou une obligation de produire un skill.
2. **Le test de sélection doit exercer le raccourci natif.** Le calcul du prochain
   index ne voyait pas une closure SwiftUI conservée sur la première proposition.
   L'identité de la sous-vue suit désormais le skill ; l'ancien build échoue à
   la même navigation et au même raccourci.
3. **Un catalogue peut arriver trop tard avec succès ou avec erreur.** Les deux
   voies vérifient la destination et l'annulation. Un ticket distingue aussi
   deux lectures successives du même skill pour protéger l'indicateur de
   chargement. Trois sabotages exercent ces courses.
4. **L'isolation d'une recette doit être prouvée jusqu'au helper.** Les aliases
   `/tmp` et `/private/tmp` sont normalisés des deux côtés. Le remplacement des
   commandes se fait après décodage JSON, sinon les slashs échappés laissaient
   appeler le wrapper personnel. Les premiers parcours ont été écartés et les
   cinq parcours Codex rejoués avec le helper réellement vérifié.
5. **Une recette GUI doit garder le focus et publier ses échecs bruts.** La
   reconnaissance OCR sur police petite et le focus perdu ont produit des faux
   négatifs. Les captures sont relues ; les tests de clic/survol et les films
   sont rejoués seuls. Aucun total « tout vert » n'est déduit de la matrice OCR.
6. **Les limites externes ne demandent pas plus de code.** Le refus de l'appel
   Claude demande de vérifier le contexte de connexion utilisé ; l'écoute est
   désormais confirmée par Mehdi et le retour au terminal exige encore une
   recette observable. Ni bascule API, ni identité de terminal fabriquée, ni
   réparation destructive des données incertaines.

Le périmètre reste adapté : aucune couche de génération propre à un modèle,
aucun nouveau format de skill et aucune réécriture des skills installés. Les
améliorations servent les deux CLI au même endroit dans le code.
