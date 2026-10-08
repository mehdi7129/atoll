# A07/A08 — conserver les groupes de hooks

Lot de l’[audit #8](https://github.com/mehdi7129/atoll/pull/8), préparé depuis
`aed6546362e10d601820fea365aeb541c574acf6`. La branche est indépendante de la
[PR #14](https://github.com/mehdi7129/atoll/pull/14), consacrée à A02/A03.

## Défauts et comportement corrigé

**A07.** Deux hooks sonores identiques sous `Bash` et `Edit` étaient comptés
ensemble au moment de leur restitution. Remettre manuellement celui d’`Edit`
pouvait empêcher le retour de celui de `Bash`, puis faire supprimer le fichier
de parking comme si tout avait été restitué.

La restitution associe désormais les exemplaires à leur groupe d’origine.
Le contexte du groupe est conservé aussi pour les groupes mixtes : matcher,
métadonnées inconnues et hooks tiers permettent de distinguer les origines.
Les doublons légitimes, l’ordre des hooks et les restitutions manuelles
partielles sont couverts. Un fragment de parking illisible provoque un refus
explicite, permettant au caller de conserver le parking pour une reprise.
Les parkings successifs conservent la multiplicité des sons et regroupent les
nouveaux sons lorsque le contexte et la position de leur groupe concordent.
Le format Codable reste compatible avec les anciens parkings.

**A08.** L’installation ne retirait que les groupes entièrement gérés par
Atoll. Dans un groupe mixte, l’ancien hook Atoll restait à côté du hook tiers,
puis une nouvelle entrée Atoll était ajoutée.

Installation et désinstallation utilisent maintenant la même suppression des
seuls sous-hooks Atoll. Les hooks tiers, leur ordre et les métadonnées des
groupes restent présents. Une racine `hooks` présente mais mal typée est
refusée lors de l’installation au lieu d’être remplacée par une racine vide.

Le helper détecte également les doublons dans une installation déjà complète,
sinon son garde évitait d’appeler l’éditeur corrigé. Le prédicat `isInstalled`
reste inchangé, notamment pour préserver la logique du backup pré-Atoll.
Après normalisation, une nouvelle installation ne réécrit pas les settings.
Les événements inconnus ne déclenchent pas de normalisation répétée.

Le recall conserve son fonctionnement : OFF asynchrone, ON synchrone avec un
timeout de cinq secondes. `PermissionRequest` reste synchrone, timeout 86 400.
Aucun réglage, geste sonore ou écran n’est ajouté.

## Validation

- **1 119 tests Core réussis**, un test live opt-in ignoré, zéro échec.
  Le lot ajoute **27 tests** : 18 pour les sons et neuf pour les hooks mixtes.
- **12 parcours du vrai helper réussis** : réparation d’une installation déjà
  complète, conservation des tiers et du backup, recall ON/OFF, absence de
  réécriture inutile, restitution partielle, lien symbolique, refus sans perte
  des fichiers illisibles et quatre scénarios de désinstallation existants.
- **25 sabotages compilés détectés** après nominal obligatoire : 12 pour les
  sons, 12 pour les réglages de hooks et un dans le garde réel du helper.
  Un échec de compilation ne compte jamais comme détection. Deux mutants
  initialement survivants ont fait renforcer les fixtures avant la campagne
  finale entièrement verte.
- **Builds Xcode Debug et Release réussis**, sans signature ni lancement.
  App et helper Release universels arm64/x86_64 ; Debug arm64.
- Empreintes des sources contrôlées autour des validations. Les trois
  configurations personnelles, l’app installée 0.18.5/build 40 et quatre
  produits Debug habituels restent identiques.
- Relectures croisées des éditeurs, callers, tests et scripts, sans bloquant
  restant dans ce périmètre. Registre en `sweep`, sans prétention de relecture
  exhaustive des consommateurs.

Les preuves reproductibles et empreintes des sources sont dans le
[relevé de validation](audit-support/2026-10-08-a07-a08/validation.json).

```sh
swift test --package-path AtollCore --build-system native --scratch-path /tmp/atoll-a07-a08-core --jobs 4
python3 Scripts/test-sound-hook-sabotage.py --output /tmp/atoll-a07-sabotage
python3 Scripts/test-hook-settings-sabotage.py --output /tmp/atoll-a08-sabotage
python3 Scripts/test-hook-installation.py --output /tmp/atoll-hooks-integration --sabotage
python3 Scripts/check-docs.py --no-tests
git diff --check
```

## Portée et limites

Les homes du vrai helper sont privés et vérifiés par `status` avant toute
écriture de fixture. Les sons ne sont pas joués et aucun CLI authentifié n’est
appelé. Les builds ne constituent pas une recette GUI ou audio.

Les anciens parkings sans contexte de groupe restent lisibles ; ils ne
permettent pas de retrouver des métadonnées qui n’avaient jamais été
enregistrées. Si une édition externe rend les groupes indiscernables ou
modifie leur contexte, la restitution exacte de leur organisation n’est pas
garantie. Aucun verrou n’est ajouté contre un écrivain
externe entre lecture et écriture atomique.

Ce lot est préparé pour revue, sans fusion ni distribution. La version publiée
reste **0.18.5, build 40** ; le README et l’appcast conservent cette version.
