# HANDOFF — recentrage essentiel Atoll

État du 22 octobre 2026, **release 0.19.0/build 43 publiée, flux Sparkle 43 préparé et vérifié dans ce commit**.

Mehdi a confirmé le suivi visuel et Codex + Claude Code, puis approuvé le [plan](PLAN-2026-10-22-simplification.md) par « ok je valide ». Leurs événements utiles sont conservés ; permissions et prompts deviennent passifs, sans décision ni injection de mémoire.

Source initiale : main 751dd680, produit de la 0.18.7/build 42. Le développement essentiel a été intégré par la PR #21, commit 172ff8963d601cd23a673bba1215566ee7586754 ; son arbre est identique au paquet préparé sur 9e1325b. Le tag v0.19.0 pointe vers ce commit fusionné. Le checkout de livraison reste hors iCloud ; le dossier du Bureau conserve son ancienne branche d’exploration.

Après la préparation locale, Mehdi a demandé explicitement de publier la release GitHub et d’actualiser Sparkle. Les assets ont été publiés et vérifiés avant l’activation de l’appcast. La publication n’installe pas la mise à jour : la copie stable 0.18.7 n’a pas été remplacée par cette tâche.

## Fonctionnement cible

- Îlot et liste de sessions, regroupements, contexte et quotas conservés ; aspect et invisibilité au repos inchangés.
- Création de propositions de skills facultative, choix existant conservé, revue indépendante du switch. Modèle/payeur/destination distincts de l’affichage.
- Génération de skills seule : aucune note, curation, indexation ou recherche mémoire. Les anciens résultats restent récupérables sans nouvelle dépense.
- Hooks toujours utiles au suivi des sessions. Pas de cartes d’autorisation, Rockstar, sons, passation, arrêt ou ouverture de terminal.
- Migration sélective, reprenable, sauvegardes/archives vérifiées, restauration des anciens hooks sonores et deny. Aucune purge des skills ni des anciennes données ; config.toml jamais écrit.

## Validation finale

- CI de la PR #21 : **20/20 étapes du profil standard réussies**, dont **1 157 tests Core, deux ignorés, zéro échec**. Le relevé local initial 19/19, avec un test ignoré, reste une preuve historique distincte.
- Builds Debug et Release d’implémentation réussis ; puis build Release 0.19.0/build 43 signé Developer ID et notarisé, ZIP et DMG vérifiés.
- **24 scénarios UI distincts qualifiés**, captures regardées et deux animations examinées. Le dernier build a rejoué navigation vers Skills, bouton ON/OFF et îlot Codex.
- Migrateur, OFF/ON, reprise des résultats, installation protégée et hooks passifs vérifiés par des sabotages compilés causaux. Homes et CLI factices uniquement.
- Contrôle documentaire sans tests passant ; les avertissements de couverture de revue ne sont pas une certification ligne à ligne.
- Génération Codex native : trois cas, zéro/zéro/un skill, aucune note ; un faux négatif du vérificateur corrigé et rejoué sans modèle, originaux conservés.
- Codex CLI 0.163.0 reconnaît les douze hooks. Un tour natif avec app/helper Debug inchangés confirme attente de permission, absence de décision Atoll, accord du client natif, puis Stop synchrone et retour à l’attente d’entrée. La première tentative interrompue pour erreur de corrélation de la recette est conservée.
- Sept exécutables universels signés, Hardened Runtime, staples et Gatekeeper app/DMG valides ; 134 objets identiques entre les apps ZIP et DMG, ainsi qu’après application du delta 42→43.
- Six signatures Sparkle valides et six copies altérées rejetées ; cinq deltas depuis les builds 42 à 38, trois anciennes entrées conservées sous leurs propres tags. Sept téléchargements publics identiques et quinze URL contrôlées avant activation du nouveau flux.

Le [rapport complet](IMPLEMENTATION-2026-10-22-essential.md) donne les preuves, les interruptions de compilation, les anciennes recettes corrigées et les limites. Rapport standard : `~/Library/Caches/atoll-essential-standard-qualified/results.json`. Captures finales : `~/Library/Caches/atoll-essential-ui-qualified/`.

Le scratch Core jetable de cette tâche a été retiré après les tests pour libérer la place des builds. Les rapports restent présents ; une prochaine validation le recompilera. Aucun cache préexistant n’a été purgé.

La [qualification du paquet local](QUALIFICATION-2026-10-22-essential-local.md) précise les preuves natives et leurs limites ; le [relevé de distribution publique](releases/0.19.0.json) ajoute les signatures Sparkle, le delta, la CI et les téléchargements. L’ancien appcast est resté servi jusqu’à la fin de ces contrôles. Le fichier de référence de ce commit est docs/appcast.xml, version 0.19.0/build 43.

Après déploiement Pages, le relevé final des octets canoniques, du contrôle réseau et de l’offre dans l’app existante est conservé dans `~/Library/Caches/atoll-essential-publication/COMPLETED.json`, avec une copie dans le dossier de livraison du Bureau. Ce contrôle runtime est distinct des assertions de ce commit avant déploiement.

## Suite éventuelle

La mise à jour peut être installée par Mehdi. Il a choisi de terminer avec Codex validé et Claude à revalider après connexion. VoiceOver, l’identité d’un terminal TUI/IDE et le parcours de refus natif n’ont pas été qualifiés par la recette app-server. La release publiée est 0.19.0/build 43 ; la copie locale observée avant publication est 0.18.7/build 42. Ne pas installer pour vérifier la publication, ni remplacer la stable sans instruction.

Lire CLAUDE.md, ce HANDOFF et le rapport avant reprise. Utiliser le checkout de livraison hors iCloud, aligné sur main après publication, pas l’ancien checkout du Bureau. Le retour vers une vieille app peut réinstaller ses producteurs : restaurer sélectivement après inspection, jamais en recopiant tout un backup.

Les preuves de livraison précédentes sont dans releases/0.18.7.json. Le [handoff précédent intégral](archive/HANDOFF-2026-10-22-before-essential.md) conserve les résultats historiques sans faire autorité sur ce développement. La recette Claude authentifiée nécessite une connexion valide ; ne pas substituer une clé API.
