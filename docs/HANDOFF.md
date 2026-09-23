# HANDOFF — reprendre Atoll

État du **23 septembre 2026**. Fiche courante ; les règles détaillées restent dans
[CLAUDE.md](../CLAUDE.md). L'[ancien handoff](HANDOFF-2026-09-10-archive.md) conserve
les mesures et pièges historiques, sans faire autorité sur l'état actuel.

## v0.18.3, build 38 — publiée

[Release](https://github.com/mehdi7129/atoll/releases/tag/v0.18.3) autorisée par
Mehdi le 23 septembre, tag sur `d438b8e`. Code produit identique à `30847d6`,
déjà validé avant fusion. App et DMG universels signés Developer ID, notarisés,
staplés et acceptés par Gatekeeper ; six signatures Sparkle vérifiées.
Le différentiel 37 → 38 reproduit fichiers, liens et modes de l’archive complète.
[Relevé de livraison](releases/0.18.3.json). Les assets sont publiés avant le flux.
L’app installée n’est pas remplacée ; appliquer la mise à jour depuis Atoll ou le DMG.

## PR #5 fusionnée — corrections du rendement de l’apprentissage

Mehdi a autorisé les corrections de l’[audit du 11 septembre](AUDIT-2026-09-11-learning-efficiency.md).
La [PR #5](https://github.com/mehdi7129/atoll/pull/5) est **fusionnée sur `main`**
le 23 septembre à sa demande : merge `8b7e9a9`, depuis la tête testée `30847d6`.
L’arbre de la fusion est identique à celui testé ; aucun conflit ni changement
de code pendant la fusion. La mise à jour de cette fiche est documentaire.
Ces corrections sont publiées en v0.18.3. L’app installée reste sur v0.18.2
tant que sa mise à jour n’a pas été appliquée.
Le [rapport de correction](REVIEW-2026-09-22-learning-efficiency.md) décrit les preuves,
les commandes de test et les limites ; l’audit initial reste un constat historique.

- Sorties sauvegardées avant livraison, écritures confirmées et reprise locale
  au démarrage ou avant une nouvelle analyse. Un résultat incomplet ne marque
  pas la session traitée ; une destination différente ne reçoit jamais l’ancien résultat.
- Même condensé déjà traité : aucun nouvel appel automatique. Rangement :
  annulation persistée, empreinte du corpus après succès, relance manuelle conservée.
- Antériorité bornée des notes, propositions, refus et installations ; catalogue
  Claude remontant au projet. Les doublons exacts sont filtrés avant livraison.
- Usage natif et inconnues explicites, durée, taille du prompt et résultats
  conservés dans le journal existant. Digest : coupures et bornes distinctes,
  conclusions mieux préservées, commandes tronquées signalées.

Validation du 22 septembre : **1 070 tests Core, un skip opt-in et aucun échec**,
**135 parcours** dans les quatre harnesses runtime, **34 sabotages détectés**,
builds Debug/Release et contrôle documentaire réussis. L’interface n’a pas été
réorganisée dans ce lot ; aucune app n’a été lancée pour cette validation.

Les premières recettes ([initiale](REVIEW-2026-09-22-learning-live.md),
[profil allégé](REVIEW-2026-09-22-codex-lean.md)) sont historiques.
La [correction suivante du générateur](REVIEW-2026-09-22-generator-quality.md)
traite la séparation note/skill, les comptes rendus inutiles et le rejet silencieux
pour identifiant trop long. Le schéma annonce les 2–40 caractères réellement admis ;
le parseur signale les rejets sans exposer de champ non validé. Les identifiants
présents dans le résumé ne sont plus envoyés deux fois ; les autres sont conservés.

Dernière comparaison : **28 988 → 8 894 tokens d’entrée (−69,3 % depuis le départ,
−6,1 % depuis le profil allégé)**. Cas banal vide, préférence en note, export en
skill complet de 118 mots. Deux autres abstentions et une procédure indépendante
ont été validées avant l’ultime précision sur les notes. **10 appels dans ce lot :
44 468 tokens d’entrée, 3 203 de sortie**, diagnostics inclus. Les captures brutes,
échecs initiaux et revalidations hors ligne sont conservés ; ne pas repayer ces
appels à chaque reprise. Les mesures ne garantissent pas le rendement de toute session.

Validation finale : **1 078 tests Core, un skip, zéro échec**, 25 scénarios de contexte,
26 parcours rétrospectives, deux sabotages compilés, builds Debug/Release et contrôle
documentaire. Vérificateur : 15 bons rapports et 28 contre-épreuves. Trois usages
finaux rejoués dans le journal sans nouvel appel. Instructions globales et outils
résiduels Codex subsistent ; le flux JSON n’expose pas tous les appels de wrappers.
Le runtime conserve le home choisi, les modèles et configurations personnelles.

Suite du 23 septembre : le [rangement des notes reprend son résultat sauvegardé](REVIEW-2026-09-23-curation-recovery.md)
après un échec local, avant toute capture du modèle ou réservation de budget.
La reprise vérifie les notes, la provenance et les contradictions ; un corpus changé
ne reçoit jamais une ancienne réponse. Aucun nouvel appel IA dans cette validation.
La reprise reste liée au bouton ou à l’échéance autorisée, sans nouvel automatisme
au démarrage. Les mesures de tokens ci-dessus restent celles du 22 septembre.
Validation du lot : **1 083 tests Core (un skip, aucun échec)**, 98 parcours de
reprise, 26 de cadence/annulation, 60 runtime, sept sabotages compilés détectés
et builds Debug/Release. Cas de crash reconstitués, CLI factices ; preuves liées.
Un début de remplacement est journalisé ; en cas ambigu, fichiers et résultat
restent conservés, sans nouveau modèle. Lire les limites du rapport avant de
supprimer un checkpoint ou un staging manuellement.

Les fichiers du Bureau étant partiellement déchargés par iCloud, la validation
utilise une copie locale : `/private/tmp/atoll-learning-local-20260922`.
Les changements sont aussi présents dans le dossier d’origine, revenu sur `main`. Xcode 27 nécessite
le composant Metal ; les harnesses Swift utilisent provisoirement `--build-system native`.
Ne pas relancer des builds dans le Bureau tant que les fichiers ne sont pas hydratés.

Incident sonore du 22 septembre sur le poste : le son de fin Atoll se superposait
à la cloche de Codex dans Cursor. Correctif local, aucun changement Swift :
`accessibility.signals.terminalBell.sound = "off"` dans Cursor, avec sauvegarde.
État vérifié dans son UI et avec les fonctions installées de sélection du son ;
accessibilité toujours active, annonce conservée, toutes les cloches de terminaux
Cursor désormais muettes. Écoute humaine non effectuée. Ne pas désactiver les sons
Atoll ni modifier `config.toml` pour reproduire ce correctif.

## v0.18.2 publiée — réglages réorganisés

Mehdi a demandé la fusion et la release le 11 septembre. La
[PR #4](https://github.com/mehdi7129/atoll/pull/4) est **fusionnée** sur `main`
(`9e93bb3`), depuis le code vérifié `e50e269` de `codex/settings-ux`.
La **[v0.18.2, build 37](https://github.com/mehdi7129/atoll/releases/tag/v0.18.2)**
est publiée depuis `66aaba4`, sans changement du code testé. Le flux Sparkle
servi propose le build 37 ; les fichiers publics et leurs signatures sont vérifiés.

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

Lors de cette release, l’app stable était **v0.18.1, build 36**. Ses fichiers, les deux builds Debug
et les huit configurations personnelles contrôlées sont identiques avant/après
cette release ; la publication n'a installé aucune app.

## État de livraison

| Élément | État vérifié |
|---|---|
| Version publiée | **[v0.18.3, build 38](https://github.com/mehdi7129/atoll/releases/tag/v0.18.3)** |
| Fusion / source | [PR #5](https://github.com/mehdi7129/atoll/pull/5) fusionnée (`8b7e9a9`) ; tag sur `d438b8e` ; fusion et publication demandées par Mehdi |
| Distribution | Universelle arm64 / x86_64 ; app et DMG signés Developer ID, notarisés, staplés et acceptés par Gatekeeper |
| Mise à jour | Sept fichiers publiés ; activation et vérification de l’appcast en cours, après validation des téléchargements |
| Référence précédente | v0.18.2, build 37 ; [preuves de sa livraison](releases/0.18.2.json) |
| Tests fonctionnels | Code `30847d6` : 1 083 tests Core, 1 skip opt-in, 0 échec ; dernier lot de 184 parcours runtime et sept sabotages détectés ; Debug/Release réussis. Code inchangé ; distribution signée reconstruite et vérifiée |
| Recettes | PR #5 : mesures Codex réelles du 22 septembre archivées ; reprises exercées avec CLI factices et états de crash reconstitués. Aucune nouvelle génération pour publier. Interface inchangée ; limites ci-dessous conservées |
| Installation de travail | `~/Applications/Atoll.app` **v0.18.2, build 37**, observée le 23 septembre avant préparation ; la publication ne l’installe pas automatiquement |

Vérifier l'état réel avant toute action : `git status --short --branch`,
`git log -5 --oneline`, `git worktree list`, puis `gh release view`.
Une source publiée et une app installée peuvent avoir des versions différentes.
Le [relevé de livraison](releases/0.18.3.json) conserve les commits, identifiants
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
