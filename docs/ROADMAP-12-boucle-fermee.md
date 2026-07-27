# Phase 12 — « Boucle fermée » : Atoll rend Claude Code meilleur à l'usage

> Plan de développement validé avec Mehdi le 2026-07-27.
> Principe : **plus on utilise l'outil, plus on devient performant grâce à lui-même.**
> Cible : v0.12.0. Chaque jalon a un critère de succès MESURABLE — pas « c'est fait »
> mais « voici le chiffre ».

## Le constat qui fonde ce plan (mesuré, pas supposé)

Diagnostic du 2026-07-27 sur la machine de Mehdi, 8 jours d'usage (~4 sessions/jour) :

| Fait mesuré | Valeur |
|---|---|
| Rétrospectives réellement lancées | **2** en 7 jours (dont 1 déclenchée à la main en debug) |
| Skills proposés | **0** |
| Notes produites par une vraie rétrospective | **0** (la seule note vient du test de debug) |
| Sessions passant les critères de substance | 9 sur 29 (31 %) |
| Dont transcripts ≥ 9 Mo | **5 sur 9** |
| Trace permettant de savoir POURQUOI ça n'a pas tourné | **aucune** |

**Trois causes, dans l'ordre de contribution :**
1. **Le quota vit uniquement en mémoire.** `LearningGate` refuse (`quotaMissing`) tant
   qu'aucune statusline n'est arrivée — c'est-à-dire à chaque redémarrage d'Atoll, et
   pour toute session `--bg` (pas de TUI, donc pas de statusline). C'est LA cause
   dominante : le pipeline ne démarre pas.
2. **Les transcripts éligibles sont hors de portée du budget.** Le gate a un plancher
   (100 Ko) mais aucun plafond : il sélectionne des fichiers de 9 à 47 Mo que le modèle
   lit avec `Read` sous 1,50 $ — il en voit ~8 %.
3. **Le prompt est dissuasif** : « When in doubt, return ZERO skills ». Il refait le
   travail du filtre humain qui existe déjà (quarantaine + revue ⌘⏎/⌘⌫).

---

## Jalon 12a — Réparer la boucle *(socle)* — ✅ LIVRÉ

