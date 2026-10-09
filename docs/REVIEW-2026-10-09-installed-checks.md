# Vérifications après installation — Atoll 0.18.6

Relevé du **9 octobre 2026**, après la mise à jour effectuée par Mehdi.
L’app installée et utilisée est **0.18.6/build 41**. Ces observations complètent
les [preuves de livraison](releases/0.18.6.json), qui décrivent la publication
et ne constituent pas une installation automatique sur le poste.

## Résultats observés

| Contrôle | Observation | Portée |
|---|---|---|
| Préécoutes « Décision attendue » et « Tour terminé » | Les deux boutons Écouter ont été actionnés dans Alertes, avec quelques secondes d’écart. Mehdi confirme avoir entendu les deux sons. | Lecture audible des deux sons configurés, au volume existant de 10 %. Aucun réglage sonore modifié. |
| Retour à Cursor | Sur la carte Codex du projet Dynamic_Island, le bouton réel est « OUVRIR DANS CURSOR ». Mehdi l’a actionné et confirme que Cursor s’ouvre bien. | Ouverture de l’application, conforme au niveau `app` annoncé pour cet IDE. Aucun onglet ni fichier précis n’a été confirmé. |
| CI après livraison documentaire | [26 étapes sur 26 réussies](https://github.com/mehdi7129/atoll/actions/runs/37908020493) sur `9d955369bc5cc3febe74e8400eb5a19e3112b264`. | Ce passage sur le commit de clôture documentaire est terminé ; il complète la CI du commit source publié `3e10e804`. |

Ces confirmations sont des observations d’usage, distinctes des tests compilés
et de leurs sabotages. Les préécoutes ne constituent pas une nouvelle recette
complète du déclenchement automatique des sons par les hooks. L’utilisateur n’a
pas donné de qualification acoustique détaillée sur les coupures ou doublons.
Le clic Cursor ne prouve ni le succès de sa sous-commande CLI ni le choix d’un
onglet : ces chemins restent couverts séparément par le harness A17.

## Limites conservées

- **Onglet Terminal** : non qualifié. Le contrôle GUI refuse l’accès à Terminal.
  Une fixture locale sans modèle a été préparée, puis son chemin macOS `date`
  corrigé. Son événement de démarrage a été envoyé manuellement ; sa carte
  synthétique a ensuite disparu lors de la réconciliation avec les sessions
  Claude réelles. L’injection unique ne permettait pas une recette durable.
- **Passation** : « CONTINUER DANS CLAUDE » a été actionné par erreur sur une
  carte Codex. Ce geste lance une passation ; il ne valide pas le retour au
  terminal. Il est distinct du bouton d’ouverture placé à sa gauche.
- **Claude authentifié** : la génération reste différée faute d’abonnement
  Claude, confirmé par Mehdi. Aucun recours à une clé API n’a été entrepris.
- **Crash Codex CLI** : l’utilisateur a signalé un panic d’affichage dans
  `tui/src/terminal_hyperlinks.rs:394`, pendant le rendu d’une question de test.
  Le CLI local observé était 0.162.0. Les instructions ont ensuite été données
  en texte simple ; le correctif de ce crash et sa résolution restent non vérifiés.

Aucun code produit ni artefact de release n’est modifié par ce relevé. Les
preuves locales restent dans le dossier privé
`atoll-post-update-verification-20261009`, dont le relevé référence les scripts
temporaires. La validation du retour à Cursor ne
remplace pas une future recette d’onglet Terminal si cet usage doit être qualifié.
