# Mémoire : documents à jour et lectures reprises

Lot A04/A05/A18 de l'audit du 8 octobre. Aucun nouveau réglage, aucune cadence
modifiée : scan existant de 30 secondes, nudges et plafond Codex conservés.
Ce rapport décrit des corrections de code et leur validation locale ; il ne
constitue pas une preuve de publication ou d'installation.

## Corrections

- **A04** : les notes et mémoires Markdown passent par un remplacement SQLite
  transactionnel du document complet. Une réécriture au même inode, à la même
  taille et au même mtime remplace bien les fragments. Une lecture réussie vide
  ou composée de whitespace les retire ; un refus de lecture les conserve.
  La comparaison des fragments persistés évite les réécritures inchangées,
  y compris après réouverture. Aucun changement de version du schéma et aucune
  reconstruction de la base existante.
- **A05** : le `cwd` de la dernière ligne terminée par newline est conservé.
  Le fragment incomplet reste exclu, avec la même limite de lecture de 256 Kio
  et le même fallback entre transcripts frères.
- **A18** : une erreur d'ouverture, seek ou read n'acquitte pas `lastSeen`.
  La prochaine passe ou le prochain nudge retente aux mêmes métadonnées.
  Une rotation n'est enregistrée qu'après une première lecture réussie ; les
  erreurs antérieures préservent ainsi l'ancienne version et son offset.
  Après une erreur tardive, seuls les lots transactionnellement validés restent
  acquis, et la reprise repart de leur offset.

La validation a aussi reproduit un défaut adjacent de reprise JSONL : le
splitter avait déjà avancé à la fin du bloc de 4 Mio alors que seul un premier
lot de 500 lignes était validé. Une panne au lot suivant faisait sauter le reste.
L'offset est maintenant borné à la dernière ligne effectivement traitée au
moment de chaque flush. La déduplication existante reste inchangée.

## Vérification

- **37 tests Core ciblés**, zéro échec : 31 tests historiques `MemoryIndexTests`
  et six tests `MemoryDocumentTests` (remplacement, vide, rollback, stabilité
  des identités et récupération du projet).
- **40 scénarios runtime** avec le véritable worker et SQLite : notes et
  mémoires, taille égale/croissance/réduction/rotation, mtime inchangé,
  documents vides et whitespace, UTF-8 invalide, transaction refusée puis
  reprise, frontière de 256 Kio, scan/nudge après refus IO, rotation avec refus,
  erreur après un premier bloc et transaction après un premier lot.
- **Neuf sabotages compilés détectés**, chaque campagne précédée de son
  nominal vert : ancien saut Markdown, guard du document vide, perte de la
  dernière ligne `cwd`, faux acquittement open/seek/read, offset anticipé du
  bloc JSONL, suppression hors transaction et réécriture du document inchangé.
- La suppression réelle d'un transcript conserve ses messages avec
  `missing=1`. Une dernière ligne JSONL incomplète attend toujours son newline.
- `git diff --check` et `Scripts/check-docs.py --no-tests` réussis.

Commandes reproductibles :

```sh
swift test --package-path AtollCore --build-system native --filter 'Memory(Index|Document)Tests'
python3 Scripts/test-memory-indexer.py
python3 Scripts/test-memory-indexer.py --sabotage batch-offset
python3 Scripts/test-memory-document-sabotage.py
```

Le harness accepte `--build-dir` pour réutiliser les objets Core déjà compilés.
Les sources produit ne sont jamais modifiées par les sabotages : les copies,
la compilation et les homes restent privés. L'ouverture est refusée réellement
par les permissions du fichier ; les exceptions seek/read sont injectées dans
une couture du harness qui appelle les `FileHandle` réels le reste du temps.
Le home Foundation et le home Codex sont vérifiés avant toute fixture.

## Limites

Aucun CLI authentifié, modèle, app graphique ou réglage personnel n'est utilisé.
Les builds app et la suite Core complète sont à refaire sur l'arbre intégré,
puisque les autres lots de l'audit évoluent séparément. Ces tests qualifient le
contrôle de flux et les transactions, pas les incidents matériels d'un disque
ou la cohérence d'un fournisseur de fichiers cloud pendant une écriture externe.