**Objectif mesurable :** 100 % des fins de session laissent une trace d'évaluation
lisible dans les Réglages, et sur une semaine d'usage normal ≥ 5 rétrospectives
aboutissent (contre 1 aujourd'hui).

- **Journal d'apprentissage persistant** — chaque évaluation écrit une ligne :
  session, date, décision (`run`/`skip(raison)`), taille du transcript, quota au moment
  de la décision, coût, notes et skills produits, erreur éventuelle. Affiché dans
  Réglages › Apprentissage. *Sans ça, on règle à l'aveugle.*
- **Quota persistant** — `QuotaSnapshot` écrit dans `state.json`, rechargé au lancement ;
  « quota inconnu » n'est plus un refus sec mais autorise **un** run par fenêtre de 5 h.
- **Condensé côté Atoll** — le changement décisif : au lieu de faire lire un JSONL de
  47 Mo au modèle, Atoll extrait lui-même (Swift, gratuit, `TranscriptLineParser` existe
  déjà) prompts utilisateur + conclusions + erreurs et leur résolution + commandes qui
  ont marché, capé à ~150 000 caractères, passé DANS le prompt avec `--tools ""`.
  Effet : analyse enfin complète, coût effondré, et Haiku/Sonnet deviennent viables.
- **Un retry sur échec** — aujourd'hui un run avorté marque la session « traitée » pour
  toujours.
- **Prompt rééquilibré** (choix de Mehdi : *équilibré*) — proposer dès qu'une procédure a
  été exécutée avec succès et est rejouable, avec `confidence` affichée à la revue.

## Jalon 12b — Ne pas réinventer *(chercher avant de créer)* — ✅ LIVRÉ

**Objectif mesurable :** aucune proposition ne duplique un skill, une command ou un
plugin déjà présent ; chaque proposition affiche « rien d'équivalent parmi N existants »
ou « existe déjà : X ».

- **Catalogue local** — inventaire unifié : skills de `~/.claude/skills` (19 chez Mehdi),
  commands de `~/.claude/commands` (~60 `gsd:*`), composants des plugins installés
  (181 SKILL.md en cache). Piège connu : **le nom fait autorité par le DOSSIER**, pas par
  le front-matter (collision `apex` vérifiée).
- **Recherche d'antériorité** avant toute proposition — Haiku compare le besoin aux
  descriptions du catalogue (c'est exactement sa taille de tâche).

## Jalon 12c — Plugins *(diagnostic, puis proposition sous confirmation)* — ✅ LIVRÉ (diagnostic + actions)

**Objectif mesurable :** le panneau signale les anomalies réelles déjà présentes chez
Mehdi — 31 plugins installés / 4 activés, `security-pro` cassé (2 fichiers manquants),
6 doublons entre deux marketplaces — et affiche le coût en tokens **par session** de
chaque plugin activé.

- Interfaces SUPPORTÉES uniquement : `claude plugin list --json`,
  `list --available --json` (268 plugins, avec `installCount`), `details <nom>` (coût en
  tokens, sortie texte → parsing défensif), `install|enable|disable`. **Watchdog
  obligatoire** sur `--available` : il touche le réseau (même piège que le FleetPoller).
- **Jamais d'écriture directe** dans `~/.claude/settings.json` (`enabledPlugins`) ni dans
  le cache des plugins : on délègue au CLI.
- **Installation = acte explicite** (choix de Mehdi) : la fenêtre de revue montre ce que
  le plugin exécute (hooks `SessionStart`, serveurs MCP auto-démarrés), son coût en
  tokens et sa popularité, puis ⌘⏎ lance `claude plugin install`. Jamais automatique,
  jamais depuis l'îlot en un clic.

## Jalon 12d — Réglages *(modèles par tâche)* — ✅ LIVRÉ

**Objectif mesurable :** chaque analyse peut être routée vers Haiku / Sonnet / Opus /
Fable indépendamment, et le défaut retenu est appliqué.

Défauts choisis par Mehdi : **Haiku pour chercher** (antériorité, plugins),
**Sonnet pour analyser** (rétrospective, curation).

## Hors périmètre pour l'instant (décidé)

- Export des skills vers un dépôt marketplace / publication publique : Mehdi ne veut,
  pour l'instant, que le partage **entre ses projets** — déjà acquis techniquement
  (`~/.claude/skills` est global), à rendre visible et à vérifier.
- Import de skills tiers depuis un dépôt.

## Ordre d'exécution

12a (socle) → 12d (réglages, greffés sur 12a) → 12b (antériorité) → 12c (plugins).
Chaque jalon se termine par : tests AtollCore verts, vérification EN VRAI sur des
sessions réelles, captures d'écran lues, revue adversariale multi-agents.


---

## État au 2026-07-27 — les quatre jalons sont livrés

| Jalon | Critère mesurable | Résultat |
|---|---|---|
| 12a | ≥ 5 rétrospectives aboutissent / semaine | **8 notes + 2 skills** produits dès le premier run réel (0 en 7 jours avant) ; chaque décision laisse une trace dans le journal |
| 12b | Aucune proposition ne duplique l'existant | Le prompt reçoit les **117 capacités** existantes ; le modèle nomme ce qu'il recoupe (`similar_existing`) ; **détection locale déterministe** en filet (`SkillCatalog.closestMatch`), affichée en tête de la revue |
| 12c | Les anomalies réelles sont visibles | Mesuré en vrai : **31 installés, 4 activés, 1 cassé** ; coût en tokens à la demande ; activer/désactiver/installer délégués à la CLI, jamais d'écriture directe |
| 12d | Un modèle par tâche | Rétrospective / curation / recherche, parmi haiku · sonnet · opus · fable |

**Deux skills réellement appris et activés** par cette boucle : `atoll-release-pipeline`
et `atoll-adversarial-review-workflow-recovery`.

### Ce qui reste ouvert (non tranché)

- **Recherche de plugin par besoin** : le catalogue public (268 entrées avec leur
  popularité) est décodé et prêt, mais rien ne s'en sert encore — il manque le geste
  produit (« trouve-moi un plugin pour X ») et son coût en quota.
- **Sceller les notes** comme les skills (manifeste + SHA256).
- **Rendre l'injection du recall proactif visible** dans l'îlot.
