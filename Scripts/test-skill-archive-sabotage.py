#!/usr/bin/env python3
"""Réintroduit A19 dans une copie Core : une archive échouée est ignorée.

La baseline doit passer, le mutant compiler puis échouer dans l'assertion qui
exige la propagation de l'erreur. Aucun skill ou réglage personnel n'est lu.
"""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="atoll-skill-archive-mutant-") as temporary:
    package = Path(temporary) / "AtollCore"
    shutil.copytree(repo / "AtollCore", package,
                    ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))

    def run(name, selected):
        result = subprocess.run(
            ["swift", "test", "--package-path", str(package), "--build-system", "native",
             "--filter", selected], capture_output=True, text=True, timeout=240)
        log = result.stdout + result.stderr
        (args.output / (name + ".log")).write_text(log)
        return result.returncode, log

    code, log = run("baseline", "LearnedSkillArchivingTests")
    if code != 0 or not re.search(r"Executed 3 tests, with 0 failures", log):
        raise SystemExit("Baseline incomplète ou en échec ; sabotage non interprétable.\n" + log[-3000:])

    path = package / "Sources/AtollCore/LearnedSkillStore.swift"
    original = path.read_text()
    needle = 'try archiveDirectory(target, category: "uninstalled", slug: slug, stamp: timestamp())'
    if original.count(needle) != 1:
        raise SystemExit("Point de mutation absent ou ambigu.")
    path.write_text(original.replace(needle, "_ = try? " + needle.removeprefix("try ")))

    selected = "LearnedSkillArchivingTests/testArchiveInstalledPreservesSourceAndManifestWhenArchiveCannotBeCreated"
    code, log = run("ignored-archive-error", selected)
    detected = (code != 0 and "Build complete!" in log
                and "XCTAssertThrowsError failed: did not throw an error" in log
                and re.search(r"Executed 1 test, with [1-9][0-9]* failures", log) is not None)
    (args.output / "results.json").write_text(json.dumps({
        "baseline_tests": 3,
        "mutation": "archiveInstalled ignores archive failure",
        "test": selected,
        "compiled_and_detected": detected
    }, indent=2) + "\n")
    if not detected:
        raise SystemExit("Sabotage non détecté par l'assertion attendue.\n" + log[-3000:])
    print("PASS A19 : échec d'archive ignoré, mutant compilé et détecté.")
