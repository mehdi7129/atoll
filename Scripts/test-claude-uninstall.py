#!/usr/bin/env python3
"""Retrait des seuls hooks Claude : skills et manifestes restent intacts.

Racines Foundation privées vérifiées avant toute écriture. Les manifestes
absents, valides et corrompus n'affectent pas cette déconnexion. Le flag legacy
--sabotage-manifest réintroduit uninstallAll en copie pour prouver la protection.
"""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("helper", type=Path)
parser.add_argument("--expect-failure", action="store_true")
parser.add_argument("--sabotage-manifest", action="store_true")
parser.add_argument("--build-dir", type=Path)
args = parser.parse_args()
helper = args.helper.resolve(strict=True)
if args.sabotage_manifest:
    assert not args.expect_failure
    subprocess.run(["python3", __file__, str(helper)], check=True)
    repo = Path(__file__).resolve().parent.parent
    build = (args.build_dir or repo / "AtollCore/.build/debug").resolve()
    objects = sorted((build / "AtollCore.build").glob("*.o"))
    assert objects, "Réutiliser les objets Core compilés avec --build-dir"
    with tempfile.TemporaryDirectory(prefix="atoll-uninstall-sabotage-") as directory:
        root = Path(directory)
        source = (repo / "Bridge/main.swift").read_text()
        needle = "        let soundRestoreFailed = restoreParkedSoundHooks()"
        assert source.count(needle) == 1
        (root / "main.swift").write_text(source.replace(needle, needle + "\n        _ = try? LearnedSkillStore().uninstallAll()"))
        sources = [root / "main.swift", repo / "Shared/ProcessInspector.swift", repo / "Bridge/CodexBridge.swift"]
        command = ["swiftc", "-swift-version", "5", "-I", str(build / "Modules"), "-lsqlite3",
                   "-import-objc-header", str(repo / "Shared/BridgingHeader.h")]
        binary = root / "atoll-bridge"
        compiled = subprocess.run(command + list(map(str, sources + objects)) + ["-o", str(binary)], capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stderr
        subprocess.run(["python3", __file__, str(binary), "--expect-failure"], check=True)
    raise SystemExit(0)

failures = []
with tempfile.TemporaryDirectory(prefix="atoll-uninstall-test-") as directory:
    for mode in ["absent", "foreign", "managed", "healthy"]:
        root = Path(directory) / mode
        root.mkdir(mode=0o700)
        env = dict(os.environ, CFFIXED_USER_HOME=str(root), CODEX_HOME=str(root / ".codex"))
        env.pop("ATOLL_RETROSPECTIVE", None)
        def run(*arguments):
            return subprocess.run([str(helper), *arguments], env=env, capture_output=True, text=True, timeout=15)
        status = json.loads(run("status").stdout)
        assert Path(status["memoryIndexPath"]).resolve() == (root / ".atoll/memory.db").resolve(), "Home non isolé"
        settings = root / ".claude/settings.json"
        settings.parent.mkdir(parents=True, exist_ok=True)
        foreign = {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "printf foreign-fixture"}]}]}}
        settings.write_text(json.dumps(foreign))
        if mode == "managed":
            result = run("install")
            assert result.returncode == 0, result.stderr
            assert not (root / ".claude/skills/atoll-recall/SKILL.md").exists(), "Recall réinstallé"
        elif mode == "absent":
            settings.unlink()
        learning = root / ".atoll/learning"
        learning.mkdir(parents=True, exist_ok=True)
        retained = root / ".claude/skills/atoll-kept/SKILL.md"
        retained.parent.mkdir(parents=True)
        markdown = "Procédure à conserver, avec une ressource unique."
        retained.write_text(markdown)
        resource = retained.parent / "scripts/unique.py"
        resource.parent.mkdir(); resource.write_text("unique resource\n")
        if mode == "healthy":
            manifest = learning / "installed-v2-claude.json"
            manifest.write_text(json.dumps({"v": 2, "legacySnapshot": [], "skills": [{
                "destination": "claude", "slug": "kept", "dirName": "atoll-kept",
                "installedAt": "2026-01-01T00:00:00Z", "skillSHA256": hashlib.sha256(markdown.encode()).hexdigest()}]}))
            assert json.loads(run("status").stdout)["learnedSkills"] == 1, "Fixture de skill géré invalide"
        else:
            manifest = learning / "installed.json"
            manifest.write_text("{broken manifest")
        protected = {file: file.read_bytes() for file in [retained, resource, manifest]}
        result = run("uninstall")
        if result.returncode != 0:
            failures.append(mode + " : retrait hooks couplé au manifeste des skills")
        for file, before in protected.items():
            if not file.exists() or file.read_bytes() != before:
                failures.append(mode + " : skill, ressource ou manifeste modifié par la déconnexion")
        if mode != "absent":
            restored = json.loads(settings.read_text())
            assert restored.get("hooks", {}).get("SessionStart") == foreign["hooks"]["SessionStart"], "Hook étranger modifié"
            assert '/.atoll/bin/' not in settings.read_text(), "Hooks Atoll encore installés"
        print("Vérifié : " + mode, flush=True)
if args.expect_failure:
    assert failures, "Sabotage non détecté"
    print("PASS sabotage : " + "; ".join(failures))
elif failures:
    raise SystemExit("; ".join(failures))
else:
    print("PASS retrait Claude : hooks retirés, skills gérés/ressources/manifestes et hooks étrangers préservés")
