from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE = Path(__file__).parents[1] / "m0_025_windows_resource_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("m0_025_windows_resource_diagnostics", MODULE)
assert SPEC is not None and SPEC.loader is not None
diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostics)


class M0025WindowsResourceDiagnosticsTests(unittest.TestCase):
    def test_mode_order_and_command_are_fixed(self) -> None:
        self.assertEqual(
            (
                "connect-close",
                "echo-close",
                "peer-reset",
                "close-during-read",
            ),
            diagnostics.DIAGNOSTIC_MODES,
        )
        command = diagnostics.diagnostic_command(Path("probe.exe"), "peer-reset", 1234, 60_000)
        self.assertEqual(
            ["probe.exe", "peer-reset", "1234", "60000", "256"],
            command,
        )

    def test_unknown_mode_and_invalid_budget_fail_closed(self) -> None:
        with self.assertRaises(diagnostics.DiagnosticError) as raised:
            diagnostics.diagnostic_command(Path("probe.exe"), "mixed-soak", 1234, 1)
        self.assertEqual("MODE", raised.exception.code)
        with self.assertRaises(diagnostics.DiagnosticError) as raised:
            diagnostics.diagnostic_command(Path("probe.exe"), "peer-reset", 1234, 0)
        self.assertEqual("ITERATIONS", raised.exception.code)
        with self.assertRaises(diagnostics.DiagnosticError) as raised:
            diagnostics.validate_budget(600, 1.0, 600.0, 1_000)
        self.assertEqual("ITERATIONS", raised.exception.code)
        diagnostics.validate_budget(600, 1.0, 600.0, 16_384)

    def test_environment_non_windows_is_blocked(self) -> None:
        with (
            mock.patch.object(diagnostics.m0011.platform, "system", return_value="Linux"),
            mock.patch.object(diagnostics.m0011.platform, "machine", return_value="x86_64"),
            mock.patch.object(diagnostics.m0011.os, "name", "posix"),
        ):
            report = diagnostics.environment_report("a" * 40)
        self.assertEqual("BLOCKED", report["status"])
        self.assertIn(
            "NON_NATIVE_WINDOWS",
            {item["code"] for item in report["blockers"]},
        )
        self.assertEqual("M0-025", report["task_id"])

    def test_environment_ready_keeps_non_claims(self) -> None:
        with (
            mock.patch.object(diagnostics.m0011.platform, "system", return_value="Windows"),
            mock.patch.object(diagnostics.m0011.platform, "machine", return_value="AMD64"),
            mock.patch.object(diagnostics.m0011.os, "name", "nt"),
            mock.patch.object(diagnostics.m0011.shutil, "which", return_value="tool.exe"),
            mock.patch.object(diagnostics.m0011, "command_version", return_value="version"),
        ):
            report = diagnostics.environment_report("a" * 40)
        self.assertEqual("READY", report["status"])
        self.assertIn(
            "the public std.net probe is not Wirestack production-path evidence",
            report["non_claims"],
        )

    def test_mode_workload_rejects_wrong_mode_and_gc_cadence(self) -> None:
        fields = {
            "mode": "peer-reset",
            "iterations": "10",
            "connected": "10",
            "completed": "10",
            "socketErrors": "10",
            "otherErrors": "0",
            "closeErrors": "0",
            "unknownMode": "false",
            "gcEvery": "1",
        }
        workload = diagnostics._mode_workload(fields, 10)
        self.assertEqual("FAIL", workload["decision"])
        fields["gcEvery"] = "256"
        workload = diagnostics._mode_workload(fields, 10)
        self.assertEqual("PASS", workload["decision"])

    def test_mode_workload_timeout_is_incomplete(self) -> None:
        with mock.patch.object(diagnostics, "_parse_fields", return_value=(None, None)):
            workload = diagnostics._mode_workload(None, 10)
        self.assertEqual("INCOMPLETE", workload["decision"])

    def test_atomic_report_has_no_temporary_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "diagnostic.json"
            target.write_text("old", encoding="utf-8")
            diagnostics.atomic_json(target, {"status": "FAIL"})
            self.assertEqual({"status": "FAIL"}, json.loads(target.read_text()))
            self.assertEqual([target], list(Path(directory).iterdir()))

    def test_run_diagnostics_does_not_run_on_non_windows(self) -> None:
        with (
            mock.patch.object(diagnostics, "environment_report", return_value={
                "status": "BLOCKED",
                "blockers": [{"code": "NON_NATIVE_WINDOWS"}],
            }),
        ):
            report = diagnostics.run_diagnostics(
                Path("."),
                Path("build/m0-025-test"),
                "a" * 40,
                60,
                5.0,
                120.0,
            )
        self.assertEqual("BLOCKED", report["status"])
        self.assertEqual("NON_NATIVE_WINDOWS", report["blockers"][0]["code"])
        self.assertEqual(
            diagnostics.DEFAULT_ITERATIONS_PER_MODE,
            report["diagnostic_budget"]["iterations_per_mode"],
        )

    def test_run_diagnostics_uses_explicit_iterations_per_mode(self) -> None:
        with (
            mock.patch.object(
                diagnostics,
                "environment_report",
                return_value={"status": "READY"},
            ),
            mock.patch.object(
                diagnostics.m0011,
                "compile_probe",
                return_value=(Path("probe.exe"), {}),
            ),
            mock.patch.object(
                diagnostics,
                "_mode_report",
                return_value={"status": "INCOMPLETE"},
            ) as mode_report,
        ):
            report = diagnostics.run_diagnostics(
                Path("."),
                Path("build/m0-025-budget-test"),
                "a" * 40,
                600,
                1.0,
                600.0,
                8_192,
            )
        self.assertEqual("INCOMPLETE", report["status"])
        self.assertEqual(4, mode_report.call_count)
        self.assertEqual(
            [8_192] * 4,
            [call.args[3] for call in mode_report.call_args_list],
        )
        self.assertEqual(8_192, report["requested_iterations_per_mode"])


if __name__ == "__main__":
    unittest.main()
