# Preuves de l'audit du 8 octobre 2026

Lire d'abord le [rapport et ses 17 propositions](../../AUDIT-2026-10-08-robustesse-simplicite.md).
Base : `a1c7d6999d6921906f26c405fc4f48e7bde30e91` (Atoll 0.18.4, build 39).
Ce dossier contient des **reproductions de défauts**, pas leurs corrections ni
une nouvelle suite de non-régression. Un constat qui cesse de se reproduire après
un correctif est attendu ; son test définitif devra vérifier le comportement corrigé.

[validation.json](validation.json) conserve les observations synthétiques et la
baseline. [inventory.json](inventory.json) compte les fichiers suivis sur la base,
avant cet ajout documentaire. Les comptages de lignes incluent commentaires et
lignes vides ; les périmètres comprennent Swift, Metal, C/header, Python et shell
selon le dossier. Les 150 fichiers / 33 350 lignes Swift produit excluent tests et
scripts. Les logs locaux de build ne sont pas publiés : ils contiennent des chemins
de machine sans valeur pour la reproduction.

## Exécution

Prérequis : macOS, Xcode/Swift, Python 3 et le checkout de la base indiquée. Validé
sur Apple Silicon, macOS 27.0.1, Xcode 27.0, Swift 6.4 (language mode 5), Python 3.9.6.
Depuis la racine du dépôt, construire d'abord les objets Core natifs. Exécuter les
commandes ci-dessous séquentiellement pour éviter les verrous SwiftPM :

```sh
swift test --package-path AtollCore --build-system native
python3 docs/audits/2026-10-08/probes/repro-memory-index.py .
python3 docs/audits/2026-10-08/probes/repro-helper-mainactor.py .
python3 docs/audits/2026-10-08/probes/sessions/run.py . --skip-build
python3 docs/audits/2026-10-08/probes/installation/run.py . --skip-build
```

Les probes d'apprentissage acceptent un build existant pour éviter sa reconstruction :

```sh
atoll_audit_build="$(swift build --package-path AtollCore --build-system native --show-bin-path)"
python3 docs/audits/2026-10-08/probes/learning/run.py . --build-dir "$atoll_audit_build"
```

Pour les trois probes UI, choisir une destination neuve, hors dépôt. Le dossier
créé par `mktemp` reste disponible pour inspecter les résultats :

```sh
atoll_audit_output="$(mktemp -d -t atoll-audit-ui)"
python3 docs/audits/2026-10-08/probes/ui/run.py --repo . --output "$atoll_audit_output/probes"
```

Les runners écrivent uniquement leurs fixtures/binaries dans des dossiers
temporaires ou dans la destination explicite. Ils compilent les classes réelles
avec des collaborateurs factices ; aucune authentification, préférence personnelle,
application normale, génération réelle ni lecture sonore. `UserDefaults` du probe
sessions est limité à un domaine volatile. Les probes skills changent seulement
les permissions d'un dossier synthétique, puis les rétablissent. Exécuter sous un
compte utilisateur normal : root peut contourner le refus d'accès d'A03.

Les chemins de stockage sont redirigés pour MemoryIndexer et HookInstaller.
FleetPoller reçoit une petite extension d'accès au lecteur privé, sans changer son
corps. Le probe jump extrait `focusIDE`, expose seulement sa visibilité et remplace
ses collaborateurs ; il ne pilote pas Cursor. Les sondes UI d'identité sonore et de
drain démontrent les primitives utilisées par l'app, pas une recette GUI complète.

## Observations attendues sur cette base

| Runner | Constats | Observation |
|---|---|---|
| `learning` | A01/A02/A03 | Note non conservée malgré succès ; état invalide remplacé ; manifeste purgé malgré skill intact |
| `repro-memory-index` | A04/A05 | Ancien texte encore indexé après deux éditions ; mémoire sans cwd exploitable |
| `sessions` | A06/A09 | Carte B annulée après A, seule A autorisée ; Fleet attend environ 8 s malgré deadline 5 s |
| `installation` | A07/A08 | Restitution partielle Edit/Edit ; doublon Atoll dans groupe mixte ; mauvais type racine remplacé |
| `repro-helper-mainactor` | A10 | Heartbeat MainActor retardé de plus de 0,6 s par le helper synthétique |
| `ui` | A09/A15/A17 | Pipe gardé ouvert après sortie parent ; objet sonore partagé ; faux succès focus |

Les runners affichent leurs observations ; seul `ui` exige que ses trois constats
se reproduisent pour sortir à zéro. **Exit 0 n'est donc pas un verdict de bonne
santé de l'app.** Les délais exacts dépendent de la machine. La collision A01 est
injectée par réservation de noms `.orphan` autour de l'horloge réelle ; elle ne
mesure pas une fréquence d'incident spontanée.

A11/A12/A13/A14/A16 restent des constats de source documentés et bornés dans le
rapport. Les contrôles de budgets, de migration et de livraison déjà présents
restent acquis ; les sabotages des futurs correctifs restent à écrire.

SwiftPM avertit que `--build-system native` est déprécié ; ce backend est utilisé
ici pour lier les mêmes objets Core dans les petits exécutables de preuve. Aucune
modification du build produit n'est proposée par ces scripts.
