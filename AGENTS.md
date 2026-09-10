# AGENTS.md — instructions projet Atoll (pour Codex)

La seule source de vérité des règles, des pièges et des arbitrages est
`CLAUDE.md`, à la racine du dépôt : lis-le en entier avant d'agir, puis
`docs/HANDOFF.md`. Ce fichier ne le duplique pas. Une copie mécanique de
`CLAUDE.md` où « Claude » avait été remplacé par « Codex » a circulé sous ce nom
le 9 septembre 2026 ; elle affirmait des faits faux (chemins, quotas, rôle
d'Atoll). Un `AGENTS.md` long est cette copie : il ne fait pas foi.

**Passation en cours (2026-09-10).** La relecture de la PR #2 par Claude, avec
chaque constat, sa preuve, sa direction de correctif et la méthode de recette
visuelle, est dans `codex/MESSAGE-DE-CLAUDE.md`. Lis-la avant de toucher au
code de la branche `codex/claude-codex-compatibility`.

Règles minimales, toutes détaillées dans `CLAUDE.md` :

- Communication en français ; identifiants de code en anglais, commentaires en
  français.
- Fail-open absolu du helper `atoll-bridge` : rien de ce qu'Atoll installe ne
  peut casser ni ralentir un CLI.
- `~/.claude/settings.json` est sacré. Pour Codex : `hooks.json` sauvegardé
  avant écriture, hooks étrangers préservés, `config.toml` jamais écrit.
- Aucune fonction nouvelle sans avoir lu `docs/VISION-2026-08.md` : soustraire
  avant d'ajouter.
- Chaque correctif porte un test de non-régression vérifié par sabotage.
- Ne jamais lancer le produit de build (toujours une copie `ditto`), jamais
  deux Atoll normaux en même temps ; la copie stable `~/Applications/Atoll.app`
  ne se remplace pas ; rien ne se publie sans Mehdi.
- Après tout changement d'interface, vérification visuelle par captures ;
  méthode dans `codex/MESSAGE-DE-CLAUDE.md`, section 2.
- Pas de `rm -rf` : un hook local le bloque, utiliser la corbeille.
- `Scripts/check-docs.py --no-tests` avant de croire un document, et après en
  avoir modifié un.
