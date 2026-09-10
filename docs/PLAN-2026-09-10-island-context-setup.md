# Îlot compact, contexte Codex et configuration

Retour de Mehdi après v0.18.0, le 10 septembre 2026. Branche
`codex/island-context-setup`, base `25132e3`.

## Demande et décisions

- Retrouver le compact d'avant : activité à gauche, quota à droite, une seule
  ligne. Aucun « CL » / « CX » ; la couleur distingue le fournisseur.
- Garder le choix Claude/Codex dans le panneau ouvert. Conserver les tailles
  par écran, le silence au repos et l'indicateur Rockstar avec son quota.
- Afficher le contexte Codex actuel en tokens et en pourcentage.
- Rendre la configuration compréhensible et diagnostiquer les sessions absentes.

## Constats vérifiés avant correction

- Le compact v0.18.0 empile sélecteur et activité, en police 8 au lieu de 10.
- Les trois CLI interactifs observés utilisent `--yolo`. Le parseur de processus
  rejette cet alias et ne peut donc pas fournir l'identité au registre de sessions.
- Le détecteur accepte aussi `codex-code-mode-host`, parce qu'il reconnaît tout
  chemin sous `.codex/packages`. Ce processus auxiliaire n'est pas la session.
- Le lanceur installé vise bien le helper exécutable de l'app v0.18.0. Le socket
  Codex fonctionne ; un événement reçu crée une session sans registre associé.
- `hooks/list` reconnaît douze définitions : dix approuvées, seuls SubagentStart
  et SubagentStop restent à approuver. Le résumé ne les nomme pas.
- Les rollouts natifs portent `last_token_usage.total_tokens` et
  `model_context_window`. Atoll lit déjà leur fraction, mais perd les nombres.
  `total_token_usage` est cumulatif et ne mesure pas le contexte actuel.

## Plan

1. Reconnaître les options interactives réelles et exclure les auxiliaires du
   détecteur. Garder l'identité PID + démarrage et le refus des commandes headless.
2. Restaurer la disposition compacte précédente ; retirer la branche compacte
   du sélecteur et son traitement de survol devenu inutile.
3. Conserver une mesure de tokens validée, la propager au modèle de session et
   l'afficher dans le détail. Une compaction ou une mesure inconnue l'efface.
4. Mettre les étapes d'installation au premier plan dans Réglages › Codex :
   nommer les hooks à approuver, expliquer `/hooks`, choisir le dossier du projet.
   Ranger les chemins et la réparation dans les options avancées.
5. Tests ciblés puis sabotage ; build Debug, captures des trois largeurs en
   pilule et encoche, détail de contexte et réglages. Vérifier les processus et
   les mesures réels en lecture seule ; conserver les configurations personnelles.
6. Relire le diff, vérifier la documentation et mettre à jour la passation avec
   les preuves et les limites constatées.

## Seconde lecture du plan

La confiance des hooks et l'identité du processus sont deux problèmes distincts :
faire approuver les deux hooks ne répare pas `--yolo`. Le contexte dispose déjà
d'un chemin de lecture borné : l'étendre évite un nouveau poller ou une génération
IA. La couleur et le sélecteur étendu suffisent ; retirer le sélecteur compact
retire aussi ses courses de survol. Ne pas déduire une session d'un simple dossier.

Sources de contrat : [hooks officiels](https://learn.chatgpt.com/docs/hooks), aide
et `hooks/list` du CLI 0.154.0 installé, métadonnées numériques de rollouts réels.
Les captures personnelles et identifiants de sessions restent hors du dépôt.

## Exécution

Les six étapes sont terminées. Builds Debug/Release, 1 020 tests Core,
60 scénarios runtime, 19 cas UI et sabotages vérifiés : voir le
[rapport avec captures et limites](REVIEW-2026-09-10-island-context-setup.md).
La seconde revue du diff confirme les choix ci-dessus. Les corrections sont
prêtes à relire ; aucune nouvelle version n'a été publiée.
