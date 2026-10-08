# Contre-audit de la PR #8 — 8 octobre 2026

**La première passe avait oublié cinq sujets et borné A04 trop étroitement.**
La PR passe de 17 à [22 propositions](AUDIT-2026-10-08-robustesse-simplicite.md).
Les constats initiaux ne sont pas réfutés ; la description d'A04 est corrigée.
La validation globale ne peut plus être dite entièrement verte : un harness Codex
supplémentaire échoue et accepte un faux succès de sabotage.

Relecture demandée par Mehdi après ouverture de la PR. Tête relue : `910836a` ;
code produit : `a1c7d6999d6921906f26c405fc4f48e7bde30e91`, inchangé dans ce complément.
Quatre agents simultanés au maximum, avec permutation des périmètres précédents :
UI → données, stockage → runtime, sessions → UI. Le coordinateur a relu la PR,
la portée des preuves et les scripts de validation/distribution. Lectures bornées,
contre-épreuves ciblées, puis relecture des ajouts ; aucune correction produit.

## Ce qui a changé dans le diagnostic

| Sujet | Résultat de la contre-épreuve | Suite minimale proposée |
|---|---|---|
| A04, portée corrigée | Une mémoire projet vide/whitespace reste cherchable même après inode neuf/reset ; réduction non vide témoin correcte | Distinguer contenu vide lu avec succès et erreur de lecture dans le remplacement documentaire |
| A18, nouveau P2 | JSONL : accès rétabli à inode/taille/mtime égaux, toujours 0 hit ; changer seulement mtime donne 1 hit | Ne pas enregistrer un échec d'ouverture dans le cache de lecture réussie |
| A19, nouveau P1 | « Archiver » : dossier/manifeste retirés, ressource unique perdue, aucun throw ; témoin conservé | Sauvegarde complète réussie avant suppression unitaire |
| A20, nouveau P2 | Réponse du projet/binaire A publiée dans l'état de B ; garde du home en vol correcte | Révoquer les anciennes lectures par révision du contexte |
| A21, nouveau P2 | Bridge Codex : pipe aval fermé → SIGABRT ; writer POSIX déjà présent → exit 0 | Réutiliser le writer fail-open en conservant le JSON Codex |
| A22, nouveau P2 | Préparation offline en échec ; mode sabotage PASS même sans mutation du produit | Faux CLI à jour, nominal vert préalable et échec causal obligatoire |

A19 est distinct de la désinstallation globale best-effort, politique existante
explicitement conservée. A20 emploie les méthodes de la vue avec un State contrôlé,
pas une recette SwiftUI réelle. A21 ne prouve pas l'interruption d'un CLI encore
actif. A22 établit un défaut de validation, pas une régression du profil produit
sans plugins. Les reproductions et leurs contrôles sont
[versionnés dans le dossier de preuves](audits/2026-10-08/counteraudit/README.md).

## Couverture et contre-vérifications

| Zone | Lecture ou exécution de cette passe | Limites |
|---|---|---|
| PR et preuves | Rapport complet ; runners initiaux, correspondance des observations et contrats ; clarification du checkout pour les rejouer | Pas de réexécution systématique de tous les anciens probes |
| Mémoire/données | MemoryIndexer entier, API/ingestion MemoryIndex, chemins curation/checkpoint/provenance, LearnedSkillStore/manifeste | Search/ranking et tous les parseurs non relus intégralement ; pas de disque plein/iCloud réel |
| Sessions/bridge | InteractionCenter, transitions et appels ciblés de SessionStore ; CodexBridge, sendToSocket, stdout, CodexReadClient, lifecycle | Pas de socket produit saturé ni de timeout interactif de dix minutes |
| UI/réglages | CodexCatalogSection et parent, SkillReviewCenter/SkillReviewWindow, chemin Archiver, hooks sonores, plugins, sons et jump | Pas de GUI, VoiceOver, écoute ou foyer de fenêtre réel |
| Build/distribution/tests | release.sh, project.yml, contrôles de version, préparateurs de copies, test-release-trash, test-claude-uninstall et test-codex-exec offline | Pas de release, signature/notarisation nouvelle ni dépendances en ligne |

Les relectures croisées n'ont pas trouvé de correction factuelle nécessaire à
A01–A03 et A05–A17 dans leurs limites déclarées. Cela ne signifie ni qu'un scénario
réel a été exercé pour chacun, ni qu'aucun autre défaut ne subsiste.

Hypothèses écartées de la liste des corrections :

- Deadline de socket par lecture et écriture serveur potentiellement bloquante :
  pas de scénario produit suffisamment établi avec le helper qui lit normalement
  sa petite réponse. Même limite pour un stdin qui ne ferme jamais.
- Nudge mémoire utilisant le parseur Claude : les appelants vérifiés viennent de
  SessionStore Claude ; pas de corruption Codex déduite de ce défaut de paramètre.
- Catalogue de SkillReviewCenter : ses gardes de classe et son `.task(id:)`
  diffèrent de la capture de valeur de CodexCatalogSection ; ne pas généraliser A20.
- Release : versions/signatures/deltas à revérifier lors d'une livraison, mais
  aucune nouvelle panne de pipeline démontrée par cette lecture.

## Bilan de validation et ordre révisé

Les 1 089 tests Core (un skip) et 218 scénarios du premier audit restent la baseline
observée sur le même produit ; ils ne sont pas présentés comme rejoués ici.
Les nouveaux contrôles passent pour la désinstallation Claude (quatre modes) et le
nettoyage réversible de release, y compris son sabotage. Les cinq nouvelles familles
de probes ont été rejouées depuis leurs emplacements livrés, sans compte ni modèle.
**Le harness `test-codex-exec.py --prepare-only` échoue sur la source inchangée.**
La copie de contrôle qui actualise uniquement les arguments factices passe ; le
script produit n'est pas corrigé par cette PR.

Réparer d'abord cette garde de validation (A22), puis conserver l'ordre proposé :
intégrité, avec A19 au même niveau qu'A01 ; lifecycle/permissions, incluant A21 ;
mémoire avec A18 ; invalidations/UI avec A20 ; extractions et entretien associés.
Pas de nouvelle fonctionnalité, de cadence ou d'appel IA introduit. Une recette GUI
restera nécessaire pendant l'implémentation des corrections qui touchent l'interface.

Le contre-audit réduit les angles morts identifiés. Il ne constitue pas une garantie
d'exhaustivité : concurrence sur volumes réels, corpus volumineux, réactions des CLI
authentifiés, performance, focus et accessibilité restent des limites explicites.
