#!/usr/bin/env python3
"""Contre-épreuves du verdict de sabotage Codex, avec compilations hors ligne.

Ne lance que le faux CLI de test-codex-exec.py. Chaque variante du harness est
une copie jetable ; les sources produit et l'authentification restent intactes.
"""
from pathlib import Path
import subprocess
import sys
import tempfile


repo = Path(__file__).resolve().parent.parent
source = (repo / "Scripts/test-codex-exec.py").read_text()
success = "PASS sabotage compilé : fichier d’instructions manquant détecté"
nominal = "PASS CodexRun.prepare réel hors ligne"
write_copy = "        copy.write_text(sabotaged)"
catalog_arguments = "['-c', 'features.plugins=false', 'app-server', '--listen', 'stdio://']"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit("Couture du contre-test introuvable ou ambiguë : " + old)
    return text.replace(old, new)


# Un faux catalogue défaillant après le nominal reproduit l'ancien faux positif
# sans permettre à la première exécution verte de masquer la panne suivante.
catalog_failure = write_copy + '''
        fixture.write_text("#!" + os.sys.executable + "\\nraise SystemExit('catalogue indisponible')\\n")'''

cases = [
    ("sabotage réel", source, True, True, success),
    ("sabotage neutralisé",
     replace_once(source, write_copy, "        copy.write_text(content)"),
     False, True, "Sabotage non détecté par le garde des instructions"),
    ("catalogue nominal invalide",
     replace_once(source, catalog_arguments, "['app-server', '--listen', 'stdio://']"),
     False, False, "Préparation nominale en échec ; aucun sabotage validé"),
    ("catalogue mutant invalide",
     replace_once(source, write_copy, catalog_failure),
     False, True, "préparation réelle impossible avec le catalogue factice"),
    ("mutant non compilable",
     replace_once(source, write_copy, '        copy.write_text("Ceci ne compile pas en Swift")'),
     False, True, "error:"),
]

for name, content, expected_success, expected_nominal, diagnostic in cases:
    with tempfile.TemporaryDirectory(prefix="atoll-exec-verdict-") as directory:
        root = Path(directory)
        (root / "Scripts").mkdir()
        # Réutiliser les objets Swift construits ; aucune copie de produit,
        # aucune modification des fichiers visés par ces liens.
        for component in ("AtollCore", "App", "Shared"):
            (root / component).symlink_to(repo / component, target_is_directory=True)
        harness = root / "Scripts/test-codex-exec.py"
        harness.write_text(content)
        result = subprocess.run(
            [sys.executable, str(harness), "--prepare-only", "--sabotage-instructions-file"],
            capture_output=True, text=True, timeout=360,
        )
        output = result.stdout + result.stderr
        if ((result.returncode == 0) != expected_success
                or (success in output) != expected_success
                or (nominal in output) != expected_nominal
                or diagnostic not in output):
            print(output, file=sys.stderr)
            raise SystemExit("FAIL verdict inattendu : " + name)
        print("PASS verdict : " + name, flush=True)

print("PASS 5 contre-épreuves du verdict Codex ; aucun appel modèle.")
