# Lectures Codex : arrêter les synchronisations de plugins inutiles

7 octobre 2026 · correctif local, sans fusion, release ni remplacement de l'app stable.

## Problème vérifié

L'affichage du quota lance un `codex app-server` à chaque lecture, puis attend
120 secondes. Sur le poste audité, deux départs étaient espacés de 122,192 secondes.
Le démarrage de Codex 0.160.1 synchronise les marketplaces configurées, même si
Atoll ne demande ensuite que `account/rateLimits/read`. Cette synchronisation
se déroule en parallèle du protocole et peut survivre à la réponse RPC.

Une fixture Git locale a reproduit des répertoires de staging abandonnés lors
de fermetures rapides, y compris après EOF et une sortie normale du serveur.
Attendre sa sortie ne suffit donc pas, à lui seul, à supprimer cette cause.
L'option temporaire `-c features.plugins=false` conserve les lectures quota et
modèles sur ce CLI et supprime les commandes Git observées dans cette fixture.

Le poste contenait 945 staging historiques, dont 870 remplis : 34,727 Go
alloués selon `st_blocks`. Leur cadence et les processus observés établissent
la contribution d'Atoll aux vérifications répétées ; ils ne permettent pas
d'attribuer chaque copie historique à Atoll. Le cache installé des plugins
est distinct de ces répertoires de travail abandonnés.

## Correction

- `CodexReadClient` ajoute l'override de plugins uniquement pour `.quota` et
  `.models`. Les inventaires hooks, skills et plugins conservent leur profil.
  Le fichier personnel `config.toml` n'est jamais écrit.
- Une requête déjà annulée est rejetée avant lancement et avant initialisation.
  L'arrêt commence par EOF, puis accorde trois délais bornés de 0,5 seconde :
  sortie normale, TERM, puis KILL si l'enfant identifié reste vivant.
- `CodexService` attend la fin du worker précédent avant une nouvelle lecture.
  La chaîne est conservée lors d'un arrêt ou d'une désactivation du quota ;
  les réponses d'un ancien compte, home ou exécutable restent ignorées.

La cadence de 120 secondes est conservée. Ce lot traite le travail annexe
et le chevauchement des lectures ; il n'ajoute pas de serveur persistant.
Une lecture authentifiée additionnelle prend 0,784 seconde, dont 0,111 seconde
de CPU cumulé pour le harness et ses enfants récoltés, hors compilation.
Cette mesure ponctuelle ne justifie pas une connexion persistante ; elle
ne constitue pas un benchmark de batterie ou de mémoire.
L'option d'affichage du quota a été désactivée sur l'app stable pendant
l'intervention. Le correctif source n'est pas installé dans cette app.

## Validation et relecture

- 1 089 tests Core, un skip opt-in, aucun échec.
- Huit scénarios du poller extrait des méthodes de production, avec transport
  contrôlé : désactivation, annulation avant lancement, changements rapides,
  réponse périmée, arrêt/reprise et file de relances annulées.
- Dix sabotages compilés détectés par les tests du transport : profils quota,
  modèles et inventaires, gardes d'annulation, EOF, TERM, KILL et délai d'arrêt.
  Cinq autres sabotages détectés par le harness du poller.
- 60 parcours runtime existants passent, sans génération IA.
- Builds Xcode Debug et Release réussis. Une copie Debug protégée a été lancée
  et inspectée visuellement, puis fermée. Son affichage utilise des fixtures ;
  il ne prouve pas le fonctionnement authentifié du quota dans la GUI.
- Contrôle documentaire sans échec, avec 115 avertissements : le clone local
  peu profond ne contient pas tous les anciens commits de relecture ni les
  artefacts de distribution. Le compte des tests provient de leur exécution,
  pas du contrôle `--no-tests`.
- Le témoin positif du banc stockage produit un clone Git local observable.
  Le profil corrigé retourne huit modèles sans compte, refuse le quota pour
  absence de connexion et ne produit ni Git ni staging. Un faux exécutable
  qui ne répond à aucun RPC est rejeté par le témoin.
