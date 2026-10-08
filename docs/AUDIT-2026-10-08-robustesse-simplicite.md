# Audit Atoll — robustesse, simplicité et efficacité

État audité : **`a1c7d6999d6921906f26c405fc4f48e7bde30e91`**, `main`,
Atoll **0.18.4 / build 39**, le 8 octobre 2026.

**Cette PR propose des corrections ; elle ne les implémente pas.** Aucun fichier
produit, préférence, hook utilisateur, numéro de version ou appcast n'est modifié.
La demande est de conserver les usages et l'interface tout en améliorant la fiabilité
et la lisibilité. Les issues d'erreur incorrectes doivent changer ; les parcours
nominaux, choix utilisateur et contrats des CLI doivent rester identiques.

## Diagnostic

Le projet a de bonnes fondations : un cœur Swift séparé, des tests nombreux,
des garde-fous explicites et des harnesses qui exécutent les vrais services.
Une réécriture générale serait disproportionnée. La dette est surtout concentrée
dans l'orchestration des processus, les transactions disque et les services qui
combinent état observable, planification, persistance et exécution.

**22 sujets de correction sont retenus**, avec preuve et portée explicites ci-dessous.
La [contre-relecture de la PR](REVIEW-2026-10-08-counteraudit.md) a ajouté A18–A22
et corrigé la portée d'A04. Le premier passage en comptait 17.
Les plus urgents concernent la conservation de fichiers et de leur suivi. Plusieurs
tests actuels passent parce qu'ils ne croisent pas les conditions qui déclenchent
ces défauts : restauration *partielle* de hooks, accès temporairement refusé,
descendant qui conserve un pipe, deux permissions du même outil.
Un script supplémentaire de préparation Codex échoue et peut annoncer un faux
succès de sabotage (A22) : le bilan de toutes les validations n'est donc pas vert.

Les simplifications proposées découlent de ces frontières défaillantes. La longueur
d'un fichier, un singleton ou un `try?` ne constituent pas, seuls, un défaut.

## Méthode et validations

Quatre agents au maximum simultanément, coordinateur compris : trois périmètres
complémentaires, une seconde vague sur l'installation et les zones adjacentes,
puis contre-revue des principaux constats. Les contre-relecteurs cherchaient à
réfuter les scénarios. Les preuves utilisent des données synthétiques et des homes
temporaires ; aucun appel génératif réel, son joué ou lancement de l'app de production.

| Vérification sur la base auditée | Résultat |
|---|---|
| `swift test --package-path AtollCore --build-system native` | 1 089 tests, 1 skip, 0 échec |
| `Scripts/test-runtime.py` | 60 scénarios réussis |
| `Scripts/test-codex-quota-poller.py` | 8 scénarios réussis |
| `Scripts/test-curation.py --build-system native` | 26 scénarios réussis |
| `Scripts/test-curation-recovery.py --build-system native` | 98 scénarios réussis |
| `Scripts/test-learning-retrospective.py` | 26 scénarios réussis |
| Build Xcode Debug, DerivedData isolé | Réussi ; aucun warning Swift, avertissement AppIntents sans dépendance |
| `Scripts/check-docs.py --no-tests`, avant audit | Réussi ; avertissements de couverture/relecture et rappel des tests sautés |
| Recherche limitée de secrets dans les textes suivis ≤ 2 Mo | Aucun motif de clé privée/OpenAI/GitHub détecté ; pas de scan historique ou d'entropie |
| Contre-audit : `Scripts/test-codex-exec.py --prepare-only` | **Échec** du catalogue factice ; faux succès du sabotage confirmé, même sans mutation — A22 |
| Contre-audit : `Scripts/test-claude-uninstall.py <helper Debug>` | Quatre modes réussis, homes synthétiques |
| Contre-audit : `Scripts/test-release-trash.py` | Réussite et sabotage détecté, artefacts synthétiques récupérables |

Les cinq harnesses du premier passage représentent **218 scénarios hors suite Core**. Ces succès établissent la
baseline, pas l'absence de défaut. Les probes de cet audit exposent précisément
des cas non couverts. Leurs sources portables et résultats synthétiques sont dans
[le dossier de preuves](audits/2026-10-08/README.md).

### Périmètre réellement couvert

L'inventaire contient 573 fichiers suivis ; 150 fichiers Swift produit,
33 350 lignes commentaires compris. Le package a 85 fichiers de tests.
Les fichiers les plus longs sont RetrospectiveRunner (1 176), MemoryIndex (1 150),
NotesCurationService (1 119), SessionStore (1 083) et SkillCatalog (951).
[Mesures reproductibles](audits/2026-10-08/inventory.json).

