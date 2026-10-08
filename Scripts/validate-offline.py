#!/usr/bin/env python3
"""Validation macOS reproductible, sans app, compte ni CLI agent installé."""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
EXCLUDED = {
    "test-codex-catalog.py": "Recette du CLI Codex installé ; validation native séparée.",
    "test-codex-read-storage.py": "Exige un binaire Codex natif ; mesure séparée, jamais implicite.",
    "test-ui.py": "Lance un aperçu GUI protégé ; captures à lire séparément.",
    "test-ui-sabotage.py": "Compile et lance des aperçus GUI protégés.",
    "test-settings-sabotage.py": "Compile et lance des aperçus GUI protégés.",
    "test-voiceover.py": "Exige une app et VoiceOver déjà autorisé.",
}


@dataclass(frozen=True)
class Step:
    name: str
    command: list
    needs_core: bool = False
    timeout: int = 600
    baseline: str = ""


def plan(profile, output, build, only=()):
    """Liste fermée : aucune option utilisateur ne devient un argument de CLI."""
    scratch = output / "core"
    core = Step("core", ["swift", "test", "--package-path", str(REPO / "AtollCore"),
                        "--scratch-path", str(scratch), "--build-system", "native", "--jobs", "4"], timeout=1200)
    steps = [core]

    def add(name, *arguments, core=True, timeout=600):
        steps.append(Step(name, [sys.executable, str(REPO / "Scripts" / ("test-" + name + ".py")),
                                 *map(str, arguments)], core, timeout))

    add("offline-validation", core=False, timeout=30)
    if profile != "core":
        for name in ["runtime", "skill-review", "curation", "curation-recovery", "curation-state",
                     "learning-note-context", "learning-retrospective"]:
            add(name, "--build-dir", build)
        add("learning-digest", "--output", output / "digest", core=False)
        add("learning-metrics", "--scratch-path", scratch)
        add("learning-usage-replay", "--synthetic", "--build-dir", build, "--output", output / "usage")
        add("memory-indexer", "--build-dir", build, "--output", output / "memory-indexer.json")
        add("feedback", "--build-dir", build, "--output", output / "feedback",
            *(["--sabotage"] if profile == "full" else []))
        add("plugin-services", "--skip-core-build", "--core-build", scratch, "--output", output / "plugins",
            *(["--sabotage"] if profile == "full" else []))
        for name in ["process-services", "analysis-processes", "codex-stdout"]:
            add(name, "--build-dir", build, "--output", output / name,
                *(["--sabotage"] if profile == "full" and name == "codex-stdout" else []))
        add("claude-permissions", "--build-dir", build, "--output", output / "claude-permissions")
        add("codex-quota-poller", core=False)
        add("codex-exec", "--prepare-only", "--build-dir", build,
            *(["--sabotage-instructions-file"] if profile == "full" else []))
        add("codex-exec-verdict", "--build-dir", build, timeout=1800)
        add("skill-generation", "--prepare-only", "--build-dir", build, "--output", output / "generation")
        add("release-trash", core=False)
        add("hook-installation", "--build-dir", build, "--lifecycle", "--output", output / "hooks",
            *(["--sabotage"] if profile == "full" else []))
    if profile == "full":
        variants = {
            "curation": "cancellation unchanged post-write archive-uniqueness",
            "curation-recovery": "checkpoint fingerprint swap-recovery swap-proof swap-marker swap-marker-write collision-preflight collision-preservation",
            "curation-state": "empty-fallback spawn-guard write-guard apply-guard reload-cadence repaired-absent",
            "learning-digest": "head-only command-marker shortened-count dropped-count read-stop",
            "learning-metrics": "unknown duration late-usage writes cache latest json cold-metrics cold-usage",
            "learning-retrospective": "checkpoint counts material dedup recovery-progress recovery-independent reader usage digest-metrics journal-revision notes-revision",
            "memory-indexer": "document empty cwd open seek read batch-offset",
            "codex-quota-poller": "overlap stop-reference before-fetch stale child-cancel",
            "process-services": "heartbeat serialization coalescing barrier",
            "analysis-processes": "retrospective curation",
            "claude-permissions": "card phase helper-exit disconnected-helper",
        }
        flags = {
            "runtime": "cancellation quota-projection oversize-diagnostic launch-retro launch-curation launch-search curation-retry curation-journal budget-recovery budget-admission capture-journal",
            "skill-review": "stale-catalog stale-error loading access-error access-recovery access-clear",
            "learning-note-context": "",
        }
        originals = {step.name: step for step in steps}
        for name, options in {**variants, **flags}.items():
            baseline = originals[name]
            for option in options.split() or [""]:
                key = name + "/" + (option or "sabotage")
                arguments = baseline.command.copy()
                if "--output" in arguments:
                    index = arguments.index("--output") + 1
                    suffix = Path(arguments[index]).suffix
                    arguments[index] = str(output / (key.replace("/", "-") + suffix))
                arguments += (["--sabotage", option] if name in variants
                              else ["--sabotage" + ("-" + option if option else "")])
                steps.append(Step(key, arguments, baseline.needs_core, baseline.timeout, name))
        add("learning-core", "--all", "--build-dir", build, timeout=1200)
        add("review-regressions", core=False, timeout=1800)
        for name in ["bounded-process-sabotage", "hook-settings-sabotage", "sound-hook-sabotage",
                     "skill-archive-sabotage", "skill-reconciliation-sabotage", "island-context-sabotage"]:
            add(name, "--output", output / name, core=False, timeout=1800)
        add("memory-document-sabotage", "--output", output / "memory-document.json", core=False, timeout=1800)
    steps.append(Step("docs", [sys.executable, str(REPO / "Scripts/check-docs.py"), "--no-tests"], timeout=600))
    if only:
        unknown = set(only) - {step.name for step in steps}
        if unknown:
            raise ValueError("Étapes absentes de ce profil : " + ", ".join(sorted(unknown)))
        selected = [step for step in steps if step.name in only]
        if any(step.needs_core for step in selected) and core not in selected:
            selected.insert(0, core)
        requested_baselines = {step.baseline for step in selected if step.baseline}
        selected = [step for step in steps if step in selected or step.name in requested_baselines]
        return selected
    return steps


