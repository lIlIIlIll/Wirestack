from __future__ import annotations

import copy
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools import development_baseline as baseline


class DevelopmentBaselineTests(unittest.TestCase):
    def test_direct_cli_bootstraps_outside_checkout(self) -> None:
        environment = dict(os.environ)
        environment.pop("PYTHONPATH", None)
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(baseline.ROOT / "tools/development_baseline.py"),
                                     "--help"], cwd=directory, env=environment,
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("capture", result.stdout)
        self.assertIn("verify", result.stdout)

    def report(self) -> dict:
        return {
            "schema_version": 1, "source_task": baseline.TASK, "profile": baseline.PROFILE,
            "status": "PASS", "release": dict(baseline.RELEASE),
            "commands": [{"id": name, "status": "PASS", "exit_code": 0, "timed_out": False}
                         for name in baseline.STEPS],
            "outcomes": {"installed_consumer": "PASS", "fuzz": "PASS", "fuzz_target_count": 10,
                         "resource_preflight": "PASS", "preflight_seconds": 600,
                         "formal_parameters_met": False},
        }

    def test_missing_gate_cannot_promote_development(self) -> None:
        report = self.report()
        report["commands"].pop(1)
        with self.assertRaisesRegex(ValueError, "missing or reordered"):
            baseline.validate_results(report)

    def test_timeout_and_nonzero_exit_cannot_be_hidden_by_pass(self) -> None:
        for field, value in (("exit_code", 1), ("timed_out", True), ("status", "SKIPPED")):
            with self.subTest(field=field):
                report = self.report()
                report["commands"][0][field] = value
                with self.assertRaisesRegex(ValueError, "failed or was not run"):
                    baseline.validate_results(report)

    def test_development_result_cannot_claim_release(self) -> None:
        for field in baseline.RELEASE:
            with self.subTest(field=field):
                report = self.report()
                report["release"][field] = "PASS"
                with self.assertRaisesRegex(ValueError, "cannot confer release"):
                    baseline.validate_results(report)

    def test_partial_campaign_or_shortened_preflight_is_not_accepted(self) -> None:
        for field, value in (("fuzz_target_count", 9), ("preflight_seconds", 60),
                             ("formal_parameters_met", True), ("installed_consumer", "NOT_RUN")):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report())
                report["outcomes"][field] = value
                with self.assertRaises(ValueError):
                    baseline.validate_results(report)

    def test_paths_are_normalized_before_retention(self) -> None:
        root = Path("/tmp/example-workspace")
        captured = baseline.redact(
            "/tmp/example-workspace/src/http.cj /var/tmp/consumer-123/main.cj "
            "/tmp/sdk/bin/cjc /home/example-user/cache", root)
        self.assertEqual("<repo>/src/http.cj <scratch> <scratch> <scratch>", captured)


if __name__ == "__main__":
    unittest.main()
