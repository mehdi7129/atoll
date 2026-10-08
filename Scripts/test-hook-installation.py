#!/usr/bin/env python3
"""Exerce le vrai helper et les éditeurs A07/A08 dans des homes jetables.

Le home Foundation est vérifié avant toute fixture. Aucun hook sonore ni CLI
authentifié n'est lancé. Le sabotage retire uniquement le garde du caller :
un défaut de compilation ne compte jamais comme détection.
"""
import argparse
import copy
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PostToolUseFailure", "PermissionDenied", "Notification", "Stop",
          "StopFailure", "SubagentStart", "SubagentStop", "PreCompact",
          "PostCompact", "SessionEnd", "PermissionRequest"]
FIXTURE_SOURCE = '''import Foundation
import AtollCore
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
let parking = URL(fileURLWithPath: CommandLine.arguments[3])
guard let result = try SoundHookEditor.park(in: Data(contentsOf: input)) else {
    fatalError("Fixture sans son")
}
let data = try SoundHookEditor.encodeParked(.init(hooks: result.parked,
    parkedAt: Date(), committedAt: Date()))
try data.write(to: parking, options: .atomic)
try result.updated.write(to: output, options: .atomic)
'''


def managed(hook):
    return ".atoll/bin/atoll-bridge" in hook.get("command", "")


