#!/usr/bin/python3
"""CLI strictement privé : ses seules écritures restent à côté de ce fichier."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parent
config = json.loads((root / "config.json").read_text())
arguments = sys.argv[1:]
kind = arguments[1] if len(arguments) > 1 else "unknown"
identity = arguments[2] if len(arguments) > 2 else ""
event = {"kind": kind, "id": identity, "pid": os.getpid()}


def record(phase):
    line = dict(event, phase=phase, at=time.monotonic())
    descriptor = os.open(root / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(line) + "\n").encode())
    finally:
        os.close(descriptor)


record("start")
try:
    if arguments[:2] == ["plugin", "list"]:
        available = "--available" in arguments
        time.sleep(config.get("availableDelay", 0) if available else config.get("listDelay", 0))
        installed = config["installed"]
        if config.get("inheritedPipe"):
            # Le parent finit ; ce descendant privé garde les deux pipes ouverts.
            subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3)"])
        print(json.dumps({"installed": installed, "available": [{
            "pluginId": "fixture@market", "name": "fixture", "description": "plugins fixture"
        }]} if available else installed), flush=True)
    elif arguments[:2] == ["plugin", "details"]:
        time.sleep(config.get("detailsDelay", 0.06))
        short = identity.split("@")[0]
        if short in config.get("fail", []) or identity in config.get("fallback", []):
            sys.exit(1)
        print("Always-on: %s tokens" % config.get("tokens", {}).get(short, 100), flush=True)
    elif kind in ["install", "enable", "disable"]:
        time.sleep(config.get("mutationDelay", 0.3))
        (root / "mutation-finished").write_text(identity)
    else:
        raise SystemExit("Commande de fixture inconnue")
finally:
    record("end")
