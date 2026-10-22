# Atoll 0.19.0/build 43 — qualification locale

22 octobre 2026. Préparation autorisée par Mehdi après l’implémentation
95b9d4f, sur la branche `codex/atoll-essential`, hors iCloud. Aucune modification
du code produit pendant cette qualification : versions, outils de recette et
documentation seulement. Aucun push, publication ou remplacement de l’app
stable. La copie 0.18.7/build 42 a été relancée après chaque test isolé.

Mehdi a choisi explicitement de terminer avec Codex validé et Claude Code à
revalider après connexion. Aucun abonnement de secours ni clé API substitué.

## Génération Codex

Trois exécutions du générateur réel via Codex CLI 0.163.0, modèle demandé
`gpt-6.1-sol`, sur des condensés synthétiques : routine → zéro skill ; technique
déjà couverte → zéro ; procédure réutilisable → un. Aucune note dans les
sorties brutes. Les trois processus terminent avec le code zéro. Les fixtures
n’installent aucun skill personnel. Le contrôle préalable du compte sélectionné
a constaté une authentification ChatGPT ; le harness utilise une copie privée
temporaire de cette authentification, sans fallback, puis la retire.

Le vérificateur rejetait initialement « doit donner » dans l’exemple numérique
correct. Son acceptation a été corrigée avec contre-exemples et trois mutations
causales. Une relecture hors ligne valide les trois sorties existantes sans
nouvelle génération. Le résultat initial en échec est conservé. Les sept
empreintes de fichiers source et celle du checker ont été revérifiées
indépendamment. Le modèle réellement servi n’étant pas rapporté, seul le modèle
demandé est annoncé ; trois processus ne signifient pas trois requêtes réseau.

Preuves : `/private/tmp/atoll-essential-generator-live-20261022/`, notamment
`recheck-results-20261022T130628108221Z-7f792bd8.json` et ses sept sources.

## Hooks Codex natifs

La recette A, sans compte ni modèle, constate douze définitions reconnues par
`hooks/list` : PermissionRequest asynchrone, Stop et SessionEnd synchrones,
timeout de trois secondes. Leur confiance n’est pas accordée par Atoll.

La recette B utilise une copie isolée de l’app Debug et son helper inchangés.
Un relais transparent mesure les hooks de cette seule fixture. La confiance
de leurs hashes revus est accordée via le RPC natif Codex dans le config.toml
privé de la fixture ; Atoll ne l’écrit pas. Le vrai app-server Codex demande
l’accord pour une unique commande créant un marqueur privé. L’app affiche
awaitingPermission, aucune interaction Atoll n’est en attente et le marqueur
reste absent pendant une seconde supplémentaire. Le client natif donne ensuite
accept. Une seule commande est exécutée, le marqueur est exact, Stop synchrone
est confirmé et l’app retrouve awaitingInput. Tous les hooks enregistrés ont
stdout/stderr vides et code zéro.

Une première tentative a été interrompue par une erreur de recette : elle
cherchait l’identifiant natif sans le préfixe applicatif `codex:`. Les preuves
partielles sont conservées ; un self-check et une mutation détectent ce défaut.
La seconde fixture complète passe. Ce test qualifie le protocole app-server,
pas l’attachement à un terminal TUI/IDE ni un parcours de refus natif.

Preuves : `/private/tmp/atoll-native-passive-A-final.json`,
`/private/tmp/atoll-native-passive-B.json`,
`/private/tmp/atoll-native-state-self-check.json` et
`/private/tmp/atoll-native-passive-B-first-analysis.json`.

## Paquet signé et notarisé

`Scripts/release.sh --local` a construit la version 0.19.0/build 43 dans le
DerivedData privé de cette tâche. Le mode local s’arrête avant l’appcast, les
archives de mise à jour et les deltas. Des outils factices, des cas négatifs et
quatre mutations causales couvrent ces protections ; le nouveau stage offline
`local-release` est exécuté séparément du relevé d’implémentation 19/19.

`Scripts/verify-release.py --local` passe sur les artefacts réels : sept
exécutables universels arm64/x86_64 signés Developer ID, équipe X524H8XA4L,
Hardened Runtime, aucun get-task-allow, entitlements app vides, staples valides
et Gatekeeper app/DMG acceptés. Les 134 objets de l’app du DMG monté en lecture
seule sont identiques au ZIP : contenu, liens, modes et tailles. Le volume est
démonté et les extractions temporaires retirées. L’app n’a été ni lancée ni
installée par ce vérificateur.

| Artefact | Octets | SHA256 |
|---|---:|---|
| Atoll-0.19.0.dmg | 8 677 337 | 31769f040e7c085c1f538b557b2114d8990c1d8f8926d6abe8af7bbac84a6365 |
| Atoll-0.19.0.zip | 7 855 793 | 110643c2c4244d6e06d50b60c49380ed5429c877ebcd0ca06e7bb6aa5c415e12 |

Notarisations Apple Accepted : app `fdd82cb5-ca26-4c54-905c-693046a1d2d9`,
DMG `658bc9b8-4979-4ffd-9860-bf78253e667b`.

Preuve complète :
`~/Library/Caches/atoll-essential-local-package-proof/run-yghlcboe/validation.json`.
Log : `~/Library/Caches/atoll-essential-package-local.log`. Les empreintes de
l’appcast et l’inventaire des archives de mise à jour avant/après concordent.
L’EdDSA Sparkle, les deltas et les assets publics restent hors qualification
locale. La publication demeure 0.18.7/build 42.

Les preuves essentielles et le DMG/ZIP sont recopiés dans le dossier du Bureau
`Dynamic_Island/codex/atoll-essential-20261022/`. Claude authentifié et VoiceOver
restent à valider séparément. Les 1 157 tests Core et les 24 scénarios UI du
rapport d’implémentation restent leurs validations historiques, sans nouvelle
suite globale ni mesure comparative de RAM/batterie.
