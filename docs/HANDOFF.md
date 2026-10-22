# HANDOFF — recentrage essentiel Atoll

État du 22 octobre 2026, **implémentation locale terminée et vérifiée, non distribuée**.

Mehdi a confirmé le suivi visuel et Codex + Claude Code, puis approuvé le [plan](PLAN-2026-10-22-simplification.md) par « ok je valide ». Leurs événements utiles sont conservés ; permissions et prompts deviennent passifs, sans décision ni injection de mémoire.

Source : main 751dd680, produit de la 0.18.7/build 42. Le développement vit dans la branche codex/atoll-essential, checkout local hors iCloud. Le dossier du Bureau est volontairement préservé sur son ancienne branche d’exploration. L’app installée 0.18.7 n’est pas modifiée. Aucun accord de publication ou de remplacement de l’app stable.

## Fonctionnement cible

- Îlot et liste de sessions, regroupements, contexte et quotas conservés ; aspect et invisibilité au repos inchangés.
- Création de propositions de skills facultative, choix existant conservé, revue indépendante du switch. Modèle/payeur/destination distincts de l’affichage.
- Génération de skills seule : aucune note, curation, indexation ou recherche mémoire. Les anciens résultats restent récupérables sans nouvelle dépense.
- Hooks toujours utiles au suivi des sessions. Pas de cartes d’autorisation, Rockstar, sons, passation, arrêt ou ouverture de terminal.
- Migration sélective, reprenable, sauvegardes/archives vérifiées, restauration des anciens hooks sonores et deny. Aucune purge des skills ni des anciennes données ; config.toml jamais écrit.

## Validation finale

- Profil offline standard : **19/19 étapes réussies**, dont **1 157 tests Core, un test authentifié ignoré, zéro échec**.
- Builds Debug et Release réussis ; app et helper Release universels x86_64/arm64, signature désactivée.
- **24 scénarios UI distincts qualifiés**, captures regardées et deux animations examinées. Le dernier build a rejoué navigation vers Skills, bouton ON/OFF et îlot Codex.
- Migrateur, OFF/ON, reprise des résultats, installation protégée et hooks passifs vérifiés par des sabotages compilés causaux. Homes et CLI factices uniquement.
- Contrôle documentaire sans tests passant ; les avertissements de couverture de revue ne sont pas une certification ligne à ligne.

Le [rapport complet](IMPLEMENTATION-2026-10-22-essential.md) donne les preuves, les interruptions de compilation, les anciennes recettes corrigées et les limites. Rapport standard : `~/Library/Caches/atoll-essential-standard-qualified/results.json`. Captures finales : `~/Library/Caches/atoll-essential-ui-qualified/`.

Le scratch Core jetable de cette tâche a été retiré après les tests pour libérer la place des builds. Les rapports restent présents ; une prochaine validation le recompilera. Aucun cache préexistant n’a été purgé.

## Suite éventuelle

L’implémentation est prête à relire localement. Une recette native authentifiée (génération et permissions CLI), VoiceOver et la qualification signée/notarisée restent distinctes. Les fixtures ne valent pas ces qualifications. Ne pas publier, pousser ou remplacer l’app stable sans instruction de Mehdi ; la version reste 0.18.7/build 42 tant qu’une release n’est pas préparée.

Lire CLAUDE.md, ce HANDOFF et le rapport avant reprise. Travailler dans la branche essentielle hors iCloud, pas dans l’ancien checkout du Bureau. Le retour vers une vieille app peut réinstaller ses producteurs : restaurer sélectivement après inspection, jamais en recopiant tout un backup.

Les preuves de livraison précédentes sont dans releases/0.18.7.json. Le [handoff précédent intégral](archive/HANDOFF-2026-10-22-before-essential.md) conserve les résultats historiques sans faire autorité sur ce développement. La recette Claude authentifiée nécessite un abonnement disponible ; ne pas substituer une clé API.
