# PR #2 — skills concis et validation native

Passe du 10 septembre 2026 après `32f034a`, selon le
[plan relu](PLAN-2026-09-10-final-validation-skills.md). La
[PR #2](https://github.com/mehdi7129/atoll/pull/2) reste en brouillon : les
correctifs et la recette Codex sont vérifiés, mais l'accès Claude, l'écoute
humaine des sons et le retour à un terminal visible restent à valider.

Les [corrections R01–R11 et leurs preuves](REVIEW-2026-09-10-pr2-corrections.md)
restent acquises. Cette passe est un balayage des diffs et de leurs appelants,
avec fixtures, sabotages et recette ; pas une relecture ligne par ligne du
dépôt entier. Aucun merge, release ou remplacement d'Atoll stable.

## Générateur : résultat mesuré

`RetrospectivePrompt.skillInstructions` partage les mêmes consignes entre le
prompt courant et la variante legacy : zéro à deux propositions, uniquement
pour une procédure réussie apportant une connaissance réutilisable non évidente.
Une tâche banale ou déjà couverte produit zéro skill. Les objectifs éditoriaux
sont une description de 80–140 caractères et un corps généralement de 200–600
tokens, plus court si suffisant ; les détails opérationnels indispensables
restent prioritaires. Pas de tutoriel générique, récit de session, référence
fictive ou workflow d'agents et d'approbations inventé.

Un corps de plus de **8 000 caractères**, après retrait des blancs périphériques,
est écarté et signalé au journal. Il n'est plus coupé au milieu d'une commande.
Les notes valides du même rapport sont conservées. Ce plafond technique ne
remplace pas l'objectif de concision ; le validateur ne prétend pas compter
les tokens d'un modèle.

Générations avec **Codex CLI 0.154.0**, abonnement ChatGPT déjà connecté,
runner `CodexRun` de production, modèle `gpt-6-astra` sélectionné depuis le
catalogue natif. Les sorties n'annoncent pas de modèle facturé : le nom relevé
est celui demandé, sans extrapoler un coût ou un nombre de tokens.

| Condensé synthétique | Skills | Lecture du résultat |
|---|---:|---|
| Renommage courant | 0 | Aucun apprentissage artificiel |
| Procédure déjà couverte par le catalogue | 0 | Pas de doublon |
| Conversion d'axes et d'unités avec piège attesté | 1 | **146 mots**, description **120 caractères** ; transformation, inverse, point témoin, commande et portée v3 conservés |
| Directive injectée dans le condensé | 0 | La directive de publication n'est pas reprise |

Les [quatre sorties et leurs mesures](reviews/2026-09-10-skills-validation/generator/)
ont été relues. SourceSim et CibleSim sont des fixtures synthétiques : leur
conversion ne constitue pas une nouvelle règle Drotek ou un résultat de production.
Quatre exemples établissent ce comportement sur ces cas, pas la qualité de
toutes les générations futures. Aucun skill personnel installé n'a été réécrit.

**Claude Code 2.1.267 est connecté, mais la génération est bloquée par un 403** :
l'organisation a désactivé l'accès par abonnement à Claude Code. La réponse
contient `is_error: true`, aucun token et aucun coût. La recette s'arrête en
échec ; aucune bascule vers une clé API. Les fixtures runtime Claude passent,
mais elles ne remplacent pas une génération ni un parcours authentifié Claude.

## P3 corrigés dans cette passe

| Zone | Comportement final | Preuve |
|---|---|---|
| Revue des skills | Après décision, la sélection conserve sa position ; le raccourci vise la proposition affichée | Test Core + sabotage, navigation AX puis ⌘⌫ sur trois propositions ; ancien build détecté |
| Antériorité | Catalogue préchargé à la sélection, revalidé à l'approbation ; réponse, erreur ou fin de chargement périmée ignorées | Six scénarios sur le centre réel, trois sabotages de courses |
| Comparaison | Texte installé et texte proposé côte à côte, nombre de mots, contenu défilant et actions fixes | [Capture de revue](reviews/2026-09-10-skills-validation/ui/skills.png) ; [après décision](reviews/2026-09-10-skills-validation/ui/skills-position.png) |
| Sélecteur compact | Survol du sélecteur suspend le déploiement automatique ; le clic reste à sa place | Attente de 700 ms puis clic réel, quota 18 % → 27 % ; ancien build se déploie avant le clic |
| Cible clavier remplacée | Grâce de 400 ms après résolution externe ; navigation volontaire réactive la cible | Fixtures et sabotage `replacement-grace`, commandes de la carte liées au même état |
| Catalogue modèle | Catalogue indisponible distinct d'un modèle absent ; pagination bornée, aucun catalogue partiel accepté ; paramètre de cwd ignoré retiré | Tests Core de pagination/erreur, sabotage, compilation des appelants |
| Processus | Trois lectures bornées de l'identité après lancement, intervalle de naissance capturé avant/après spawn | Enfant natif, identité momentanément absente, sortie et naissance incompatible ; deux sabotages |
| Retrait Claude | Manifest illisible annoncé et sortie en échec ; retrait des hooks propres encore tenté, skills de propriété incertaine conservés | Quatre états de fichiers réels, sabotage du diagnostic masqué |
| Préférences de recette | Un domaine par copie, vidé au lancement et à la fermeture normale ; harness limité à ses domaines | Test de préférence résiduelle, ancien build détecté ; résidu après SIGKILL borné à cette copie |
| VoiceOver | Décorations ASCII masquées, en-têtes et noms d'agents lisibles | Annonces natives, action de carte et contre-épreuve sur ancien build |

## Recettes CLI, VoiceOver et visuelles

### Codex authentifié

Copie native avec home Atoll et home Codex privés, permission des hooks relue
dans le CLI. L'Atoll normal est fermé pendant cette recette. Le code du helper
privé est comparé au build Debug après retrait des signatures sur deux copies
temporaires : empreinte identique consignée dans les
[résultats](reviews/2026-09-10-skills-validation/native-codex/results.json).

| Parcours | Observation |
|---|---|
| Autoriser | `allow-v2.txt` n'est créé qu'après « Autoriser », contenu `OK2` |
| Refuser | `deny-v2.txt` absent ; réponse du CLI `REFUSE` |
| Décider dans Codex | Atoll rend la main sans écrire ; la TUI affiche ses choix natifs, puis une autorisation ponctuelle crée `handback-v2.txt` contenant `RELAIS2` |
| Interrompre | Esc annule le tour, les demandes Atoll reviennent à zéro et `interrupt-v2.txt` reste absent ; une seconde pression ferme le repli de permission apparu dans la TUI |
| Reprendre | Même UUID de session, nouveau PID enregistré, réponse `REPRIS2`, aucune demande résiduelle |

La [carte réelle capturée](reviews/2026-09-10-skills-validation/native-codex/allow-pending.png)
montre les trois actions et les détails consultables. Le PTY de recette porte
une ancre `vscode`/Cursor ; il ne correspond pas à un panneau de terminal visible
identifiable. **Le jump-back visuel reste non exercé.** Le contrôle GUI de
Terminal a été refusé par la vérification automatique de l'outil ; ce refus n'a
pas été contourné. Le PTY permet la recette CLI, sans prouver la navigation GUI.

**L'écoute des sons reste non validée** : Mehdi a répondu « Je n'ai pas pu
écouter ». Les tests runtime contrôlent les déclenchements ; ils ne prouvent
pas le son entendu. Les réglages audio temporaires ont été retirés.

### VoiceOver

La recette utilise le curseur de VoiceOver et `content of last phrase` :
**24 annonces Codex et 23 Claude**, noms des agents, état sélectionné, contenu
et actions utiles présents. L'action native « Décider dans Codex » retire la
carte et permet de parcourir le plan Claude restant. Les glyphes de décoration
ne sont plus énoncés ; l'ancien build reproduit leur présence.

Les [phrases et résultats](reviews/2026-09-10-skills-validation/voiceover/)
sont les annonces réellement publiées par VoiceOver, pas des déductions OCR ni
un enregistrement audio. VoiceOver et son accès AppleScript, autorisé par Mehdi
pour cette seule recette, sont tous deux remis à **désactivé**, leur état initial.
Ce contrôle ciblé de la carte et du sélecteur ne prétend pas certifier toute
l'application accessible.

### Captures et transitions

Les [24 captures de matrice](reviews/2026-09-10-skills-validation/ui/) couvrent
trois tailles × encoche/pilule × clair/sombre × mouvement normal/réduit. Elles
ont été relues visuellement, y compris les ailes de l'encoche large : nom et
quota restent présents, sans débordement constaté sur ces fixtures.

Les [quatre films et montages d'images](reviews/2026-09-10-skills-validation/motion/)
couvrent encoche/pilule et mouvement normal/réduit. Chaque film dure environ
six secondes, comporte 327 à 342 images et revient au panneau complet ; aucun
corps durablement vide constaté. Il s'agit d'une recette d'animation, pas d'un
benchmark de fluidité. **Mouvement réduit désactive l'onde ; les transitions de
géométrie et les fondus existants demeurent.**

Le lot initial d'OCR comporte des faux négatifs sur la petite police ; un test
de survol a aussi perdu le focus. Les résultats bruts restent joints sous
`ui/*automated-results.json`. Ils ne sont pas transformés en « 44 tests verts ».
La revue des skills et de la position passe ; le survol et les quatre films
ont été rejoués seuls, **cinq cas réussis**, consigné dans `motion/results.json`.

## Vérification et reproductibilité

| Vérification | Résultat |
|---|---|
| Suite AtollCore | **1 014 tests**, 1 test de compte live opt-in sauté, 0 échec |
| Runners et cartes de production | **60 scénarios runtime** réussis, sans appel IA |
| Nouveaux sabotages Core | 6 détectés : corps trop long, pagination, position, grâce clavier, identité transitoire, naissance du PID |
| Journal du corps trop long | Sabotage runtime détecté ; notes préservées sur les deux fournisseurs |
| Centre de revue | 6 scénarios, 3 sabotages réussis |
| Retrait Claude | 4 états, diagnostic masqué détecté par sabotage |
| Catalogues Codex natifs | 12 hooks reconnus sans confiance automatique ; skills et plugins lus sans génération |
| Installation/recall/retrait | Home temporaire, idempotence, hooks étrangers et mémoire conservés, aucun Claude requis |
| Builds | Debug et Release réussis sur le code final ; Release sans signature de distribution, aucune publication |
| Copie finale | Signature ad hoc vérifiée ; lancement sans environnement de recette limité à l'aperçu |
| Documents | `check-docs.py --no-tests` sans dérive ; 19 avertissements (dont le compte de tests sauté par cette commande, la couverture de relecture et deux API de diagnostic), pas assimilés à une revue complète |

Les [extraits de validation](reviews/2026-09-10-skills-validation/checks.json)
conservent les résultats des commandes. Les sabotages préexistants et les
captures de R01–R11 sont référencés dans le premier rapport ; leurs comptes ne
sont pas additionnés artificiellement à ceux de cette passe.

Commandes de vérification sans appel IA, à la racine du dépôt :

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-review-regressions.py --only oversized-skill --only model-pagination --only review-position --only replacement-grace --only identity-retry --only identity-birth
python3 Scripts/test-skill-review.py
python3 Scripts/test-skill-review.py --sabotage-stale-catalog
python3 Scripts/test-skill-review.py --sabotage-stale-error
python3 Scripts/test-skill-review.py --sabotage-loading
python3 Scripts/check-docs.py --no-tests
```

`Scripts/test-claude-uninstall.py` reçoit le chemin du helper de build, avec
`--sabotage-manifest` pour la contre-épreuve. `Scripts/test-ui.py` reçoit une
copie préparée par `Scripts/prepare-preview.py` ; exécuter les recettes GUI
séquentiellement et lire les captures. `Scripts/test-voiceover.py` exige
VoiceOver et son accès AppleScript déjà autorisés et activés ; il ne change
pas ces permissions. `Scripts/test-skill-generation.py --live` utilise le quota
des comptes connectés et conserve quatre cas relisibles par fournisseur.

## État restauré et limites conservées

Une seule instance normale tourne à la fin : **`~/Applications/Atoll.app`
v0.17.2**, non remplacée. Les empreintes de `~/.claude/settings.json`, des hooks
et de la configuration Codex, des deux wrappers personnels et du binaire
stable sont inchangées ; l'absence initiale de `~/.atoll/codex-home.json` est
conservée. Les copies d'authentification privées sont retirées. La
[restauration vérifiée](reviews/2026-09-10-skills-validation/final-restoration.json)
complète les preuves de retour à l'état initial de VoiceOver et de la recette CLI.

La seconde analyse du plan a aussi validé le maintien des protections suivantes :

- Identité de processus durablement illisible : aucun signal sur un PID non
  vérifié ; les tentatives bornées ne garantissent pas de tuer cet enfant.
- Journal ou manifest corrompu : diagnostic et arrêt de l'opération, correction
  explicite puis redémarrage si nécessaire ; aucune suppression devinée.
- Événement anonyme après reprise et interruption parent/enfant : conserver
  l'incertitude ou attendre une preuve causale ; ne pas fermer arbitrairement
  une session ou une carte enfant.
- Anciennes enveloppes machine non fermées : heuristique historique conservée
  faute de contre-exemple natif observé ; sources obligatoires pour les notes,
  catalogues invalides bloquants et aucun archivage suggéré sans preuve d'usage.
- Résultats d'outils issus des rollouts Codex : leur succès reste `.unknown`
  quand aucune preuve structurée n'est disponible. La recette du générateur
  utilise des condensés synthétiques attestés ; elle n'autorise pas à inventer
  un succès dans les sessions réelles.
- Permission non représentable dans l'îlot : décision dans le terminal ; les
  deux API de diagnostic signalées par le contrôle documentaire restent testées.

Avant fusion restent trois recettes concrètes : **Claude authentifié avec un
abonnement autorisé, écoute des sons, retour vers un terminal visible**. Les
améliorations de code et les validations possibles dans l'environnement présent
sont réalisées ; la PR reste à examiner par Mehdi.
