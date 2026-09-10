# Pièces reproductibles de l'audit

Base : commit `1b08ebd`, Atoll 0.17.2, 2026-09-09.

Exécuter depuis la racine du dépôt :

```sh
python3 docs/audit-support/2026-09-09/reproduce.py
```

Le script compile les sources de production concernées avec des fixtures synthétiques dans un répertoire temporaire, puis le retire. Il ne lance ni Codex ni Claude, n'ouvre aucune session, n'utilise aucun compte et ne modifie aucun réglage personnel.

Résultats observés sur la base auditée :

```text
PROBE runtime
generic live process + closed rollout -> ["codex:historical"]
after SessionEnd -> 0
late async tool after SessionEnd -> accepted= true sessions= 1
permission summary for exec_command cmd -> exec_command
silent crashed session after 23h -> 1
Stop without turn then late same-turn prompt -> accepted= true active= true
legacy async permission + timeout3 installed -> true
PROBE digest
ok-read tool_result
failed-cmd tool
AGENTS envelope roles -> ["user"]
```

Ces probes montrent le comportement actuel ; elles ne sont pas des tests de non-régression affirmant qu'il faut le conserver. Les futurs correctifs devront inverser les assertions utiles, ajouter les cas nominaux et compléter les fixtures par les contrats réellement émis par le CLI. La fixture exec_command/cmd n'est notamment pas présentée comme un payload réel capturé.

Autres contrôles exécutés pendant l'audit :

- suite AtollCore : 929 tests, 1 ignoré, 0 échec ;
- test opt-in de lecture du quota relancé seul : 1 succès, 2 catégories, aucun thread ;
- build Debug app et helper : succès, un warning de métadonnées AppIntents ;
- schémas générés par codex-cli 0.153.4 ;
- hooks/list dans un home jetable avec les définitions produites par Atoll : 10 hooks, zéro erreur, PermissionRequest synchrone/600 s, trust non accordé.

Les sorties brutes locales de build/RPC ne sont pas copiées ici, car elles comportent des chemins de machine. Aucun transcript personnel, jeton ou quota personnel ne fait partie de ces fixtures.

[Couverture nominative et profondeur de lecture](COUVERTURE.md).
