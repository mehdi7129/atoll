#!/usr/bin/env python3
"""Déduplication du contexte des notes : vrai Core/runner, CLI fictifs et racines privées."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path)
parser.add_argument("--sabotage", action="store_true", help="réintroduire la liste brute dans une copie du runner")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
base = ["swift", "build", "--package-path", str(repo / "AtollCore"), "--build-system", "native", "--jobs", "4"]
if args.build_dir:
    build = args.build_dir
else:
    subprocess.run(base, check=True, timeout=180)
    build = Path(subprocess.check_output(base + ["--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-note-context-") as name:
    root = Path(name)
    source = repo / "App/RetrospectiveRunner.swift"
    if args.sabotage:
        original = source.read_text()
        needle = "existingNoteSlugs: noteContext.additionalSlugs,"
        assert original.count(needle) == 1, "Couture de sabotage absente ou ambiguë"
        source = root / "RetrospectiveRunner.swift"
        source.write_text(original.replace(needle, "existingNoteSlugs: noteHistory.slugs(project: job.snapshot.cwd, query: digest.text),"))
    # Observer l'argument réellement transmis, sans changer les stubs partagés.
    stubs = (repo / "Scripts/runtime-tests/Stubs.swift").read_text()
    mutations = [
        ("await Resolver.resolve(.codex)",
         'await Resolver.resolve(.codex)\n        try? prompt.write(to: BridgePaths.root.appendingPathComponent("captured-prompt.txt"), atomically: true, encoding: .utf8)'),
        ("guard let path = await ClaudeExecutable.resolve() else { return nil }",
         'guard let path = await ClaudeExecutable.resolve() else { return nil }\n        if let prompt = arguments.last { try? prompt.write(to: BridgePaths.root.appendingPathComponent("captured-prompt.txt"), atomically: true, encoding: .utf8) }'),
    ]
    for needle, replacement in mutations:
        assert stubs.count(needle) == 1, "Couture d'observation absente ou ambiguë"
        stubs = stubs.replace(needle, replacement)
    (root / "Stubs.swift").write_text(stubs)
    binary = root / "note-context-tests"
    command = ["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library", "-I", str(build / "Modules"),
               "-lsqlite3", str(source),
               *[str(repo / ("App/" + file + ".swift")) for file in
                 ["NotesCurationService", "CodexInteractionCenter", "AnalysisExecution", "PluginInventory"]],
               str(root / "Stubs.swift"), str(repo / "Scripts/learning-tests/NoteContextMain.swift"),
               *[str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))], "-o", str(binary)]
    subprocess.run(command, check=True, timeout=120)
    cases = [["core"]] + [["runner", provider, str(count)] for provider in ["claude", "codex"] for count in [20, 60]]
    results = []
    detected = False
    for index, case in enumerate(cases):
        fixture = root / str(index)
        fixture.mkdir(mode=0o700)
        env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture))
        result = subprocess.run([str(binary), *case], env=env, capture_output=True, text=True, timeout=20)
        if result.returncode:
            if args.sabotage and "slug déjà résumé transmis deux fois" in result.stderr:
                detected = True
                break
            raise SystemExit(result.stdout + result.stderr)
        results.append(json.loads(result.stdout))
    if args.sabotage and not detected:
        raise SystemExit("Sabotage non détecté")
    report = {"passed": True, "syntheticData": True, "generativeCLICalls": 0,
              "sabotageDetected": detected, "results": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print("PASS sabotage : slug déjà résumé transmis deux fois" if detected else
          "PASS " + str(sum(result["passedScenarios"] for result in results)) + " scénarios contexte de notes, dont 4 vrais runners")
