# A09, A10, A11, A21 — processus et helper

Lot préparé le 8 octobre et terminé le 9 octobre 2026, sur la base combinée
des PR #14 et #15 (`5cddb8b`).
La version distribuée reste 0.18.5/build 40. Aucun lancement d’Atoll, appel
génératif authentifié, accès au Trousseau réel ou écriture de configuration
personnelle pendant cette recette.

## Corrections

- **A09** : `BoundedProcessRunner` draine stdout et stderr simultanément, avec
  plafonds et horloge monotone. Après la sortie du parent, un descendant gardant
  les tubes ouverts n’impose plus d’attendre son EOF : la collecte abandonne après
  200 ms. Le résultat distingue succès, timeout, annulation et dépassement stdout.
  FleetPoller, les résolutions Claude/Codex et les deux services d’apprentissage
  utilisent ce chemin. La deadline des analyses commence avant leur résolution.
  L’intégration de PluginInventory appartient au lot plugins associé.
- **A11** : la lecture de quota Claude emploie le même exécuteur. Chaque TERM et
  KILL revérifie le couple PID/instant de démarrage. Une identité absente ou
  différente interdit le signal ; le test simule aussi la réutilisation du PID.
- **A10** : HookInstaller attend le helper hors MainActor. Les écritures sont
  sérialisées ; deux demandes consécutives identiques partagent une opération,
  mais `install → uninstall → install` garde les trois intentions. Les décisions
  de réparation/parking relisent l’état après la file. La restitution des sons
  précède le retrait dans cette même file. Les écrivains directs et le changement
  de home Codex sont refusés pendant une écriture active. Les callers relisent
  l’installation même après interruption ; aucun retry aveugle n’est ajouté.
  Le callback Rockstar vérifie que le mode est toujours actif après son attente.
- **A21** : CodexBridge réutilise l’écrivain POSIX existant de stdout. Un lecteur
  fermé n’entraîne plus l’exception Objective-C de FileHandle ; le helper reste
  fail-open. Le format de décision est conservé.

La contre-relecture a trouvé une régression intermédiaire : une collecte bornée
ne garantit pas la mort d’un enfant dont les signaux sont refusés. Les analyses
conservent donc sa référence, son PID interne et sa réservation de budget jusqu’à
la sortie observée. Une petite tâche attachée à cet enfant libère ensuite ces
ressources et permet la reprise ; aucun nouveau poller global ni signal ajouté.
Fleet et la lecture du Trousseau conservent également leur enfant encore vivant
après un retour borné ; leurs prochaines entrées reprennent seulement après sa
sortie. La garde couvre aussi l’attente initiale avant le spawn détaché.

## Validation ciblée

| Périmètre exécuté | Résultat |
|---|---:|
| Vraies classes Core, suite BoundedProcessRunnerTests | 6 tests |
| Fleet, quota, helper, deux résolutions login shell | 17 scénarios |
| Bilan/rangement, Claude/Codex, descendant et enfant survivant | 8 scénarios |
| Compatibilité du vrai RetrospectiveRunner | 26 scénarios |
| Compatibilité du vrai NotesCurationService | 26 scénarios |
| Vrai helper Codex, stdout ouvert/fermé | 2 parcours |
| Écrivain POSIX existant, EINTR puis écritures partielles | validé |
| Mutations compilées causales | 12 détectées |

Les trois mutations Core rétablissent l’attente d’EOF, retirent la borne stdout
ou la vérification d’identité. Quatre mutations du helper bloquent MainActor,
retirent la sérialisation, absorbent une intention alternée ou lisent l’état avant
la fin de la queue. Deux mutations des analyses libèrent le budget d’un enfant
encore vivant ; deux autres font relancer Fleet et le Trousseau alors que leur
enfant précédent tourne toujours. La dernière remet FileHandle sur stdout : nominal conservé,
lecteur fermé reproduisant le signal 6. Une erreur de compilation ne compte
jamais comme sabotage détecté.

Les services sont compilés entiers. Les collaborateurs de test isolent les
chemins, le quota et les faux CLI. Pour accélérer les deux cas d’enfant survivant,
seuls les délais des copies de test passent de 600 s à 1 s et de 5 s à 0,1 s ;
le stub d’identité refuse les signaux. Le budget reste retenu, un autre modèle
est refusé et une nouvelle analyse fonctionne après la vraie sortie. Les quatre
premiers parcours, exécutés aussi avec les délais de production, ont rendu la
main 0,235–0,281 s après la sortie du parent.

Le test des resolvers relocalise seulement les deux emplacements globaux Codex
pour que le binaire installé ne masque pas le fallback. Pour les deux sondes
survivantes, la copie de la vraie primitive ignore uniquement l’identité capturée,
via une variable réservée à ces fixtures. Le nominal initial des quinze autres
scénarios passe aussi avec la primitive Core compilée sans adaptation.
Le helper complet utilise
une copie de CodexPaths dont seul le socket fixe est dirigé vers la fixture ;
son statut est contrôlé dans le home privé avant l’envoi. La recette ne prétend
pas qualifier une réponse réelle du Trousseau ou d’un CLI authentifié.

Le [relevé compact](audit-support/2026-10-08-processes/validation.json) conserve
les empreintes et les verdicts. Les premiers essais intermédiaires restent dans
les preuves privées : timeout de compilation sous charge, fixture d’interruption
trop courte, seuil de drain initial incluant aussi la préparation et anciens
mutants de sondes échouant sur un autre oracle. Les deux mutants finaux conservent
la garde de collecte et déclenchent précisément la perte de l’enfant survivant.
Les essais intermédiaires ne sont
pas comptés comme réussites. La compilation globale et la recette d’intégration
avec les autres lots sont suivies dans le rapport de clôture de l’audit.

## Rejouer

Construire Core dans un scratch privé avec `swift build --package-path AtollCore
--build-system native --scratch-path "$ATOLL_PROCESS_CORE"`, puis donner son
répertoire `--show-bin-path` aux scripts. Chaque `--output` désigne un dossier
neuf réservé à la recette.

```sh
python3 Scripts/test-bounded-process-sabotage.py --output "$ATOLL_PROCESS_EVIDENCE/core"
python3 Scripts/test-process-services.py --build-dir "$ATOLL_PROCESS_BIN" --output "$ATOLL_PROCESS_EVIDENCE/services"
python3 Scripts/test-analysis-processes.py --build-dir "$ATOLL_PROCESS_BIN" --output "$ATOLL_PROCESS_EVIDENCE/analyses"
python3 Scripts/test-codex-stdout.py --build-dir "$ATOLL_PROCESS_BIN" --output "$ATOLL_PROCESS_EVIDENCE/stdout"
```

Les contre-épreuves des services prennent `--sabotage heartbeat`, `serialization`,
`coalescing`, `barrier`, `fleet-ownership` ou `keychain-ownership` ;
celles des analyses `retrospective` ou `curation` ;
celle de stdout le drapeau `--sabotage`. Exécuter leur nominal avant les mutants.
Les suites de compatibilité sont `Scripts/test-learning-retrospective.py` et
`Scripts/test-curation.py`.
