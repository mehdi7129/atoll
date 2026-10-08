#!/usr/bin/env python3
"""Vérifie l'atomicité et l'idempotence des documents avec deux mutations compilées."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-memory-document-", dir=Path.home() / "Library/Caches"))
package = work / "AtollCore"
shutil.copytree(REPO / "AtollCore/Sources", package / "Sources")
shutil.copy2(REPO / "AtollCore/Package.swift", package / "Package.swift")
tests = package / "Tests/AtollCoreTests"
tests.mkdir(parents=True)
shutil.copy2(REPO / "AtollCore/Tests/AtollCoreTests/MemoryDocumentTests.swift", tests / "MemoryDocumentTests.swift")
source = package / "Sources/AtollCore/MemoryIndex.swift"
original = source.read_text()
command = ["swift", "test", "--package-path", str(package), "--build-system", "native", "--jobs", "2",
           "--filter", "MemoryDocumentTests"]

def run(name):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (work / (name + ".log")).write_text(result.stdout)
    assert "Build complete!" in result.stdout, result.stdout[-4000:]
    return result

baseline = run("baseline")
assert baseline.returncode == 0, baseline.stdout[-4000:]
mutations = [
    ("atomicity", '                try run("DELETE FROM messages WHERE file_id = ?1", binds: [.int(fileID)])',
     '                try run("DELETE FROM messages WHERE file_id = ?1", binds: [.int(fileID)])\n'
     '                try exec("COMMIT")\n                try exec("BEGIN IMMEDIATE")',
     "transaction lost original content"),
    ("unchanged", "        return position == fragments.count", "        return false",
     "no rewrite"),
]
results = []
for name, needle, replacement, expected in mutations:
    assert original.count(needle) == 1, "Couture ambiguë : " + name
    source.write_text(original.replace(needle, replacement))
    result = run(name)
    assert result.returncode != 0 and expected in result.stdout, result.stdout[-4000:]
    results.append({"sabotage": name, "compiled": True, "detected": expected})
    print(name + " detected", flush=True)
source.write_text(original)
report = {"baseline": True, "tests": 6, "mutations": results, "evidence": str(work)}
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(report, indent=2, ensure_ascii=False))
