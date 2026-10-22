# CLAUDE.md — instructions projet Atoll

Lire ensuite [docs/HANDOFF.md](docs/HANDOFF.md). Les incidents et décisions historiques restent dans les [archives](docs/archive/CLAUDE-2026-10-08.md) et les [règles avant recentrage](docs/archive/CLAUDE-2026-10-22-before-essential.md).

Version publiée : **v0.19.0**, build 43. [Release GitHub](https://github.com/mehdi7129/atoll/releases/tag/v0.19.0) et [relevé de distribution](docs/releases/0.19.0.json). La [qualification locale](docs/QUALIFICATION-2026-10-22-essential-local.md) conserve les preuves de préparation.

## Produit et périmètre approuvé

Le [plan approuvé](docs/PLAN-2026-10-22-simplification.md) conserve l’îlot ASCII, les sessions Claude Code et Codex CLI, les quotas et la création facultative de skills. Les autorisations se traitent dans le CLI. Mémoire/recall, notes/curation, gestion de plugins, sons, Rockstar, passation et pilotage de sessions sont retirés du produit. Leurs données restent préservées.

- Français ; identifiants anglais, commentaires français. Swift/SwiftUI natif, macOS 14+, GPL-3.0-or-later, aucune télémétrie.
- Compact, géométrie, palettes, onde, Reduce Motion et regroupements conservés. Invisible au repos. Les réglages regroupent Général, Connexions, Skills et les volets de support.
- Ne pas confondre CLI et app Codex : l’inventaire desktop exhaustif n’est pas garanti.
- Préserver les cadences, seuils, modèles et destinations hors changement approuvé. Soustraire avant d’ajouter ; pas de refonte générale de services.
- Chaque correctif important comporte une régression vérifiée par sabotage causal compilé. Une compilation en échec ne compte jamais comme défaut détecté.
- Vérifier branche, worktree et travaux concurrents avant édition. Ne jamais remplacer l’app stable dans ~/Applications ni lancer deux Atoll normaux. Rien ne se publie sans Mehdi.

## Hooks, migration et données

1. Fail-open absolu : stdout réservé au protocole, exit 0/abstention sur panne, latences bornées. Aucun helper d’Atoll ne décide allow/deny.
2. PermissionRequest reste une observation passive. Les événements de fin Codex gardent leur livraison synchrone courte lorsque nécessaire. UserPromptSubmit n’injecte plus de mémoire. Ne pas confondre retour du helper et décision native : garder une attente incertaine jusqu’à un fait probant.
3. settings.json Claude et hooks.json Codex : sauvegardes avant écritures, merge sélectif, tiers/groupes/métadonnées/personnalisations préservés, symlinks respectés ; refus sur accès invalide/inconnu. config.toml n’est jamais écrit. La confiance native n’est pas accordée automatiquement. Le tee de statusline Claude reste nécessaire au quota.
4. Les wrappers supervisent le worker et conservent stdin : exec 3<&0, redirection depuis fd3 puis wait silencieux. Ne pas remplacer par un simple exec ou un job qui perd son stdin.
5. La migration essentielle précède toute réconciliation des stores ; erreur visible et réessayable dans Connexions. Désactiver le fallback sonore avant restitution des anciens hooks. Restaurer les deny parqués ; ne jamais les parquer de nouveau. Préserver les modifications concurrentes et toutes les données inconnues.
6. Ne jamais utiliser une désinstallation générale pour migrer. Les skills, ressources et manifestes restent intacts. Le retrait d’intégration ne retire que l’intégration, pas les skills.
7. Skills OFF : pas de nouvelle préparation/réservation/génération/livraison automatique. Revue manuelle et skills installés restent utilisables. ON ne provoque pas de rattrapage massif. L’arrêt du modèle est demandé immédiatement, avec escalade bornée et réservation conservée jusqu’à sortie effective.
8. Sauvegarder les résultats payés avant livraison. Reprendre localement avant tout nouveau modèle ; conserver les identités et progrès legacy, les dépenses de la fenêtre et les preuves d’archives. Les notes anciennes sont héritées, jamais annoncées comme écrites par le nouveau chemin. Pas de purge sur doute.
9. Un PID seul n’est pas une identité : vérifier PID et naissance avant chaque signal. Tous les processus, résolutions et drains sont bornés ; aucune attente bloquante sur MainActor.
10. JSONL : n’acquitter que les lignes complètes traitées. Parsing défensif, digest borné ; conserver résultat inconnu et commande incomplète. Ne pas transformer une absence de mesure en zéro.

## Architecture et validation

App : façades observables et UI ; AtollCore : logique pure testable ; Bridge : helper ; Shared : API système communes. Les lecteurs legacy restent isolés des producteurs retirés. BSD sockets non bloquants avec contrôle des pairs ; pas de NWListener Unix.

Résoudre les CLI en chemin absolu, conserver stdin /dev/null pour codex exec et le profil login requis par l’auth. Un shell login non interactif ne lit pas .zshrc. Le modèle ne peut installer aucun fichier : sorties revalidées puis revue explicite et installation avec archive confirmée.

Builds/validation hors Bureau iCloud. Ne jamais lancer un produit Build/Products ; préparer une copie protégée via Scripts/prepare-preview.py, qui attribue un bundle ID privé et AtollPreviewOnly. Après toute UI, regarder ses captures ciblées par CGWindowID ; filmer les animations. Ne pas englober ScrollView/champs AppKit dans layerEffect. Ne pas contourner les permissions macOS.

    python3 Scripts/validate-offline.py --profile standard
    python3 Scripts/check-docs.py --no-tests
    xcodegen generate

Les générations authentifiées sont distinctes, limitées à une question nouvelle et jamais lancées implicitement par la CI. Tests simulés, build, aperçu, CLI authentifié et distribution prouvent des couches distinctes. Un build ne met pas à jour l’app installée.

Pas de rm -rf. Conserver les données utilisateur ; corbeille pour les artefacts identifiés. Les fixtures privées jetables peuvent être nettoyées par leur harness. Les caches préexistants ne sont pas des fixtures.

## Documentation et distribution

Exécuter check-docs sans tests avant de croire un document et après édition. README reste une vitrine, HANDOFF porte l’état courant ; conserver les audits historiques. Le registre des relectures ne crédite que ce qui a effectivement été relu et documenté.

Une future release augmente version ET build, préserve les archives Sparkle, publie les assets avant l’appcast et vérifie architectures/signatures/notarisation/deltas/octets servis. Voir docs/RELEASE-VALIDATION.md. Ne jamais exporter les clés de signature, écraser un Debug quotidien ou installer la release pour la vérifier.

## Triggers debug

Liste exhaustive, noms littéraux dans AppDelegate :

- Release et Debug, sans décision : `expand`, `compact`.
- DEBUG seulement : `seedSkill`, `skillReview`, `approveSkill`, `rejectSkill`, `select`, `settings`, `onboarding`.

Les fixtures et aperçus restent isolés ; aucun trigger d’autorisation, de son ou de génération automatique ne subsiste.
