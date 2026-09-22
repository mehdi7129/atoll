# Apprentissage — corrections et validation du rendement

22 septembre 2026 · mise en œuvre du [plan d’audit du 11 septembre](AUDIT-2026-09-11-learning-efficiency.md),
pour la PR #5. Mehdi a autorisé corrections et validation, sans fusion ni release.
Ce rapport décrit le changement en préparation, pas une version publiée.

Le bilan conserve sa sortie avant d’écrire les artefacts et reprend une livraison
incomplète sans rappeler le modèle. Les automatismes évitent la matière inchangée ;
les journaux distinguent usage natif, écritures confirmées et données inconnues.
Les plafonds de génération et le budget commun par abonnement ne sont pas relevés.

## Comportements corrigés

| Constat | Comportement du changement |
|---|---|
| **E1 — faux succès après erreur disque** | `RetrospectiveDelivery` conserve le rapport validé et sa progression. Le runner compte les notes/propositions réellement écrites ; une panne partielle conserve son échec et le résultat récupérable. La reprise vérifie les artefacts existants et persiste le reçu avant d’effacer le checkpoint. |
| **E2 — digest identique repassé au modèle** | Une empreinte versionnée distingue matière, origine et destination. La croissance du JSONL filtrée par le parseur ne suffit plus : `skip(unchangedMaterial)` intervient avant le spawn. Les sorties du dernier bilan, le modèle ou le seul catalogue ne rendent pas automatiquement la matière nouvelle. |
| **E3 — rangement répété après annulation ou sans changement** | L’annulation après spawn persiste la cadence avant le signal d’arrêt. Avant spawn, le report court reste distinct d’une dépense. L’automatisme compare le corpus exact avec celui enregistré **après** le dernier swap réussi ; le geste manuel garde son intention explicite. Les archives créées dans la même seconde restent distinctes. |
| **E4 — antériorité incomplète des skills** | Le catalogue Claude lit les skills de projet du cwd à la racine Git, worktrees compris, avec précédences déterministes. Propositions, décisions et installations alimentent une antériorité compacte par fournisseur/home. Un refus ne bannit pas une procédure dont le contenu a changé. |
| **E5 — consommation non mesurable** | Le journal commun conserve durée terminée, caractères du prompt complet, usage natif disponible et sorties confirmées. Les anciens records restent lisibles. Un retour stdout tardif peut compléter la mesure sans rouvrir l’issue ni le budget. La reprise charge le journal avant d’enrichir un reçu existant. |
| **E6 — preuves finales coupées** | Le digest sépare fragments raccourcis encore présents, entrées élaguées et limite de lecture source. Les longs fragments assistant/summary gardent tête et fin sous le même cap. Commandes et résultats restent contigus ; une commande coupée porte `command=incomplete`. |
| **E7 — doublons et antériorité volumineuse** | Notes et propositions identiques sont reconnues malgré un slug différent. L’identité des notes inclut catégorie et projet ; celle des skills conserve le contenu utile hors front matter. Résumés et listes injectés sont bornés. Le rangement conserve son refus explicite au-delà de 80 000 caractères. |

Les principaux points d’appel sont `RetrospectiveRunner`, `NotesCurationService`,
`AnalysisBudget` et la recherche IA de `PluginInventory`. Le démarrage d’Atoll
branche la reprise locale ; aucun service distant ni dashboard n’est ajouté.

## Reprise et limites de persistance

Les checkpoints de `learning/deliveries-v1` sont bornés à 16 résultats et
256 Kio par fichier. Le plafond bloque une nouvelle dépense, sans supprimer
les sorties en attente. Un fichier étranger, un lien symbolique ou une
destination différente ne sont pas écrasés ou redirigés.

Après correction d’un obstacle disque, la reprise intervient au démarrage et
avant une nouvelle analyse, avec l’apprentissage activé, les services disponibles
et la destination inchangée. Une session ayant encore une livraison en attente
ne doit pas repayer ce résultat. Si le disque empêche aussi la sauvegarde initiale,
la récupération n’est pas garantie : l’échec reste visible.

La relecture a ajouté une provenance unique et un marqueur persisté avant chaque
installation. Si l’utilisateur a entre-temps approuvé/rejeté le skill ou rangé la
note, les archives permettent de reconnaître cette livraison sans la recréer.
Si une écriture a commencé mais que sa preuve est introuvable (archive purgée,
lecture impossible ou ancien checkpoint ambigu), le résultat reste en attente.
Les reprises indépendantes continuent malgré un reçu bloqué ; les progrès partiels
actualisent leurs compteurs sans marquer la session traitée.

