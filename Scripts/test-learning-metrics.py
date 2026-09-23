#!/usr/bin/env python3
"""Usage natif + journal réel, sans app/CLI/compte ; sabotages sur copies temporaires."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scratch-path", type=Path)
parser.add_argument("--sabotage", choices=["unknown", "duration", "late-usage", "writes", "cache", "latest", "json", "cold-metrics", "cold-usage"])
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="atoll-learning-metrics-") as directory:
    root = Path(directory)
    package = repo / "AtollCore"
    source = repo / "App/AnalysisExecution.swift"
    expected_core_failure = None
    expected_runtime_failure = None
    core_mutations = {
        "cache": ("AnalysisUsage.swift", "inputTokens: input, outputTokens: output, cachedInputTokens: cached,",
                  "inputTokens: input.map { $0 + (cached ?? 0) }, outputTokens: output, cachedInputTokens: cached,",
                  "testCodexNativeSnapshotPreservesCacheAndReasoningWithoutAddingThem"),
        "latest": ("AnalysisUsage.swift", 'case "turn.completed":',
                   'case "turn.completed":\n                    if latest.availability != .unknown { continue }',
                   "testLatestSnapshotReplacesEarlierCountsAndIgnoresOtherTotals"),
        "json": ("CodexExecPlan.swift", '            "--json",', "",
                 "testCodexPlanEnablesJSONLEventsWithoutRemovingStructuredFileOutput"),
    }
    runtime_mutations = {
        "cold-metrics": ("// peut n'exister que sur disque. Un journal illisible reste intact.\n        do { try load() } catch { return }",
                         "// Chargement supprimé par le sabotage.", "métriques perdues sur instance froide"),
        "cold-usage": ("func recordUsage(_ id: UUID, stdout: Data) {\n        do { try load() } catch { return }",
                       "func recordUsage(_ id: UUID, stdout: Data) {", "usage perdu sur instance froide"),
        "unknown": ('usage: .unknown))', 'usage: nil))', "nouveau journal sans inconnue explicite"),
        "duration": ("records[index].durationSeconds = elapsed >= 0 ? elapsed : nil",
                     "records[index].durationSeconds = nil; _ = elapsed", "durée terminée absente"),
        "late-usage": ("func recordUsage(_ id: UUID, stdout: Data) {",
                       "func recordUsage(_ id: UUID, stdout: Data) {\n        guard active == id else { return }",
                       "usage tardif perdu après clôture"),
        "writes": ("if let notesWritten, notesWritten >= 0 { records[index].notesWritten = notesWritten }",
                   "_ = notesWritten", "compteurs d'écritures confirmées perdus"),
    }
    if args.sabotage in core_mutations:
        package = root / "AtollCore"
        package.mkdir()
        shutil.copy2(repo / "AtollCore/Package.swift", package / "Package.swift")
        for name in ["Sources", "Tests"]:
            shutil.copytree(repo / "AtollCore" / name, package / name)
        name, needle, replacement, expected_core_failure = core_mutations[args.sabotage]
        target = package / "Sources/AtollCore" / name
        content = target.read_text()
        if content.count(needle) != 1:
            raise SystemExit("Couture de sabotage Core ambiguë ou absente")
        target.write_text(content.replace(needle, replacement))
    elif args.sabotage:
        needle, replacement, expected_runtime_failure = runtime_mutations[args.sabotage]
        content = source.read_text()
        if content.count(needle) != 1:
            raise SystemExit("Couture de sabotage runtime ambiguë ou absente")
        source = root / "AnalysisExecution.swift"
        source.write_text(content.replace(needle, replacement))

    scratch = root / "build" if expected_core_failure else (args.scratch_path or root / "build")
    # swiftbuild (nouveau défaut) utilise un autre layout de produits ; ce
    # harness lie directement les .o selon le layout natif encore supporté.
    base = ["--package-path", str(package), "--scratch-path", str(scratch), "--build-system", "native", "--jobs", "4"]
    core = subprocess.run(["swift", "test", *base, "--filter", "AnalysisUsageTests"],
                          capture_output=True, text=True, timeout=180)
    combined = core.stdout + core.stderr
    if expected_core_failure:
        if core.returncode == 0 or expected_core_failure not in combined or "XCTAssert" not in combined:
            raise SystemExit("Sabotage Core non détecté par une assertion attendue :\n" + combined)
        print("PASS sabotage Core : " + expected_core_failure)
        raise SystemExit(0)
    if core.returncode:
        raise SystemExit(combined)
    print("PASS tests Core AnalysisUsageTests")
    build = Path(subprocess.check_output(["swift", "build", *base, "--show-bin-path"], text=True).strip())
    binary = root / "metrics-tests"
    command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
               "-lsqlite3", str(source), str(repo / "Scripts/runtime-tests/Stubs.swift"),
               str(repo / "Scripts/learning-tests/MetricsMain.swift")]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True, timeout=120)
    environment = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(root / "fixtures"), ZDOTDIR=str(root))
    result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, timeout=20)
    if expected_runtime_failure:
        if result.returncode == 0 or expected_runtime_failure not in result.stderr:
            raise SystemExit("Sabotage runtime non détecté : " + result.stdout + result.stderr)
        print("PASS sabotage runtime : " + expected_runtime_failure)
    elif result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    else:
        print(result.stdout, end="")