- Avec le même témoin et le compte connecté, le banc final retourne sept
  modèles et deux fenêtres de quota fraîches, sans Git ni staging.
- L'app stable, quota désactivé, ne présente aucun enfant Codex sur 64
  instantanés espacés de deux secondes pendant 131,8 secondes. Ce sondage
  peut manquer un processus plus bref que son intervalle.
- La mesure authentifiée a duré **1 802,309 secondes** : sept modèles et
  **16 relevés de quota frais**, **zéro commande Git et zéro staging**.
  Durée médiane d'un relevé : 1,062 seconde. La copie d'authentification a
  été retirée. Le témoin positif ajouté ensuite est une preuve distincte ;
  les sources du harness et du transport ainsi que la section machine
  `__text` concordent entre cette mesure et le banc final reconstruit.

Les changements du transport et du poller ont fait l'objet de relectures
croisées ciblées. Le script `Scripts/test-codex-read-storage.py` final a été
relu intégralement : le témoin positif, l'exigence d'une réponse modèles
non vide et le build obligatoire ferment trois risques de faux succès.
Cette campagne ne revendique pas une nouvelle relecture intégrale de tous
les consommateurs de `CodexReadClient`.

## Reproduire

```sh
swift test --build-system native --package-path AtollCore
python3 Scripts/test-codex-quota-poller.py
python3 Scripts/test-codex-quota-poller.py --sabotage overlap
python3 Scripts/test-codex-quota-poller.py --sabotage stop-reference
python3 Scripts/test-codex-quota-poller.py --sabotage before-fetch
python3 Scripts/test-codex-quota-poller.py --sabotage stale
python3 Scripts/test-codex-quota-poller.py --sabotage child-cancel
python3 Scripts/test-runtime.py
python3 Scripts/test-codex-read-storage.py --codex "$HOME/.local/bin/codex" \
  --output /private/tmp/atoll-storage-check
# Opt-in : copie privée temporaire de auth.json, RPC de lecture seulement.
python3 Scripts/test-codex-read-storage.py --codex "$HOME/.local/bin/codex" \
  --output /private/tmp/atoll-storage-live --live --duration 1800 --interval 120
python3 Scripts/check-docs.py --no-tests
```

Chaque mesure exige un nouveau dossier de résultats. Le banc construit le
transport réel et conserve sa fixture privée pour inspection. Il retire sa
copie d'authentification dans `finally`, sans journaliser son contenu.

## Limites et nettoyage

Le test réel porte sur Codex 0.160.1 et sur le transport compilé, avec HOME,
CODEX_HOME et marketplace locaux dédiés ; il ne constitue pas une recette
de trente minutes de la GUI de production ni de toutes les versions Codex.
Le shim Git est vérifié par le témoin ; le staging est inventorié entre les
lectures, sans traçage continu de toutes les écritures du système.

Si l'identité d'un processus ne peut pas être établie, le transport envoie
seulement EOF et reste borné. Il ne signale jamais un PID par supposition.
La sérialisation des workers ne garantit pas alors qu'un enfant récalcitrant
soit mort. Les descendants indépendants ne sont pas un groupe tué en bloc.

Les 945 staging historiques ont été déplacés vers un lot dédié de la corbeille
après la recette de trente minutes. La procédure utilise un manifeste
exact, contrôle d'identité et de métadonnées, stabilité de trente minutes,
absence de référence ou fichier ouvert observé, puis déplacement individuel
journalisé. Le cache des plugins installés, les sessions,
les configurations et les anciennes versions du CLI restent hors périmètre.
Le déplacement vers la corbeille ne libère pas d'espace physique. Les contrôles
de références et `lsof` sont des instantanés, pas un verrou interprocessus ;
APFS et ses snapshots peuvent aussi limiter le gain d'une suppression future.
La procédure a passé quatre essais dans une fixture privée : 945 déplacements
conservent les contenus et inodes, tandis qu'une dérive de métadonnées, un lien
symbolique ou une stabilité inférieure à trente minutes bloquent tout déplacement.