La cadence de curation et la dépense sont séparées. Une écriture impossible de
`curation.json` ne peut garantir sa cadence sur disque ; le budget commun conserve
son propre reçu de lancement. Les états anciens et empreintes malformées ne
réinitialisent pas les dates ni les opt-ins.

**Défaut trouvé par l’intégration de la reprise :** sur une instance neuve,
`updateMetrics` cherchait dans une liste encore vide et perdait les compteurs de
livraison récupérée. Les deux entrées d’enrichissement chargent désormais le journal
avant de chercher l’identifiant. Les tests exercent des instances froides distinctes
pour compteurs et usage, ainsi qu’un journal corrompu préservé sans écriture.

## Mesures communes

Les tokens viennent exclusivement de l’enveloppe Claude `result.usage` ou de
l’événement Codex `turn.completed.usage`. Le dernier snapshot remplace le précédent ;
il n’est pas additionné aux messages, à `modelUsage` ou à un autre total cumulé.
Entrée, sortie, cache et raisonnement restent distincts : le cache lu est inclus
dans l’entrée Codex et séparé côté Claude. Aucun coût ou token n’est déduit de
la taille du prompt.

`codex exec --json` est confirmé par l’aide locale **0.155.1** et la
[documentation officielle](https://developers.openai.com/codex/noninteractive).
Les fixtures couvrent absences, zéros mesurés, valeurs invalides, snapshots répétés,
erreurs et interruptions. Un stdout dépassant 4 Mio rend l’usage inconnu ; un
dernier tour incomplet empêche de présenter un ancien snapshot comme complet.

`durationSeconds` va de la réservation à la clôture, préparation comprise. Après
crash, l’instant de fin inconnu n’est pas remplacé par celui du redémarrage.
`promptCharacters` compte système et utilisateur fournis par Atoll, sans prétendre
mesurer une surcharge native du CLI. Aucun texte de prompt ou de réponse n’entre
dans les nouvelles métriques.

`fragmentsShortened` compte les fragments raccourcis **gardés dans le rendu final** ;
`entriesDropped` compte les entrées retirées faute de budget. `sourceReadStopped`
reste indépendant et absent si le lecteur n’est pas instrumenté. L’ancien
`truncated` garde son sens : perte d’entrées entières. Le lecteur signale une borne atteinte, y compris à la fin exacte du fichier : ce
signal conservateur ne prouve pas à lui seul qu’un octet manque. Ces champs ne mesurent pas
les éventuelles coupes réalisées en amont par les parseurs ou les CLI.

## Benchmark du digest, sans génération

Le [harness comparatif](../Scripts/test-learning-digest.py) compile la production
et une copie reproduisant sa coupe initiale par préfixe. Les budgets restent
**150 000 caractères au total et 2 000 par fragment**. Neuf fixtures annotées
couvrent routine, antériorité, piège vérifié, correction finale, résumé de compaction,
commande longue, reprise, succès inconnu et élagage avec lecture arrêtée.
Les [résultats JSON archivés](audit-support/2026-09-22-learning-efficiency/digest-results.json)
conservent les mesures et extraits attendus de chaque fixture.

| Mesure sur les fixtures | Préfixe initial | Tête+fin ciblée et coupes signalées |
|---|---:|---:|
| Extraits attendus conservés | 10 sur 12 | 12 sur 12 |
| Caractères rendus | 6 651 | 6 706 |

Les deux extraits récupérés sont les conclusions finales des longs fragments
assistant/summary. Les 55 caractères supplémentaires incluent les étiquettes
de coupure. La commande longue reste incomplète et signalée ; elle n’est pas
reconstruite en collant des morceaux éloignés.

« Aucun skill attendu » est une annotation du corpus, pas une réponse de modèle.
Le benchmark ne mesure ni tokens économisés, ni qualité de génération, ni temps
humain de revue, ni réutilisation future d’un skill accepté ou installé.

## Validation

Ces ensembles ciblés peuvent se recouvrir ; leurs comptes ne s’additionnent pas
en un total de tests distincts.

| Ensemble | Résultat établi |
|---|---|
| Usage et digest | **44 tests Core**, zéro échec : 15 tests d’usage, 21 tests historiques du digest, 8 nouveaux tests de preuves |
| Journal commun | **23 parcours**, zéro échec : deux moteurs, trois consommateurs, succès/échec/annulation, retours tardifs et froids, compteurs, quatre états legacy et journal corrompu |
| Curation | **4 tests Core et 26 parcours service/budget**, zéro échec ; annulation, redémarrage, corpus après swap, geste manuel, état ancien, archives et panne disque |
| Catalogue, nouveauté et livraison | **77 tests Core ciblés**, zéro échec : 56 catalogue, 8 nouveauté, 13 livraison ; archives réelles et respect des décisions humaines inclus |
| Sabotages ciblés | **34 au total** : 14 métriques/digest, 4 curation, 7 catalogue/nouveauté/livraison, 9 runner : compilation réussie puis assertion attendue en échec |
| Runtime historique | **60 parcours verts sur les sources finales** |
| Livraison, reprise et matière inchangée | **26 scénarios et 9 sabotages verts sur les sources finales**, avec CLI fictifs Claude et Codex |
| Suite Core complète, Debug et Release | **1 070 tests Core, 1 skip opt-in, zéro échec** ; builds **Debug et Release réussis** après installation du composant Metal. |

Les harnesses emploient des racines temporaires, le vrai code métier et des CLI
fictifs. Les routes arrêt/changement de home de curation sont extraites des vrais
appelants puis exercées sur le service ; ce n’est pas une recette de fermeture GUI.
Les signaux simulés permettent le retour tardif après annulation. Aucun CLI
génératif authentifié ni produit Atoll n’a été lancé pour ces mesures ; aucun
événement d’usage d’un nouveau run réel n’a donc été capturé pendant ce lot.

Les descendants de projet non parcourus et les ajouts dynamiques `--add-dir` ne
sont pas déduits du disque par le catalogue Claude. La déduplication est exacte,
pas sémantique : elle préserve les espaces internes et ne fusionne pas des souvenirs
exprimés autrement. Les décisions restent dans leurs métadonnées de revue ;
l’usage des skills Codex n’est pas mesuré.

## Rejouer

Des fichiers iCloud `dataless` ont bloqué les lectures des compilateurs. Un scratch
externe seul ne suffit pas : les **sources aussi** doivent être locales, hors iCloud.
La recette utilise un clone sous `/private/tmp`, complété par les fichiers du
changement. Sous **Xcode 27.0, build 27A266a**, SwiftPM choisit `swiftbuild` par défaut ; les commandes
suivantes fixent `native` pour le layout attendu par les harnesses. Ce moteur
reste accepté, avec un avertissement de dépréciation.

Depuis cette copie locale :

```sh
swift test --package-path AtollCore --build-system native --jobs 4
python3 Scripts/test-runtime.py
python3 Scripts/test-learning-retrospective.py
python3 Scripts/test-learning-core.py --all
python3 Scripts/test-curation.py --build-system native
python3 Scripts/test-learning-metrics.py --scratch-path /private/tmp/atoll-metrics-check
python3 Scripts/test-learning-digest.py --output /private/tmp/atoll-digest-check.json
python3 Scripts/check-docs.py --no-tests
```

Rétrospective et métriques fixent elles-mêmes le moteur natif dans leurs scripts.
Le benchmark du digest compile directement deux sources Core. Les builds d’app
suivent [HANDOFF](HANDOFF.md), avec DerivedData hors du Bureau ; ne pas lancer
le produit de build ni remplacer l’app stable.

Les sabotages prennent un nom à la fois avec `--sabotage` :

| Script | Noms |
|---|---|
| `Scripts/test-learning-core.py` | `project-scope`, `proposal-identity`, `note-dedup`, `incomplete-history`, `delivery-archives`, `delivery-intent`, `delivery-provenance` |
| `Scripts/test-learning-metrics.py` | `unknown`, `duration`, `late-usage`, `writes`, `cache`, `latest`, `json`, `cold-metrics`, `cold-usage` |
| `Scripts/test-learning-digest.py` | `head-only`, `command-marker`, `shortened-count`, `dropped-count`, `read-stop` |
| `Scripts/test-curation.py` | `cancellation`, `unchanged`, `post-write`, `archive-uniqueness` |
| `Scripts/test-learning-retrospective.py` | `checkpoint`, `counts`, `material`, `dedup`, `recovery-progress`, `recovery-independent`, `reader`, `usage`, `digest-metrics` |

Le script Core compile des bundles XCTest temporaires : sa baseline vérifie les
mêmes scénarios avant les mutations. Tous les sabotages doivent compiler puis
échouer sur l’assertion témoin ; un timeout ou un fichier iCloud indisponible ne
valide jamais un sabotage. Les warnings restants sont la dépréciation du moteur
SwiftPM `native` et l’extraction AppIntents ignorée faute de dépendance, sans
échec de build.
