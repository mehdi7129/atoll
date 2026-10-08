#!/usr/bin/env python3
"""État illisible : service réel, fichiers privés, zéro CLI authentifié."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path, help="Core déjà compilé ; aucun SwiftPM partagé.")
parser.add_argument("--output", type=Path)
parser.add_argument("--sabotage", choices=["empty-fallback", "spawn-guard", "write-guard", "apply-guard", "reload-cadence", "repaired-absent"])
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-curation-state-"))
print(f"Fixtures et compilation : {work}", flush=True)
if args.build_dir:
    build = args.build_dir.resolve()
else:
    command = ["swift", "build", "--package-path", str(REPO / "AtollCore"), "--build-system", "native",
               "--scratch-path", str(work / "core-build"), "--jobs", "4"]
    subprocess.run(command, check=True)
    build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
modules = build / "Modules"
if not objects or not modules.is_dir():
    if not (build / "libAtollCore.a").is_file():
        raise SystemExit("Compilation Core introuvable : " + str(build))
    modules, objects = build, [build / "libAtollCore.a"]

service = REPO / "App/NotesCurationService.swift"
expected_failure = None
if args.sabotage:
    # Le même exécutable de tests doit passer avant de compiler le mutant.
    subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build-dir", str(build),
                    "--output", str(work / "baseline.json")], check=True)
    text = service.read_text()
    if args.sabotage == "empty-fallback":
        needle = '            return nil\n        }\n    }\n\n    private static func loadState() throws'
        replacement = '            return PersistedState()\n        }\n    }\n\n    private static func loadState() throws'
        expected_failure = "état initial illisible a préparé ou lancé une analyse"
    elif args.sabotage == "spawn-guard":
        needle = "        guard readState() != nil else { spawnFailure = lastOutcome; return nil }"
        replacement = ""
        expected_failure = "état devenu illisible avant spawn a déclenché une dépense"
    elif args.sabotage == "write-guard":
        needle = "        guard readState() != nil else { return false }"
        replacement = ""
        expected_failure = "cycle a écrasé l'état devenu illisible"
    elif args.sabotage == "apply-guard":
        needle = "        // Le résultat payé est déjà sauvegardé. Une panne de l'état survenue\n        // pendant les await conserve ce checkpoint et toutes les notes.\n        guard readState() != nil else { phase = .idle; return }"
        replacement = ""
        expected_failure = "état devenu illisible pendant le modèle a laissé appliquer les notes"
    elif args.sabotage == "reload-cadence":
        needle = "        guard stateNeedsReload else { return true }"
        replacement = ""
        expected_failure = "échec de sauvegarde a oublié la cadence en mémoire"
    else:
        needle = "        // Un état retiré pendant la réparation rejoint le premier armement :\n        // le scheduler reste vivant, mais cette absence n'autorise pas à payer.\n        if lastRunAt == nil {\n            lastRunAt = Date()\n            persistState()\n            return\n        }"
        replacement = ""
        expected_failure = "état retiré après erreur a lancé au lieu d'armer"
    expected_count = 2 if args.sabotage == "write-guard" else 1
    if text.count(needle) != expected_count:
        raise SystemExit("Couture de sabotage absente ou ambiguë : " + args.sabotage)
    service = work / service.name
    service.write_text(text.replace(needle, replacement))

binary = work / "curation-state-tests"
subprocess.run(["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library", "-I", str(modules),
                "-lsqlite3", str(service), str(REPO / "App/AnalysisExecution.swift"),
                str(REPO / "Scripts/runtime-tests/Stubs.swift"),
                str(REPO / "Scripts/curation-tests/RetrospectiveStub.swift"),
                str(REPO / "Scripts/curation-tests/StateMain.swift"), *map(str, objects), "-o", str(binary)], check=True)
cases = ["invalid", "empty", "type", "date", "array", "directory", "unreadable", "parent-denied", "dangling",
         "warm-invalid", "warm-empty", "warm-type", "warm-unreadable", "warm-parent-denied",
         "absent", "absent-manual", "repaired-absent", "legacy", "fingerprint", "repaired-fresh", "save-failure",
         "during-prepare", "during-cancel", "during-model"]
results = []
failure = None
for provider in ["claude", "codex"]:
    for scenario in cases:
        fixture = work / f"{provider}-{scenario}"
        fixture.mkdir(mode=0o700)
        env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture))
        run = subprocess.run([str(binary), scenario, provider], env=env, text=True, capture_output=True, timeout=30)
        if run.returncode:
            if expected_failure and run.returncode == 1 and run.stderr.strip() == "FAIL: " + expected_failure:
                failure = {"provider": provider, "scenario": scenario, "exitCode": run.returncode,
                           "stderr": run.stderr.strip()}
                print("PASS sabotage compilé détecté : " + expected_failure, flush=True)
                break
            raise SystemExit(run.stdout + run.stderr)
        result = json.loads(run.stdout)
        if result.get("passed") is not True or result.get("scenario") != scenario or result.get("provider") != provider:
            raise SystemExit("Verdict du harness incohérent")
        results.append(result)
        print(f"PASS {provider}/{scenario}", flush=True)
    if failure:
        break
if args.sabotage and failure is None:
    raise SystemExit("Sabotage non détecté : " + args.sabotage)
summary = {"realGenerativeCLICalls": 0, "casesPassed": len(results), "sabotageDetected": args.sabotage,
           "detectedFailure": failure, "results": results, "coreBuildDirectory": str(build),
           "scope": "Vrai service et budget, fixtures privées, deux CLI factices ; aucune app ni configuration personnelle."}
output = args.output or work / "results.json"
output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
print(f"Résultats : {output}")
