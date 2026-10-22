# Atoll essentiel — réalisation et preuves

22 octobre 2026. Branche locale `codex/atoll-essential`, issue de main 751dd680.
Développement approuvé par Mehdi. App stable 0.18.7/build 42 et configurations
personnelles intactes ; aucune publication ni installation.

## Périmètre réalisé

L’îlot conserve ses sessions Claude Code et Codex CLI, leurs regroupements,
les détails utiles en lecture seule, les quotas et leur fraîcheur. Les réglages
comptent cinq onglets : Général, Connexions, Skills, Mises à jour et À propos.

Le bouton « Créer automatiquement des propositions de skills » réutilise la
préférence existante, sans changer son choix. OFF annule les candidats et les
processus de génération, avec escalade après la grâce existante de 5 secondes.
La réservation reste occupée jusqu’à la sortie du processus. Les résultats
payés restent sauvegardés ; ON reprend leur livraison locale sans nouveau
modèle. Revue et skills installés restent disponibles en OFF.

Le générateur produit seulement des skills. Il conserve ses protections de
qualité, de catalogue, d’installation et d’archives. Les notes présentes dans
une ancienne livraison sont conservées comme héritage, sans nouvelle écriture.
Les dépenses historiques restent lisibles et comptées ; aucun abonnement de
secours n’est sélectionné automatiquement.

Les services de mémoire, curation, plugins, sons, autorisations, Rockstar,
passation et contrôle de terminal ont été retirés du fonctionnement produit.
Les quelques lecteurs de formats anciens utiles à la migration ou au budget
restent présents. Les données personnelles anciennes ne sont pas purgées.

## Hooks et migration

Les événements utiles au suivi restent installés. PermissionRequest observe
l’attente ; aucun helper n’émet de réponse allow/deny ni n’attend une décision
Atoll. Les prompts n’injectent plus de mémoire. Les événements de fin Codex
restent synchrones et courts pour préserver leur livraison. Les wrappers
restent fail-open, y compris si leur worker meurt.

Claude conserve le tee de statusline alimentant son quota. Codex conserve son
lecteur quota indépendant. La migration sauvegarde et vérifie les artefacts
concernés, restaure les deny et anciens hooks sonores, préserve les hooks tiers
et la confiance native, et n’écrit jamais config.toml. Les cas inconnus,
symlinks et corruptions restent signalés et récupérables. Une sélection Codex
invalide ne bloque plus la récupération commune/Claude et ne sélectionne aucun
autre compte. Les anciens clients encore chargés sont acceptés passivement.

## Preuves de sous-lots

Ces preuves portent sur leurs couches respectives, avec homes, CLI et processus
factices. Elles ne valent ni génération authentifiée ni recette du poste réel.

| Domaine | Résultat | Preuve locale |
|---|---|---|
| Skills, parser/livraison | 50 tests ciblés, puis 18 tests de livraison finale | logs des campagnes learning-core privées |
| Générateur et revue | 44 scénarios générateur, 12 revue, 4 processus | `/private/tmp/atoll-essential-skills-generator/` et `atoll-essential-skills-processes/results.json` |
| Skills, contre-épreuves | 8 mutants compilés détectés, dont arrêt/reprise et rétention d’archive | `/private/tmp/atoll-essential-skills-processes-sabotage/results.json` et logs learning-core |
| Migration finale | 18 tests Core, 22 scénarios des vrais services, 10 mutants compilés détectés | `~/Library/Caches/atoll-essential-migration-proof-final/summary.json`, `atoll-essential-process-proof-reviewed/results.json`, `atoll-essential-invalid-home-sabotage/results.json`, `atoll-essential-repair-writer-sabotage/results.json` |
| Hooks passifs | helpers/serveur, anciens clients, wrappers et cinq mutants compilés finaux | `/private/tmp/atoll-passive-hooks-final.json`, `atoll-passive-hooks-wrappers.json` |
| Préparation génération | 15 rapports et 28 contre-exemples, sans modèle | `/private/tmp/atoll-essential-skills-generator/` |

