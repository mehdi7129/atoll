# Preuves de l'audit d'apprentissage

Voir le [rapport et le plan](../../AUDIT-2026-09-11-learning-efficiency.md).
Base produit : `53c0a59`. Aucun fichier de production modifié.

## Reproduire hors ligne

Depuis la racine du dépôt, sur macOS avec Swift et Python 3 :

```sh
python3 docs/audit-support/2026-09-11-learning-efficiency/run.py
```

Le script construit AtollCore, compile les sources réelles avec les fixtures,
et conserve les binaires, journaux et résultats dans un nouveau dossier
temporaire dont il affiche le chemin. Aucun Atoll ni CLI génératif réel lancé.
`--output /chemin/results.json` permet de choisir le fichier de synthèse.
Le [résultat versionné](results.json) est celui du passage d'audit ; ses empreintes
identifient les sources examinées.

| Fixture | Couverture | Limite |
|---|---|---|
| `value/main.swift` | Catalogue Claude du projet ; catalogue inchangé après ajout de propositions/archives ; preuve finale coupée dans un fragment | Racines `BridgePaths` isolées ; pas de génération ni de double proposition réelle |
| `growth/main.swift` | Parseur Codex + digest + gate réels ; même digest, croissance brute admissible ; contrôles sans croissance et budget plein | Pas de runner ni de journal commun dans ce scénario |
| `CurationMain.swift` | Service/budget réels : annulation puis tick, corpus identique à l'échéance suivante | Stubs du harness runtime ; dates de fixture changées avant initialisation ; signaux simulés pour un résultat tardif |
| `WriteMain.swift` | Runner/budget réels, chemin normal : contrôle nominal puis vraies erreurs filesystem ; écritures et compteurs comparés | Résolution du moteur, catalogue et quota simulés ; faux résultat CLI valide |

Les assertions attendent les défauts constatés au moment de l'audit. Elles ne
doivent pas empêcher une future correction : convertir le scénario concerné en
test de non-régression avec attente inverse et sabotage dans le lot produit.

## Agrégats locaux facultatifs

```sh
python3 docs/audit-support/2026-09-11-learning-efficiency/observe.py --learning-dir "$HOME/.atoll/learning"
```

Lecture seule, sortie stdout ; aucun CLI appelé. L'export est limité aux comptes,
dates et indicateurs numériques avec une liste de labels autorisés. Aucun ID,
chemin personnel, contenu de transcript/note/skill, modèle personnel ou message
d'erreur libre n'est exporté. Le script ne modifie pas les données d'apprentissage.

[local-aggregates.json](local-aggregates.json) est un relevé historique conservé,
pas un benchmark du prompt actuel, ni une facture. Ne pas assimiler décisions,
spawns, montants rapportés, écritures, approbations et usages. Les cohortes et
les données manquantes sont détaillées dans le rapport.