| Zone | Travail effectué | Limite |
|---|---|---|
| Sessions, permissions, bridge, quotas | Traçage des événements, lifecycle, installation/restitution, probes de vraies classes | Pas de nouvelle recette Claude authentifiée |
| Apprentissage et stockage | Gates, budget, archive/swap/reprise, manifeste, tests par fautes de fichiers | Aucun modèle réel appelé |
| Mémoire et recall | Lecture de l'indexeur complet, transactions et recherche, Markdown/JSONL/cwd | Pas de benchmark représentatif du corpus personnel |
| UI, réglages, sons, fenêtres, jump-back | Source, callbacks, invalidations, ownership, probes AppKit/processus | Pas de nouvelle capture GUI, écoute ou recette VoiceOver |
| Build, tests, distribution, documentation | Build complet, suites offline, pipeline/relevés de release, carte des relectures | Pas de notarisation/publication ou audit de dépendance exhaustive |

Il s'agit d'un audit transversal du projet avec approfondissement des chemins à
risque, **pas d'une attestation de lecture ligne à ligne de chaque fichier**.
Le registre classe donc cette campagne en `sweep`.

## Corrections proposées

Priorités : **P1** conservation des données à traiter en premier ; **P2** fiabilité
ou ressources ; **P3** exactitude secondaire ou durcissement. « Reproduit » désigne
une fixture, jamais un incident supposé sur les données de l'utilisateur.