def hooks_for(settings, event):
    return [hook for group in settings["hooks"][event]
            for hook in group.get("hooks", []) if managed(hook)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sabotage", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    inputs = ["AtollCore/Sources/AtollCore/HookSettingsEditor.swift",
              "AtollCore/Sources/AtollCore/SoundHookEditor.swift", "Bridge/main.swift",
              "Scripts/test-hook-installation.py", "Scripts/test-claude-uninstall.py"]

    def hashes():
        return {path: hashlib.sha256((REPO / path).read_bytes()).hexdigest() for path in inputs}

    summary = {"scenarios": [], "sabotage": None, "source_sha256": hashes()}

    def command(arguments, log):
        result = subprocess.run([str(arg) for arg in arguments], capture_output=True,
                                text=True, timeout=600)
        (args.output / (log + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Échec {log} : " + (result.stdout + result.stderr)[-3000:])
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="atoll-hook-integration-") as temporary:
        root = Path(temporary)
        build_args = ["swift", "build", "--package-path", REPO / "AtollCore",
                      "--build-system", "native", "--scratch-path", root / "core", "--jobs", "4"]
        command(build_args, "core-build")
        build = Path(command(build_args + ["--show-bin-path"], "core-path").strip())
        link = ["swiftc", "-swift-version", "5", "-I", build / "Modules", "-lsqlite3",
                "-import-objc-header", REPO / "Shared/BridgingHeader.h"]
        objects = sorted((build / "AtollCore.build").glob("*.o"))
        assert objects, "Objets Core absents"
        bridge_sources = [REPO / "Shared/ProcessInspector.swift"]
        bridge_sources += sorted(p for p in (REPO / "Bridge").glob("*.swift") if p.name != "main.swift")

        def compile_helper(source, name):
            binary = root / name
            command(link + [source] + bridge_sources + objects + ["-o", binary], name + "-build")
            return binary

        helper = compile_helper(REPO / "Bridge/main.swift", "atoll-bridge")
        fixture_source = root / "main.swift"
        fixture_source.write_text(FIXTURE_SOURCE)
        fixture = root / "park-fixture"
        command(link + [fixture_source] + objects + ["-o", fixture], "fixture-build")

        def home(name, binary=helper):
            path = root / name
            path.mkdir(mode=0o700)
            env = dict(os.environ, CFFIXED_USER_HOME=str(path), CODEX_HOME=str(path / ".codex"))
            env.pop("ATOLL_RETROSPECTIVE", None)

            def run(verb, expected=0):
                result = subprocess.run([str(binary), verb], env=env, capture_output=True,
                                        text=True, timeout=20)
                assert result.returncode == expected, f"{name}/{verb}: {result.stderr}"
                return result

            status = json.loads(run("status").stdout)
            assert Path(status["memoryIndexPath"]).resolve() == (path / ".atoll/memory.db").resolve(), "Home non isolé"
            settings = path / ".claude/settings.json"
            settings.parent.mkdir(parents=True, exist_ok=True)
            return path, settings, run

        def repair_duplicate(name, binary=helper):
            path, settings, run = home(name, binary)
            foreign = {"type": "command", "command": "printf foreign-fixture"}
            original = {"env": {"KEEP": "yes"}, "statusLine": {"type": "command", "command": "printf status"},
                        "hooks": {"Stop": [{"matcher": "original", "hooks": [foreign]}]}}
            settings.write_text(json.dumps(original))
            run("install")
            backups = list((path / ".claude").glob("*backup*"))
            assert len(backups) == 1, f"Backup introuvable : {backups}"
            backup = backups[0].read_bytes()
            installed = json.loads(settings.read_text())
            for event in EVENTS:
                # Reproduit le défaut historique, y compris les doublons tiers légitimes.
                installed["hooks"][event].insert(0, {
                    "matcher": "fixture", "description": "métadonnées tierces",
                    "hooks": [copy.deepcopy(hooks_for(installed, event)[0]), foreign, foreign]})
            settings.write_text(json.dumps(installed))
            run("install")
            repaired = json.loads(settings.read_text())
            assert all(len(hooks_for(repaired, event)) == 1 for event in EVENTS), "A08-caller-duplicate"
            for event in EVENTS:
                expected_group = copy.deepcopy(installed["hooks"][event][0])
                expected_group["hooks"] = [foreign, foreign]
                assert repaired["hooks"][event][0] == expected_group, "Groupe tiers altéré"
            for enabled in [True, False]:
                (path / ".atoll/proactive-recall.json").write_text(json.dumps({"enabled": enabled}))
                run("install")
                updated = json.loads(settings.read_text())
                prompt = hooks_for(updated, "UserPromptSubmit")
                assert len(prompt) == 1 and (prompt[0].get("async") is True) == (not enabled)
                assert prompt[0]["timeout"] == (5 if enabled else 10)
                permission = hooks_for(updated, "PermissionRequest")
                assert len(permission) == 1 and permission[0].get("async") is not True
                assert permission[0]["timeout"] == 86400
                assert all(updated["hooks"][event][0] == repaired["hooks"][event][0] for event in EVENTS)
            before, modified = settings.read_bytes(), settings.stat().st_mtime_ns
            run("install")
            assert settings.read_bytes() == before and settings.stat().st_mtime_ns == modified, "Réécriture inutile"
            assert backups[0].read_bytes() == backup, "Backup pré-Atoll remplacé"
            run("uninstall")
            restored = json.loads(settings.read_text())
            assert all(not managed(hook) for groups in restored["hooks"].values()
                       for group in groups for hook in group["hooks"])
            assert restored["env"] == original["env"] and restored["statusLine"] == original["statusLine"]
            for event in EVENTS:
                assert restored["hooks"][event][0] == repaired["hooks"][event][0]
            return True

        repair_duplicate("repair-existing")
        summary["scenarios"].append("réparation existante, tiers, recall ON/OFF, backup et absence de réécriture")
        sound = {"type": "command", "command": "afplay /tmp/atoll-fixture.aiff", "async": True}
        foreign = {"type": "command", "command": "printf retained-fixture"}
        original = {"hooks": {"PreToolUse": [
            {"matcher": matcher, "description": matcher, "hooks": [sound, foreign]}
            for matcher in ["Bash", "Edit"]]}}
        for mode in ["regular", "symlink", "invalid-root", "invalid-fragment"]:
            path, settings, run = home("sound-" + mode)
            if mode == "symlink":
                target = path / "settings-target.json"
                target.write_text("{}")
                settings.symlink_to(target)
            settings.write_text(json.dumps(original))
            if mode in ["regular", "symlink"]:
                run("install")
            source = path / "before-parking.json"
            source.write_bytes(settings.read_bytes())
            parking = path / ".atoll/parked-sound-hooks.json"
            parking.parent.mkdir(parents=True, exist_ok=True)
            command([fixture, source, settings, parking], "park-" + mode)
            partial = json.loads(settings.read_text())
            partial["hooks"]["PreToolUse"][1]["hooks"].insert(0, sound)
            settings.write_text(json.dumps(partial))
            if mode == "invalid-root":
                settings.write_text('{"hooks": null}')
            elif mode == "invalid-fragment":
                damaged = json.loads(parking.read_text())
                damaged["hooks"][0]["hookJSON"] = "{broken"
                parking.write_text(json.dumps(damaged))
            settings_before, parking_before = settings.read_bytes(), parking.read_bytes()
            run("uninstall", expected=1 if mode.startswith("invalid") else 0)
            if mode.startswith("invalid"):
                assert settings.read_bytes() == settings_before and parking.read_bytes() == parking_before
            else:
                assert json.loads(settings.read_text()) == original, "A07-caller-matcher"
                assert not parking.exists(), "Parking conservé après réussite"
                before = settings.read_bytes()
                run("uninstall")
                assert settings.read_bytes() == before, "Deuxième désinstallation non idempotente"
                if mode == "symlink":
                    assert settings.is_symlink() and settings.resolve() == target.resolve()
            summary["scenarios"].append("restitution sonore : " + mode)

        for number, value in enumerate([None, [], "future-format"]):
            path, settings, run = home(f"invalid-install-{number}")
            settings.write_text(json.dumps({"hooks": value, "env": {"KEEP": "yes"}}))
            before = settings.read_bytes()
            run("install", expected=1)
            assert settings.read_bytes() == before
            summary["scenarios"].append(f"installation refusée sans écriture : racine hooks {number}")

        command(["python3", REPO / "Scripts/test-claude-uninstall.py", helper], "existing-uninstall")
        summary["existing_uninstall_scenarios"] = 4
        if args.sabotage:
            source = (REPO / "Bridge/main.swift").read_text()
            guard = "                || HookSettingsEditor.hasDuplicateManagedHooks(in: current)\n"
            assert source.count(guard) == 1
            fixture_source.write_text(source.replace(guard, ""))
            mutant = compile_helper(fixture_source, "atoll-bridge-mutant")
            try:
                repair_duplicate("mutant-repair", mutant)
            except AssertionError as error:
                assert str(error) == "A08-caller-duplicate", f"Échec non causal : {error}"
                summary["sabotage"] = {"compiled_and_detected": True, "assertion": str(error)}
            else:
                raise AssertionError("Sabotage non détecté")
        assert hashes() == summary["source_sha256"], "Sources modifiées pendant la recette : relancer"
        (args.output / "results.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
