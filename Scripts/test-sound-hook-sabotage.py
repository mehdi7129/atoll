#!/usr/bin/env python3
"""Vérifie A07 sur une copie Core privée, puis compile des défauts causaux.

Aucun CLI, son, configuration personnelle ou app ne sont exécutés. La baseline
complète est obligatoire ; un échec de build n'est jamais une détection.
"""
import argparse
import hashlib
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
source = Path("Sources/AtollCore/SoundHookEditor.swift")
tests = Path("Tests/AtollCoreTests/SoundHookEditorTests.swift")

with tempfile.TemporaryDirectory(prefix="atoll-sound-hook-sabotage-") as temporary:
    package = Path(temporary) / "AtollCore"
    # Quatre fichiers produit entiers, sans stub ni extraction de fonction.
    # Le Core complet est validé séparément ; limiter cette copie évite de
    # recompiler ses 1 000+ tests pour chaque défaut ciblé.
    copied = [Path("Package.swift"), source, tests,
              Path("Sources/AtollCore/HookSettingsEditor.swift"),
              Path("Sources/AtollCore/ShellSplitter.swift"),
              Path("Sources/AtollCore/SoundPreferences.swift")]
    for relative in copied:
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / "AtollCore" / relative, target)
    original = (package / source).read_text()
    test_text = (package / tests).read_text()
    expected = len(re.findall(r"^    func test", test_text, re.MULTILINE))
    report = {
        "baseline_tests": expected,
        "source_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "tests_sha256": hashlib.sha256(test_text.encode()).hexdigest(),
        "copied_inputs": {str(relative): hashlib.sha256((package / relative).read_bytes()).hexdigest()
                          for relative in copied},
        "mutations": [],
    }

    def run(name, selected):
        result = subprocess.run([
            "swift", "test", "--package-path", str(package), "--build-system", "native",
            "--jobs", "4", "--filter", selected,
        ], capture_output=True, text=True, timeout=360)
        log = result.stdout + result.stderr
        (args.output / (name + ".log")).write_text(log)
        return result.returncode, log

    code, log = run("baseline", "SoundHookEditorTests")
    if code != 0 or f"Executed {expected} tests, with 0 failures" not in log:
        raise SystemExit("Baseline incomplète/en échec ; sabotage non interprétable.\n" + log[-4000:])
    report["baseline_passed"] = True

    # Chaque mutation revient au même témoin ; aucune accumulation de défauts.
    mutations = [
        ("event-wide-matching", "testA07PartialManualRestorationKeepsOriginalMatchers", "A07 matcher", [
            ('for origin in origins {\n            guard let original =',
             'for origin in [] as [Origin] {\n            guard let original ='),
            ('(groups[index]["matcher"] as? String) == origin.matcher', 'true'),
            ('if let context {', 'if let context, false {'),
        ]),
        ("ignore-group-context", "testA07SameMatcherKeepsUnknownGroupMetadata", "A07 metadata", [
            ('for origin in origins {\n            guard let original =',
             'for origin in [] as [Origin] {\n            guard let original ='),
            ('guard context == NSDictionary(dictionary: metadata),', 'guard true,'),
        ]),
        ("skip-exact-group-reservation", "testA07ExactMixedGroupIsReservedBeforeSoundSubset", "A07 reserve exact mixed group", [
            ('for origin in origins {\n            guard let original =',
             'for origin in [] as [Origin] {\n            guard let original ='),
        ]),
        ("reuse-already-consumed-group", "testA07KeepsIdenticalGroupsAndDuplicateEntriesWithinGroup", "A07 legitimate duplicates", [
            ('guard !used.contains(index),', 'guard true,'),
        ]),
        ("collapse-identical-entries", "testA07KeepsIdenticalGroupsAndDuplicateEntriesWithinGroup", "A07 legitimate duplicates", [
            ('if occurrences > handled { continue }', 'if occurrences > 0 { continue }'),
        ]),
        ("forget-mixed-group-context", "testA07RemovedMixedGroupDoesNotResurrectThirdPartyHooks", "A07 missing mixed context", [
            ('let groupJSON = serializeFragment(group)', 'let groupJSON: String? = nil'),
        ]),
        ("silently-skip-corrupt-hook", "testA07InvalidParkingFragmentRefusesSuccessfulRestoration", "XCTAssertThrowsError failed: did not throw an error", [
            ('guard let entry = parseFragment(hook.hookJSON) else {\n                    throw EditorError.unparseableParking\n                }',
             'guard let entry = parseFragment(hook.hookJSON) else {\n                    return [:]\n                }'),
        ]),
        ("merge-ignores-multiplicity", "testA07MergeParkingKeepsNewGroupContextAndMultiplicity", "A07 merge multiplicity/context", [
            ('remaining.remove(at: index)', '_ = index'),
        ]),
        ("merge-ignores-group-context", "testA07MergeParkingKeepsNewGroupContextAndMultiplicity", "A07 merge context without old group", [
            ('let context = groupContext(hook.groupJSON)', 'let context: String? = nil'),
        ]),
        ("foreign-sound-is-ignored", "testA07PartialMixedGroupWithForeignSoundIsNotConsumed", "A07 foreign sound in mixed group", [
            ('guard currentSounds.allSatisfy(soundKeys.contains) else { return false }',
             'guard true else { return false }'),
        ]),
        ("shared-anchor-is-enough", "testA07SharedAnchorDoesNotAbsorbDifferentMixedGroup", "A07 shared anchor", [
            ('return anchors == currentAnchors', 'return anchors.contains(where: currentAnchors.contains)'),
        ]),
        ("split-successive-parking-snapshots", "testA07MergeNewSoundWithinSameGroupKeepsOneGroup", "A07 merge within one group", [
            ('matcher: hook.matcher, context: groupContext(hook.groupJSON))',
             'matcher: hook.matcher, context: hook.groupJSON)'),
        ]),
    ]
    report["expected_mutations"] = len(mutations)
    for name, test, assertion, replacements in mutations:
        mutated = original
        for needle, replacement in replacements:
            if mutated.count(needle) != 1:
                raise SystemExit(f"{name}: point de mutation absent ou ambigu: {needle}")
            mutated = mutated.replace(needle, replacement)
        (package / source).write_text(mutated)
        selected = "SoundHookEditorTests/" + test
        code, log = run(name, selected)
        detected = (code != 0 and "Build complete!" in log
                    and assertion in log and "XCTAssert" in log
                    and re.search(r"Executed 1 test, with [1-9][0-9]* failures?", log) is not None
                    and f"{test}]' failed" in log)
        report["mutations"].append({
            "name": name, "test": selected, "compiled_and_detected": detected,
            "expected_assertion": assertion,
            "mutated_source_sha256": hashlib.sha256(mutated.encode()).hexdigest(),
        })
        report["passed"] = (len(report["mutations"]) == len(mutations)
                            and all(item["compiled_and_detected"] for item in report["mutations"]))
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        if not detected:
            raise SystemExit(f"{name}: sabotage non détecté par l'assertion attendue.\n" + log[-5000:])
        print(f"PASS A07 : {name}, mutant compilé et détecté.", flush=True)
