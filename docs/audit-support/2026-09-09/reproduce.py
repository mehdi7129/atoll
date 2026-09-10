#!/usr/bin/env python3
"""Probes d'audit sur fixtures synthétiques ; aucun CLI IA ni config utilisateur."""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
core = root / "AtollCore/Sources/AtollCore"
cases = {
    "runtime": ["CodexIntegration", "CodexSessionDiscovery", "CodexPermissionTiming", "SessionModel", "HookEvent", "TerminalTarget", "TaskCompletion"],
    "digest": ["TranscriptLine", "CodexTranscriptParser", "TranscriptDigest"],
}
with tempfile.TemporaryDirectory(prefix="atoll-audit-fixtures-") as directory:
    scratch = Path(directory)
    for name, sources in cases.items():
        main = scratch / "main.swift"
        main.write_text((here / (name + ".swift")).read_text())
        executable = scratch / name
        subprocess.run(["swiftc", *[str(core / (s + ".swift")) for s in sources], str(main), "-o", str(executable)], check=True)
        print("PROBE " + name, flush=True)
        subprocess.run([str(executable), str(scratch / "hooks.json")], check=True)