def environment(output):
    env = dict(os.environ)
    for key in ["ATOLL_CODEX_LIVE_TEST", "ATOLL_CODEX_EXECUTABLE", "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY", "CODEX_API_KEY"]:
        env.pop(key, None)
    temporary = output / "tmp"
    temporary.mkdir(parents=True, exist_ok=True)
    env["TMPDIR"] = str(temporary) + os.sep
    env["PYTHONUNBUFFERED"] = "1"
    return env


def run_command(step, log, env):
    started = time.monotonic()
    status, code = "failed", None
    try:
        with log.open("w") as stream:
            process = subprocess.Popen(step.command, cwd=REPO, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=step.timeout)
                status = "passed" if code == 0 else "failed"
            except subprocess.TimeoutExpired:
                status = "timed_out"
                # Seulement le groupe créé pour cette étape, jamais un nom de processus.
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
    except OSError as error:
        log.write_text(str(error) + "\n")
    return {"name": step.name, "command": step.command, "status": status, "returncode": code,
            "seconds": round(time.monotonic() - started, 3), "log": str(log)}


def execute(steps, output, env, runner=run_command):
    """Un échec reste un échec ; ses dépendants sont bloqués, les autres continuent."""
    results = []
    core_ok = False
    for step in steps:
        print("RUN " + step.name, flush=True)
        baseline_ok = not step.baseline or any(result["name"] == step.baseline and result["status"] == "passed"
                                               for result in results)
        if (step.needs_core and not core_ok) or not baseline_ok:
            result = {"name": step.name, "command": step.command, "status": "blocked",
                      "returncode": None, "reason": "La compilation/test Core ou le nominal requis a échoué."}
        else:
            result = runner(step, output / (step.name.replace("/", "-") + ".log"), env)
        if step.name == "core":
            core_ok = result["status"] == "passed"
        results.append(result)
        (output / "steps.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
        print(result["status"].upper() + " " + step.name, flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["core", "standard", "full"], default="standard")
    parser.add_argument("--output", type=Path, help="Racine privée des builds, rapports et fichiers temporaires.")
    parser.add_argument("--only", nargs="+", help="Étapes ciblées de ce profil, dépendance Core incluse.")
    parser.add_argument("--list", action="store_true", help="Décrire les commandes sans les exécuter.")
    args = parser.parse_args()
    cache = Path.home() / "Library/Caches/AtollValidation"
    if args.output:
        output = args.output.expanduser().resolve()
    elif args.list:
        output = cache / "RUN"
    else:
        cache.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="run-", dir=cache))
    # SwiftPM native expose ce lien indépendamment de l'architecture du Mac.
    build = output / "core/debug"
    try:
        steps = plan(args.profile, output, build, args.only or ())
    except ValueError as error:
        parser.error(str(error))
    report = {"profile": args.profile, "scope": "selected" if args.only else "profile",
              "started_at": datetime.now(timezone.utc).isoformat(), "output": str(output),
              "excluded": EXCLUDED, "steps": [{"name": s.name, "command": s.command} for s in steps]}
    if args.list:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    if sys.platform != "darwin":
        parser.error("Cette validation demande macOS et les outils Xcode.")
    output.mkdir(parents=True, exist_ok=True)
    report["steps"] = execute(steps, output, environment(output))
    passed = all(step["status"] == "passed" for step in report["steps"])
    report["status"] = "passed" if passed else "failed"
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    (output / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(str(output / "results.json"))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
