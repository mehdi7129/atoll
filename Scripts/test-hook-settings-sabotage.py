#!/usr/bin/env python3
"""Réintroduit A08 dans une copie privée du vrai éditeur Core et de ses tests.

Le nominal doit réussir, puis chaque mutant doit compiler et échouer sur
l'assertion causale attendue. Aucun réglage personnel ni CLI n'est utilisé.
"""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUITE = "HookSettingsEditorMixedGroupsTests"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only", nargs="+", help="Rejouer seulement les mutants nommés, après le nominal complet.")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    mutations = [
        ("mixed-duplicate", "testInstallReplacesMixedManagedHooksForEveryManagedEvent", "A08-single-managed",
         'var entries = try strictEntries(hooks[event.name]).compactMap(removingManagedHooks)',
         'var entries = try strictEntries(hooks[event.name])\n            entries.removeAll { isManagedEntry($0) }'),
        ("drop-foreign-group", "testInstallPreservesForeignGroupsOrderMatchersAndMetadata", "A08-foreign-groups",
         'let remaining = inner.filter { !isManagedHook($0) }',
         'let remaining: [[String: Any]] = []'),
        ("drop-group-metadata", "testInstallPreservesForeignGroupsOrderMatchersAndMetadata", "A08-foreign-groups",
         'var result = entry\n        result["hooks"] = remaining',
         'var result: [String: Any] = [:]\n        result["hooks"] = remaining'),
        ("reverse-foreign-hooks", "testInstallPreservesForeignGroupsOrderMatchersAndMetadata", "A08-foreign-groups",
         'let remaining = inner.filter { !isManagedHook($0) }',
         'let remaining = Array(inner.filter { !isManagedHook($0) }.reversed())'),
        ("keep-stale-recall", "testMixedGroupRecallToggleLeavesExactlyOneHookInRequestedMode", "A08-recall-single",
         'var entries = try strictEntries(hooks[event.name]).compactMap(removingManagedHooks)',
         'var entries = try strictEntries(hooks[event.name])\n            entries.removeAll { isManagedEntry($0) }'),
        ("recall-always-async", "testMixedGroupRecallToggleLeavesExactlyOneHookInRequestedMode", "A08-recall-async",
         'if event.async { hook["async"] = true }',
         'hook["async"] = true'),
        ("malformed-root-as-missing", "testInstallRefusesPresentMalformedHooksRootAndUninstallPreservesIt",
         "A08-malformed-root",
         '''var hooks: [String: Any] = [:]
        if let value = settings["hooks"] {
            guard let existing = value as? [String: Any] else {
                throw EditorError.unparseableSettings
            }
            hooks = existing
        }''',
         'var hooks = settings["hooks"] as? [String: Any] ?? [:]'),
        ("drop-unknown-groups", "testUnknownOrEmptyGroupsRemainUntouchedBesideManagedHooks", "A08-unknown-groups",
         'inner.contains(where: isManagedHook) else { return entry }',
         'inner.contains(where: isManagedHook) else { return nil }'),
        ("append-on-every-install", "testMixedGroupReinstallIsByteIdempotent", "A08-idempotence",
         'var entries = try strictEntries(hooks[event.name]).compactMap(removingManagedHooks)',
         'var entries = try strictEntries(hooks[event.name])'),
        ("uninstall-keeps-mixed-managed", "testMixedGroupUninstallPreservesExactlyTheForeignConfiguration",
         "A08-direct-uninstall",
         'let remaining = entries.compactMap(removingManagedHooks)',
         'let remaining = entries.filter { !isManagedEntry($0) }'),
        ("miss-existing-duplicates", "testDuplicateDetectionFindsMixedAndPureInstalledDuplicates",
         "A08-detect-pure", 'return count > 1', 'return count > 100'),
        ("single-hook-is-duplicate", "testDuplicateDetectionIgnoresForeignUnknownAndSingleManagedHooks",
         "A08-no-false-duplicate", 'return count > 1', 'return count > 0'),
    ]
    if args.only:
        unknown = set(args.only) - {item[0] for item in mutations}
        if unknown:
            parser.error("Mutants inconnus : " + ", ".join(sorted(unknown)))
        mutations = [item for item in mutations if item[0] in args.only]
    summary = {"baseline_tests": 9, "mutations": []}
    with tempfile.TemporaryDirectory(prefix="atoll-hook-settings-sabotage-") as temporary:
        package = Path(temporary) / "AtollCore"
        # Cet éditeur ne dépend que de Foundation. Compiler sa vraie source et
        # ses vrais tests suffit au sabotage ; la suite Core complète est séparée.
        for relative in ["Sources/AtollCore/HookSettingsEditor.swift",
                         "Tests/AtollCoreTests/HookSettingsEditorMixedGroupsTests.swift"]:
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "AtollCore" / relative, target)
        (package / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AtollCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "AtollCore"),
    .testTarget(name: "AtollCoreTests", dependencies: ["AtollCore"])
])
''')
        source = package / "Sources/AtollCore/HookSettingsEditor.swift"
        original = source.read_text()

        def run(name, selected):
            result = subprocess.run(
                ["swift", "test", "--package-path", str(package), "--build-system", "native",
                 "--jobs", "4", "--filter", selected],
                capture_output=True, text=True, timeout=240)
            log = result.stdout + result.stderr
            (args.output / (name + ".log")).write_text(log)
            return result.returncode, log

        code, log = run("baseline", SUITE)
        if code != 0 or not re.search(r"Executed 9 tests, with 0 failures", log):
            raise SystemExit("Baseline incomplète ou en échec ; sabotage non interprétable.\n" + log[-3000:])
        print("PASS nominal A08 : 9 tests.", flush=True)

        for name, test, marker, needle, replacement in mutations:
            if original.count(needle) != 1:
                raise SystemExit(f"Point de mutation absent ou ambigu : {name}.")
            source.write_text(original.replace(needle, replacement))
            code, log = run(name, SUITE + "/" + test)
            # XCTest imprime les collections sur plusieurs lignes et emploie
            # « failure » au singulier : conserver le bloc de l'assertion entière.
            failures = re.findall(
                r"^[^\n]*error:[^\n]*XCTAssert[^\n]*failed\b.*?"
                r"(?=^Test Case |^Test Suite |^[^\n]*error:|\Z)", log, re.MULTILINE | re.DOTALL)
            assertion = any(marker in failure for failure in failures)
            detected = (code != 0 and "Build complete!" in log and assertion
                        and re.search(r"Executed 1 test, with [1-9][0-9]* failures?", log) is not None)
            summary["mutations"].append({"name": name, "test": test, "assertion": marker,
                                         "compiled_and_detected": detected})
            (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
            if not detected:
                raise SystemExit(f"Sabotage non détecté par l'assertion attendue : {name}.\n" + log[-3000:])
            print(f"PASS A08 : {name}, mutant compilé et détecté.", flush=True)
        source.write_text(original)


if __name__ == "__main__":
    main()
