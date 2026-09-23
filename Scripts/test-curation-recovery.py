#!/usr/bin/env python3
"""Reprise du rangement : service/budget réels, deux CLI factices, aucun appel modèle."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sabotage", choices=["checkpoint", "fingerprint", "swap-recovery", "swap-proof", "swap-marker", "swap-marker-write"])
parser.add_argument("--output", type=Path)
parser.add_argument("--build-dir", type=Path, help="Réutiliser une compilation Core existante, sans lancer SwiftPM.")
parser.add_argument("--build-system", choices=["native", "swiftbuild"], default="native")
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-curation-recovery-"))
print(f"Fixtures et compilation : {work}", flush=True)
command = ["swift", "build", "--package-path", str(REPO / "AtollCore"), "--build-system", args.build_system]
if args.build_dir:
    build = args.build_dir
else:
    subprocess.run(command, check=True)
    build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
modules = build / "Modules"
if not objects or not modules.is_dir():
    build = next(path for path in [build, REPO / "AtollCore/.build/out/Products/Debug"]
                 if (path / "libAtollCore.a").is_file())
    modules, objects = build, [build / "libAtollCore.a"]

service = REPO / "App/NotesCurationService.swift"
expected_failure = None
if args.sabotage:
    text = service.read_text()
    if args.sabotage == "checkpoint":
        needle = "try Self.checkpointStore.save(checkpoint)"
        if text.count(needle) != 1:
            raise SystemExit("Couture checkpoint ambiguë ou absente")
        text = text.replace(needle, "// Sauvegarde supprimée par sabotage.")
        expected_failure = "résultat payé perdu après échec archive"
    elif args.sabotage in ["swap-recovery", "swap-proof", "swap-marker", "swap-marker-write"]:
        if args.sabotage == "swap-recovery":
            needle = "do { try Self.recoverCheckpointSwap() }"
            replacement = "do { try { () throws in }() }"
            expected_failure = "crash intermédiaire a perdu la reprise locale"
        elif args.sabotage == "swap-proof":
            needle = "present.allSatisfy({ source[$0.key] == $0.value || target[$0.key] == $0.value })"
            replacement = "true"
            expected_failure = "reprise ambiguë a écrasé une modification externe"
        elif args.sabotage == "swap-marker":
            needle = "swapStarted && target.allSatisfy"
            replacement = "target.allSatisfy"
            expected_failure = "reprise ambiguë a écrasé une modification externe"
        else:
            needle = 'try Data(checkpoint.id.uuidString.utf8).write(\n                to: staging.appendingPathComponent(".swap-started"), options: .atomic)'
            replacement = "// Écriture du marqueur supprimée par sabotage."
            expected_failure = "bascule appliquée sans marqueur de démarrage"
        if text.count(needle) != 1:
            raise SystemExit("Couture reprise de bascule ambiguë ou absente")
        text = text.replace(needle, replacement)
    else:
        needles = [
            ("guard CurationCorpusFingerprint(notes: Self.readNotes()) == CurationCorpusFingerprint(notes: previous) else", 1),
            ("guard checkpoint.sourceFingerprint == CurationCorpusFingerprint(notes: Self.readNotes()) else", 2),
        ]
        for needle, count in needles:
            if text.count(needle) != count:
                raise SystemExit("Couture empreinte ambiguë ou absente")
            text = text.replace(needle, "guard true else")
        expected_failure = "modification concurrente écrasée après await modèle"
    service = work / service.name
    service.write_text(text)

binary = work / "curation-recovery-tests"
subprocess.run(["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
                "-I", str(modules), "-lsqlite3", str(service),
                str(REPO / "App/AnalysisExecution.swift"),
                str(REPO / "Scripts/runtime-tests/Stubs.swift"),
                str(REPO / "Scripts/curation-tests/RetrospectiveStub.swift"),
                str(REPO / "Scripts/learning-tests/CurationRecoveryMain.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
cases = []
for provider in ["claude", "codex"]:
    for scenario in ["warm-resume", "resume-shrink", "resume-provenance", "invalid", "shrink", "provenance", "corrupt-cache",
                     "checkpoint-write-failure", "during-added", "during-modified", "during-deleted"]:
        cases.append((provider, scenario, scenario))
    for follow in ["cold-resume", "cold-opt-out", "cold-added", "cold-modified", "cold-deleted"]:
        cases.extend([(provider, "archive-seed", follow), (provider, follow, follow)])
    cases.extend([(provider, "target-seed", "target"), (provider, "cold-target", "target")])
    for boundary in ["before-delete", "delete-first", "delete-all", "move-first", "same-names",
                     "external-modified", "external-added", "staging-modified", "archive-modified",
                     "before-delete-external-deleted", "before-delete-empty-staging", "marker-absent", "marker-invalid"]:
        follow = "crash-refusal" if boundary in ["external-modified", "external-added", "staging-modified", "archive-modified",
                                               "before-delete-external-deleted", "before-delete-empty-staging", "marker-absent", "marker-invalid"] else "crash-resume"
        cases.extend([(provider, "crash-seed-" + boundary, "crash-" + boundary),
                      (provider, follow, "crash-" + boundary)])
results = []
for provider, scenario, folder in cases:
    fixture = work / f"{provider}-{folder}"
    fixture.mkdir(exist_ok=True)
    env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture))
    run = subprocess.run([str(binary), scenario, provider], env=env, text=True, capture_output=True, timeout=30)
    if run.returncode:
        if expected_failure and expected_failure in run.stderr:
            print("PASS sabotage compilé détecté : " + expected_failure, flush=True)
            break
        raise SystemExit(run.stdout + run.stderr)
    result = json.loads(run.stdout)
    results.append(result)
    print(f"PASS {provider}/{folder}/{scenario}", flush=True)
else:
    if args.sabotage:
        raise SystemExit("Sabotage non détecté : " + args.sabotage)
summary = {"realGenerativeCLICalls": 0, "casesPassed": len(results),
           "sabotageDetected": args.sabotage, "results": results,
           "scope": "Service et budget réels, racines privées, redémarrages réels du harness ; aucun lancement GUI ni CLI authentifié."}
output = args.output or work / "results.json"
output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
print(f"Résultats : {output}")
