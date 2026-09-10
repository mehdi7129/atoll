#!/usr/bin/env python3
"""Le vrai helper signale le manifest illisible et retire quand même ses hooks.

Racines Foundation privées vérifiées avant toute écriture. Aucun compte ni
réglage personnel n'est utilisé. --expect-failure sert à la copie sabotée.
"""
import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("helper", type=Path)
parser.add_argument("--expect-failure", action="store_true")
parser.add_argument("--sabotage-manifest", action="store_true")
args = parser.parse_args()
helper = args.helper.resolve(strict=True)
if args.sabotage_manifest:
    assert not args.expect_failure
    subprocess.run(["python3", __file__, str(helper)], check=True)
    repo = Path(__file__).resolve().parent.parent
    subprocess.run(["swift", "build", "--package-path", str(repo / "AtollCore")], check=True)
    build = Path(subprocess.check_output(["swift", "build", "--package-path", str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="atoll-uninstall-sabotage-") as directory:
        root = Path(directory)
        source = (repo / "Bridge/main.swift").read_text()
        assert source.count("skillRestoreFailed = true") == 1
        (root / "main.swift").write_text(source.replace("skillRestoreFailed = true", "skillRestoreFailed = false"))
        sources = [root / "main.swift", repo / "Shared/ProcessInspector.swift"]
        sources += [p for p in (repo / "Bridge").glob("*.swift") if p.name != "main.swift"]
        command = ["swiftc", "-swift-version", "5", "-I", str(build / "Modules"), "-lsqlite3",
                   "-import-objc-header", str(repo / "Shared/BridgingHeader.h")]
        command += [str(p) for p in sources] + [str(p) for p in (build / "AtollCore.build").glob("*.o")]
        binary = root / "atoll-bridge"
        subprocess.run(command + ["-o", str(binary)], check=True)
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
        elif mode == "absent":
            settings.unlink()
        learning = root / ".atoll/learning"
        learning.mkdir(parents=True, exist_ok=True)
        if mode != "healthy":
            (learning / "installed.json").write_text("{broken manifest")
        retained = root / ".claude/skills/atoll-kept/SKILL.md"
        retained.parent.mkdir(parents=True)
        retained.write_text("Procédure à conserver, propriété non démontrée.")
        result = run("uninstall")
        if result.returncode != (0 if mode == "healthy" else 1):
            failures.append(mode + " : erreur de manifest masquée par le code de sortie")
        if mode != "healthy" and "skills appris conservés" not in result.stderr:
            failures.append(mode + " : diagnostic du retrait absent")
        assert retained.read_text().startswith("Procédure à conserver"), "Retrait sans propriété démontrée"
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
    print("PASS retrait Claude : erreur explicite, hooks retirés, skills et hooks étrangers préservés")
