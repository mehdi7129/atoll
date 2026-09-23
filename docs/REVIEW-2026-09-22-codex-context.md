# Contexte ajouté par Codex aux analyses

> Diagnostic conservé dans son état initial. Le [profil ensuite implémenté et mesuré](REVIEW-2026-09-22-codex-lean.md)
> adopte les réductions vérifiées ci-dessous et précise les limites restantes.

22 septembre 2026 · suite de la [recette authentifiée](REVIEW-2026-09-22-learning-live.md).

Le prompt minimal d’Atoll n’explique pas les **13 397 tokens d’entrée** du test.
Codex ajoute ses instructions, ses outils et un catalogue de skills. Ce catalogue
reste présent avec `--ignore-user-config`, un `CODEX_HOME` vide et un cwd privé.

Capture locale de **Codex CLI 0.155.1 / gpt-5.6-luna**, paramètres du test minimal
et métadonnées du modèle issues du catalogue natif :

| Bloc | Caractères mesurés |
|---|---:|
| Instructions générales du modèle | 17 730 |
| Définitions d’outils en JSON compact | 10 698 |
| Instructions et catalogue des skills | 10 916 |
| Instructions de permissions | 341 |
| Contexte d’environnement | 551 |
| Consigne Atoll | 234 |
| Schéma Atoll | 156 |

Le format de sortie complet fait 260 caractères **schéma compris**. Les instructions
générales figurent aussi dans `input` : ne pas compter ces éléments deux fois.
Les chemins temporaires font légèrement varier certaines tailles.

Le catalogue contient les noms des **46 skills personnels** relevés sur cette
machine, avec descriptions et chemins. Cela ne signifie pas que les corps complets
des 46 fichiers sont chargés. « N’utilise aucun outil ni skill » dans le prompt
n’empêche pas l’envoi du catalogue et des définitions d’outils.

## Contre-épreuve sans génération

L’option locale `-c skills.include_instructions=false` fait passer le bloc skills
de **10 916 à zéro caractère**. Instructions du modèle, outils, consigne et schéma
restent présents. Les skills installés et configurations personnelles sont intacts.
Cela prouve l’absence de l’injection automatique, pas l’impossibilité de lire un skill.

Preuves : [baseline](audit-support/2026-09-22-codex-context/baseline.json) et
[sans instructions skills](audit-support/2026-09-22-codex-context/without-skills.json).
Retirer l’option dans une copie du script fait échouer l’assertion : le catalogue
encore présent est détecté. Script et mesures relus indépendamment.

```sh
python3 Scripts/probe-codex-context.py --output /private/tmp/atoll-context-base.json
python3 Scripts/probe-codex-context.py --without-skill-instructions \
  --output /private/tmp/atoll-context-without-skills.json
```

La sonde n’utilise aucune authentification. Son fournisseur pointe vers un serveur
HTTP loopback qui reçoit la requête puis renvoie volontairement une erreur 400,
sans retry ni réponse de modèle. Catalogue lu localement, captures brutes temporaires,
seules les tailles et empreintes sont exportées. Aucun nouvel appel génératif authentifié.

## Limites et suite

Ces tailles expliquent les sources du contexte, **pas la répartition exacte des
13 397 tokens d’entrée**. Le transport local sans auth diffère du transport ChatGPT ;
la sérialisation des outils et les ajouts du service n’ont pas de compteur natif ici.
Ne pas convertir ces caractères en une promesse d’économie de tokens.

Le runtime Atoll utilise le `CODEX_HOME` choisi par l’utilisateur, alors que les
trois essais précédents avaient un home privé. Les instructions globales et
extensions d’une installation réelle peuvent ajouter du contexte supplémentaire.
Le projet analysé reste une donnée du prompt, pas le cwd du processus interne.

Première correction à privilégier : omettre les instructions automatiques de skills
**uniquement pour les analyses internes**, qui reçoivent déjà leur matière.
Réduire les outils et remplacer les instructions natives serait un changement
distinct, à vérifier avec le benchmark qualitatif avant adoption. Le runtime produit
n’est pas modifié par ce diagnostic et l’échec qualitatif précédent demeure ouvert.
Aucune économie réelle après correction n’est encore mesurée.

Références officielles consultées le 22 septembre :
[portée de `--ignore-user-config`](https://learn.chatgpt.com/docs/non-interactive-mode),
[emplacements des skills](https://learn.chatgpt.com/docs/build-skills),
[schéma de configuration, `skills.include_instructions`](https://developers.openai.com/codex/config-schema.json).
