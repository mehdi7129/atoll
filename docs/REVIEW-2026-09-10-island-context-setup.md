# Compact d'origine, contexte et configuration Codex

Validation du **10 septembre 2026**, branche `codex/island-context-setup`, base
`25132e3`, après le retour de Mehdi sur v0.18.0. Correctifs testés, **non publiés**.
Le [plan et sa seconde lecture](PLAN-2026-09-10-island-context-setup.md) précèdent
l'implémentation. Cette passe relit les diffs et leurs appelants ; elle ne
prétend pas refaire un audit complet du dépôt.

## Corrections et preuves

| Problème observé | Correction | Vérification |
|---|---|---|
| Compact sur deux lignes, boutons « CL/CX » | Une ligne en police 10, activité à gauche, quota à droite ; choix du CLI dans le panneau ouvert | Captures des trois tailles pilule/encoche, couleurs Claude/Codex, deux écrans ; ancien build refusé par le test |
| Trois TUI réels lancés avec `--yolo` non reconnus | Alias et options actuelles reconnus, commandes headless et options inconnues toujours exclues | Tests et sabotage de l'alias ; sonde native du vrai `ProcessInspector`, trois PID correctement associés |
| Auxiliaire `codex-code-mode-host` pris pour un CLI | Nom de l'image exécutable vérifié, pas tout le dossier `.codex/packages` | Test et sabotage du prédicat de chemin ; quatre app-servers réels exclus |
| Contexte réduit à une fraction | Conservation et affichage des tokens utilisés / capacité et de l'heure de mesure | Tests de parsing, propagation, nombres invalides et compaction ; sabotage de la propagation ; capture 173 617 / 258 400 tokens, 67 % |
| Réglages longs et diagnostic « 2 hooks à approuver » | Étapes `/hooks`, projet puis vérification ; noms des hooks manquants ; chemins et réparation repliés | Fixture RPC 10/12 approuvés, test et sabotage du résumé ; captures des options repliées et ouvertes |

Les relevés natifs sont en lecture seule, avec **Codex CLI 0.154.0** : le wrapper
installé était valide, le socket actif, dix hooks approuvés. Seuls `SubagentStart`
et `SubagentStop` attendaient la confiance. Cela n'expliquait pas à lui seul
l'absence d'identité : l'ancienne app rejetait `--yolo` et acceptait l'auxiliaire.
Les PID, chemins de projets et rollouts personnels restent hors du dépôt.

Le contexte vient de `last_token_usage.total_tokens / model_context_window`.
Une compaction ou une mesure inconnue efface le relevé précédent. Aucun nouveau
poller, aucune génération IA, aucun calcul à partir du cumul de tokens. Le
rafraîchissement suit les événements et la lecture existante toutes les 30 s ;
l'heure affichée distingue la dernière mesure d'un compteur instantané.

## Résultats

[Relevé structuré](reviews/2026-09-10-island-context-setup/checks.json) :

- **1 020 tests Core**, 1 skip live opt-in, 0 échec ; **60 scénarios runtime** réussis.
- Builds **Debug et Release** réussis. Le Release de contrôle est non signé ;
  il ne constitue pas un artefact de distribution.
- **4 sabotages Core détectés par assertions XCTest**, baseline verte ; une
  compilation en échec ne compte pas comme détection.
- **19 cas UI réussis** : trois tailles en pilule/encoche, variantes claires
  avec mouvement réduit, sélection dans le panneau, repos, Rockstar, détail
  de contexte, réglages et deux écrans (Retina 2× et externe 1×).
- **3 contre-épreuves sur l'ancien build** échouent chacune pour le défaut
  attendu : compact, contexte chiffré, étapes de configuration.

Deux premières assertions OCR attendaient « projet- » dans une aile qui affiche
correctement « projet… ». Captures relues, assertion adaptée au texte réellement
visible et complétée par le nom complet dans l'arbre AX ; les deux reprises passent.
Les captures ont été lues, l'OCR n'a pas servi seul à déclarer le rendu correct.

Captures conservées, toutes issues de données fictives sur des copies protégées :
[compact Codex](reviews/2026-09-10-island-context-setup/compact-codex.png),
[encoche Retina](reviews/2026-09-10-island-context-setup/compact-retina.png),
[compact Claude](reviews/2026-09-10-island-context-setup/compact-claude.png),
[choix dans le panneau](reviews/2026-09-10-island-context-setup/provider-expanded.png),
[contexte](reviews/2026-09-10-island-context-setup/context.png),
[réglages](reviews/2026-09-10-island-context-setup/settings.png),
[Rockstar](reviews/2026-09-10-island-context-setup/rockstar.png).
Les boutons des réglages sont désactivés uniquement dans cet aperçu de rendu.

Pour reproduire sur une copie préparée avec `Scripts/prepare-preview.py` :

```sh
swift test --package-path AtollCore
python3 Scripts/test-runtime.py
python3 Scripts/test-island-context-sabotage.py --output /private/tmp/atoll-island-sabotage
python3 Scripts/test-ui.py --app /private/tmp/Atoll-preview.app --output /private/tmp/atoll-island-ui --case compact --case provider-expanded --case detail-context --case settings-codex --case settings-codex-advanced
```

Les cas `physical-screen-0` et `physical-screen-1` emploient la géométrie réelle
de l'écran choisi ; un écran absent est refusé. La recette reste une fenêtre
isolée, pas une installation de la nouvelle version sur les barres de menus.

## Seconde revue et état de reprise

Le choix confirmé par Mehdi retire le sélecteur compact et son traitement de
survol : il évite aussi la course au clic de l'ancienne disposition. Rockstar
reste nommé pour l'accessibilité malgré son marqueur visuel réduit. Les nombres
du contexte utilisent la même identité validée que les autres métadonnées.
Le dossier de projet n'est plus initialisé avec le home Codex ; changer de home
ne change pas ce projet. Aucun contrat de trust n'est contourné.

Empreintes avant/après identiques pour les réglages Claude, `config.toml`,
`hooks.json` et les deux lanceurs Atoll. La copie stable reste **v0.18.0 / 35**.
Pour bénéficier du correctif sur les sessions réelles, il faut le nouveau
helper puis un événement du CLI ; approuver les deux hooks ne corrige pas
l'ancien parseur. Ni nouvelle release ni remplacement de l'app stable.

Les anciennes limites Claude authentifié et retour GUI au terminal restent
documentées dans [HANDOFF.md](HANDOFF.md). Cette passe ne relance pas de
génération authentifiée et ne réactive pas VoiceOver ; elle contrôle les noms
accessibles via AX. Les parcours v0.18.0 ne sont pas revendiqués comme répétés.
