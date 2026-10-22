# HANDOFF — recentrage essentiel Atoll

État du 22 octobre 2026, **paquet local 0.19.0/build 43 signé, notarisé et vérifié**.

Mehdi a confirmé le suivi visuel et Codex + Claude Code, puis approuvé le [plan](PLAN-2026-10-22-simplification.md) par « ok je valide ». Leurs événements utiles sont conservés ; permissions et prompts deviennent passifs, sans décision ni injection de mémoire.

Source : main 751dd680, produit de la 0.18.7/build 42. Le développement vit dans la branche codex/atoll-essential, checkout local hors iCloud. Le dossier du Bureau est volontairement préservé sur son ancienne branche d’exploration. L’app installée 0.18.7 n’est pas modifiée. Mehdi a demandé ensuite « ok fais cela » pour la recette native et la préparation d’un paquet signé/numéroté. La publication et le remplacement de l’app stable restent hors de cette préparation.

## Fonctionnement cible

- Îlot et liste de sessions, regroupements, contexte et quotas conservés ; aspect et invisibilité au repos inchangés.
- Création de propositions de skills facultative, choix existant conservé, revue indépendante du switch. Modèle/payeur/destination distincts de l’affichage.
- Génération de skills seule : aucune note, curation, indexation ou recherche mémoire. Les anciens résultats restent récupérables sans nouvelle dépense.
- Hooks toujours utiles au suivi des sessions. Pas de cartes d’autorisation, Rockstar, sons, passation, arrêt ou ouverture de terminal.
- Migration sélective, reprenable, sauvegardes/archives vérifiées, restauration des anciens hooks sonores et deny. Aucune purge des skills ni des anciennes données ; config.toml jamais écrit.

## Validation finale

- Profil offline standard : **19/19 étapes réussies**, dont **1 157 tests Core, un test authentifié ignoré, zéro échec**.
- Builds Debug et Release d’implémentation réussis ; puis build Release 0.19.0/build 43 signé Developer ID et notarisé, ZIP et DMG vérifiés.
- **24 scénarios UI distincts qualifiés**, captures regardées et deux animations examinées. Le dernier build a rejoué navigation vers Skills, bouton ON/OFF et îlot Codex.
- Migrateur, OFF/ON, reprise des résultats, installation protégée et hooks passifs vérifiés par des sabotages compilés causaux. Homes et CLI factices uniquement.
- Contrôle documentaire sans tests passant ; les avertissements de couverture de revue ne sont pas une certification ligne à ligne.
- Génération Codex native : trois cas, zéro/zéro/un skill, aucune note ; un faux négatif du vérificateur corrigé et rejoué sans modèle, originaux conservés.
- Codex CLI 0.163.0 reconnaît les douze hooks. Un tour natif avec app/helper Debug inchangés confirme attente de permission, absence de décision Atoll, accord du client natif, puis Stop synchrone et retour à l’attente d’entrée. La première tentative interrompue pour erreur de corrélation de la recette est conservée.
- Sept exécutables universels signés, Hardened Runtime, staples et Gatekeeper app/DMG valides ; 134 objets identiques entre les apps ZIP et DMG. Aucun appcast ni archive de mise à jour modifié.

Le [rapport complet](IMPLEMENTATION-2026-10-22-essential.md) donne les preuves, les interruptions de compilation, les anciennes recettes corrigées et les limites. Rapport standard : `~/Library/Caches/atoll-essential-standard-qualified/results.json`. Captures finales : `~/Library/Caches/atoll-essential-ui-qualified/`.

Le scratch Core jetable de cette tâche a été retiré après les tests pour libérer la place des builds. Les rapports restent présents ; une prochaine validation le recompilera. Aucun cache préexistant n’a été purgé.

La [qualification du paquet local](QUALIFICATION-2026-10-22-essential-local.md) précise les preuves natives, les empreintes et les limites. Le nouveau stage offline `local-release` passe séparément ; le relevé historique 19/19 n’est pas présenté comme une nouvelle exécution du profil désormais à vingt étapes.

## Suite éventuelle

Le paquet local est prêt pour une installation décidée par Mehdi. Il a choisi de terminer avec Codex validé et Claude à revalider après connexion. VoiceOver, l’identité d’un terminal TUI/IDE et le parcours de refus natif n’ont pas été qualifiés par la recette app-server. Ne pas publier, pousser ou remplacer l’app stable sans instruction de Mehdi ; la candidate locale porte 0.19.0/build 43 ; la version publiée et la copie installée restent 0.18.7/build 42.

Lire CLAUDE.md, ce HANDOFF et le rapport avant reprise. Travailler dans la branche essentielle hors iCloud, pas dans l’ancien checkout du Bureau. Le retour vers une vieille app peut réinstaller ses producteurs : restaurer sélectivement après inspection, jamais en recopiant tout un backup.

Les preuves de livraison précédentes sont dans releases/0.18.7.json. Le [handoff précédent intégral](archive/HANDOFF-2026-10-22-before-essential.md) conserve les résultats historiques sans faire autorité sur ce développement. La recette Claude authentifiée nécessite un abonnement disponible ; ne pas substituer une clé API.
