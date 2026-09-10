#!/usr/bin/env python3
"""Réintroduit les défauts de détection, contexte et diagnostic dans une copie.

Le dépôt et les configurations personnelles restent intacts. Un échec de
compilation ne vaut jamais détection d'une régression.
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
mutants = [
    ("yolo", "CodexProcessKind.swift", ', "--yolo"', "",
     "CodexProcessKindTests/testYoloAliasAndCurrentInteractiveFlagsPreserveSessionDetection"),
    ("helper", "CodexProcessKind.swift", '(path as NSString).lastPathComponent == "codex"',
     '(path as NSString).lastPathComponent == "codex" || path.contains("/.codex/packages/")',
     "CodexProcessKindTests/testHelpersInsideTheCodexPackageAreNotSessionProcesses"),
    ("context", "CodexIntegration.swift", "entry.session.contextTokenUsage = metadata.contextUsage",
     "entry.session.contextTokenUsage = nil",
     "CodexSessionMetadataTests/testNativeTokenCountsReachTheSessionAndCompactionClearsThem"),
    ("trust", "CodexHookDiagnostics.swift", 'return "\\(activeCount)/\\(managedCount) hooks actifs. À approuver dans /hooks : \\(untrustedEventNames.joined(separator: ", "))."',
     'return "\\(untrustedCount) hooks à approuver — ouvre /hooks"',
     "CodexSetupTests/testPartialTrustNamesOnlyTheHooksThatNeedReview"),
]
results = []
with tempfile.TemporaryDirectory(prefix="atoll-island-mutants-") as directory:
    root = Path(directory)
    package = root / "AtollCore"
    shutil.copytree(repo / "AtollCore", package,
                    ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))

    def run(name, selected):
        result = subprocess.run(["swift", "test", "--package-path", str(package), "--filter", selected],
                                capture_output=True, text=True, timeout=240)
        log = result.stdout + result.stderr
        (args.output / (name + ".log")).write_text(log)
        return result.returncode, log

    code, log = run("baseline", "|".join(m[-1] for m in mutants))
    if code != 0:
        raise SystemExit("Baseline en échec ; les sabotages ne sont pas interprétables. " + log[-3000:])
    for name, filename, before, after, selected in mutants:
        path = package / "Sources/AtollCore" / filename
        original = path.read_text()
        if original.count(before) != 1:
            raise SystemExit("Point de mutation introuvable ou ambigu : " + name)
        path.write_text(original.replace(before, after))
        try:
            code, log = run(name, selected)
            detected = code != 0 and "XCTAssert" in log and "failed" in log and bool(re.search(r"Executed [1-9][0-9]* test", log))
            results.append({"case": name, "detected": detected})
            if not detected:
                raise SystemExit("Sabotage non détecté par une assertion : " + name + "\n" + log[-3000:])
            print("PASS sabotage " + name, flush=True)
        finally:
            path.write_text(original)
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
