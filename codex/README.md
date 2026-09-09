# Passation Codex → Claude

Ce dossier rassemble le contexte nécessaire pour que Claude relise
l'intégration Codex sans dépendre de l'historique de conversation.

Ordre de lecture :

1. [`HANDOFF-CLAUDE.md`](HANDOFF-CLAUDE.md) — état, carte du code et checklist.
2. [`../docs/CODEX-INTEGRATION.md`](../docs/CODEX-INTEGRATION.md) — architecture,
   protections, protocole de test et plan des prochains lots.
3. [PR GitHub #1](https://github.com/mehdi7129/atoll/pull/1) — diff et discussion.

Référence actuelle :

- branche : `codex/codex-support-dual-quotas`
- base : `main` à `dd1c456`
- premier commit Codex : `d3d7181`
- état : PR en brouillon, non publiée, à ne pas fusionner avant validation

Ces fichiers ne contiennent ni secret, ni transcript, ni valeur personnelle de
quota. Ils ne donnent pas à Claude un accès GitHub ou un abonnement : ils servent
uniquement de passation technique commune.
