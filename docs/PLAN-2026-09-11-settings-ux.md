# Réglages plus simples — 11 septembre 2026

> Historique de la première simplification. L'organisation validée ensuite est
> décrite dans le [plan des huit onglets](PLAN-2026-09-11-settings-organization.md)
> et sa [recette](REVIEW-2026-09-11-settings-organization.md).


Demande de Mehdi : conserver l'interface native d'Atoll, réduire les détails
visibles et rendre les actions nécessaires évidentes, notamment le choix du
modèle des analyses Codex.

## Changements prévus

1. Codex : état du suivi en premier ; instructions de connexion seulement
   lorsqu'aucun événement n'a été reçu. Projet et diagnostic dans un volet
   repliable, chemins et réparation dans le dépannage.
2. Analyses : modèle Codex visible et catalogue chargé en lecture seule.
   Même sélecteur dans Codex et Apprentissage ; aucun modèle choisi à la place
   de l'utilisateur, aucun changement automatique de moteur ou de budget.
3. Apprentissage : choix du moteur près du modèle, limites avancées et journal
   repliables. Les propositions de skills restent accessibles.
4. Lisibilité : textes courts, paragraphes qui reviennent à la ligne, groupes
   cohérents et espacés. Garder les onglets, couleurs, contrôles natifs et îlot.

## Vérification et seconde lecture

- Captures avant/après sur une copie Debug protégée, jamais l'app stable.
- Parcours de connexion en attente/active, diagnostic, modèle absent/choisi/
  indisponible, options repliées/dépliées ; fenêtre étroite et thème clair.
- Vérifier les actions avec l'accessibilité sur des fixtures sans connexion,
  puis vérifier que les préférences et configurations personnelles sont intactes.
- Faire échouer les assertions de visibilité sur l'ancien build : un modèle
  obligatoire caché ou un contrôle de dépannage omniprésent doit être détecté.
- Build, tests pertinents et contrôle documentaire. Relire la version finale
  pour éviter qu'un réglage nécessaire ait été caché ou une valeur modifiée.

La publication et le remplacement de l'app installée ne font pas partie de ce lot.

## Seconde lecture du résultat

- Le modèle reste visible lorsque Codex peut servir aux analyses (moteur choisi
  ou repli autorisé). Sous Claude seul, le panneau Codex renvoie au choix du
  moteur sans demander un modèle qui ne serait pas utilisé.
- Le catalogue se charge à l'ouverture ; son actualisation devient une petite
  commande nommée pour l'accessibilité, à côté du sélecteur. L'ancien choix reste
  intact, même indisponible. Les erreurs sont affichées près du choix concerné.
- Mesuré en recette : le style natif ouvrait les volets au clic sur le chevron,
  mais pas sur le libellé ni via l'action AXPress testée. Le style partagé rend
  toute la ligne cliquable, en conservant le rôle et l'état accessibles.
- Les explications gardent les conséquences utiles : dépense de quota, mémoire
  commune et extraits transmis au fournisseur. Les détails de mécanisme quittent
  le parcours courant. Le texte sur les animations nomme précisément l'onde.
- Le diagnostic de réception donne priorité à une intégration retirée, même
  si un événement antérieur existe. Aucun changement du suivi, des hooks, du
  budget ou du moteur par simple ouverture des réglages.

Validation et captures : [rapport de recette](REVIEW-2026-09-11-settings-ux.md).
