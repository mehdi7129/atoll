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
| `standard` (défaut) | Core, runtimes d'apprentissage et de plugins, mémoire, processus, feedback, quotas, cycle du helper, préparation Codex/générateur, cinq contre-épreuves du verdict Codex, nettoyage de release simulé, documentation |
| `full` | Standard, variantes nommées des harnesses de services et campagnes de sabotage autonomes Core/hooks/mémoire, avec sabotages intégrés des plugins, du feedback, de stdout Codex et de l'installation |

Les variantes nommées sont bloquées si leur nominal échoue. Les campagnes
autonomes conservent aussi leur propre nominal obligatoire. Une compilation
ratée n'est jamais une régression détectée. Ce profil long reste explicite ;
la CI utilise `standard`. Les scripts conservent leurs commandes individuelles
pour rejouer une contre-épreuve utile au changement.

```sh
python3 Scripts/validate-offline.py --profile core
python3 Scripts/validate-offline.py --profile full --list
python3 Scripts/validate-offline.py --only runtime skill-review
python3 Scripts/validate-offline.py --only offline-validation release-trash
```

`--list` décrit les commandes sans exécution. `--only` conserve la dépendance
Core lorsqu'elle est nécessaire ; le rapport porte alors `scope: selected`.
Un nom inconnu est refusé. Le test du plan exige que chaque harness du dépôt
soit classé, pour qu'un nouveau script ne soit pas oublié silencieusement.

L'étape documentaire utilise `check-docs.py --no-tests --preflight` dans tous
les profils : elle valide les sources pendant qu'une release peut encore
conserver l'ancien appcast public. Seule l'égalité entre la version préparée
et la première entrée du flux est différée ; les autres contrôles restent
actifs, notamment les tags des URL présentes dans l'appcast. Ce résultat ne
qualifie pas une distribution. Après packaging, exécuter le contrôle
strict `check-docs.py --no-tests`, puis les [vérifications des artefacts et
octets publics](RELEASE-VALIDATION.md). Après publication du flux, exécuter
`check-docs.py --no-tests --network`. Les assets précèdent toujours l'appcast ;
aucun contrôle réseau ni accès authentifié n'est ajouté à la CI offline.

## Périmètres conservés séparément

- `test-codex-catalog.py` et `test-codex-read-storage.py` nécessitent un vrai
  binaire Codex. Ils restent des recettes natives explicites.
- `test-ui.py`, `test-ui-refresh.py`, `test-ui-sabotage.py`, `test-settings-sabotage.py` et
  `test-voiceover.py` ouvrent un aperçu protégé ou demandent VoiceOver. Leurs
  captures et interactions se vérifient séparément.
- Les modes `--live` de `test-codex-exec.py` et `test-skill-generation.py` ne
  sont jamais utilisés ici. Les modes de préparation compilent les vrais
  adaptateurs et utilisent uniquement des fixtures privées.

La commande retire aussi l'opt-in du test Core authentifié et les variables
de clés API du processus enfant. Elle n'installe aucune app, ne lit ni ne copie
aucune authentification et ne publie rien. Les recettes du helper vérifient
leurs racines Foundation privées avant toute écriture. Les sons de feedback
ne sont pas joués. Ces preuves ne remplacent pas une recette GUI, un compte
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
