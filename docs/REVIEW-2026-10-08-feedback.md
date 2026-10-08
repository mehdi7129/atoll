# Feedback fidèle — A15, A16, A17

Relevé du 2026-10-08, sur les corrections combinées des PR #14 et #15.

- **A15** : `NSSound(named:)` fournit un objet partagé malgré les clés de cache
  distinctes. Chaque événement conserve désormais sa propre copie, puis réutilise
  cette instance pour ses répétitions. Choix, volumes, anti-rafale et fichiers
  personnalisés gardent leurs contrats.
- **A16** : la façade observable de rétrospective publie une révision après
  écriture du journal et après chaque note effectivement livrée. Le panneau
  Apprentissage observe ces changements, ainsi que la fin du rangement existante.
  Aucun timer ajouté. Une écriture refusée ne publie pas un résultat fictif ; une
  reprise qui ne réécrit aucune note ne prétend pas avoir modifié les notes.
- **A17** : le jump IDE attend la fin du CLI dans la primitive de processus bornée,
  hors MainActor. Un spawn ne vaut plus succès. Le repli d'activation est conservé,
  et le résultat annonce la granularité `app`, seule confirmée par l'activation.
  La contre-review a reproduit une inversion des callbacks lors de deux jumps
  successifs : le remplacement de la queue série par des tâches indépendantes
  permettait au premier jump, plus lent, de reprendre le focus après le second.
  Les tâches sont désormais chaînées dans l'ordre des clics ; l'exécution reste
  détachée et les callbacks reviennent sur MainActor.

## Validation

`Scripts/test-feedback.py --output <preuves> --sabotage` compile les vraies classes
SoundCenter et TerminalJumpService. Sept assertions AppKit vérifient identité,
volume, cache, silence et fichier personnalisé, sans lecture audible. Sept parcours
IDE couvrent succès différé avec vraie racine Git, exit 42, repli, refus
d'activation, timeout, exécutable absent et résolution absente. Un parcours
supplémentaire utilise le vrai point d'entrée `jump`, deux CLI privés et un focus
injecté : processus, activations et callbacks conservent leur ordre. Le premier
CLI attend un signal écrit par MainActor, prouvant que celui-ci reste disponible.
Quatre sabotages
compilés échouent sur l'assertion attendue : singleton partagé, succès inventé,
fin du CLI non attendue, exécution concurrente des jumps.

`Scripts/test-learning-retrospective.py` exerce les vrais runners sur les deux
fournisseurs fictifs : 26 parcours, dont livraison, abstention, panne locale,
journal illisible et reprise partielle. Des observateurs Observation suivent les
révisions avant les opérations. Les sabotages `journal-revision` et
`notes-revision` compilent et sont détectés à l'exécution.

Les preuves se trouvent dans le dossier local
`atoll-audit-completion-evidence-20261008/feedback`. La compilation de l'app entière,
les captures de la copie protégée et la relecture croisée sont consignées dans le
rapport de clôture commun. Ces tests silencieux ne constituent pas une écoute
humaine ni une qualification du focus sur un terminal authentifié.

Les preuves complémentaires de l'ordre des jumps sont dans les sous-dossiers
`counterreview` (avant/après la régression) et `feedback-order` (nominal et quatre
sabotages) du même dossier de preuves.
