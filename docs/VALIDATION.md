# Validation locale et CI

La commande commune compile le Core et exerce les vrais services avec des
collaborateurs contrôlés, des CLI factices et des fichiers privés :

```sh
python3 Scripts/validate-offline.py
```

Elle demande macOS et les outils Xcode. La racine créée sous
`~/Library/Caches/AtollValidation/` contient les logs, les produits Core natifs,
les fixtures temporaires et `results.json`. Chaque étape expose sa commande,
son code de sortie et son verdict. Une étape en échec reste visible même si
les suivantes réussissent ; ses dépendants sont bloqués. La commande renvoie
0 seulement quand toutes les étapes sélectionnées passent, sinon 1.

L'option `--output` choisit une autre racine privée. Le build Core est réutilisé
par les harnesses qui l'acceptent. Les campagnes qui modifient le Core gardent
leur copie séparée. Les timeouts bornent les étapes et arrêtent uniquement leur
groupe de processus ; aucun processus n'est recherché ou arrêté par son nom.

## Profils

| Profil | Contenu |
|---|---|
| `core` | Tests Swift du Core, contre-tests du verdict commun, cohérence documentaire sans réseau |
| `standard` (défaut) | Core, générateur de skills et revue, digest/métriques, processus, quotas, cycle du helper, hooks passifs, préparation Codex/générateur, contre-épreuves du verdict Codex, nettoyage réversible de release, packaging local factice (`local-release`), documentation |
| `full` | Standard (dont `local-release`), migration essentielle, variantes nommées des services et campagnes de sabotage Core/hooks/archives/réconciliation, stdout Codex et installation |

Les variantes nommées sont bloquées si leur nominal échoue. Les campagnes
autonomes conservent aussi leur propre nominal obligatoire. Une compilation
ratée n'est jamais une régression détectée. Ce profil long reste explicite ;
la CI utilise `standard`. Les scripts conservent leurs commandes individuelles
pour rejouer une contre-épreuve utile au changement.

```sh
python3 Scripts/validate-offline.py --profile core
python3 Scripts/validate-offline.py --profile full --list
python3 Scripts/validate-offline.py --only learning-retrospective skill-review
python3 Scripts/validate-offline.py --only offline-validation release-trash
python3 Scripts/validate-offline.py --only local-release
```

`--list` décrit les commandes sans exécution. `--only` conserve la dépendance
Core lorsqu'elle est nécessaire ; le rapport porte alors `scope: selected`.
Un nom inconnu est refusé. Le test du plan exige que chaque harness du dépôt
soit classé, pour qu'un nouveau script ne soit pas oublié silencieusement.

L'étape `local-release` exécute `test-local-release.py` avec des outils factices
et des fichiers privés. Elle vérifie l'arrêt avant l'appcast, la préservation
des archives et les gardes du vérificateur local, avec sabotages ciblés. La
construction, la signature et la notarisation sont simulées ; la qualification
des artefacts d'une distribution reste séparée.

L'étape documentaire utilise `check-docs.py --no-tests --preflight` dans tous
les profils : elle valide les sources pendant qu'une release peut encore
conserver l'ancien appcast public. Une version préparée déclarée doit correspondre
au projet ; le flux peut encore annoncer la version publiée. Les autres contrôles restent
actifs, notamment les tags des URL présentes dans l'appcast. Ce résultat ne
qualifie pas une distribution. Après packaging, exécuter le contrôle
documentaire `check-docs.py --no-tests`, puis les [vérifications du paquet local
ou de la mise à jour publique](RELEASE-VALIDATION.md). Après publication du flux, exécuter
`check-docs.py --no-tests --network`. Les assets précèdent toujours l'appcast ;
aucun contrôle réseau ni accès authentifié n'est ajouté à la CI offline.

## Périmètres conservés séparément

- `test-codex-catalog.py` et `test-codex-read-storage.py` nécessitent un vrai
  binaire Codex. Ils restent des recettes natives explicites.
- `test-native-passive-hooks.py` utilise le Codex installé pour qualifier les
  définitions de hooks ou un tour passif natif coordonné. Cette recette reste
  volontairement séparée des profils offline, y compris `full` ; elle n'est
  jamais déclenchée implicitement par `local-release`.
- `test-ui.py` exerce les sessions, détails en lecture seule, connexions, revue de skills et bouton ON/OFF dans un aperçu protégé. Les captures sont à lire. `test-voiceover.py` exige VoiceOver déjà activé et autorisé ; il ne change pas ces réglages.
- Les modes `--live` de `test-codex-exec.py` et `test-skill-generation.py` ne
  sont jamais utilisés ici. Les modes de préparation compilent les vrais
  adaptateurs et utilisent uniquement des fixtures privées.

La commande retire aussi l'opt-in du test Core authentifié et les variables
de clés API du processus enfant. Elle n'installe aucune app, ne lit ni ne copie
aucune authentification et ne publie rien. Les recettes du helper vérifient
leurs racines Foundation privées avant toute écriture. Les migrations de sons ne jouent aucun fichier audio. Ces preuves ne remplacent pas une recette GUI, un compte
natif ou une qualification de release.

## GitHub Actions

`.github/workflows/validation.yml` exécute le profil standard sur les PR et
les pushes de `main`, avec un runner macOS 26 standard, sans secret ni droit
d'écriture. Les rapports et logs sont conservés 14 jours, y compris en cas
d'échec ; produits et fixtures temporaires sont exclus des artefacts.

Le workflow suit les contrats de [déclenchement GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
et de [conservation des artefacts](https://docs.github.com/en/actions/tutorials/store-and-share-data).
Sa première exécution sur GitHub reste à observer après intégration : une
vérification locale ne prouve pas la disponibilité du runner distant.

## Entretien du code

L'ancien appariement de `CodexSessionDiscovery` et ses types d'entrée n'avaient
aucun consommateur produit. Seul le DTO de session utilisé par le registre,
le scanner et l'adoption est conservé. Le prédicat de migration inutilisé est
également retiré ; les tests gardent les migrations réelles, la préservation
des personnalisations et l'idempotence de l'installation. Aucun flux utilisateur
n'est remplacé par ce nettoyage.

## Recentrage essentiel

Les anciennes recettes de cartes de permission, mémoire active, plugins,
curation, sons et autonomie ont été retirées avec leurs services. Leurs preuves
historiques restent dans [l’ancienne fiche](archive/VALIDATION-2026-10-22-before-essential.md).
Les lecteurs de journaux et de données héritées restent testés lorsqu’ils
servent au budget ou à la récupération locale.

`test-essential-migration.py --output /chemin/prive` exerce la sauvegarde,
les parkings, les données inconnues et les reprises dans une copie privée du
Core. `test-process-services.py` compile la vraie façade de migration et le
vrai installateur avec des collaborateurs contrôlés. `test-passive-hooks.py`
exerce les helpers et le serveur, y compris des anciens clients de permission.
Leurs variantes de sabotage doivent échouer après compilation, sur l’oracle
annoncé. Ne jamais compter un échec de compilation comme un mutant détecté.

La campagne finale et ses limites sont consignées dans le rapport
[IMPLEMENTATION-2026-10-22-essential.md](IMPLEMENTATION-2026-10-22-essential.md).
Une fixture de CLI ne qualifie pas un abonnement authentifié ; une capture
AX ne qualifie pas les annonces vocales de VoiceOver.