| ID | Priorité | Sujet | Niveau de preuve |
|---|---|---|---|
| [A01](#a01) | P1 | Curation : note non archivée supprimée si sa mise à l'écart échoue | Service réel, reproduit et contre-vérifié |
| [A02](#a02) | P2 | État de curation illisible remplacé silencieusement | Service réel reproduit |
| [A03](#a03) | P2 | Skills : accès refusé confondu avec suppression | Store réel reproduit |
| [A04](#a04) | P2 | Markdown réécrit sur place conservé périmé dans l'index | Indexeur réel reproduit, contre-revue |
| [A05](#a05) | P2 | Dernière ligne complète de `cwd` ignorée | Indexeur réel reproduit, contre-revue |
| [A06](#a06) | P2 | Fin d'un outil Claude retirant une autre permission vivante | Classe réelle, deux probes |
| [A07](#a07) | P2 | Restauration sonore confondant les matchers | Core réel reproduit |
| [A08](#a08) | P2 | Installation Claude dupliquant un hook dans un groupe mixte | Core réel reproduit |
| [A09](#a09) | P2 | Deadlines de processus ne bornant pas les pipes hérités | Fleet réel et primitive reproduits |
| [A10](#a10) | P2 | Installation du helper bloquant le MainActor | Façade réelle, helper lent factice |
| [A11](#a11) | P2 | Escalade Keychain utilisant un PID sans identité | Code, course possible non déclenchée |
| [A12](#a12) | P2 | Annuler une recherche interrompant d'autres actions plugins | Chaîne d'appels vérifiée |
| [A13](#a13) | P2 | Une estimation globale pouvant lancer N CLI à la fois | Code ; coût CPU/RAM non mesuré |
| [A14](#a14) | P3 | Cache de coût d'un plugin périmé après mise à jour | Code |
| [A15](#a15) | P2 | Deux événements partageant un même son système | Identité/volume AppKit reproduits |
| [A16](#a16) | P3 | Journal et notes périmés dans le panneau ouvert | Source ; GUI non exercée |
| [A17](#a17) | P2 | Retour IDE annoncé réussi malgré deux échecs | Méthode extraite, collaborateurs factices |
| [A18](#a18) | P2 | Transcript ignoré après un refus temporaire de lecture | Indexeur réel reproduit, contrôles mtime/suppression |
| [A19](#a19) | P1 | « Archiver » supprimant le skill après échec de sauvegarde | Store réel, perte d'une ressource synthétique reproduite |
| [A20](#a20) | P2 | Ancien catalogue réaffiché après changement de projet/binaire | Méthodes extraites, état/CLI contrôlés ; GUI non exercée |
| [A21](#a21) | P2 | Helper Codex abortant lorsque stdout est fermé | Bridge réel, contrôle avec writer existant |
| [A22](#a22) | P2 | Test de préparation Codex périmé et faux succès de sabotage | Harness réel et contre-épreuves en copies temporaires |

### A01

**Préserver toute note non archivée lors d'une collision de sortie.**
[NotesCurationService.swift:508](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/NotesCurationService.swift#L508)
tente de déplacer un fichier homonyme vers `.orphan-<timestamp>`, puis le supprime
si le déplacement échoue. Une note non UTF-8 est exclue de `readNotes()` et de
l'archive ; si le nom de secours est occupé, ses octets sont perdus et le rangement
annonce pourtant le succès. Reproduction avec le service **verbatim et l'horloge
réelle** : original absent, octets absents des archives, succès affiché.

- [ ] Refuser la collision avant la bascule, ou réserver une sauvegarde libre et
      propager son échec ; jamais de suppression d'une source non archivée.
- [ ] Tester note illisible + nom final occupé + secours occupé, restauration et
      checkpoint. Le retour à `removeItem` après échec doit faire échouer le test.

C'est une faute de fichier injectée ; aucune fréquence de collision réelle n'est
établie. Conserver noms finaux, provenance, cadence et reprise locale sans IA.

### A02

**Distinguer un état absent d'un état illisible.**
[NotesCurationService.swift:1092](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/NotesCurationService.swift#L1092)
réduit une erreur de JSON à un état neuf ; `syncWithSettings()` le persiste quand
la planification est déjà active. Dernier résultat, contradictions et échéance
disparaissent ; le délai repart pour une semaine. Reproduction sans CLI.

- [ ] Conserver les octets illisibles, exposer l'erreur et empêcher leur réécriture,
      comme le journal de rétrospective ; aucune réparation destructive automatique.
- [ ] Tester absence, ancien état valide, JSON/type invalide et empreinte optionnelle
      invalide ; garder la tolérance actuelle sur cette dernière. Vérifier zéro spawn.

### A03

**Ne retirer une entrée du manifeste que sur absence prouvée.**
[LearnedSkillStore.swift:400](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/AtollCore/Sources/AtollCore/LearnedSkillStore.swift#L400)
vérifie la présence de la racine, puis traite `fileExists(child)==false` comme une
suppression. Avec une racine visible mais sans droit de traversée, la fixture perd
l'entrée du manifeste ; après restauration de l'accès, `SKILL.md` existe mais est
`unmanaged`. Le contenu survit, son autorité de gestion est perdue.

- [ ] Distinguer absence et erreur d'accès par une opération qui remonte son erreur ;
      préserver le manifeste en cas d'incertitude, comme pour une racine non montée.
- [ ] Ajouter accès refusé/rétabli aux tests de racine absente, sans modifier les
      choix d'installation, de désinstallation ni les fichiers tiers.

### A04

**Indexer un document Markdown comme un document remplaçable.**
[MemoryIndexer.swift:434](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/MemoryIndexer.swift#L434)
utilise les offsets JSONL pour les notes et mémoires `.md`. Même inode et même
taille : lecture ignorée. Même inode et croissance : UUID constant +
`INSERT OR IGNORE` conservent l'ancien texte tout en avançant l'offset.
Probe : l'ancien marqueur reste cherchable dans les deux documents ; les nouveaux sont absents.

- [ ] Remplacement transactionnel du document complet quand son contenu change,
      avec détection adaptée ; garder le chemin append-only des JSONL séparé.
- [ ] Tester taille égale, croissance, réduction, remplacement atomique, échec de
      transaction et répétition inchangée. Aucun doublon ni ancien texte réinjecté.
- [ ] Traiter une lecture réussie vide/whitespace comme un document désormais vide,
      distinct d'une lecture échouée : effacer transactionnellement les anciens
      fragments dans le premier cas, les préserver dans le second.

**Portée corrigée par le contre-audit :** les remplacements atomiques et réductions
fonctionnent pour une mémoire de projet finale **non vide après trim**. Si elle est
vidée ou réduite à du whitespace, le guard de `indexProjectMemory` à la ligne 472
retourne avant `openFile` : l'ancien texte reste cherchable, même avec un inode neuf
et après reset du worker. La fixture conserve un hit périmé dans chacun de ces cas ;
la réduction non vide témoin remplace correctement le texte. Cette seconde branche
concerne la mémoire de projet, pas le guard du chemin des notes d'apprentissage.

### A05

**Conserver la dernière ligne lorsqu'elle est complète.**
[MemoryIndexer.swift:515](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/MemoryIndexer.swift#L515)
fait `split(..., omittingEmptySubsequences: true).dropLast()`, même quand le bloc
finit par `\n`. Si cette ligne est le seul `cwd` exploitable, la mémoire n'a plus
de projet et le recall limité au projet l'exclut. Probe : mémoire présente,
`project_path=null`, zéro résultat filtré.

- [ ] Retirer seulement le fragment réellement incomplet. Tester ligne terminée,
      fragment tronqué et coupure à 256 Ko ; conserver cette limite et le fallback.

### A06

**Corréler une fin d'outil à la bonne demande Claude.**
[InteractionCenter.swift:265](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/InteractionCenter.swift#L265)
annule par seul couple session/nom d'outil ; `SessionStore` le déclenche à chaque
`PostToolUse`/échec. A et B demandent Bash, A est autorisée, A termine : B disparaît
et la phase quitte l'attente. Deux probes confirment la perte de carte ;
**B n'est pas auto-autorisée**. Codex a déjà retiré une heuristique apparentée.

- [ ] Utiliser une preuve causale de résolution : identifiant natif après vérification
      du payload, décision explicite ou liveness du helper ; pas de résumé comparé
      ni d'heuristique « un seul candidat restant ».
- [ ] Tester ensemble carte et phase : A/B même outil, sous-agent, réponse terminal,
      arrêt et timeout. Préserver Manuel/Rockstar et les issues fail-open.

### A07

**Restituer les hooks sonores dans leur matcher d'origine.**
[SoundHookEditor.swift:306](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/AtollCore/Sources/AtollCore/SoundHookEditor.swift#L306)
compte les hooks identiques à l'échelle de l'événement, sans matcher. Deux sons
identiques sous Bash et Edit sont parqués ; seul Edit est rétabli manuellement :
la restitution donne **Edit, Edit**, perd Bash, puis peut supprimer le parking.
Le contrôle sans restitution manuelle rend bien Bash, Edit.

- [ ] Associer occurrence et consommation au groupe/matcher, en préservant ordre,
      métadonnées inconnues et doublons légitimes.
- [ ] Tester restitution nulle, complète et partielle, ordre inverse, puis idempotence.
      Conserver les gestes actuels d'adoption/restitution et les sons choisis.

### A08

**Réinstaller chirurgicalement dans les groupes de hooks Claude mixtes.**
[HookSettingsEditor.swift:76](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/AtollCore/Sources/AtollCore/HookSettingsEditor.swift#L76)
retire les groupes entièrement Atoll, mais garde `[Atoll, tiers]` avant d'ajouter
le nouveau hook. Probe : **Atoll, tiers, Atoll**. Le doublon persiste, sans croissance
infinie à chaque installation. Les doubles événements réels restent à qualifier.

- [ ] Retirer seulement les sous-hooks gérés, conserver les tiers et leur groupe,
      puis installer une définition gérée unique. Le retrait possède déjà ce principe.
- [ ] Ajouter groupe mixte aux tests d'installation, de bascule recall et d'idempotence.
- [ ] Durcissement P3 associé : si la clé racine `hooks` existe avec un mauvais type,
      refuser au lieu de l'assimiler à une absence. Cette fixture est déjà non conforme
      au CLI ; ne pas la présenter comme perte d'une configuration valide.

Le contrat de migration Codex, qui respecte les retraits et personnalisations,
reste distinct et inchangé.

### A09

**Borner toute l'opération de sous-processus, drains compris.**
[FleetPoller.swift:129](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/FleetPoller.swift#L129)
attend EOF alors que son watchdog ne surveille que le parent. Parent sorti, descendant
gardant stdout : **8,23 s mesurées malgré un watchdog de 5 s**. Même condition dans
les drains de PluginInventory ; la primitive conserve l'attente après sortie du
parent. RetrospectiveRunner et NotesCurationService ont le même patron, constaté
statiquement mais non reproduit sur leurs runs complets dans cet audit.

- [ ] Deadline monotone couvrant résolution, processus et collecte ; drains simultanés
      bornés en taille et durée ; aucun signal sans identité. Fermer proprement les
      descripteurs détenus sans attendre un EOF hérité indéfiniment.
- [ ] Tester descendant silencieux, stdout/stderr volumineux, TERM ignoré, annulation,
      succès/échec nominal ; restaurer l'attente EOF illimitée doit casser le test.

Préserver commandes, auth, profils de lecture, cadences et politique de retry.
La correction quota/modèles de 0.18.4 reste acquise ; aucun retour à la synchronisation
de plugins pour ces lectures. La preuve ne décrit pas une panne du CLI installé.

### A10

**Exécuter le helper d'installation hors MainActor.**
[HookInstaller.swift:101](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/HookInstaller.swift#L101)
attend synchroniquement sa sortie, sans deadline ; stdout n'est pas vidé, stderr
n'est lu qu'après la fin. Le chemin est appelé au démarrage et par les réglages.
Avec un helper factice lent, le heartbeat MainActor demandé à 20 ms n'arrive
qu'à **774 ms**, après la méthode réelle.

- [ ] Exécution asynchrone sérialisée, drains et timeout bornés ; état relu après une
      interruption susceptible d'avoir laissé une écriture partielle. Aucune relance aveugle.
- [ ] Tester heartbeat, gros stderr, double clic, erreurs et ordre des sauvegardes /
      migrations / restitutions. Même UI, mêmes confirmations et aucun writer parallèle.

Le helper réel installé n'a pas été bloqué pour cette mesure.

### A11

**Appliquer la garde d'identité au watchdog Keychain.**
[ModelQuotaPoller.swift:115](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/ModelQuotaPoller.swift#L115)
capture un PID, envoie TERM, puis fait `kill(pid, 0)` / SIGKILL une seconde plus tard.
Si le PID a été recyclé, un autre processus peut être visé. La garde déjà employée
ailleurs (`ProcessIdentity`) manque ici. Aucun recyclage ni signal réel testé.

- [ ] Capturer et revérifier l'identité avant chaque signal ; identité illisible =
      aucun signal. Tester sondes et signaux injectés, sans accès au vrai Keychain.
      Garder la lecture seule du jeton, l'opt-in et la cadence de 120 s.

### A12

**Donner à l'annulation de recherche un périmètre propre.**
[PluginInventory.swift:370](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/PluginInventory.swift#L370)
appelle `inFlight.terminateAll()`. Le bouton de recherche utilise cette méthode,
alors que l'UI autorise simultanément des commandes d'installation/désactivation.
Toutes partagent le registre. Annuler une recherche peut donc interrompre une
mutation indépendante ; pas de perte de fichiers alléguée sans preuve.

- [ ] Séparer annulation de l'opération et arrêt global à la fermeture ; conserver
      l'identité des enfants et les contrôles du budget.
- [ ] Deux commandes factices simultanées : la recherche s'arrête, l'installation
      finit ; à la fermeture, les deux s'arrêtent. Garder les actions actuelles.

### A13

**Borner la concurrence du calcul de coût des plugins.**
[PluginInventory.swift:163](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/PluginInventory.swift#L163)
lance une tâche par id, et le bouton collectif parcourt tous les plugins actifs.
La déduplication par id ne limite pas le nombre de CLI simultanés. C'est une borne
manquante prouvée par le code ; le coût CPU/RAM réel n'a pas été mesuré.

- [ ] File simple avec une ou deux lectures simultanées, à choisir par mesure ;
      garder le bouton global, l'ordre des lignes et les résultats progressifs.
- [ ] Fixture de 30 plugins : maximum d'enfants borné, une opération en vol par id, échec
      local indépendant, aucun spawn au simple rendu, annulation du lot maîtrisée.
      Préserver le fallback id complet → nom court, qui peut exécuter deux commandes.

### A14

**Invalider le coût estimé quand un plugin change de version/source.**
[PluginInventory.swift:139](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/PluginInventory.swift#L139)
rafraîchit l'inventaire sans invalider `tokenCosts`, indexé seulement par id.
Une mise à jour native garde donc l'ancien coût jusqu'au redémarrage.

- [ ] Invalidation ciblée et réponse associée à la version demandée ; tester réponse
      tardive de l'ancienne version, disparition et inventaire inchangé sans nouvel appel.

### A15

**Une instance sonore réellement indépendante par événement.**
[SoundCenter.swift:267](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/SoundCenter.swift#L267)
utilise deux clés de cache mais `NSSound(named:)` rend le même objet pour un même
son système. Mesure AppKit : identité commune et volume du premier changé par le
second. `emit` arrête une instance déjà en lecture, ce qui permet aux deux événements
de se couper. Aucune écoute effectuée ; les fichiers custom ne sont pas concernés.

- [ ] Instance séparée et vérifiée pour chaque événement, sans changer choix, volumes,
      anti-rafale ni relance du même événement. Test d'identité/volume, puis écoute
      des deux événements lors de l'implémentation.

### A16

**Rafraîchir le panneau sur les écritures effectivement réussies.**
[LearningSettingsPane.swift:62](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/LearningSettingsPane.swift#L62)
charge le journal dans `onAppear` ; les notes se rafraîchissent surtout au changement
de curation. Une rétrospective finie panneau ouvert laisse le journal et le compte
de notes périmés ; « Ranger maintenant » peut rester désactivé jusqu'à réouverture.

- [ ] Émettre une révision à l'écriture du journal/corpus, observée par la vue ;
      aucun nouveau timer ni scan à chaque `body`.
- [ ] Tester vue montée pendant succès, abstention, erreur et reprise locale ;
      mêmes contrôles, dispositions et fréquence d'analyse.

### A17

**Ne pas annoncer un focus IDE sur la seule réussite du spawn.**
[TerminalJumpService.swift:76](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/TerminalJumpService.swift#L76)
ignore le résultat de l'activation et le futur exit du CLI. La méthode extraite
renvoie `focused(..., fenêtre)` avec activation `false` et CLI factice exit 42.
C'est une preuve de faux succès possible, pas une mesure du focus Cursor réel.

- [ ] Attendre le résultat CLI dans une borne hors MainActor, vérifier le fallback
      d'activation et nommer seulement la granularité établie. Un exit 0 ne prouve
      pas à lui seul le focus de la bonne fenêtre : conserver une recette GUI réelle.
- [ ] Tester spawn échoué, exit non nul, activation refusée et fallback réussi ;
      garder le même bouton et la résolution de workspace existante.

### A18

**Retenter une ouverture refusée à la prochaine passe existante.**
[MemoryIndexer.swift:550](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/MemoryIndexer.swift#L550)
pose le même `lastSeen` lorsque le fichier est déjà lu ou lorsque `FileHandle`
ne peut pas s'ouvrir. Une lecture refusée puis rétablie, sans changement du triplet
inode/taille/mtime, reste ignorée par le scan et le nudge. Fixture réelle : zéro hit
après rétablissement ; changer seulement le mtime donne un hit. Le fichier survit.

- [ ] Séparer fin de fichier et échec d'ouverture ; ne mémoriser la lecture réussie
      qu'après succès. Examiner aussi les erreurs de seek/read actuellement masquées,
      sans les confondre avec EOF ; elles n'ont pas été injectées dans ce probe.
- [ ] Tester accès refusé/rétabli à métadonnées égales, scan et nudge, offsets conservés
      et absence de réingestion après succès. Préserver cadence et déduplication.

Une vraie suppression après indexation conserve bien la mémoire historique avec
`missing=1` : ce contrôle nominal doit rester distinct d'un accès temporairement refusé.

### A19

**Ne finaliser « Archiver » qu'après conservation du dossier installé.**
[LearnedSkillStore.swift:358](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/AtollCore/Sources/AtollCore/LearnedSkillStore.swift#L358)
ignore l'échec d'`archiveDirectory` puis supprime le dossier et son entrée du manifeste.
Le bouton « Archiver » appelle ce chemin. Une ressource ajoutée après approbation
est perdue si le parent d'archive est un fichier : zéro copie restante, aucun throw.
Le témoin avec archive accessible conserve une copie de cette ressource.

- [ ] Propager l'échec d'archive avant tout retrait de source ou de manifeste ;
      garder le dossier entier, y compris les ressources ajoutées depuis l'installation.
- [ ] Tester archive impossible, archive partielle et réussite, état du manifeste,
      ressource unique et retour UI fidèle. Le `try?` suivi de suppression doit
      réintroduire la perte et faire échouer le futur test.

Le cas reproduit est une faute de fichier synthétique ; aucune perte utilisateur
supposée. La désinstallation globale `uninstallAll`, dont la politique best-effort
est explicite, reste un contrat séparé et n'est pas modifiée par ce correctif.

### A20

**Rejeter une réponse de catalogue appartenant à un ancien contexte.**
[CodexCatalogSection.swift:80](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/App/CodexCatalogSection.swift#L80)
capture le `self` de la vue au démarrage ; les comparaisons finales de `projectPath`
et d'`executableOverride` relisent les mêmes anciennes valeurs. `invalidate()` vide
l'état partagé mais n'invalide pas la tâche. La vue parente conserve l'identité de
la section lorsque le projet ou le binaire change.

Les méthodes extraites sans changement de corps, avec état/CLI contrôlés, montrent
un panneau de projet B recevant le skill du projet A, et le même défaut pour le
binaire. C'est une preuve de la logique d'état, pas une recette SwiftUI réelle.

- [ ] Identifier chaque chargement par une révision du contexte courant et rejeter
      toute réponse antérieure, même après annulation ; inclure projet, binaire et home.
- [ ] Tester A→B pendant lecture, erreur tardive, succès normal et changement de home
      après chargement. Aucun appel automatique supplémentaire ni nouveau contrôle UI.

Le garde du home **en vol** fonctionne dans le témoin. Le catalogue déjà chargé
ne possède pas d'invalidation au changement de home : sous-cas constaté dans la
source, à vérifier en GUI lors du correctif, sans l'assimiler au témoin en vol.

### A21

**Écrire la réponse du helper Codex sans exception si le lecteur a disparu.**
[CodexBridge.swift:80](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/Bridge/CodexBridge.swift#L80)
utilise `FileHandle.standardOutput.write`. Ignorer SIGPIPE ne suffit pas : pipe aval
fermé, le bridge réel abort avec `NSFileHandleOperationException`/Broken pipe et
exit signal 6 ; pipe ouvert, il rend bien le JSON attendu et exit 0.

- [ ] Réutiliser le writer POSIX fail-open déjà employé côté Claude, sans changer
      validation des décisions ni format du JSON. Sa contre-épreuve temporaire
      rend le même JSON avec lecteur ouvert et exit 0 avec lecteur fermé.
- [ ] Tester lecteur absent, écritures partielles/interrompues et décision valide ;
      aucun diagnostic ni exception sur stdout du hook.

Le transport vers l'app est simulé. Cette reproduction d'une disparition du lecteur
ne démontre pas qu'une session CLI encore active a été interrompue en production.

### A22

**Réparer le faux CLI et rendre le verdict de sabotage causal.**
[test-codex-exec.py:62](https://github.com/mehdi7129/atoll/blob/a1c7d6999d6921906f26c405fc4f48e7bde30e91/Scripts/test-codex-exec.py#L62)
attend `app-server --listen stdio://` exactement, et rejette le préfixe
`-c features.plugins=false` ajouté pour la lecture des modèles. `--prepare-only`
échoue avant la préparation. Le mode sabotage accepte pourtant cette erreur
générique et annonce une détection du fichier d'instructions manquant.

Contre-épreuve : le mode sabotage affiche encore PASS quand la copie du produit
reste **strictement non sabotée**. Actualiser seulement les arguments attendus de
la fixture, dans une copie temporaire, fait passer la préparation nominale. Le
correctif de stockage produit reste intact ; le défaut démontré est dans son harness.

- [ ] Actualiser le contrat d'arguments factices, exiger un nominal vert avant le
      sabotage et vérifier la cause précise de l'échec après la mutation.
- [ ] Exiger qu'un sabotage neutralisé soit rejeté. Inclure ce harness hors ligne
      dans la commande commune/CI proposée ; séparer les recettes authentifiées.

Ces probes ne corrigent pas `Scripts/test-codex-exec.py` dans cette PR documentaire.

## Simplifier après avoir caractérisé les contrats

| Lot structurel | Extraction minimale | Justification et garde |
|---|---|---|
| Processus | Un petit exécuteur borné réutilisable, après inventaire des différences | A09/A10/A11 ; ne pas uniformiser auth, profils Codex, retry ou décisions fournisseurs |
| Curation | Store de transaction disque : archive, swap, restauration, checkpoint et état de lecture | A01/A02 ; façade observable et scheduler conservés, reprise locale avant tout modèle |
| Rétrospectives | Isoler le lifecycle des processus sans changer les API de la façade | A09 et exécution dupliquée ; conserver les séparations préparation/livraison existantes, sauf invariant concret à mieux tester |
| Sessions | Petites transitions de corrélation et snapshot diagnostic immutable | A06 ; éviter des décisions contradictoires entre carte et phase, conserver les autorités Claude/Codex distinctes |
| Plugins | Ownership des commandes, file des détails, cache versionné, recherche | A12/A13/A14 ; quatre responsabilités aujourd'hui réunies dans PluginInventory |
| Mémoire | Deux politiques d'ingestion explicites : flux JSONL et document Markdown | A04/A05/A18 ; garder transaction/dédup du flux, distinguer absence, erreur et contenu vide |

**Pas de framework de services, de conteneur DI global, de nouvelle base de données
ou de refonte SwiftUI.** Extraire seulement lorsqu'une dépendance ou un invariant
devient testable ; déplacer des lignes sans réduire le couplage n'est pas un résultat.

### Entretien à faible risque

- [ ] Retirer, après vérification des consommateurs, les fonctions test-only
      `CodexSessionDiscovery.discover` et `CodexHookSettingsEditor.needsMigration`.
      Les types `RunningProcess`/`Rollout` du premier sont également candidats.
      **Garder `Discovered`**, le registre, le scanner et les tests d'adoption qui
      les utilisent réellement. Aucun retrait de fichier entier par heuristique.
- [ ] Créer une commande offline courte et fiable regroupant Core + harnesses
      pertinents + contrôle documentaire, avec codes de sortie et compte rendu.
      Aucun workflow de tests n'est actuellement versionné ; la PR #7 n'affiche
      aucun status check. Proposer ensuite ce même contrôle en CI macOS, sans
      auth, génération, app normale ou publication automatique.
- [ ] Versionner les vérifications de distribution réutilisables déjà employées
      pour les releases : architectures, signatures imbriquées, archive/delta,
      assets et appcast. Leur résultat documentaire existe ; leur exécution ne
      doit pas dépendre de scripts conservés seulement sur un poste.
- [ ] Alléger les instructions de reprise : garder les règles actives et leurs
      liens dans `CLAUDE.md`, déplacer son historique détaillé vers une archive
      conservée. Aujourd'hui 1 700 lignes mélangent règles et incidents datés.
      Garder `CLAUDE.md` comme autorité des règles, HANDOFF pour l'état courant,
      les rapports datés comme preuves et la vision comme cadre produit.

### Mesurer avant d'ajouter une optimisation

L'I/O des notes/historiques sur MainActor, la recherche de racine Git depuis
ExpandedView, les tris répétés de NotchViewModel et les scans Markdown toutes les
30 s méritent une mesure avec un corpus/flotte représentatifs. Pas de fuite ou de
consommation excessive annoncée ici. Réutiliser `WorkspaceRoot` et les résolveurs
CLI existants seulement après comparaison des contrats. N'ajouter un cache ou un
snapshot que si la mesure justifie sa politique d'invalidation.

## Ordre de correction proposé

0. **Garde de validation** — A22 : nominal et sabotage causal fiables avant de
   s'appuyer sur ce harness pour les prochains changements Codex.
1. **Intégrité** — A01/A19, A02/A03, puis A07/A08 : sources, états et configurations
   conservés avant toute simplification. Petits commits séparés par scénario.
2. **Lifecycle et décisions** — A06, A09/A10/A11, A12 : une décision correctement
   corrélée, une opération annulée ciblée, une attente bornée ; A21 pour le fail-open.
3. **Mémoire exacte** — A04/A05/A18 : documents à jour, bon périmètre et reprise de lecture.
4. **Efficacité et feedback** — A13/A14/A20, A15/A16/A17 : concurrence bornée, données
   fraîches et retours conformes aux preuves.
5. **Entretien** — extractions locales liées aux lots précédents, code mort vérifié,
   commande de validation et documentation raccourcie. Aucune réécriture globale.

Pour chaque correction : test de caractérisation du nominal, test du défaut,
sabotage compilé de la garde avec échec à l'exécution, puis suite ciblée. Pour
chaque extraction : mêmes événements/résultats, clés de préférences, cadence,
seuils, modèles et sorties. Les changements touchant le rendu se vérifient par
captures de la copie protégée ; les sons par écoute et le jump-back sur terminal réel.

Critères communs : aucune source non archivée supprimée par consolidation, aucune
purge de manifeste sur accès incertain, politiques de désinstallation explicites
conservées, zéro signal sans identité, zéro nouveau spawn après annulation, délais
couvrant les drains et aucune dépense IA ajoutée. Mesurer les gains avant/après
lorsque le lot vise la performance.

## Ce qui reste acquis ou hors de ce chantier

- Compact, ASCII, palette, onde, huit onglets, « +N autres », Rockstar exclusivement
  Claude, mémoire partagée, opt-in et destinations distinctes restent les contrats.
- Le correctif 0.18.4 de staging Codex n'est pas remis en cause. Les tests quota
  actuels passent ; cet audit ne répète pas la campagne authentifiée de trente minutes.
- `history_mode=paginated` de Codex ne démontre pas une incompatibilité : le contrôle
  local des métadonnées confirme que les projections JSONL sont encore présentes et
  actualisées. Aucune migration spéculative vers la base privée de Codex proposée.
- Aucun empilement d'observers d'îlot démontré ; teardown et annulations existent.
  Les previews restent nécessaires, et AppDelegate demeure un point de composition
  légitime. Les marqueurs d'âge du registre sont des indices, pas des bugs.
- Les recettes Claude authentifiée et focus GUI réel déjà différées restent des
  limites, pas des succès réattribués à ce nouvel audit.

La PR peut être relue et priorisée indépendamment de toute implémentation.
Sa fusion éventuelle ne corrige pas l'app ; les lots ci-dessus feront l'objet
de changements et validations séparés.
