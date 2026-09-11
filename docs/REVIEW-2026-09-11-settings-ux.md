# Réglages Atoll — recette et seconde lecture

> Historique de la première simplification. L'organisation validée ensuite est
> décrite dans le [plan des huit onglets](PLAN-2026-09-11-settings-organization.md)
> et sa [recette](REVIEW-2026-09-11-settings-organization.md).


11 septembre 2026 · branche `codex/settings-ux`, base `a961c10`.
Retouches demandées par Mehdi, en préparation ; aucune release dans ce lot.
[Plan et arbitrages](PLAN-2026-09-11-settings-ux.md).

## Résultat

- Connexion Codex : état en premier, instructions d'approbation lorsque le
  premier événement manque. Projet et diagnostic repliés ; chemins et réparation
  sous « Dépannage ». Le catalogue garde son propre choix de projet accessible.
- Modèle d'analyse : visible lorsque Codex est le moteur ou le repli autorisé,
  catalogue lu automatiquement, sélection explicite partagée entre les deux
  onglets. Aucun remplacement silencieux après une erreur ou un modèle retiré.
- Apprentissage : limites avancées et journal repliés, modèles Claude seulement
  lorsqu'ils sont pertinents. Textes courts, aides regroupées et interlignage
  régulier dans Général, Claude Code, Codex et Apprentissage.
- Les lignes des volets repliables sont entièrement cliquables. Le rôle natif
  `AXDisclosureTriangle` et son état fermé/ouvert restent exposés.

## Vérifications

| Contrôle | Résultat |
|---|---|
| Build Debug | Réussi ; seul avertissement Xcode AppIntents sans dépendance, déjà présent |
| AtollCore | 1 020 tests, 1 ignoré live opt-in, 0 échec |
| Rendu et interactions | 21 parcours UI avec OCR et arbre d'accessibilité ; captures relues |
| Configuration personnelle | Empreintes identiques avant/après : préférences Atoll, hooks Claude/Codex, `config.toml`, sélection de home et lanceur Codex |
| Ancien panneau v0.18.1 | Test en échec : modèle caché, projet et diagnostic visibles par défaut |
| Premier prototype | Test en échec : action AX sur le libellé du volet sans ouverture effective |
| Mutant compilé | Test en échec : sélection automatique du premier modèle à la lecture du catalogue |

Les parcours couvrent attente/connexion, diagnostic après clic, installation
absente et retrait simulé, quota désactivé, modèle absent/existant/retiré,
catalogue indisponible, sélection d'un modèle et passage vers Apprentissage,
bascule Claude → Codex conservant le modèle, options avancées, thème clair,
largeur 640 pt et fenêtre courte. Les assertions vérifient aussi les contrôles
qui doivent rester cachés et les préférences qui ne doivent pas changer.

Les trois volets Général, Claude et Apprentissage complet sont des recettes de
**rendu avec commandes désactivées**. Le composant Analyses et le panneau Codex
sont interactifs sur des préférences privées ; leurs appels externes sont
simulés. Les modèles des captures sont fictifs. Cette recette ne prétend pas
revalider la génération authentifiée ni les phrases prononcées par VoiceOver.

## Relecture des changements

Balayage ciblé du diff des sept fichiers App modifiés ou créés, des scénarios UI
et du sabotage ; il ne s'agit pas d'un nouvel audit complet des services.

1. Le choix du modèle ne doit pas être demandé lorsque seul Claude sert aux
   analyses. Le sélecteur reste visible en cas de repli Codex autorisé.
2. Les résultats de catalogue sont bornés par le client existant et rejetés
   si la requête est annulée, remplacée, ou si le home/exécutable a changé.
   L'exécution d'une analyse garde sa revalidation native, inchangée.
3. Après retrait de l'intégration, un événement ancien ne doit pas laisser
   l'interface annoncer qu'elle est installée. Scénario simulé ajouté et vérifié.
4. La simplification garde les conséquences utiles : consommation du quota,
   mémoire commune et transmission des extraits au fournisseur. Le texte
   d'animation parle de l'onde, sans promettre la suppression de tous les fondus.
5. Les copies d'aperçu restent protégées sans argument. Les commandes natives
   du panneau Codex sont simulées ; les contrôles de rendu des autres volets
   sont désactivés. L'app stable et les configurations personnelles sont conservées.

## Rejouer

```sh
swift test --package-path AtollCore
python3 Scripts/test-ui.py --app /private/tmp/Atoll-settings-ux-review.app \
  --output /private/tmp/atoll-settings-check \
  --case settings-codex --case settings-codex-diagnostic \
  --case settings-codex-model-shared --case settings-analysis-options \
  --case settings-analysis-switch --case settings-codex-model-offline
python3 Scripts/test-settings-sabotage.py --output /private/tmp/atoll-settings-mutant-check
python3 Scripts/check-docs.py --no-tests
```

Le script de sabotage travaille dans une copie temporaire, exige un build réussi
et utilise les mêmes assertions que le code corrigé. Les deux autres témoins
étaient les copies protégées de v0.18.1 et du premier prototype ; les résultats
et captures sélectionnées sont conservés dans `docs/reviews/2026-09-11-settings-ux/`.

Aperçus : [Codex connecté](reviews/2026-09-11-settings-ux/settings-codex-connected.png),
[fenêtre étroite en thème clair](reviews/2026-09-11-settings-ux/settings-codex-narrow-light.png),
[diagnostic ouvert](reviews/2026-09-11-settings-ux/settings-codex-diagnostic.png),
[Apprentissage](reviews/2026-09-11-settings-ux/settings-learning.png).

Preuves : [21 parcours UI](reviews/2026-09-11-settings-ux/ui-results.json),
[validation et empreintes des sources](reviews/2026-09-11-settings-ux/validation.json),
témoins en échec attendu [ancien panneau](reviews/2026-09-11-settings-ux/sabotage-old.json),
[volet inaccessible](reviews/2026-09-11-settings-ux/sabotage-disclosure.json) et
[modèle choisi automatiquement](reviews/2026-09-11-settings-ux/sabotage-model.json).
