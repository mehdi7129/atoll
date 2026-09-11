# HANDOFF — reprendre Atoll

État du **11 septembre 2026**. Fiche courante ; les règles détaillées restent dans
[CLAUDE.md](../CLAUDE.md). L'[ancien handoff](HANDOFF-2026-09-10-archive.md) conserve
les mesures et pièges historiques, sans faire autorité sur l'état actuel.

## Préparation de v0.18.2 — réglages réorganisés

Mehdi a demandé la fusion et la release le 11 septembre. La
[PR #4](https://github.com/mehdi7129/atoll/pull/4) est **fusionnée** sur `main`
(`9e93bb3`), depuis le code vérifié `e50e269` de `codex/settings-ux`.
La version préparée est **v0.18.2, build 37**. Publication et vérification du flux
Sparkle restent à achever ; la version distribuée est encore v0.18.1.

[Plan validé](PLAN-2026-09-11-settings-organization.md),
[recette et seconde lecture](REVIEW-2026-09-11-settings-organization.md).
L'organisation est implémentée : mémoire commune et modèles dans Apprentissage,
raccourci direct depuis Codex, destination des skills près de leur revue,
alertes communes et anciens sons Claude distingués, Autonomie explicitement
Claude, vérification manuelle des mises à jour. Diagnostics et longues listes
sont repliés ; erreurs et actions indispensables restent accessibles.
Builds Debug/Release, 1 020 tests Core (un skip), 58 parcours UI et six sabotages
validés. Captures des huit onglets et limites de recette dans le rapport lié.

Les clés des préférences et les services sont conservés. Le code des gros volets
Claude et Apprentissage a quitté `SettingsView.swift` pour des fichiers dédiés.
La recette protégée peut maintenant ouvrir la vraie scène macOS Settings avec
`--preview-all-settings --preview-settings=codex` ; elle conserve un domaine de
préférences privé et simule ses actions externes. Ne jamais tester ces actions
sur la copie stable. Les anciens rapports de [première simplification](REVIEW-2026-09-11-settings-ux.md)
sont historiques ; la maquette validée reste dans `docs/mockups/2026-09-11-settings/`.

L'app stable reste **v0.18.1, build 36** ; la publication ne la remplace pas.

## État de livraison

| Élément | État vérifié |
|---|---|
| Version publiée | **[v0.18.1, build 36](https://github.com/mehdi7129/atoll/releases/tag/v0.18.1)** |
| Fusion / source | [PR #3](https://github.com/mehdi7129/atoll/pull/3) fusionnée ; tag sur `ec6708a` ; fusion et publication demandées par Mehdi |
| Distribution | Universelle arm64 / x86_64 ; app et DMG signés Developer ID, notarisés, staplés et acceptés par Gatekeeper |
| Mise à jour | Appcast poussé après les assets (`b54a144`) et identique au flux servi ; 19 URL disponibles, SHA256 des sept fichiers publiés et six signatures EdDSA vérifiés |
| Référence précédente | v0.18.0, build 35 ; `main` avant PR #3 : `25132e3` |
| Tests fonctionnels | 1 020 tests Core, 1 skip live opt-in, 0 échec ; 60 scénarios runtime |
| Recettes | PR #3 : 19 cas UI relus et sabotages détectés, trois TUI réels identifiés. Codex authentifié, VoiceOver et sons validés en v0.18.0 ; non répétés pour ce patch |
| Installation de travail | `~/Applications/Atoll.app` **v0.18.1, build 36**, vérifiée le 11 septembre ; les retouches locales des réglages ne l'ont pas remplacée |

Vérifier l'état réel avant toute action : `git status --short --branch`,
`git log -5 --oneline`, `git worktree list`, puis `gh release view`.
Une source publiée et une app installée peuvent avoir des versions différentes.
Le [relevé de livraison](releases/0.18.1.json) conserve les commits, identifiants
de notarisation, résultats et empreintes des fichiers distribués.

## Correctifs après le retour sur v0.18.0

Branche `codex/island-context-setup`, base `25132e3`, correctifs `88ecbb2`.
**Livrés en v0.18.1, build 36**, après fusion de la
[PR #3](https://github.com/mehdi7129/atoll/pull/3) et publication autorisées par Mehdi.
Il a confirmé le retour au compact d'origine : activité à gauche, quota à droite,
couleurs du CLI, choix du fournisseur uniquement dans le panneau ouvert.

- Compact sur une ligne, police 10, aucun « CL/CX ». Le marqueur Rockstar est
  un losange rouge, avec son nom complet pour l'accessibilité.
- Détection des trois vrais CLI `codex --yolo` corrigée ; les auxiliaires du
  même dossier et les app-servers sont exclus. Les hooks restent l'autorité.
- Détail du contexte : tokens utilisés / capacité, pourcentage et date de mesure.
  Les tokens cumulés ne mesurent pas le contexte ; une compaction l'efface.
- Réglages guidés : `/hooks`, choix du dossier du projet, diagnostic qui nomme
  les hooks à approuver. Chemins, réparation et retrait dans les options avancées.

Sur le poste lors du diagnostic, **10/12 hooks étaient actifs** ; seuls
`SubagentStart` et `SubagentStop` attendaient la confiance dans `/hooks`.
Leur approbation seule ne corrige pas le rejet de `--yolo` dans l'ancienne app.
Le helper corrigé doit être utilisé, puis un nouvel événement reçu.

Preuves, limites et captures : [rapport de validation](REVIEW-2026-09-10-island-context-setup.md).
La procédure de release ne remplace pas la copie stable. La mise à jour se fait
depuis Réglages → Mises à jour ou depuis le DMG publié.

## Comportement du code actuel

- Atoll suit **Codex CLI dans le terminal**, Claude Code, ou les deux. Le bouton
  choisit les sessions affichées, la palette et le quota. Les deux collecteurs
  restent actifs ; une carte garde son fournisseur jusqu'à sa résolution.
- Le moteur des trois analyses et la destination des skills sont deux choix
  distincts du bouton d'affichage. Apprentissage et failover sont opt-in.
- Îlot invisible sans activité ni Rockstar ; liste bornée avec « +N autres » ;
  sélecteur dans le panneau ouvert ; Rockstar exclusivement Claude, marqueur et quota
  simultanés. Questions, plans et interruption Codex restent dans le terminal.
- Hooks Codex migrés avec sauvegarde, retraits et personnalisations respectés ;
  réparation complète explicite. `config.toml` n'est jamais écrit par Atoll.
- Mémoire commune aux deux CLI. Recall manuel disponible des deux côtés ;
  injection proactive Codex désactivée faute de contrat vérifié.
- Skills : zéro proposition pour une tâche banale ou déjà couverte ; corps
  généralement de 200–600 tokens, procédures utiles et commandes préservées.
  Au-delà de 8 000 caractères, refus tracé, jamais troncature. La revue compare
  avec l'installation, précharge l'antériorité et conserve la sélection.

## Limites à connaître, pas des tâches à relancer aveuglément

1. **Claude authentifié** : le test de génération a reçu un 403 d'accès abonnement.
   Mehdi confirme maintenant ne plus disposer d'un abonnement Claude. Différer
   cette recette jusqu'à disponibilité d'un accès ; ne pas basculer sur une clé API.
2. **Retour au terminal visible** : le PTY a permis de tester le CLI, pas le focus
   d'un onglet réel. L'outil de contrôle GUI a refusé Terminal. Aucun échec du
   bouton d'Atoll n'est établi ; cette recette reste non exercée.
3. **Protections conservées** : aucun signal vers un PID non vérifié, aucun succès
   d'outil Codex inventé, aucune réparation destructive de journal/manifest,
   sources de notes obligatoires et catalogues invalides bloquants. Événements
   anonymes et interruptions parent/enfant restent incertains sans preuve causale.
4. **Mouvement réduit** désactive l'onde ; les fondus et transitions de taille
   existants demeurent. L'OCR ne remplace ni la lecture des captures ni VoiceOver.

La fusion et la publication ont eu lieu avec l'accord de Mehdi malgré les deux recettes différées.
Ne pas les déclarer réussies lors d'une reprise de session.

## Vérifier ou modifier

Avant de croire un document et après toute modification documentaire :

```sh
python3 Scripts/check-docs.py --no-tests
```

Pendant une préparation de release, ajouter `--preflight` tant que l'appcast
n'a pas été régénéré. Après publication, utiliser `--no-tests --network` pour
les URL des assets et le flux GitHub Pages réellement servi.

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-skill-review.py
python3 Scripts/test-release-trash.py
```

Les sabotages ciblés sont documentés dans les rapports. Une compilation ratée
n'est jamais une régression détectée. Ne relancer une génération `--live` que
si elle répond à une question nouvelle : elle consomme le quota du compte.

Pour compiler, suivre le [README](../README.md). Ne jamais lancer le produit
`Build/Products` ni recopier un Debug sur l'app stable. `Scripts/prepare-preview.py`
crée une copie protégée dans `/private/tmp`, fictive même rouverte sans arguments.
`Scripts/test-ui.py` et `Scripts/test-voiceover.py` utilisent cette copie.

La recette authentifiée utilise `Scripts/prepare-cli-validation.py` : deux homes
privés vérifiés, hooks privés et copie native. **Fermer l'Atoll normal avant de
lancer la copie native** ; ne jamais avoir deux instances normales. Retirer les
copies d'authentification et restaurer les préférences et l'app stable à la fin.
Ne pas activer un accès VoiceOver temporaire sans l'autorisation correspondante.

## Publier une prochaine version

1. Mettre à jour version **et** build dans `project.yml`, README et cette fiche.
2. Tester, committer et fusionner le code ; garder l'appcast courant servi.
3. `zsh Scripts/release.sh` : signature Developer ID, notarisation app et DMG,
   staples, ZIP signé Sparkle, deltas. Le nettoyage passe par la corbeille.
4. Publier DMG, ZIP et deltas de **ce build** sous leur tag. Vérifier toutes les
   URL référencées : les entrées anciennes restent sous leurs propres tags.
5. Pousser `docs/appcast.xml` en dernier, attendre GitHub Pages et vérifier le
   flux servi avec `check-docs.py --no-tests --network`. Mettre cette fiche à jour.

Profil notarytool : `atoll-notary`. Clés de signature dans le Keychain ; ne jamais
les exporter dans les logs ou le dépôt. Préserver le DerivedData Debug et les
archives `dist/updates`. Les anciennes sorties remplacées restent récupérables
à la corbeille. Une nouvelle release ne nécessite pas de réinstaller l'app stable.

Incident local du 10 septembre : 44 copies non suivies suffixées « 2 », toutes
identiques aux originaux et absentes des six listes de compilation Release, ont
été conservées dans `/private/tmp/atoll-018-sync-copies-yjutnk0r/` avec manifeste.
La cause reste indéterminée ; si elles réapparaissent, comparer avant de déplacer,
sans les intégrer au build ni supprimer un changement distinct.

## Références utiles

- [Validation finale, preuves et P3](REVIEW-2026-09-10-skills-validation.md)
- [Correction du compact, contexte et configuration](REVIEW-2026-09-10-island-context-setup.md)
- [Plan skills et seconde analyse](PLAN-2026-09-10-final-validation-skills.md)
- [Corrections R01–R11](REVIEW-2026-09-10-pr2-corrections.md)
- [Contrat Codex / Claude](CODEX-INTEGRATION.md), [analyses et passation](CODEX-FAILOVER.md)
- [Vision produit](VISION-2026-08.md) : soustraire avant d'ajouter

Le rendez-vous du recall est **clos et tranché depuis le 9 septembre**. Ne pas
reprendre les anciennes mentions « décision en attente » : mesures et choix
sont conservés dans `CLAUDE.md` et l'archive historique.
