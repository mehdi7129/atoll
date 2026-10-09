#!/usr/bin/env python3
"""Reproductions audit Atoll, racines privées et faux CLI uniquement (macOS)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repo", type=Path)
parser.add_argument("--build-dir", type=Path, help="Build Core native existant")
parser.add_argument("--case", choices=["collision", "state", "skill-root", "all"], default="all")
args = parser.parse_args()
repo = args.repo.resolve()
source = Path(__file__).resolve().parent
command = ["swift", "build", "--build-system", "native", "--package-path", str(repo / "AtollCore")]
if args.build_dir:
    build = args.build_dir.resolve()
else:
    subprocess.run(command, check=True)
    build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Build Core native requis : aucun objet à lier")
work = Path(tempfile.mkdtemp(prefix="atoll-learning-audit-"))
results = {}
for case, main in [("collision", "CurationCollision.swift"), ("state", "CurationState.swift"), ("skill-root", "SkillRoot.swift")]:
    if args.case not in [case, "all"]:
        continue
    fixture = work / case
    fixture.mkdir()
    additional = []
    if case != "skill-root":
        service = repo / "App/NotesCurationService.swift"
        additional = [service, repo / "App/AnalysisExecution.swift", repo / "Scripts/runtime-tests/Stubs.swift", repo / "Scripts/curation-tests/RetrospectiveStub.swift"]
    binary = work / (case + "-probe")
    subprocess.run(["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library", "-I", str(build / "Modules"), "-lsqlite3", *map(str, additional), str(source / main), *map(str, objects), "-o", str(binary)], check=True)
    env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture))
    output = subprocess.check_output([str(binary), str(fixture)], env=env, text=True, timeout=30)
    results[case] = json.loads(output)
(work / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(results, indent=2, ensure_ascii=False))
print("Fixtures et résultats conservés :", work)
