# A16 et A20 — actualisation des vues montées

Recette GUI terminée le 9 octobre 2026, sur la base intégrée `7a02788`.
Les deux parcours nominaux passent et les trois mutations compilées sont
détectées. Aucun fichier produit du dépôt n’est modifié par ce lot.

## A16 : journal et notes

La même instance de `LearningSettingsPane` reste montée pendant tout le
parcours. Elle affiche initialement une note et désactive « Ranger maintenant ».
La fixture appelle le vrai journal privé de `RetrospectiveRunner` pour écrire
successivement un succès, une abstention et une erreur. Les trois entrées
apparaissent sans changer d’onglet ni rouvrir la fenêtre.

Une livraison locale est ensuite enregistrée avec le vrai
`RetrospectiveDelivery.Store`, puis reprise par `recoverPendingDeliveries()`.
La vue passe à deux notes et active « Ranger maintenant ». Le parcours observe
quatre révisions du journal et une des notes ; il ne modifie pas lui-même ces
compteurs. Les trois captures montrent le journal vide, les trois résultats
visibles, puis les deux notes après reprise.

## A20 : changement de home et retour tardif

La même instance de `CodexSettingsPane` charge le catalogue ALPHA du home A.
Le bouton réel « Appliquer le dossier Codex » sélectionne ensuite le home B :
ALPHA disparaît, « Catalogue à relire » apparaît et le compteur de lectures ne
bouge pas. Une lecture manuelle affiche alors BETA.

Le parcours revient à A, lance une lecture volontairement suspendue, puis
sélectionne B. La réponse ALPHATARDIF est libérée malgré l’annulation de sa
tâche. Un acquittement injecté à la fin de cette tâche garantit que la réponse
a été traitée avant l’oracle : elle reste absente de la vue, qui indique encore
« Catalogue à relire ». Cette vérification ne repose pas sur un simple délai.
Les trois captures montrent ALPHA, l’invalidation après changement de home,
puis l’absence du résultat tardif.

## Contre-épreuves

Chaque mutant est compilé en app complète et lancé sur une nouvelle fixture
privée, après les deux nominaux. Une erreur de compilation ou une autre erreur
d’exécution fait échouer la campagne.

| Mutation dans les sources temporaires | Oracle observé |
|---|---|
| Retirer le rafraîchissement sur `journalRevision` | `A16 journal UI remained stale` |
| Retirer le rafraîchissement sur `notesRevision` | `A16 notes UI remained stale` |
| Retirer l’affectation de `catalogHome` dans le bouton home | `A20 home UI remained stale` |

Les trois captures d’échec montrent respectivement le journal vide, une seule
note avec le rangement désactivé malgré la livraison reprise, et ALPHA encore
présent après la sélection effective de B. Les **six captures nominales et
trois captures des mutants ont été ouvertes et vérifiées visuellement**.

## Isolation et portée

Le harness copie les sources dans un dossier privé et conserve le mode preview
global. Le chemin de lancement normal d’`AppDelegate` reste désactivé : aucun
bridge, scheduler, indexeur ou CLI authentifié n’est démarré. Les préconditions
contrôlent le bundle protégé, le home réellement utilisé par Foundation et le
home Codex initial. Les préférences appartiennent au domaine unique de la copie
d’app ; les données et changements de home restent dans la fixture.

Les adaptations sont explicites et limitées aux sources temporaires :

- ouvrir les gardes preview des raccordements UI qualifiés ;
- exposer le vrai journal privé dans une extension du même fichier ;
- injecter le resolver et le lecteur via le constructeur existant du catalogue ;
- fournir la valeur d’entrée `homePath`, vérifier son rendu AX, puis presser le
  vrai bouton ; remplacer uniquement la frontière de redémarrage des services
  par `CodexPaths.selectHome` sur le home privé ;
- acquitter la fin du traitement de la tâche catalogue et faire défiler le
  `NSScrollView` réel pour produire des captures lisibles.

L’affectation de `catalogHome`, les observations SwiftUI et la validation du
contexte de la réponse sont conservées. Cette recette qualifie leur raccordement
dans des vues montées. Elle ne qualifie pas la saisie clavier AppKit, le
redémarrage réel des services Codex ni un catalogue provenant d’un CLI
authentifié. Les recettes A15 d’écoute et A17 de focus de terminal restent des
limites distinctes ; aucun résultat n’est revendiqué ici sur ces parcours.

Le produit de build n’est jamais lancé : `prepare-preview.py` prépare une copie
protégée par `ditto` sous `/private/tmp`. Les actions AX et les captures visent
le PID et la fenêtre de cette copie. Un verrou partagé avec la recette UI
existante évite deux campagnes simultanées. Aucun réglage personnel n’est écrit.

## Preuves et rejeu

Le [relevé compact](audit-support/2026-10-09-ui-refresh/validation.json) conserve
les empreintes des sources, des builds et des neuf images finales. Les preuves
locales complètes se trouvent dans
`~/Library/Caches/atoll-audit-completion-evidence-20261008/ui-refresh` :
`nominal-learning-5`, `nominal-catalog-5`, `journal-learning-2`,
`notes-learning-2` et `home-catalog-2`. Les essais intermédiaires sont conservés
à part et ne comptent pas comme réussites. Ils ont permis de corriger le probe
AX et la position de défilement des captures ; ce ne sont pas des régressions
produit.

Le harness et ses trois fichiers Swift ont été relus en entier. Une seconde
lecture indépendante a demandé l’acquittement du catalogue et le mutant notes ;
les deux ont été ajoutés avant la campagne finale.

```sh
python3 Scripts/test-ui-refresh.py --output "$ATOLL_UI_EVIDENCE" --sabotage
```

Utiliser un dossier de preuves neuf. Cette commande requiert macOS, Xcode,
XcodeGen et les accès existants de capture/Accessibilité. Elle compile dans son
propre DerivedData et reste une recette GUI explicite, exclue du profil offline.
