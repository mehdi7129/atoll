# HANDOFF — reprendre Atoll

État du **10 septembre 2026**. Fiche courante ; les règles détaillées restent dans
[CLAUDE.md](../CLAUDE.md). L'[ancien handoff](HANDOFF-2026-09-10-archive.md) conserve
les mesures et pièges historiques, sans faire autorité sur l'état actuel.

## État de livraison

| Élément | État vérifié |
|---|---|
| Version du code | **v0.18.0, build 35** ; publication en préparation |
| Fusion / release | Mehdi les a autorisées après lecture des deux limites de recette ci-dessous ; PR #2 en cours de finalisation |
| Référence précédente | v0.17.2, build 34 ; `main` avant PR #2 : `1b08ebd` |
| Tests fonctionnels | 1 014 tests Core, 1 skip live opt-in, 0 échec ; 60 scénarios runtime |
| Recettes | Codex authentifié : autoriser, refuser, rendre la décision au CLI, interrompre/reprendre ; VoiceOver natif, sons entendus, 24 variantes et quatre films relus |
| Installation de travail | `~/Applications/Atoll.app` v0.17.2 au dernier contrôle ; elle n'est pas remplacée par la procédure de release |

Vérifier l'état réel avant toute action : `git status --short --branch`,
`git log -5 --oneline`, `git worktree list`, puis `gh release view`.
Une source publiée et une app installée peuvent avoir des versions différentes.

## Ce qui est livré dans le code

- Atoll suit **Codex CLI dans le terminal**, Claude Code, ou les deux. Le bouton
  choisit les sessions affichées, la palette et le quota. Les deux collecteurs
  restent actifs ; une carte garde son fournisseur jusqu'à sa résolution.
- Le moteur des trois analyses et la destination des skills sont deux choix
  distincts du bouton d'affichage. Apprentissage et failover sont opt-in.
- Îlot invisible sans activité ni Rockstar ; liste bornée avec « +N autres » ;
  sélecteur compact cliquable ; Rockstar exclusivement Claude, marqueur et quota
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

La fusion et la publication sont autorisées malgré les deux recettes différées.
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

## Références utiles

- [Validation finale, preuves et P3](REVIEW-2026-09-10-skills-validation.md)
- [Plan skills et seconde analyse](PLAN-2026-09-10-final-validation-skills.md)
- [Corrections R01–R11](REVIEW-2026-09-10-pr2-corrections.md)
- [Contrat Codex / Claude](CODEX-INTEGRATION.md), [analyses et passation](CODEX-FAILOVER.md)
- [Vision produit](VISION-2026-08.md) : soustraire avant d'ajouter

Le rendez-vous du recall est **clos et tranché depuis le 9 septembre**. Ne pas
reprendre les anciennes mentions « décision en attente » : mesures et choix
sont conservés dans `CLAUDE.md` et l'archive historique.
