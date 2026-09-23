#!/usr/bin/env python3
"""Rejoue des rapports d'usage Codex dans AnalysisBudget, sans appel CLI ni compte.

--synthetic teste le harness avec des compteurs inventés, explicitement identifiés.
Les rapports attendus contiennent nativeUsage, usage, model, promptCharacters et
durationSeconds. Le JSON produit distingue durée capturée et durée du replay.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile


def synthetic_captures():
    # Ces valeurs sont des fixtures : aucune consommation réelle n'est affirmée.
    return [{
        "nativeUsage": {"input_tokens": 123, "cached_input_tokens": 40,
                        "output_tokens": 17, "reasoning_output_tokens": 5},
        "usage": {"availability": "reported", "source": "codexTurnCompleted",
                  "inputTokens": 123, "cachedInputTokens": 40,
                  "outputTokens": 17, "reasoningOutputTokens": 5},
        "model": "synthetic-fixture-model", "promptCharacters": 421, "durationSeconds": 9.5,
    }]


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="*")
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--build-dir", type=Path, help="réutiliser un produit Core natif Debug sans rebuild")
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.synthetic == bool(args.reports):
        parser.error("fournir des rapports capturés OU --synthetic")
    if args.build_dir and args.scratch_path:
        parser.error("--build-dir et --scratch-path sont exclusifs")
    captures = synthetic_captures() if args.synthetic else []
    for path in args.reports:
        value = json.loads(path.read_text())
        captures.extend(value if isinstance(value, list) else [value])
    if not captures or not all(isinstance(value, dict) for value in captures):
        parser.error("objet ou tableau non vide de rapports attendu")
    for capture in captures:
        native = capture.get("nativeUsage")
        if not isinstance(native, dict) or not native or not all(type(value) is int and value >= 0 for value in native.values()):
            parser.error("nativeUsage doit contenir exclusivement des compteurs entiers natifs")

    with tempfile.TemporaryDirectory(prefix="atoll-usage-replay-") as directory:
        root = Path(directory)
        normalized = root / "captures.json"
        normalized.write_text(json.dumps(captures, allow_nan=False))
        build = args.build_dir
        if build is None:
            command = ["swift", "build", "--package-path", str(repo / "AtollCore"),
                       "--build-system", "native", "--jobs", "4"]
            if args.scratch_path:
                command += ["--scratch-path", str(args.scratch_path)]
            subprocess.run(command, check=True, timeout=180)
            build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
        objects = sorted((build / "AtollCore.build").glob("*.o"))
        if not objects or not (build / "Modules/AtollCore.swiftmodule").exists():
            raise SystemExit("Produit Core natif absent : fournir un build Debug compatible")
        binary = root / "usage-replay"
        command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
                   "-lsqlite3", str(repo / "App/AnalysisExecution.swift"),
                   str(repo / "Scripts/runtime-tests/Stubs.swift"),
                   str(repo / "Scripts/learning-tests/UsageReplayMain.swift")]
        subprocess.run(command + [str(path) for path in objects] + ["-o", str(binary)],
                       check=True, timeout=120)
        results_path = root / "results.json"
        environment = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(root / "private-journals"), ZDOTDIR=str(root))
        result = subprocess.run([str(binary), str(normalized), str(results_path)], env=environment,
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        cases = json.loads(results_path.read_text())
        for case, capture in zip(cases, captures):
            case["nativeUsage"] = capture["nativeUsage"]
        # On ne recopie ni chemin personnel ni champs libres du rapport d'entrée.
        report = {"validation": "offline-analysis-budget-replay", "passed": True,
                  "sourceKind": "synthetic-fixture" if args.synthetic else "captured-cli-report",
                  "caseCount": len(cases), "cliInvocations": 0,
                  "durationNote": "capturedCLIDurationSeconds provient de la capture ; replayJournalDurationSeconds mesure uniquement le replay local.",
                  "cases": cases}
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
        print(result.stdout, end="")
        print("Source : " + report["sourceKind"] + " ; aucun CLI exécuté")


if __name__ == "__main__":
    main()
