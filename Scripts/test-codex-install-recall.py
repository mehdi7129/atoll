#!/usr/bin/env python3
"""Recette du helper compilé : installation Codex seule + recall + retrait.

CFFIXED_USER_HOME redirige Foundation vers un home temporaire. Aucun socket
ni réglage personnel touché, aucun appel modèle, aucun binaire Claude requis.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("helper", type=Path)
args = parser.parse_args()
helper = args.helper.resolve(strict=True)
repo = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--package-path", str(repo / "AtollCore")], check=True)
build = Path(subprocess.check_output(["swift", "build", "--package-path", str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-install-recall-") as directory:
    root = Path(directory)
    home, codex_home = root / "home", root / "codex home"
    home.mkdir(mode=0o700)
    codex_home.mkdir(mode=0o700)
    environment = dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(codex_home))
    environment.pop("ATOLL_RETROSPECTIVE", None)
    foreign = {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "printf foreign", "async": True}]}]}}
    settings = codex_home / "hooks.json"
    settings.write_text(json.dumps(foreign))
    def run(*arguments):
        result = subprocess.run([str(helper), *arguments], env=environment, text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout
    # Lecture préalable : prouve la racine réellement utilisée AVANT écriture.
    status = json.loads(run("status"))
    assert Path(status["codex"]["home"]).resolve() == codex_home.resolve(), "home Foundation/env inattendu"
    assert Path(status["memoryIndexPath"]).resolve() == (home / ".atoll/memory.db").resolve(), "racine Foundation non isolée"
    run("install-codex")
    assert not (home / ".claude").exists(), "installation Codex a créé une configuration Claude"
    skill = codex_home / "skills/atoll-recall/SKILL.md"
    assert str(helper) in skill.read_text(), "helper absolu absent du recall"
    assert ".claude/" not in skill.read_text()
    installed = settings.read_bytes()
    stamp = settings.stat().st_mtime_ns
    run("install-codex")
    assert settings.read_bytes() == installed and settings.stat().st_mtime_ns == stamp, "installation non idempotente"
    print("PASS helper installé deux fois : Codex seul, hooks étrangers préservés, aucune config Claude, idempotence.")
    source = root / "main.swift"
    source.write_text(r'''
import Foundation
import AtollCore
let db = URL(fileURLWithPath: CommandLine.arguments[1])
let index = try MemoryIndex(url: db, mode: .readWrite)
defer { index.close() }
for (session, role) in [("codex:fixture", TranscriptLine.Role.user), ("claude-fixture", .assistant), ("codex:machine", .instruction)] {
    let state = try index.openFile(path: "/fixture/\(session).jsonl", inode: 1, size: 100)
    let line = TranscriptLine(uuid: session, sessionID: session, timestamp: Date(), cwd: "/fixture/project", gitBranch: nil,
        fragments: [.init(role: role, text: "atoll quantique corail : connaissance de test")])
    try index.ingest(lines: [(line: line, syntheticUUID: session)], fileState: state,
        sessionID: session, projectDir: "fixture", newOffset: 100)
}
''')
    binary = root / "seed"
    command = ["swiftc", "-I", str(build / "Modules"), "-lsqlite3", str(source)]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    subprocess.run([str(binary), str(home / ".atoll/memory.db")], env=environment, check=True)
    results = json.loads(run("recall", "quantique corail", "--project", "/fixture/project", "--json"))
    assert {item["sessionId"] for item in results} == {"codex:fixture", "claude-fixture"}, results
    assert {item["resume"] for item in results} == {"codex resume fixture", "claude --resume claude-fixture"}
    assert all(item["role"] != "instruction" for item in results)
    print("PASS recall manuel du helper : corpus partagé, instructions exclues, bonnes commandes de reprise, aucun Claude requis.")
    run("uninstall-codex")
    assert json.loads(settings.read_text()) == foreign, "hook étranger modifié au retrait"
    assert not skill.exists(), "skill géré non retiré"
    assert (home / ".atoll/memory.db").exists(), "mémoire partagée supprimée"
    assert not (home / ".claude").exists()
    print("PASS retrait Codex : hooks étrangers et mémoire préservés, recall retiré, aucune configuration Claude.")
