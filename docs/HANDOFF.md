# HANDOFF — reprendre Atoll

État courant du **9 octobre 2026**, audit clôturé et maintenance publiée. Les règles
actives restent dans [CLAUDE.md](../CLAUDE.md), avec leur
[archive intégrale](archive/CLAUDE-2026-10-08.md). Les sections historiques en fin
de fiche décrivent leur date ; elles ne remplacent pas l'état courant ci-dessous.

## État courant : 22 constats corrigés et livrés, 0.18.6 publiée

La version publiée est **[v0.18.6, build 41](https://github.com/mehdi7129/atoll/releases/tag/v0.18.6)**.
Le [rapport d'intégration](REVIEW-2026-10-08-audit-completion.md) suit les **22 constats** :

- **Trois livrés** en 0.18.5 : A01, A19 et A22.
- **Quatre livrés en 0.18.6** : A02/A03 par
  [#14](https://github.com/mehdi7129/atoll/pull/14), merge `13dad53`, puis A07/A08
  par [#15](https://github.com/mehdi7129/atoll/pull/15), merge `0016c0c`.
- **Quinze livrés en 0.18.6 après fusion de la PR #16**, source produit `9eaa69d` : mémoire,
  permissions Claude, lifecycle des processus, plugins et feedback.
  La [PR #16](https://github.com/mehdi7129/atoll/pull/16) est fusionnée le 9 octobre,
  merge `fd763f70ea2b8ca8114f71dcc7c82feec2cf5c06`, après validation commune.

Les 22 constats sont corrigés et livrés : trois en 0.18.5 et dix-neuf en
**0.18.6, build 41**. Cette maintenance part de `3e10e804`, après fusion de la
[préparation #17](https://github.com/mehdi7129/atoll/pull/17), avec le code produit
qualifié inchangé. La publication n'a remplacé aucune app installée.

App et DMG universels arm64 / x86_64 signés Developer ID, notarisés,
staplés et acceptés par Gatekeeper. Les 6 signatures Sparkle sont vérifiées
et leurs 6 copies altérées rejetées. Le différentiel 40 → 41 et l'app du DMG
reproduisent les 134 fichiers, liens et modes du ZIP complet.
Les 7 téléchargements publics correspondent aux SHA256 et tailles validés ;
les 19 URL contrôlées sont disponibles. Le flux Sparkle a été publié après les
assets et sert les octets vérifiés, avec 0.18.6/build 41 en tête.
[Relevé de livraison](releases/0.18.6.json).

L'app stable, les quatre produits Debug et les trois configurations contrôlés
sont identiques entre la reprise de publication et son achèvement. Une différence
de `config.toml` a été constatée entre le snapshot avant packaging et la reprise,
d'origine indéterminée ; l'intégrité de cette configuration n'est pas revendiquée
sur cet intervalle. Les contrôles initiaux des tests restent des preuves séparées.

Les suites Core Debug et Release passent chacune **1 131 tests, un skip et
zéro échec**. La reprise Release dure 11,1 s, sans modifier sources ni tests.
Le premier passage du 9 octobre
avait six échecs sous une charge système supérieure à 600 ; il reste conservé
dans les preuves. Huit tests ciblés ont ensuite passé avant la reprise complète.
Les builds Debug et Release finaux passent, sans lancement de leurs produits.
Le profil offline full comporte 120 étapes et 85 variantes nommées : 119 étapes
passent immédiatement ; A21 passe après correction du chemin Unix de sa fixture
et rejeu nominal/mutant. Son résultat brut reste `failed` avec exit 1 ; le
[relevé consolidé](audit-support/2026-10-08-completion/validation.json) conserve
cette histoire et conclut `passed`, sans échec non résolu.
La [CI standard passe 26 étapes sur 26](https://github.com/mehdi7129/atoll/actions/runs/37898153598)
sur `3e10e804`, la source exacte de la release. Les contrôles documentaires
après publication sont séparés de cette exécution.

L'intégration #14 → #15 a passé **1 129 tests Core**, un skip, zéro échec,
190 parcours services, 12 parcours helper et les sabotages ciblés, puis les
builds Debug/Release. Les validations propres aux nouveaux lots sont détaillées
et séparées dans le rapport : elles ne remplacent pas le contrôle de l'arbre final.
Le lot processus passe 17 parcours de services et douze sabotages compilés.
Le nominal plugins passe 145 assertions et ses douze sabotages finaux sont
compilés et détectés. Les huit contre-épreuves du runner offline passent, dont le nettoyage
d'un descendant survivant au leader après timeout.
Les [interactions GUI A16/A20](REVIEW-2026-10-09-ui-refresh.md) passent : deux
nominaux, trois mutants compilés détectés et neuf captures effectivement lues.
La saisie du home et le lecteur catalogue sont injectés ; ces preuves ne
qualifient pas une saisie clavier AppKit ni un CLI authentifié.

Les contre-reviews ont également corrigé la fermeture d'un helper déjà sorti
(`ENOTCONN`), l'ordre de deux jumps successifs, l'offset JSONL après un premier
lot validé et le maintien du budget d'un enfant encore vivant après timeout.
Les captures d'aperçu restent distinctes de l'écoute humaine et du focus sur un
terminal authentifié, qui ne sont pas qualifiés par les fixtures.

Après installation de **0.18.6/build 41**, Mehdi confirme avoir entendu les deux
préécoutes et que **OUVRIR DANS CURSOR** ouvre bien Cursor. La CI de `9d95536`
sur `main` passe 26 étapes sur 26. Le [relevé d’usage](REVIEW-2026-10-09-installed-checks.md)
limite cette confirmation à l’ouverture de l’application ; aucun onglet Terminal
ni fichier précis Cursor n’est qualifié par ce geste.

Les vérifications de distribution sont [versionnées](RELEASE-VALIDATION.md).
Leur première qualification sur 0.18.5 et la livraison de 0.18.6 ont chacune
leurs preuves ; les résultats de l'ancienne release ne sont pas réattribués.
Les instructions actives ont été raccourcies sans retirer leur archive. La
[commande offline et la CI macOS](VALIDATION.md) sont intégrées, ainsi que le
retrait des API inutilisées ; la validation consolidée de cet ensemble est terminée.
L'audit initial et son contre-audit (#8), réunis par `c25923f`, sont désormais
sur `main` grâce à #16, avec les 30 entrées de relecture d'origine conservées.
La PR documentaire #8 est également marquée fusionnée après son intégration via #16.
Le store de curation et le snapshot
diagnostic des sessions restent des extractions conditionnées à un gain concret
de testabilité ; les invariants locaux sont testés sans refonte de ces façades.
Les pistes de performance non mesurées ne sont pas déclarées corrigées.
Les quatre tâches d'entretien sont terminées : API inutilisées retirées,
commande offline et CI communes, vérificateurs de distribution versionnés,
instructions actives séparées de l'archive conservée.

Avant de reprendre : `git status --short --branch`, `git log -5 --oneline`,
`git worktree list`, puis vérifier la PR et la release courantes. L'app installée
observée après la mise à jour de Mehdi le 9 octobre est **0.18.6/build 41** ;
vérifier son état réel avant toute action. Une fusion ou un build ne met pas à jour cette app.

**Checkouts :** le dossier original `~/Desktop/Dynamic_Island` est propre mais
reste sur `codex/atoll-future-exploration`, commit `65ce2b6`, avec un commit
divergent lié à la PR #6. Il a été préservé, sans changement de branche.
Les corrections sont sur `main` et dans le worktree d'intégration
`~/Library/Caches/atoll-audit-completion-20261008`. La livraison a été préparée
et vérifiée dans `~/Library/Caches/atoll-release-0.18.6-20261009`. Le dossier du Bureau
n'est pas une copie mise à jour de ces corrections ; vérifier la branche avant
de choisir un checkout de reprise.

## Comportement du code actuel

- Atoll suit **Codex CLI dans le terminal**, Claude Code, ou les deux. Le bouton
  choisit les sessions affichées, la palette et le quota. Les deux collecteurs
  restent actifs ; une carte garde son fournisseur jusqu'à sa résolution.
- Le moteur des trois analyses et la destination des skills sont deux choix
  distincts du bouton d'affichage. Apprentissage et failover sont opt-in.
- Îlot invisible sans activité ni Rockstar ; liste bornée avec « +N autres » ;
  sélecteur dans le panneau ouvert ; Rockstar exclusivement Claude, marqueur et quota
  simultanés. Questions, plans et interruption Codex restent dans le terminal.
- Hooks Codex migrés avec sauvegarde, retraits et personnalisations respectés ;
  réparation complète explicite. `config.toml` n'est jamais écrit par Atoll.
- Mémoire commune aux deux CLI. Recall manuel disponible des deux côtés ;
  injection proactive Codex désactivée faute de contrat vérifié.
- Skills : zéro proposition pour une tâche banale ou déjà couverte ; corps
  généralement de 200–600 tokens, procédures utiles et commandes préservées.
  Au-delà de 8 000 caractères, refus tracé, jamais troncature. La revue compare
  avec l'installation, précharge l'antériorité et conserve la sélection.

## Limites à connaître, pas des tâches à relancer aveuglément

1. **Claude authentifié** : le test de génération a reçu un 403 d'accès abonnement.
   Mehdi confirme maintenant ne plus disposer d'un abonnement Claude. Différer
   cette recette jusqu'à disponibilité d'un accès ; ne pas basculer sur une clé API.
2. **Retour à l'application / onglet Terminal** : le retour à Cursor est confirmé
   par Mehdi sur 0.18.6. Cela qualifie l'ouverture de l'app, pas un onglet précis.
   Le contrôle GUI refuse Terminal et la fixture synthétique a expiré ; la recette
   d'un onglet Terminal reste non qualifiée. Aucun échec du bouton n'est établi.
3. **Protections conservées** : aucun signal vers un PID non vérifié, aucun succès
   d'outil Codex inventé, aucune réparation destructive de journal/manifest,
   sources de notes obligatoires et catalogues invalides bloquants. Événements
   anonymes et interruptions parent/enfant restent incertains sans preuve causale.
4. **Mouvement réduit** désactive l'onde ; les fondus et transitions de taille
   existants demeurent. L'OCR ne remplace ni la lecture des captures ni VoiceOver.

Les fusions et publications antérieures ont eu lieu avec l'accord de Mehdi malgré les deux recettes différées.
Ne pas les déclarer réussies lors d'une reprise de session.

## Vérifier ou modifier

Avant de croire un document et après toute modification documentaire :

```sh
python3 Scripts/check-docs.py --no-tests
```

Pendant une préparation de release, ajouter `--preflight` tant que l'appcast
n'a pas été régénéré. Après publication, utiliser `--no-tests --network` pour
les URL des assets et le flux GitHub Pages réellement servi.

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-skill-review.py
python3 Scripts/test-release-trash.py
```

Les sabotages ciblés sont documentés dans les rapports. Une compilation ratée
n'est jamais une régression détectée. Ne relancer une génération `--live` que
si elle répond à une question nouvelle : elle consomme le quota du compte.

Pour compiler, suivre le [README](../README.md). Ne jamais lancer le produit
`Build/Products` ni recopier un Debug sur l'app stable. `Scripts/prepare-preview.py`
crée une copie protégée dans `/private/tmp`, fictive même rouverte sans arguments.
`Scripts/test-ui.py` et `Scripts/test-voiceover.py` utilisent cette copie.

La recette authentifiée utilise `Scripts/prepare-cli-validation.py` : deux homes
privés vérifiés, hooks privés et copie native. **Fermer l'Atoll normal avant de
lancer la copie native** ; ne jamais avoir deux instances normales. Retirer les
copies d'authentification et restaurer les préférences et l'app stable à la fin.
Ne pas activer un accès VoiceOver temporaire sans l'autorisation correspondante.

## Publier une prochaine version

1. Mettre à jour version **et** build dans `project.yml`, README et cette fiche.
2. Tester, committer et fusionner le code ; garder l'appcast courant servi.
3. `zsh Scripts/release.sh` : signature Developer ID, notarisation app et DMG,
   staples, ZIP signé Sparkle, deltas. Le nettoyage passe par la corbeille.
4. Publier DMG, ZIP et deltas de **ce build** sous leur tag. Vérifier toutes les
   URL référencées : les entrées anciennes restent sous leurs propres tags.
5. Pousser `docs/appcast.xml` en dernier, attendre GitHub Pages et vérifier le
   flux servi avec `check-docs.py --no-tests --network`. Mettre cette fiche à jour.

Profil notarytool : `atoll-notary`. Clés de signature dans le Keychain ; ne jamais
les exporter dans les logs ou le dépôt. Préserver le DerivedData Debug et les
archives `dist/updates`. Les anciennes sorties remplacées restent récupérables
à la corbeille. Une nouvelle release ne nécessite pas de réinstaller l'app stable.

Incident local du 10 septembre : 44 copies non suivies suffixées « 2 », toutes
identiques aux originaux et absentes des six listes de compilation Release, ont
été conservées dans `/private/tmp/atoll-018-sync-copies-yjutnk0r/` avec manifeste.
La cause reste indéterminée ; si elles réapparaissent, comparer avant de déplacer,
sans les intégrer au build ni supprimer un changement distinct.

## Références utiles

- [Validation finale, preuves et P3](REVIEW-2026-09-10-skills-validation.md)
- [Correction du compact, contexte et configuration](REVIEW-2026-09-10-island-context-setup.md)
- [Plan skills et seconde analyse](PLAN-2026-09-10-final-validation-skills.md)
- [Corrections R01–R11](REVIEW-2026-09-10-pr2-corrections.md)
- [Contrat Codex / Claude](CODEX-INTEGRATION.md), [analyses et passation](CODEX-FAILOVER.md)
- [Vision produit](VISION-2026-08.md) : soustraire avant d'ajouter

Le rendez-vous du recall est **clos et tranché depuis le 9 septembre**. Ne pas
reprendre les anciennes mentions « décision en attente » : mesures et choix
sont conservés dans `CLAUDE.md` et l'archive historique.

## Historique daté — livraisons et validations antérieures

Les résultats et états d'installation ci-dessous sont conservés comme preuves
datées. Les mentions « en revue » des lots A02/A03 et A07/A08 décrivent leur
préparation, avant les fusions indiquées en tête de cette fiche.

### 8 octobre 2026 — A07/A08 avant fusion de la PR #15

La branche `fix/a07-a08-preserve-hook-groups`, basée sur `aed6546`, corrige
la restitution des sons dans leur groupe d’origine et les doublons Atoll
dans les groupes mixtes. Le helper normalise aussi les anciennes installations
complètes concernées. Les hooks tiers, les métadonnées et les modes de recall
sont préservés ; les fichiers illisibles sont conservés pour reprise.

Validation : **1 119 tests Core**, un skip, zéro échec ; **12 parcours du
vrai helper**, **25 sabotages compilés détectés**, builds Debug/Release réussis
sans signature ni lancement. Les configurations personnelles, l’app installée
et les produits Debug habituels sont contrôlés identiques.
[Rapport et commandes](REVIEW-2026-10-08-a07-a08-hooks.md),
[relevé de validation](audit-support/2026-10-08-a07-a08/validation.json).

Ce lot est indépendant de la [PR #14](https://github.com/mehdi7129/atoll/pull/14)
(A02/A03, intégrité des états et manifestes), également en revue. Aucune de
ces quatre corrections n’est encore distribuée. La release reste **0.18.5,
build 40**. L’app installée observée lors de cette recette est désormais cette
version ; les observations plus anciennes
ci-dessous décrivent le moment de leur propre validation.

### 8 octobre 2026 — A02/A03 avant fusion de la PR #14

Le [lot suivant](REVIEW-2026-10-08-a02-a03-integrity.md) protège l’état illisible
du rangement et conserve le manifeste des skills quand leur accès échoue.
Réparation et diagnostics utilisent les chemins existants ; cadences, modèles,
destinations et interface sont conservés. La branche part de `aed6546` ;
**la release publique reste 0.18.5 / build 40**.

Validation : **1 102 tests Core (un skip, zéro échec)**, 190 parcours de services,
14 nouveaux sabotages compilés et un sabotage existant de reprise détectés,
builds Debug et Release réussis. Contre-revue favorable après correction de
trois régressions intermédiaires. Aucune recette GUI ni génération authentifiée.
[Synthèse et limites](audit-support/2026-10-08-a02-a03/validation.json).
Ces deux points restent distincts des trois déjà livrés ; A07/A08 viennent ensuite.

### v0.18.5, build 40 — publiée

La [release de maintenance](https://github.com/mehdi7129/atoll/releases/tag/v0.18.5)
est publiée depuis `74b0081`, après fusion de la préparation
[#13](https://github.com/mehdi7129/atoll/pull/13). Elle livre les trois correctifs
ci-dessous, sans ajout de fonction ni changement d'interface : échec d'archivage
sans perte du skill installé, collision de notes sans perte de l'original et
reprise locale sans nouvel appel au modèle, harness Codex fiabilisé.

App et DMG universels arm64 / x86_64 signés Developer ID, notarisés et staplés,
acceptés par Gatekeeper. Les six signatures Sparkle sont vérifiées et six
copies altérées rejetées. Le différentiel 39 → 40 et l'app du DMG reproduisent
les 134 fichiers, liens et modes du ZIP complet. La suite Core en configuration
Release passe : **1 092 tests, un skip live opt-in, zéro échec**.
Sept téléchargements publics vérifiés par SHA256 et taille ; 19 URL disponibles.
Appcast `e5bde85` publié après les assets, servi à l’identique avec 0.18.5/build 40 en tête.
[Relevé de livraison](releases/0.18.5.json).

L'app stable **v0.18.4/build 39**, quatre produits Debug et trois configurations
personnelles contrôlés restent identiques. Aucune app installée n'est remplacée ;
la mise à jour reste à appliquer par l'utilisateur. Le produit Release n'a pas
été lancé et aucune génération authentifiée n'a été nécessaire pour publier.

### Premier jalon de robustesse — livré en v0.18.5

Les PR [#9](https://github.com/mehdi7129/atoll/pull/9),
[#10](https://github.com/mehdi7129/atoll/pull/10) et
[#11](https://github.com/mehdi7129/atoll/pull/11) sont fusionnées dans cet ordre
le 8 octobre : `6d259ed`, `923d5db`, puis `65b7d52`.

- [A22](REVIEW-2026-10-08-a22-codex-harness.md) : faux CLI Codex aligné sur les
  arguments courants, nominal obligatoire et verdict de sabotage précis.
- [A19](REVIEW-2026-10-08-a19-skill-archive.md) : un échec d'archive conserve
  le skill installé et son entrée du manifeste pour une nouvelle tentative.
- [A01](REVIEW-2026-10-08-a01-curation-collision.md) : conflit avec une note
  non archivée refusé avant bascule, résultat conservé pour reprise locale.

Les fusions locales successives ont passé les tests Codex et leurs cinq
contre-épreuves, **1 092 tests Core (un skip, zéro échec)**, 104 scénarios de
récupération et 26 de curation, les sabotages ciblés et un build Debug.
L'arbre Git final `7cd1fac5474161c0b421b0f8e655e74ad0a89034` est identique
au témoin testé. Les deux conflits dans `docs/reviews.json` ont été résolus en
conservant l'historique et les trois entrées ; aucun conflit de code.
[Relevé d'intégration](audit-support/2026-10-08-milestone1/validation.json).

Cette validation utilise des fixtures privées et les services compilés, sans
génération authentifiée ni lancement GUI. Les trois correctifs sont distribués
en **v0.18.5, build 40**, sans remplacement de l'app installée. Les autres
constats de l'audit #8 restent à traiter séparément.

### v0.18.4, build 39 — publiée

Mehdi a demandé la release le 7 octobre pour mettre à jour son app lui-même.
La [PR #7](https://github.com/mehdi7129/atoll/pull/7) est fusionnée, tag sur
`9790b4e` ; le code du correctif `a948e25` est inchangé. La
[release](https://github.com/mehdi7129/atoll/releases/tag/v0.18.4) et le flux
Sparkle sont publiés : app/DMG universels signés, notarisés et staplés, six
signatures EdDSA et sept téléchargements SHA256 vérifiés. Le différentiel
38 → 39 et l'app du DMG reproduisent les 134 objets du ZIP complet.
[Relevé de livraison](releases/0.18.4.json). Flux servi identique aux octets
locaux, build 39 en tête ; 19 URL vérifiées. L'app stable n'est pas remplacée.

Le [rapport du 7 octobre](REVIEW-2026-10-07-codex-storage.md) décrit le correctif
qui désactive la synchronisation des plugins pour les lectures quota/modèles,
borne la fermeture des enfants et sérialise les relances du poller. Les
inventaires conservent leur profil. Aucun `config.toml` personnel n'est écrit.

Validation : **1 089 tests Core**, un skip, zéro échec ; huit scénarios quota,
15 sabotages compilés détectés, 60 parcours runtime et builds Debug/Release.
La mesure authentifiée de trente minutes passe : **16 quotas frais, zéro Git
et zéro staging**, sept modèles disponibles. Elle exerce le transport compilé
dans un home privé, pas la GUI authentifiée. La publication utilise une copie
locale hors iCloud. Sur le poste, l'app stable observée avant publication est
**v0.18.3, build 38** et son affichage du quota Codex a été désactivé. Les états
d'installation datés de septembre ci-dessous sont historiques.
Après la mise à jour, réactiver le quota dans Réglages → Codex si souhaité.
La release ne modifie pas cet opt-in et ne supprime aucun ancien staging.

### v0.18.3, build 38 — publiée

[Release](https://github.com/mehdi7129/atoll/releases/tag/v0.18.3) autorisée par
Mehdi le 23 septembre, tag sur `d438b8e`. Code produit identique à `30847d6`,
déjà validé avant fusion. App et DMG universels signés Developer ID, notarisés,
staplés et acceptés par Gatekeeper ; six signatures Sparkle vérifiées.
Le différentiel 37 → 38 reproduit fichiers, liens et modes de l’archive complète.
[Relevé de livraison](releases/0.18.3.json). Les assets ont précédé le flux ;
GitHub Pages sert le build 38, vérifié avec `check-docs.py --no-tests --network`.
L’app installée n’est pas remplacée ; appliquer la mise à jour depuis Atoll ou le DMG.

### PR #5 fusionnée — corrections du rendement de l’apprentissage

Mehdi a autorisé les corrections de l’[audit du 11 septembre](AUDIT-2026-09-11-learning-efficiency.md).
La [PR #5](https://github.com/mehdi7129/atoll/pull/5) est **fusionnée sur `main`**
le 23 septembre à sa demande : merge `8b7e9a9`, depuis la tête testée `30847d6`.
L’arbre de la fusion est identique à celui testé ; aucun conflit ni changement
de code pendant la fusion. La mise à jour de cette fiche est documentaire.
Ces corrections sont publiées en v0.18.3. L’app installée reste sur v0.18.2
tant que sa mise à jour n’a pas été appliquée.
Le [rapport de correction](REVIEW-2026-09-22-learning-efficiency.md) décrit les preuves,
les commandes de test et les limites ; l’audit initial reste un constat historique.

- Sorties sauvegardées avant livraison, écritures confirmées et reprise locale
  au démarrage ou avant une nouvelle analyse. Un résultat incomplet ne marque
  pas la session traitée ; une destination différente ne reçoit jamais l’ancien résultat.
- Même condensé déjà traité : aucun nouvel appel automatique. Rangement :
  annulation persistée, empreinte du corpus après succès, relance manuelle conservée.
- Antériorité bornée des notes, propositions, refus et installations ; catalogue
  Claude remontant au projet. Les doublons exacts sont filtrés avant livraison.
- Usage natif et inconnues explicites, durée, taille du prompt et résultats
  conservés dans le journal existant. Digest : coupures et bornes distinctes,
  conclusions mieux préservées, commandes tronquées signalées.

Validation du 22 septembre : **1 070 tests Core, un skip opt-in et aucun échec**,
**135 parcours** dans les quatre harnesses runtime, **34 sabotages détectés**,
builds Debug/Release et contrôle documentaire réussis. L’interface n’a pas été
réorganisée dans ce lot ; aucune app n’a été lancée pour cette validation.

Les premières recettes ([initiale](REVIEW-2026-09-22-learning-live.md),
[profil allégé](REVIEW-2026-09-22-codex-lean.md)) sont historiques.
La [correction suivante du générateur](REVIEW-2026-09-22-generator-quality.md)
traite la séparation note/skill, les comptes rendus inutiles et le rejet silencieux
pour identifiant trop long. Le schéma annonce les 2–40 caractères réellement admis ;
le parseur signale les rejets sans exposer de champ non validé. Les identifiants
présents dans le résumé ne sont plus envoyés deux fois ; les autres sont conservés.

Dernière comparaison : **28 988 → 8 894 tokens d’entrée (−69,3 % depuis le départ,
−6,1 % depuis le profil allégé)**. Cas banal vide, préférence en note, export en
skill complet de 118 mots. Deux autres abstentions et une procédure indépendante
ont été validées avant l’ultime précision sur les notes. **10 appels dans ce lot :
44 468 tokens d’entrée, 3 203 de sortie**, diagnostics inclus. Les captures brutes,
échecs initiaux et revalidations hors ligne sont conservés ; ne pas repayer ces
appels à chaque reprise. Les mesures ne garantissent pas le rendement de toute session.

Validation finale : **1 078 tests Core, un skip, zéro échec**, 25 scénarios de contexte,
26 parcours rétrospectives, deux sabotages compilés, builds Debug/Release et contrôle
documentaire. Vérificateur : 15 bons rapports et 28 contre-épreuves. Trois usages
finaux rejoués dans le journal sans nouvel appel. Instructions globales et outils
résiduels Codex subsistent ; le flux JSON n’expose pas tous les appels de wrappers.
Le runtime conserve le home choisi, les modèles et configurations personnelles.

Suite du 23 septembre : le [rangement des notes reprend son résultat sauvegardé](REVIEW-2026-09-23-curation-recovery.md)
après un échec local, avant toute capture du modèle ou réservation de budget.
La reprise vérifie les notes, la provenance et les contradictions ; un corpus changé
ne reçoit jamais une ancienne réponse. Aucun nouvel appel IA dans cette validation.
La reprise reste liée au bouton ou à l’échéance autorisée, sans nouvel automatisme
au démarrage. Les mesures de tokens ci-dessus restent celles du 22 septembre.
Validation du lot : **1 083 tests Core (un skip, aucun échec)**, 98 parcours de
reprise, 26 de cadence/annulation, 60 runtime, sept sabotages compilés détectés
et builds Debug/Release. Cas de crash reconstitués, CLI factices ; preuves liées.
Un début de remplacement est journalisé ; en cas ambigu, fichiers et résultat
restent conservés, sans nouveau modèle. Lire les limites du rapport avant de
supprimer un checkpoint ou un staging manuellement.

Les fichiers du Bureau étant partiellement déchargés par iCloud, la validation
utilise une copie locale : `/private/tmp/atoll-learning-local-20260922`.
Les changements sont aussi présents dans le dossier d’origine, revenu sur `main`. Xcode 27 nécessite
le composant Metal ; les harnesses Swift utilisent provisoirement `--build-system native`.
Ne pas relancer des builds dans le Bureau tant que les fichiers ne sont pas hydratés.

Incident sonore du 22 septembre sur le poste : le son de fin Atoll se superposait
à la cloche de Codex dans Cursor. Correctif local, aucun changement Swift :
`accessibility.signals.terminalBell.sound = "off"` dans Cursor, avec sauvegarde.
État vérifié dans son UI et avec les fonctions installées de sélection du son ;
accessibilité toujours active, annonce conservée, toutes les cloches de terminaux
Cursor désormais muettes. Écoute humaine non effectuée. Ne pas désactiver les sons
Atoll ni modifier `config.toml` pour reproduire ce correctif.

### v0.18.2 publiée — réglages réorganisés

Mehdi a demandé la fusion et la release le 11 septembre. La
[PR #4](https://github.com/mehdi7129/atoll/pull/4) est **fusionnée** sur `main`
(`9e93bb3`), depuis le code vérifié `e50e269` de `codex/settings-ux`.
La **[v0.18.2, build 37](https://github.com/mehdi7129/atoll/releases/tag/v0.18.2)**
est publiée depuis `66aaba4`, sans changement du code testé. Le flux Sparkle
servi propose le build 37 ; les fichiers publics et leurs signatures sont vérifiés.

[Plan validé](PLAN-2026-09-11-settings-organization.md),
[recette et seconde lecture](REVIEW-2026-09-11-settings-organization.md).
L'organisation est implémentée : mémoire commune et modèles dans Apprentissage,
raccourci direct depuis Codex, destination des skills près de leur revue,
alertes communes et anciens sons Claude distingués, Autonomie explicitement
Claude, vérification manuelle des mises à jour. Diagnostics et longues listes
sont repliés ; erreurs et actions indispensables restent accessibles.
Builds Debug/Release, 1 020 tests Core (un skip), 58 parcours UI et six sabotages
validés. Captures des huit onglets et limites de recette dans le rapport lié.

Les clés des préférences et les services sont conservés. Le code des gros volets
Claude et Apprentissage a quitté `SettingsView.swift` pour des fichiers dédiés.
La recette protégée peut maintenant ouvrir la vraie scène macOS Settings avec
`--preview-all-settings --preview-settings=codex` ; elle conserve un domaine de
préférences privé et simule ses actions externes. Ne jamais tester ces actions
sur la copie stable. Les anciens rapports de [première simplification](REVIEW-2026-09-11-settings-ux.md)
sont historiques ; la maquette validée reste dans `docs/mockups/2026-09-11-settings/`.

Lors de cette release, l’app stable était **v0.18.1, build 36**. Ses fichiers, les deux builds Debug
et les huit configurations personnelles contrôlées sont identiques avant/après
cette release ; la publication n'a installé aucune app.

### Livraison 0.18.5 — relevé historique du 8 octobre 2026

| Élément | État vérifié |
|---|---|
| Version publiée | **[v0.18.5, build 40](https://github.com/mehdi7129/atoll/releases/tag/v0.18.5)** |
| Fusion / source | Correctifs #9 → #10 → #11 fusionnés ; préparation [#13](https://github.com/mehdi7129/atoll/pull/13) ; source `74b0081` |
| Distribution | Universelle arm64 / x86_64 ; app et DMG signés Developer ID, notarisés, staplés et acceptés par Gatekeeper ; six signatures Sparkle vérifiées |
| Téléchargements publics | Sept assets téléchargés ; SHA256 et tailles conformes aux fichiers validés |
| Mise à jour | Appcast `e5bde85` poussé après les assets, identique au flux servi ; 19 URL disponibles |
| Référence précédente | v0.18.4, build 39 ; [preuves de sa livraison](releases/0.18.4.json) |
| Tests fonctionnels | Ordre #9 → #10 → #11 validé : 1 092 tests Core, un skip, zéro échec ; 104 scénarios de récupération, 26 de curation, Codex nominal et cinq contre-épreuves, sabotages ciblés et Debug réussis. Core Release : 1 092 tests, un skip, zéro échec |
| Recettes de distribution | Différentiel 39 → 40 et app du DMG comparés aux 134 objets du ZIP complet ; six copies altérées rejetées par les signatures Sparkle ; produit Release non lancé, aucune génération authentifiée |
| Installation de travail | `~/Applications/Atoll.app` **v0.18.5, build 40**, observée le 8 octobre pendant le lot A02/A03 ; app, quatre produits Debug quotidiens et trois configurations personnelles inchangés pendant ces tests |

Vérifier l'état réel avant toute action : `git status --short --branch`,
`git log -5 --oneline`, `git worktree list`, puis `gh release view`.
Une source publiée et une app installée peuvent avoir des versions différentes.
Le [relevé de livraison](releases/0.18.5.json) conserve les commits, identifiants
de notarisation, résultats et empreintes des fichiers distribués.

### Correctifs après le retour sur v0.18.0

Branche `codex/island-context-setup`, base `25132e3`, correctifs `88ecbb2`.
**Livrés en v0.18.1, build 36**, après fusion de la
[PR #3](https://github.com/mehdi7129/atoll/pull/3) et publication autorisées par Mehdi.
Il a confirmé le retour au compact d'origine : activité à gauche, quota à droite,
couleurs du CLI, choix du fournisseur uniquement dans le panneau ouvert.

- Compact sur une ligne, police 10, aucun « CL/CX ». Le marqueur Rockstar est
  un losange rouge, avec son nom complet pour l'accessibilité.
- Détection des trois vrais CLI `codex --yolo` corrigée ; les auxiliaires du
  même dossier et les app-servers sont exclus. Les hooks restent l'autorité.
- Détail du contexte : tokens utilisés / capacité, pourcentage et date de mesure.
  Les tokens cumulés ne mesurent pas le contexte ; une compaction l'efface.
- Réglages guidés : `/hooks`, choix du dossier du projet, diagnostic qui nomme
  les hooks à approuver. Chemins, réparation et retrait dans les options avancées.

Sur le poste lors du diagnostic, **10/12 hooks étaient actifs** ; seuls
`SubagentStart` et `SubagentStop` attendaient la confiance dans `/hooks`.
Leur approbation seule ne corrige pas le rejet de `--yolo` dans l'ancienne app.
Le helper corrigé doit être utilisé, puis un nouvel événement reçu.

Preuves, limites et captures : [rapport de validation](REVIEW-2026-09-10-island-context-setup.md).
La procédure de release ne remplace pas la copie stable. La mise à jour se fait
depuis Réglages → Mises à jour ou depuis le DMG publié.
