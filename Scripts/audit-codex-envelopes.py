#!/usr/bin/env python3
"""Mesure les enveloppes user et leurs miroirs sans afficher de conversation.

Lecture seule. Les empreintes servent seulement à comparer les deux événements
du même rollout ; le rapport ne contient ni texte, ni chemin de session.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path.home() / ".codex/sessions")
args = parser.parse_args()
counts = collections.Counter()
origins = collections.Counter()
files = 0
malformed = 0


def text(value):
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return "\n".join(item if isinstance(item, str) else item.get("text", item.get("content", ""))
                         for item in value if isinstance(item, (str, dict))).strip()
    return ""


def fingerprint(value):
    return hashlib.sha256(text(value).encode()).digest()


for path in args.root.rglob("*.jsonl"):
    files += 1
    users, twins = [], set()
    origin = "unknown"
    with path.open(errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            payload = record.get("payload", {})
            if not isinstance(payload, dict):
                continue
            if record.get("type") == "session_meta":
                origin = payload.get("originator", "unknown")
            elif record.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
                users.append(payload.get("content"))
            elif record.get("type") == "event_msg":
                item = payload.get("item", {})
                if isinstance(item, dict) and item.get("type") == "UserMessage":
                    twins.add(fingerprint(item.get("content")))
    for content in users:
        body = text(content)
        tag = next((tag for tag in ["task-notification", "command-name", "local-command-stdout", "realtime_delegation"]
                    if body.startswith("<" + tag + ">")), "other")
        counts[tag + (":twin" if fingerprint(content) in twins else ":no-twin")] += 1
        if tag != "other":
            origins[origin] += 1
print(json.dumps({"files": files, "malformedLines": malformed, "messages": counts,
                  "machineEnvelopeOrigins": origins}, ensure_ascii=False, indent=2))
