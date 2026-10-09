#!/usr/bin/env python3
"""Indexer réel en homes privés : Markdown, cwd, reprise JSONL et mutations causales."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path)
parser.add_argument("--output", type=Path)
parser.add_argument("--sabotage", choices=["document", "empty", "cwd", "open", "seek", "read", "batch-offset"])
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-memory-indexer-", dir=Path.home() / "Library/Caches"))
command = ["swift", "build", "--package-path", str(REPO / "AtollCore"), "--build-system", "native",
           "--scratch-path", str(work / "core"), "--jobs", "4"]
if args.build_dir:
    build = args.build_dir.resolve()
else:
    subprocess.run(command, check=True)
    build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
assert objects and (build / "Modules").is_dir(), "Core compilé absent"
source = (REPO / "App/MemoryIndexer.swift").read_text()


def replace(needle, replacement, count=1):
    global source
    assert source.count(needle) == count, f"Couture ambiguë : {needle}"
    source = source.replace(needle, replacement)


expected = None
if args.sabotage:
    subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build-dir", str(build),
                    "--output", str(work / "baseline.json")], check=True)
    if args.sabotage == "document":
        needle = "        let line = TranscriptLine(\n            uuid: \"note\""
        replace(needle, "        if let state = try? index.openFile(path: url.path, inode: inode, size: size), state.offset >= size { return }\n" + needle)
        expected = "Markdown equal-size replacement stale"
    elif args.sabotage == "empty":
        needle = '        let name = url.deletingPathExtension().lastPathComponent'
        replace(needle, '        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }\n' + needle)
        expected = "Markdown empty document stale"
    elif args.sabotage == "cwd":
        replace('head.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()',
                'head.split(separator: 0x0A, omittingEmptySubsequences: true).dropLast()')
        expected = "cwd complete-line boundary wrong: newline"
    elif args.sabotage == "open":
        replace('guard let handle = FileHandle(forReadingAtPath: path) else { return true }',
                'guard let handle = FileHandle(forReadingAtPath: path) else { lastSeen[path] = (inode, size, mtime); return true }')
        expected = "open failure never retried by scan"
    elif args.sabotage == "seek":
        replace('return true // Offset et lastSeen non avancés ; réessai à la passe suivante.',
                'lastSeen[path] = (inode, size, mtime); return true')
        expected = "seek failure never retried by scan"
    elif args.sabotage == "read":
        replace("return true // Une erreur de lecture n'est pas un EOF : ne pas acquitter.",
                'lastSeen[path] = (inode, size, mtime); return true')
        expected = "read failure never retried by scan"
    else:
        replace('projectDir: projectDir, newOffset: processedOffset)',
                'projectDir: projectDir, newOffset: splitter.consumedOffset)')
        expected = "failed batch skipped remaining lines"
# Injection limitée aux exceptions IO : aucune autre logique du worker changée.
replace('FileHandle(forReadingAtPath: path)', 'MemoryTestHandle(path: path)')
source += "\n" + (REPO / "Scripts/memory-index-tests/Main.swift").read_text()
fixture = work / "MemoryProbe.swift"
fixture.write_text(source)
binary = work / "memory-probe"
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
                "-lsqlite3", str(fixture), *map(str, objects), "-o", str(binary)], check=True)
home = (work / "home").resolve()
home.mkdir(mode=0o700)
environment = os.environ.copy()
environment.update(CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home / ".codex"))
result = subprocess.run([str(binary), str(home)], env=environment, capture_output=True, text=True, timeout=90)
(work / "stdout.log").write_text(result.stdout)
(work / "stderr.log").write_text(result.stderr)
if expected:
    assert result.returncode != 0 and expected in result.stderr, result.stdout + result.stderr
    report = {"sabotage": args.sabotage, "detected": expected, "compiled": True, "baseline": True}
else:
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
report["evidence"] = str(work)
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(report, indent=2, ensure_ascii=False))