## Intégration finale

Le Core final passe : **1 157 tests, un test authentifié ignoré, zéro échec**.
Les 19 scénarios de première recette UI et quatre scénarios complémentaires
passent. Les captures regardées couvrent les deux fournisseurs, la grande
liste, les détails, les six compacts, le repos, les connexions, le premier
lancement, la revue et le bouton ON/OFF. Les deux vidéos d’animation (4,03 et 5,52 secondes) ont été examinées par
extraction d’images : repli, réouverture, quota et contenu final restent visibles.
Ce contrôle ne mesure pas la fluidité sur tous les écrans.

Le premier passage intégré a repéré un test encore dépendant des notes
supprimées : sa couverture du convertisseur d’enum nullable a été conservée
avec une fixture dédiée (20 tests ciblés passants). Une relance a rencontré un
conflit de cache Clang causé par plusieurs chemins symboliques vers le même
scratch ; le runner utilise désormais son chemin canonique. Les interruptions
ENOSPC sont conservées comme échecs d’environnement. La recette des skills
nettoie ses scénarios temporaires indépendants au fil de l’eau pour borner son
occupation disque. Aucun cache préexistant ni donnée personnelle n’est purgé.

**Profil standard final : 19 étapes sur 19 réussies**, en 108,4 secondes.
Rapport : `~/Library/Caches/atoll-essential-standard-qualified/results.json`.
Les deux recettes legacy corrigées sont incluses dans ce dernier passage complet.

**Builds Debug et Release réussis**, avec signature désactivée. Le binaire
Release de l’app et son helper embarqué contiennent x86_64 et arm64. Logs :
`~/Library/Caches/atoll-essential-debug-qualified.log` et
`~/Library/Caches/atoll-essential-release-qualified.log`. Ces builds ne sont
pas des distributions signées ou notarisées.

**24 scénarios UI distincts qualifiés au total.** La dernière copie Debug
protégée a rejoué navigation Connexions → Skills, ON/OFF et îlot Codex :
`~/Library/Caches/atoll-essential-ui-qualified/results.json` (quatre cas passants).
Les premières captures et vidéos restent dans `atoll-essential-ui/` et
`atoll-essential-ui-additional/`. L’ancien oracle de navigation cherchait un
libellé absent lorsque le modèle n’était pas choisi ; la recette sélectionne
maintenant le vrai raccourci affiché et vérifie le volet d’analyse obtenu.

Autres contre-épreuves finales : stdout passif, quatre cas et trois oracles
sur mutants compilés (`/private/tmp/atoll-codex-stdout-essential-final/results.json`) ;
installation/retrait, parkings et skills gérés préservés, avec mutations A08 et
suppression destructive détectées (`/private/tmp/atoll-hook-essential-lifecycle-qualified/results.json`).

Pour terminer les builds avec le disque presque plein, le scratch Core créé
pour cette tâche et l’index jetable de son DerivedData ont été retirés après
fin de tous leurs consommateurs. Leurs logs et rapports restent conservés.
Le prochain passage de validation recompilera le Core.
Les échecs de compilation ou d’environnement ne sont jamais comptés comme
preuves positives ou sabotages détectés.

## Limites et livraison

Aucun gain de RAM, batterie ou consommation réseau n’est annoncé sans mesure
comparative. Le suivi concerne les CLI, sans garantie d’inventaire exhaustif de
l’application desktop Codex. Une fermeture passive de permission n’établit pas
que le choix natif a été fait ; l’état attend un événement CLI probant.

La génération authentifiée, les annonces vocales VoiceOver et la distribution
signée/notarisée doivent être qualifiées séparément. L’app stable et les hooks
personnels ne sont pas remplacés par ce développement. Le retour à une ancienne
app peut réinstaller d’anciens hooks ; restaurer sélectivement après inspection,
sans recopier aveuglément un backup de configuration.
