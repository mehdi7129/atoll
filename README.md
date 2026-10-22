# Atoll

**Les sessions, les quotas et les skills de Claude Code et Codex CLI, autour de l’encoche de ton Mac.**

    ░░▒▒▓▓  A T O L L  ▓▓▒▒░░
    ⠹ mon-projet                 5h 42%

Atoll est une app macOS native, gratuite et open source. Elle montre l’activité des CLI pendant que tu travailles ailleurs et peut transformer les procédures utiles de tes sessions en propositions de skills.

> Cette branche contient le recentrage essentiel validé localement. La dernière version publiée reste **v0.18.7, build 42** ; les téléchargements existants ne contiennent pas encore ce changement.

macOS 14+ · Swift/SwiftUI · Apple Silicon et Intel · GPL-3.0-or-later · aucune télémétrie

## Voir les sessions et les quotas

Survoler l’îlot l’ouvre ; cliquer l’épingle. Les sessions se regroupent par projet ou par état. La liste reste bornée et annonce les éléments supplémentaires. Le détail montre les informations effectivement observées : modèle, branche, contexte et sous-agents lorsqu’ils sont mesurés.

Le sélecteur Claude Code / Codex choisit l’affichage et sa couleur. Les deux collecteurs restent actifs. Le compact garde l’activité à gauche et le quota à droite ; au repos, l’îlot retrouve sa forme discrète.

Les quotas et dates de reset viennent des services existants. Une donnée inconnue ou périmée est signalée. Les fenêtres longues Codex affichent leur temps restant, puis passent en heures et minutes.

Les autorisations, questions et plans se traitent dans le terminal du CLI. Atoll observe leur état et ne prend aucune décision.

## Garder les procédures utiles

Dans **Réglages → Skills**, active « Créer automatiquement des propositions de skills ». Atoll analyse les sessions terminées qui remplissent les conditions de durée, de contenu et de quota. Une tâche banale ou déjà couverte peut ne produire aucun skill.

Tu choisis le moteur, son modèle et la destination des skills, indépendamment du fournisseur affiché dans l’îlot. Cette analyse utilise le quota de l’abonnement choisi.

Chaque proposition reste en attente de revue : contenu complet, provenance et comparaison avec l’existant avant installation. Une mise à jour archive le dossier précédent et conserve ses ressources. Les erreurs n’effacent pas la dernière copie récupérable.

**Couper la création conserve les skills installés et la revue des propositions existantes.** La file est arrêtée et aucun nouveau modèle n’est lancé. Une analyse déjà lancée reçoit une demande d’arrêt ; les tokens déjà consommés ne peuvent pas être annulés. Les résultats sauvegardés restent récupérables après réactivation, sans nouvel appel modèle.

## Connecter les CLI

Les intégrations se configurent séparément dans **Réglages → Connexions**. Un seul CLI suffit pour utiliser Atoll.

Pour Codex, installer les définitions puis les relire et les approuver dans `/hooks`. Reprendre une session si elle était déjà ouverte avant l’installation. Le dépannage permet de vérifier le dossier du projet, le home Codex et l’exécutable.

Atoll préserve les hooks étrangers et sauvegarde les fichiers modifiés. Il n’écrit jamais config.toml et ne choisit pas la confiance native. Retirer une intégration conserve les skills installés.

Le suivi décrit ici porte sur Claude Code et Codex **CLI** ; l’inventaire exhaustif des conversations de l’app Codex n’est pas garanti.

## Passer à la version essentielle

La migration restaure les anciennes règles deny et les hooks sonores adoptés, puis retire les producteurs abandonnés. Elle conserve les skills, les ressources, les notes, les archives et les résultats déjà payés. Une erreur reste visible et réessayable dans Connexions.

La création de notes, leur rangement, l’index mémoire/recall, les sons Atoll, Rockstar, le gestionnaire de plugins et les commandes de pilotage des sessions quittent le produit. Leurs données ne sont pas purgées automatiquement.

## Installation et développement

La version publiée est disponible dans les [Releases](https://github.com/mehdi7129/atoll/releases). Les versions distribuées sont signées et notarisées ; les mises à jour passent par Sparkle. Une branche de développement n’est pas une release installable déjà qualifiée.

Pour construire et vérifier cette branche :

    xcodegen generate
    xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Debug \
      -derivedDataPath "$HOME/Library/Caches/Atoll-Development" build
    python3 Scripts/validate-offline.py --profile standard

Ne pas lancer le produit de build : utiliser une copie protégée préparée par Scripts/prepare-preview.py. Les détails de recette sont dans [VALIDATION](docs/VALIDATION.md), les règles dans [CLAUDE](CLAUDE.md), et l’état courant dans [HANDOFF](docs/HANDOFF.md).
