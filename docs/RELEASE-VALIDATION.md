# Vérifier une distribution Atoll

`Scripts/release.sh` construit, signe, notarise et prépare l'appcast. Les deux
vérificateurs ci-dessous sont en lecture seule sur ces artefacts : ils ne lancent
pas l'app, ne l'installent pas et ne publient rien. Les clés privées ne sont pas
nécessaires à la vérification.

## Artefacts locaux

Après le packaging, indiquer la version/build à contrôler, le relevé JSON de la
release précédente et les outils du Sparkle employé pour le build :

```sh
python3 Scripts/verify-release.py \
  --version VERSION --build BUILD \
  --previous-record docs/releases/PREVIOUS_VERSION.json \
  --sparkle-bin /chemin/SourcePackages/artifacts/sparkle/Sparkle/bin \
  --output /chemin/preuves-distribution
```

`--repo` permet de vérifier un autre checkout. Le programme exige :

- un ZIP précédent conforme à l'empreinte et à la taille publiées ;
- tous les binaires Mach-O attendus, universels arm64/x86_64, signés Developer ID
  avec Hardened Runtime, sans entitlement `get-task-allow` ;
- les signatures Sparkle EdDSA du ZIP et de chaque delta ; une copie dont un octet
  est changé doit échouer pour chaque signature ;
- notarisation, staples et évaluation Gatekeeper ;
- un delta depuis le build précédent produisant le même arbre que le ZIP complet,
  en comparant fichiers, liens, modes, tailles et empreintes ;
- l'app du DMG montée en lecture seule identique au ZIP, puis le volume démonté ;
- les enclosures, longueurs, numéros de builds et tags de toutes les entrées de
  l'appcast cohérents, sans modification des artefacts pendant la vérification.

Le résultat, les manifests et les logs vont dans un sous-dossier `run-*` de la
racine de preuve. Les copies extraites et modifiées sont temporaires et retirées
à la fin, y compris sur échec. Le code de sortie est non nul si une garde échoue.
Le vérificateur vise une mise à jour avec delta immédiat, pas une première release.

## Assets publics et appcast servi

Publier les assets avant l'appcast. Vérifier le tag, l'inventaire GitHub, toutes les
URL et les octets téléchargés à partir du résultat local précédent :

```sh
python3 Scripts/verify-release-public.py \
  --repo . --validation /chemin/preuves-distribution/run-ID/validation.json \
  --source-commit SHA_COMPLET_DU_COMMIT_TAGUE \
  --expected-served-appcast-sha256 SHA256_DU_FLUX_ATTENDU \
  --output /chemin/preuves-publiques
```

Avant activation du nouveau flux, l'empreinte attendue est celle de l'ancien flux
servi. Après activation, elle est celle du nouvel appcast local validé. Chaque
contrôle vérifie cette empreinte avant et après les téléchargements. Les anciens
rapports et téléchargements sont conservés en cas de reprise. Le contrôle GitHub
utilise `gh api` ; aucun token ni URL signée de redirection n'est consigné.

Le 2026-10-08, ces commandes paramétrables ont été éprouvées sur les artefacts
0.18.5/build 40 : sept binaires, six signatures et copies corrompues, différentiel
39→40 et DMG. Ce relevé n'est pas une validation anticipée d'une future release.
