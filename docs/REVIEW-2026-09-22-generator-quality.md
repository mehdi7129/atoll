# Générateur : connaissances utiles et contexte réduit

22 septembre 2026 · PR #5, sans fusion ni release.

## Résultat mesuré

Même CLI **0.155.1**, modèle **gpt-5.6-luna** et fixtures historiques inchangées.
Les consignes ont évolué ; les chiffres sont des observations, pas une garantie
de consommation identique à chaque appel.

| Cas | Initial | Profil allégé précédent | Dernier prompt | Dernier résultat |
|---|---:|---:|---:|---|
| Renommage banal | 14 330 | 4 576 | 4 283 | Aucune note ni skill |
| Procédure d’export | 14 658 | 4 900 | 4 611 | Un skill de 118 mots, aucune note |

**28 988 → 8 894 tokens d’entrée : −69,3 % depuis le départ, −6,1 % depuis
le profil allégé.** Le dernier skill conserve formule, commande, identifiants,
timestamps, exemple numérique, 40 points aller-retour et précision mesurée.
Il s’agit de mots comptés, pas d’une mesure des tokens de son seul corps.

Une préférence durable produit une note et aucun skill. Les cas déjà couvert et
injection ne produisent rien. Une seconde procédure, LumenCache, produit un skill
conservant l’ordre des commandes, les identifiants retournés et le contrôle final.
Ces trois derniers cas ont été testés avant l’ultime précision excluant les comptes
rendus de tâches des notes ; renommage, export et préférence ont été rejoués ensuite.

Cette campagne a nécessité **10 appels : 44 468 tokens d’entrée et 3 203 de sortie**,
échecs de diagnostic inclus. Aucun retry automatique, installation de skill ou
conversion monétaire. Cache lu annoncé : zéro. Les compteurs de raisonnement
restent inclus dans les sorties, jamais additionnés une seconde fois.
[Mesures et chronologie complète](audit-support/2026-09-22-generator-quality/summary.json).

## Correctifs

- Le modèle choisit d’abord la forme du savoir : procédure vérifiée regroupée
  dans un skill, fait ou préférence dans une note, travail banal sans production.
  Les notes excluent explicitement les comptes rendus et tests ponctuels.
- Les consignes métier passent de 4 562 à 3 191 caractères sur la fixture export.
  Le profil Codex commun passe de 475 à 346 caractères. Preuves et catalogue
  fournis ne sont pas coupés pour obtenir ce gain.
- Les identifiants des notes déjà présents dans le résumé ne sont plus répétés.
  Les identifiants absents du résumé plafonné restent listés. Sur les fixtures de
  20/60 notes, la liste perd 1 039/1 248 caractères ; ce ne sont pas des tokens.
  Résumés, classement et plafonds inchangés.
- Le schéma demandait des slugs de 60 caractères alors que l’installation accepte
  2–40. Il est aligné et porte une courte description qui survit à l’adaptation
  Codex. Le parseur reste strict ; les propositions mal formées sont désormais
  signalées sans divulguer leur champ invalide.

## Ce que les échecs ont révélé

Le premier nouveau prompt a produit un skill complet de 134 mots, avec un slug de
**110 caractères**. Atoll l’écartait silencieusement. La capture brute a permis de
séparer défaut de génération et défaut de parsing. Les anciennes captures ne
conservaient pas cette sortie brute : « zéro skill après parsing » ne prouve donc
pas toujours que le modèle n’en avait généré aucun.

Après correction du schéma, le skill passe. Le cas banal produit toutefois une
note de compte rendu : l’exclusion explicite de ce type de note corrige ce cas au
dernier essai. L’apprentissage reste opt-in et les skills restent soumis à revue.

Le benchmark avait aussi des faux positifs (facteur de conversion contradictoire,
variables capturées après leur usage) et des faux négatifs (« ne pas modifier »,
« doit produire », achèvement expliqué sans le mot « acceptation »). Ils sont
corrigés avec contre-épreuves. Les rapports et statuts initiaux restent conservés ;
les [six captures retenues sont revalidées hors ligne](audit-support/2026-09-22-generator-quality/revalidation.json),
sans nouvel appel pour une simple variante de formulation.

## Vérifications et limites

- **1 078 tests Core, un skip opt-in, aucun échec** ; builds Debug et Release.
- **25 scénarios de contexte**, dont quatre vrais runners Claude/Codex, et
  **26 parcours rétrospectives** ; aucune génération dans ces harnesses.
- Deux sabotages compilés et détectés : réintroduction des slugs répétés,
  disparition de la trace des propositions invalides.
- Vérificateur : **15 bons rapports, 28 contre-épreuves**, deux anciennes sorties
  réelles rejetées ; tests Swift de l’audit des événements et journal cumulatif.
- Trois usages finaux [rejoués dans le vrai journal](audit-support/2026-09-22-generator-quality/journal-replay.json),
  compteurs et persistance vérifiés sans nouvel appel.
- Relectures ciblées des prompts, du schéma, du parseur, de la déduplication et du
  harness. Il s’agit d’un balayage de ces changements, pas d’une lecture intégrale
  de tous leurs consommateurs. Les corrections du vérificateur ont été éprouvées
  sur les captures, sans assouplir les invariants métier.

Les recettes utilisent un home privé ; elles n’exercent pas toute la chaîne
automatique de production. Les configurations personnelles Codex/Claude sont
inchangées. Aucune app lancée, remplacée ou installée ; pas de modification visuelle.
Claude authentifié n’a pas été rejoué, faute d’abonnement.

Le CLI garde les instructions globales et des outils résiduels. Aucune action
d’outil exposée par `exec --json` n’a été observée ; ce flux ne montre pas tous les
wrappers, donc ce n’est pas un audit exhaustif d’absence d’appels.
[Filtrage officiel Codex 0.155.1](https://github.com/openai/codex/blob/rust-v0.155.1/codex-rs/exec/src/event_processor_with_jsonl_output.rs#L316).
Réduire encore le corpus ou changer de modèle demanderait une autre comparaison
qualitative ; ce lot conserve les preuves plutôt que de poursuivre une taille minimale.

```sh
swift test --package-path AtollCore --build-system native --jobs 4
python3 Scripts/test-learning-note-context.py
python3 Scripts/test-learning-note-context.py --sabotage
python3 Scripts/test-learning-core.py --sabotage invalid-skill-trace
python3 Scripts/test-learning-retrospective.py
python3 Scripts/test-skill-generation.py --prepare-only --output /private/tmp/atoll-generator-check
python3 Scripts/check-docs.py --no-tests
```

`--live` consomme le quota. Ne pas relancer les dix appels pour une reprise de
session : leurs captures, échecs et empreintes sont conservés dans le dossier lié.
