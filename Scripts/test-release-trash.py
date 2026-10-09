#!/usr/bin/env python3
"""Vérifie le nettoyage réversible de release.sh, sans build ni publication."""
import os
import re
import subprocess
import tempfile
import uuid
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
script = (repo / "Scripts/release.sh").read_text()
match = re.search(r"^trash_owned_path\(\) \{\n.*?^\}", script, re.M | re.S)
assert match, "Fonction de nettoyage introuvable"
function = match.group()
assert not re.search(r"^rm\s", script, re.M), "Suppression irréversible réintroduite"
for target in ["DIST", "ZIP", "STAGE"]:
    assert f'trash_owned_path "${target}"' in script, f"Nettoyage {target} non réversible"


def exercise(body):
    with tempfile.TemporaryDirectory(prefix="atoll-release-trash-") as temporary:
        root = Path(temporary)
        target = root / ("Atoll release ' $literal " + uuid.uuid4().hex)
        target.mkdir()
        (target / "archive.txt").write_text("Artefact précédent conservé\n")
        foreign = root / "foreign"
        foreign.mkdir()
        (foreign / "untouched.txt").write_text("Autre cible\n")
        (target / "Applications").symlink_to(foreign, target_is_directory=True)
        command = ["/bin/zsh", "-c", "set -euo pipefail\n" + body + '\ntrash_owned_path "$1"', "--", str(target)]
        subprocess.run(command, check=True)
        assert not target.exists(), "Ancien artefact encore au chemin de sortie"
        saved = Path.home() / ".Trash" / target.name
        assert (saved / "archive.txt").read_text() == "Artefact précédent conservé\n", "Ancien artefact non récupérable"
        assert (saved / "Applications").is_symlink(), "Lien de staging perdu"
        assert (foreign / "untouched.txt").read_text() == "Autre cible\n", "Cible étrangère modifiée"
        # Relancer sur un chemin absent est un no-op, pas un échec du pipeline.
        subprocess.run(command, check=True)


exercise(function)
print("PASS nettoyage release : contenu récupérable, lien préservé, cible étrangère intacte, chemin absent toléré")
needle = '/usr/bin/trash --stopOnError "$1"'
assert function.count(needle) == 1
try:
    exercise(function.replace(needle, ":"))
except AssertionError as error:
    assert "encore au chemin de sortie" in str(error)
    print("PASS sabotage : nettoyage neutralisé détecté")
else:
    raise AssertionError("Sabotage non détecté")

# Le packaging peut employer un DerivedData isolé sans déplacer le build quotidien.
def check_derived_data(source):
    assignment = re.search(r'^DD=.*$', source, re.M)
    assert assignment, "Affectation DerivedData introuvable"
    env = dict(os.environ)
    env.pop("ATOLL_RELEASE_DERIVED_DATA", None)
    command = ["/bin/zsh", "-c", assignment.group() + '\nprint -r -- "$DD"']
    default = subprocess.check_output(command, env=env, text=True).strip()
    assert default == str(Path.home() / "Library/Developer/Atoll-DerivedData")
    isolated = "/private/tmp/Atoll release ' $literal DerivedData"
    env["ATOLL_RELEASE_DERIVED_DATA"] = isolated
    assert subprocess.check_output(command, env=env, text=True).strip() == isolated, "DerivedData privé ignoré"

check_derived_data(script)
print("PASS DerivedData : défaut conservé, chemin privé littéral respecté")
try:
    check_derived_data(script.replace('${ATOLL_RELEASE_DERIVED_DATA:-$HOME/Library/Developer/Atoll-DerivedData}', '$HOME/Library/Developer/Atoll-DerivedData'))
except AssertionError as error:
    assert "privé ignoré" in str(error)
    print("PASS sabotage : DerivedData privé ignoré détecté")
else:
    raise AssertionError("Sabotage DerivedData non détecté")
