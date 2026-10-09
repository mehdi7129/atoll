# Plugins — A09, A12, A13, A14 et A20

Correctifs préparés le 8 octobre 2026 depuis l'intégration des PR #14 et #15
(`5cddb8b`). La primitive de processus est celle du lot A09 (`cbb97e1`).
Complément du 9 octobre : propriété des enfants encore vivants et attentes de catalogue.
Ce document décrit une validation locale ; aucune publication ou installation.

## Comportement corrigé

- **A12** : le bouton Annuler arrête la recherche et la lecture de catalogue
  qu'elle a demandée. Une installation, activation ou estimation indépendante
  continue. L'arrêt global de l'app annule aussi les lectures en attente.
  Le registre conserve l'identité capturée au lancement de chaque enfant.
- **A13** : les estimations passent par une file FIFO, limitée à **deux lectures**
  simultanées et une seule par identifiant. Le fallback id complet → nom court
  reste dans le même emplacement de la file. Les résultats arrivent au fil des
  lectures ; un échec local ne bloque pas les autres plugins.
- **A14** : le cache dépend de la version, du marketplace, du chemin installé
  et du scope. Un inventaire inchangé conserve ses coûts ; un changement ou une
  disparition invalide seulement les entrées concernées. Une ancienne réponse
  ne publie pas son coût dans le nouvel inventaire.
- **A20** : le catalogue Codex possède un état observable commun aux rendus,
  avec une génération par chargement et un contexte projet/binaire/home.
  Changer ce contexte retire le catalogue chargé et invalide les réponses en
  vol, succès comme erreurs. Le home effectif est publié explicitement après
  application du choix utilisateur. Aucun chargement supplémentaire automatique.
- **A09, consommateur plugins** : l'exécution utilise `BoundedProcessRunner`.
  Le délai couvre résolution, processus et collecte ; les deux flux sont lus
  sans attente EOF illimitée. La sortie trop volumineuse ou dont la collecte
  dépasse la borne ne devient pas un inventaire réussi. Si l'enfant survit
  faute d'identité vérifiable, son registre/PID, budget, workspace et place
  restent réservés jusqu'à sa sortie réelle. Cela conserve la sérialisation
  des mutations et la borne des lectures de coût ; aucun fallback ne part
  pendant que le premier essai vit encore. Un contrôle local à 100 ms libère
  ces seules réservations après sortie, sans nouveau signal ni relance.
  Recherche et mutation rendent une erreur bornée si elles attendent un autre
  inventaire resté vivant ; cette lecture conserve sa propre réservation.

Les commandes, profils de lecture, budgets d'analyse, confirmations, libellés,
ordre des lignes et gestes utilisateur sont conservés. Les lectures de coût ne
partent pas au simple accès à l'état ; elles restent demandées par le bouton.

## Mesures et régressions

`Scripts/test-plugin-services.py` compile les vrais `PluginInventory` et
`CodexCatalogState`, liés au vrai Core. Les collaborateurs d'app et d'analyse
sont contrôlés ; les processus de plugin sont de vrais enfants exécutant une
fixture privée. Aucun compte, app, préférence ou CLI authentifié n'est utilisé.

La recette finale passe **145 assertions** :

| Scénario | Résultat |
|---|---|
| 30 plugins, borne 1 | 32 commandes, maximum 1 enfant, 4,85 s |
| 30 plugins, borne 2 | 32 commandes, maximum 2 enfants, 2,58 s |
| Identifiant redemandé, échec local, fallback | Déduplication, 29 coûts valides, autres lignes conservées |
| Annulation recherche + installation simultanée | Recherche arrêtée, installation terminée |
| Fermeture globale | Les deux commandes arrêtées, file de coûts vidée |
| Version/source/disparition | Invalidation ciblée, réponse ancienne refusée |
| Catalogue projet/binaire/home | Réponses tardives et erreurs rejetées ; état courant conservé |
| Home changé après chargement | Ancien catalogue retiré, aucun nouvel appel |
| Parent sorti, descendant tenant les pipes 3 s | Retour en 0,40 s, résultat non déclaré réussi |
| Recherche survivante, identité indisponible | Budget, PID et workspace conservés ; second appel refusé ; libération après sortie |
| Mutation survivante, identité indisponible | Verrou conservé ; aucune seconde installation simultanée |
| Détail survivant, identité indisponible | Aucun fallback simultané ; place conservée et file reprise après sortie |
| Recherche/mutation attendant un inventaire survivant | Retour en moins de 1,5 s avec délai de fixture 0,3 s ; PID conservé, aucune relance |

La borne 2 réduit ici le temps du lot d'environ 47 %, en gardant une limite
explicite. Ces chiffres qualifient la fixture, pas le CPU ou la RAM des plugins
installés chez un utilisateur.

**Douze sabotages compilés sont en cours de vérification**, après le nominal
final réussi. Les dix premiers avaient été détectés sur la variante précédant
les deux bornes d’attente de catalogue. La campagne finale couvre : annulation
globale depuis la recherche ; concurrence à 30 ; cache non invalidé ; ancienne
version acceptée ; ancien catalogue accepté ; changement de home ignoré ;
drain EOF illimité réintroduit ; retrait prématuré du registre ; libération
prématurée des réservations ; fallback lancé sur enfant vivant ; attente de
catalogue non bornée côté recherche puis mutation. Une compilation ratée ou
une erreur différente ne valide jamais un sabotage. La dernière compilation
nominale est sans warning.

Les cinq scénarios d'enfant survivant raccourcissent uniquement les deadlines
et le délai de grâce dans une copie compilée du service, pour finir rapidement.
Les processus, le registre, les gardes de réentrance et la file sont réels ;
le budget et les collaborateurs d'app restent contrôlés. Les délais produit
ne sont pas modifiés. L'identité volontairement indisponible interdit tout
signal : la fixture finit seule après trois secondes.

```sh
python3 Scripts/test-plugin-services.py \
  --core-build /private/tmp/atoll-plugin-core \
  --output /private/tmp/atoll-plugin-proof --sabotage
```

Les builds d'app, la suite Core complète, les harnesses transverses et les
captures d'interface relèvent de la validation d'intégration. Les scénarios A20
ci-dessus exercent le vrai modèle de chargement ; ils ne constituent pas une
recette des interactions SwiftUI projet/home/binaire.

## Périmètre relu

`App/PluginInventory.swift`, `App/CodexCatalogState.swift` et
`App/CodexCatalogSection.swift` ont été relus en entier. Les consommateurs
`ClaudeCodeSettingsPane` et `CodexSettingsPane` ont une lecture ciblée sur
l'annulation et la propagation du home. La primitive partagée est validée par
le lot processus ; son code n'est pas dupliqué dans le service plugins.
