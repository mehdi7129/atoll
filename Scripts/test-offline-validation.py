#!/usr/bin/env python3
"""Contre-épreuves du verdict offline ; seulement Python et fichiers jetables."""
import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("offline_validation", Path(__file__).with_name("validate-offline.py"))
validation = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = validation
spec.loader.exec_module(validation)


class OfflineValidationTests(unittest.TestCase):
    def run_main(self, steps):
        with tempfile.TemporaryDirectory(prefix="atoll-offline-verdict-") as temporary:
            output = Path(temporary)
            with patch.object(validation, "plan", return_value=steps), patch.object(sys, "platform", "darwin"), \
                    patch.object(sys, "argv", ["validate-offline", "--output", temporary]), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = validation.main()
            return code, json.loads((output / "results.json").read_text())

    def test_success_requires_every_step(self):
        steps = [validation.Step("fixture", [sys.executable, "-c", "print('private nominal')"])]
        code, report = self.run_main(steps)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["steps"][0]["returncode"], 0)

    def test_later_success_does_not_hide_failure(self):
        steps = [validation.Step("failure", [sys.executable, "-c", "raise SystemExit(17)"]),
                 validation.Step("success", [sys.executable, "-c", "pass"])]
        code, report = self.run_main(steps)
        self.assertEqual(code, 1, "offline-verdict-failure-must-fail")
        self.assertEqual(report["status"], "failed")
        self.assertEqual([s["status"] for s in report["steps"]], ["failed", "passed"])
        self.assertEqual(report["steps"][0]["returncode"], 17)

    def test_failed_core_blocks_runtime_without_spawning_it(self):
        steps = [validation.Step("core", [sys.executable, "-c", "raise SystemExit(2)"]),
                 validation.Step("dependent", ["/never-spawn-this-fixture"], needs_core=True),
                 validation.Step("mutant", ["/never-spawn-this-fixture"], baseline="core"),
                 validation.Step("docs", [sys.executable, "-c", "pass"])]
        code, report = self.run_main(steps)
        self.assertEqual(code, 1)
        self.assertEqual([s["status"] for s in report["steps"]], ["failed", "blocked", "blocked", "passed"])
        self.assertNotIn("log", report["steps"][1])

    def test_timeout_and_missing_binary_are_not_success(self):
        steps = [validation.Step("timeout", [sys.executable, "-c", "import time; time.sleep(20)"], timeout=0.1),
                 validation.Step("missing", ["/nonexistent-private-fixture"])]
        code, report = self.run_main(steps)
        self.assertEqual(code, 1)
        self.assertEqual([s["status"] for s in report["steps"]], ["timed_out", "failed"])

    def assert_timeout_stops_descendant(self, runner):
        with tempfile.TemporaryDirectory(prefix="atoll-offline-descendant-") as temporary:
            root = Path(temporary)
            identity = root / "child.json"
            # Le leader sort sur TERM ; son enfant l'ignore et garde le groupe.
            source = (
                "import json,os,pathlib,signal,time\n"
                "child=os.fork()\n"
                "if child==0:\n"
                " signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                f" pathlib.Path({str(identity)!r}).write_text(json.dumps([os.getpid(),os.getpgrp()]))\n"
                " time.sleep(60)\n"
                "else:\n"
                " time.sleep(60)\n"
            )
            original_popen = subprocess.Popen

            def ready_process(*arguments, **options):
                process = original_popen(*arguments, **options)
                # Le délai testé commence après la préparation, pas au lancement
                # de Python sur une machine éventuellement occupée par un build.
                deadline = time.monotonic() + 30
                while not identity.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not identity.exists():
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    self.fail("Fixture du descendant non prête : " + (root / "process.log").read_text())
                return process

            try:
                step = validation.Step("descendant", [sys.executable, "-c", source], timeout=0.1)
                with patch.object(validation.subprocess, "Popen", side_effect=ready_process):
                    result = runner(step, root / "process.log", dict(os.environ))
                self.assertEqual(result["status"], "timed_out")
                pid, _ = json.loads(identity.read_text())
                state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                                       capture_output=True, text=True, timeout=5)
                alive = state.returncode == 0 and not state.stdout.strip().startswith("Z")
                self.assertFalse(alive, "offline-timeout-descendant-survived")
            finally:
                if identity.exists():
                    pid, group = json.loads(identity.read_text())
                    try:
                        if os.getpgid(pid) == group:
                            os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_timeout_stops_descendant_after_leader_exits(self):
        self.assert_timeout_stops_descendant(validation.run_command)

    def test_timeout_descendant_sabotage_is_detected(self):
        source = inspect.getsource(validation.run_command)
        needle = "os.killpg(process.pid, signal.SIGKILL)"
        self.assertEqual(source.count(needle), 1)
        namespace = dict(validation.__dict__)
        exec(compile(source.replace(needle, "pass  # Sabotage du nettoyage du groupe."),
                     "<offline-timeout-mutant>", "exec"), namespace)
        with self.assertRaisesRegex(AssertionError, "offline-timeout-descendant-survived"):
            self.assert_timeout_stops_descendant(namespace["run_command"])

    def test_plans_are_offline_and_targeted_scope_is_explicit(self):
        root = Path("/private/fixture")
        full = validation.plan("full", root, root / "core/debug")
        for profile in ["core", "standard", "full"]:
            docs = next(step for step in validation.plan(profile, root, root / "core/debug") if step.name == "docs")
            self.assertEqual(docs.command[2:], ["--no-tests", "--preflight"],
                             "offline-docs-preflight-required")
        for step in full:
            self.assertNotIn("--live", step.command)
            self.assertNotIn("--network", step.command)
            self.assertNotIn(Path(step.command[0]).name, ["codex", "claude", "open"])
            if step.name in ["codex-exec", "skill-generation"]:
                self.assertIn("--prepare-only", step.command)
            self.assertNotIn(Path(step.command[1]).name, validation.EXCLUDED)
        selection = validation.plan("standard", root, root / "core/debug", ["runtime"])
        self.assertEqual([s.name for s in selection], ["core", "runtime"])
        mutation = validation.plan("full", root, root / "core/debug", ["runtime/launch-search"])
        self.assertEqual([s.name for s in mutation], ["core", "runtime", "runtime/launch-search"])
        self.assertEqual(mutation[-1].baseline, "runtime")
        with self.assertRaises(ValueError):
            validation.plan("standard", root, root / "core/debug", ["codex-live"])
        described = {Path(step.command[1]).name for step in full}
        described.update(validation.EXCLUDED)
        # Ces deux scripts sont exercés par le vrai helper du harness d'installation.
        described.update(["test-claude-uninstall.py", "test-codex-install-recall.py"])
        scripts = {p.name for p in Path(__file__).parent.glob("test-*.py")}
        self.assertFalse(scripts - described, "Harness non classé dans le plan offline")

    def test_environment_cannot_enable_opt_in_live_test(self):
        with tempfile.TemporaryDirectory(prefix="atoll-offline-env-") as temporary:
            with patch.dict(os.environ, {"ATOLL_CODEX_LIVE_TEST": "1", "OPENAI_API_KEY": "fixture"}):
                env = validation.environment(Path(temporary))
            self.assertNotIn("ATOLL_CODEX_LIVE_TEST", env)
            self.assertNotIn("OPENAI_API_KEY", env)
            self.assertTrue(Path(env["TMPDIR"]).is_dir())


if __name__ == "__main__":
    unittest.main()
