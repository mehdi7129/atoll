#!/usr/bin/env python3
"""Contre-épreuves du verdict offline ; seulement Python et fichiers jetables."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
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

    def test_plans_are_offline_and_targeted_scope_is_explicit(self):
        root = Path("/private/fixture")
        full = validation.plan("full", root, root / "core/debug")
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
