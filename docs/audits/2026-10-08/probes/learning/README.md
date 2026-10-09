# Probes apprentissage de l’audit du 8 octobre 2026

Depuis macOS : `python3 run.py /chemin/atoll`. Option `--build-dir` pour réutiliser les objets Core native ; `--case collision|state|skill-root` pour cibler.

Tout s’exécute sous une nouvelle racine temporaire, avec les collaborateurs factices existants. Aucun compte, Claude, Codex, GUI ni préférence personnelle. Aucun changement du dépôt. Les fixtures sont conservées pour inspection.

- `collision` : service verbatim, horloge réelle. Une note non UTF-8 homonyme d’une sortie et les noms `.orphan` précréés dans une fenêtre de 33 secondes démontrent le fallback de suppression après collision. Il s’agit d’une injection de faute de fichier, pas de la preuve que deux cycles produisent spontanément le même timestamp. Le faux CLI local produit un rapport de fixture.
- `state` : service verbatim, état curation global corrompu avec planification déjà active ; aucun CLI lancé.
- `skill-root` : vrai LearnedSkillStore, permission temporaire 000 sur la racine skills de fixture puis restauration 700 (également en defer) ; manifeste toujours accessible. Aucun fichier de l’utilisateur n’est touché.

Les JSON rapportent les observations, et non un verdict de non-régression après correctif. Après correction, les booléens de préservation doivent changer. Les harnesses compilent en Swift language mode 5, comme le projet.
