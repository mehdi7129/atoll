#!/usr/bin/env python3
"""Migration essentielle et sabotages causaux, exclusivement dans des homes privés."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    mutations = [
        ("sound-still-enabled", "EssentialMigrationTests.testUpgradeRestoresMixedSoundsAndDenyWithoutTouchingUserData",
         'try disable(home.appendingPathComponent(".atoll/sound-settings.json"), label: "sound-settings")',
         '// Sabotage : fallback autonome encore actif.', "EM-sound-off-before-restore"),
        ("overwrite-concurrent-settings", "EssentialMigrationTests.testConcurrentSettingsChangeIsNeverOverwritten",
         'guard target == url.resolvingSymlinksInPath(), try read(url) == expected else {',
         'guard target == url.resolvingSymlinksInPath() else {', "EM-concurrent-write-preserved"),
        ("trust-corrupt-archive", "EssentialMigrationTests.testUnverifiedRecallArchiveNeverRetiresTheOriginal",
         'guard try tree(archive) == snapshot, try tree(folder) == snapshot else {',
         'guard try tree(folder) == snapshot else {', "EM-unverified-archive-refused"),
        ("forget-local-notes-recovery", "EssentialNotesRecoveryTests.testMigrationRestoresInterruptedSwapLocallyWithoutPurgingPaidEvidence",
         'try EssentialNotesRecovery.recover(learningRoot: home.appendingPathComponent(".atoll/learning"))',
         '// Sabotage : ancienne bascule laissée partielle.', "EM-notes-migration-recovers"),
        ("conflate-bool-and-number", "EssentialMigrationTests.testNumericAsyncIsActuallyRewrittenToJSONBoolean",
         'return a == b', 'return (left as? NSDictionary) == (right as? NSDictionary)', "EM-numeric-async-must-be-boolean"),
        ("forget-deny-restore", "EssentialMigrationTests.testCorruptSoundConfigCannotKeepDenyRulesSuspended",
         'try restoreParking(home.appendingPathComponent(".atoll/rockstar-parked-deny.json"), sound: false)',
         '// Sabotage : restitution deny oubliée avant erreur sonore.', "EM-deny-restored-despite-sound-error"),
    ]
    summary = {"baseline": None, "mutations": []}
    with tempfile.TemporaryDirectory(prefix="atoll-essential-sabotage-") as temporary:
        root = Path(temporary)
        package = root / "AtollCore"
        shutil.copytree(REPO / "AtollCore/Sources", package / "Sources")
        shutil.copy2(REPO / "AtollCore/Package.swift", package / "Package.swift")
        tests = package / "Tests/AtollCoreTests"
        tests.mkdir(parents=True)
        for name in ["EssentialMigrationTests.swift", "EssentialNotesRecoveryTests.swift"]:
            shutil.copy2(REPO / "AtollCore/Tests/AtollCoreTests" / name, tests / name)
        build = args.build_dir.resolve() if args.build_dir else root / "build"
        source = package / "Sources/AtollCore/EssentialMigration.swift"
        original = source.read_text()

        def run(name, selected):
            result = subprocess.run(["swift", "test", "--build-system", "native", "--package-path", str(package), "--scratch-path", str(build),
                                     "--filter", selected], capture_output=True, text=True, timeout=300)
            output = result.stdout + result.stderr
            (args.output / (name + ".log")).write_text(output)
            return result.returncode, output

        status, output = run("baseline", "EssentialMigrationTests|EssentialNotesRecoveryTests")
        if status != 0 or "Executed 18 tests" not in output:
            raise SystemExit("Nominal migration échoué ou incomplet : consulter baseline.log")
        summary["baseline"] = "18 tests passed"
        for name, case, old, new, oracle in mutations:
            if original.count(old) != 1:
                raise SystemExit("Couture de sabotage ambiguë : " + name)
            source.write_text(original.replace(old, new))
            status, output = run(name, case)
            if status == 0 or "Build complete!" not in output or oracle not in output or "Test Case" not in output:
                raise SystemExit("Sabotage non détecté par son oracle : " + name)
            summary["mutations"].append({"name": name, "compiled": True, "detected": oracle})
            source.write_text(original)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS : 18 tests, 6 sabotages compilés détectés ; aucun réglage personnel ni CLI authentifié.")


if __name__ == "__main__":
    main()
