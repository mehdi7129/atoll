#!/usr/bin/env python3
"""Réintroduit les pertes d'autorité A03 dans une copie privée du Core.

Baseline obligatoire, refus POSIX réels sous un compte non root, mutants
compilés et assertion attendue. Aucun skill ni réglage personnel n'est lu.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise SystemExit("Refus : les permissions de fixtures doivent être testées sans root.")
    args.output.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parent.parent
    relative = Path("Sources/AtollCore/LearnedSkillStore.swift")
    source = repo / "AtollCore" / relative
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    results = {"baseline_tests": 10, "effective_uid": os.geteuid(),
               "source_sha256": source_sha, "mutations": []}
    with tempfile.TemporaryDirectory(prefix="atoll-skill-reconciliation-mutant-") as temporary:
        package = Path(temporary) / "AtollCore"
        shutil.copytree(repo / "AtollCore", package,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))

        def run(name, selected):
            result = subprocess.run(
                ["swift", "test", "--package-path", str(package), "--build-system", "native",
                 "--jobs", "4", "--filter", selected],
                capture_output=True, text=True, timeout=240)
            log = result.stdout + result.stderr
            (args.output / (name + ".log")).write_text(log)
            return result.returncode, log

        code, log = run("baseline", "LearnedSkillReconciliationTests")
        if code != 0 or not re.search(r"Executed 10 tests, with 0 failures", log) or " skipped " in log:
            raise SystemExit("Baseline incomplète ou en échec ; sabotage non interprétable.\n" + log[-3000:])

        path = package / relative
        original = path.read_text()
        root_catch = '''            children = nil
            if (error as NSError).code != NSFileReadNoSuchFileError || (error as NSError).domain != NSCocoaErrorDomain {
                accessProblems.append("Dossier des skills inaccessible — manifeste conservé : \\(error.localizedDescription)")
            }'''
        directory_catch = '''                    let failure = error as NSError
                    if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError {
                        removedFromManifest.append(entry.slug)
                    } else {
                        kept.append(entry)
                        accessProblems.append("Dossier « \\(entry.dirName) » inaccessible — manifeste conservé : \\(error.localizedDescription)")
                    }'''
        skill_error = '''accessProblems.append("Skill « \\(entry.slug) » inaccessible — manifeste conservé : \\(error.localizedDescription)")'''
        mutations = [
            ("inaccessible-child-as-missing", [root_catch, directory_catch],
             ["            children = []", "                    removedFromManifest.append(entry.slug)"],
             "testReconcilePreservesManifestWhenRootCannotBeTraversed",
             "Le manifeste complet doit rester identique pendant l'erreur."),
            ("permission-error-as-user-edit", skill_error, "userModified.append(entry.slug)",
             "testReconcilePreservesManifestWhenSkillFileCannotBeRead",
             "Un accès refusé ne prouve pas une édition."),
            ("partial-manifest-write", "if accessProblems.isEmpty, !removedFromManifest.isEmpty {",
             "if !removedFromManifest.isEmpty {",
             "testReconcileDefersProvenDeletionWhenAnotherSkillIsInaccessible",
             "Le manifeste complet doit rester identique pendant l'erreur."),
            ("ignore-proven-absence", "removedFromManifest.append(entry.slug)", "kept.append(entry)",
             "testReconcileRemovesOnlyProvenMissingChild",
             "L'absence prouvée doit être réconciliée."),
            ("case-sensitive-name-comparison", "_ = try fm.attributesOfItem(atPath: dir.path)",
             '''guard children!.contains(where: { $0.lastPathComponent == entry.dirName }) else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }''',
             "testReconcileKeepsManagedDirectoryAfterCaseOnlyRename",
             "Le chemin existant doit garder son autorité après renommage de casse.")
        ]
        for name, needle, replacement, test, assertion in mutations:
            changes = zip(needle, replacement) if isinstance(needle, list) else [(needle, replacement)]
            mutated = original
            for before, after in changes:
                if original.count(before) != 1:
                    raise SystemExit("Point de mutation absent ou ambigu : " + name)
                mutated = mutated.replace(before, after)
            path.write_text(mutated)
            selected = "LearnedSkillReconciliationTests/" + test
            code, log = run(name, selected)
            detected = (code != 0 and "Build complete!" in log
                        and re.search(r"error: .*XCTAssert\w+ failed.*" + re.escape(assertion), log) is not None
                        and re.search(r"Executed 1 test, with [1-9][0-9]* failures \(0 unexpected\)", log) is not None)
            results["mutations"].append({"name": name, "test": selected,
                                         "compiled_and_detected": detected})
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            if not detected:
                raise SystemExit("Sabotage non détecté par l'assertion attendue : " + name + "\n" + log[-3000:])
        if hashlib.sha256(source.read_bytes()).hexdigest() != source_sha:
            raise SystemExit("Le fichier source a changé pendant les sabotages ; revalider la nouvelle version.")
    print("PASS A03 : baseline de 10 tests ; 5 mutants compilés et détectés.")


if __name__ == "__main__":
    main()
