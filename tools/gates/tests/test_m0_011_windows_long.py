from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE = Path(__file__).parents[1] / "m0_011_windows_long.py"
SPEC = importlib.util.spec_from_file_location("m0_011_windows_long", MODULE)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def valid_report() -> dict:
    sample_count = 1081
    samples = [
        {
            "elapsed_ms": index * 10_000,
            "rss_kib": 20_000,
            "private_kib": 21_000,
            "handle_count": 100,
            "thread_count": 8,
            "socket_count": 0,
        }
        for index in range(sample_count)
    ]
    return {
        "schema_version": 1,
        "task_id": "M0-011",
        "report_kind": "windows-gate-net06-4h",
        "platform": "windows-x86_64",
        "status": "PASS",
        "global_gate_status": "INCOMPLETE",
        "classification": "WINDOWS_SUPPLEMENTAL_4H",
        "repository_revision": "a" * 40,
        "requested_duration_seconds": 14_400,
        "sample_interval_seconds": 10.0,
        "minimum_samples": 1080,
        "environment": {
            "runner": {"system": "Windows", "machine": "AMD64"}
        },
        "workload": {
            "mode": "mixed-soak",
            "requested_seconds": 14_400,
            "actual_duration_ns": 14_400 * 1_000_000_000,
            "iterations": 1000,
            "connected": 1000,
            "completed": 1000,
            "server_accepted": 1000,
            "socket_errors": 400,
            "other_errors": 0,
            "close_errors": 0,
            "unknown_mode": "false",
            "gc_every_iterations": gate.WINDOWS_GC_INTERVAL_ITERATIONS,
            "decision": "PASS",
        },
        "resources": {
            "coverage": {
                "rss_kib": "MEASURED_BY_WIN32",
                "private_kib": "MEASURED_BY_WIN32",
                "handle_count": "MEASURED_BY_WIN32",
                "thread_count": "MEASURED_BY_POWERSHELL",
                "socket_count": "MEASURED_BY_NETSTAT",
            },
            "aggregate": gate.resource_aggregate(samples),
            "trend": gate.resource_trend(samples),
            "samples": samples,
            "sampler_errors": {},
        },
        "non_claims": [
            "not full GATE-NET-06 completion",
            "does not replace the required 24-hour Linux release-candidate soak",
        ],
    }


class M0011WindowsLongValidatorTests(unittest.TestCase):
    def assert_code(self, report: dict, code: str) -> None:
        with self.assertRaises(gate.GateError) as raised:
            gate.validate_result(report)
        self.assertEqual(code, raised.exception.code)

    def test_accepts_four_hour_supplemental_report(self) -> None:
        self.assertEqual("PASS", gate.validate_result(valid_report())["status"])

    def test_rejects_unknown_schema_and_stale_revision(self) -> None:
        report = valid_report()
        report["schema_version"] = 2
        self.assert_code(report, "UNKNOWN_SCHEMA")
        with self.assertRaises(gate.GateError) as raised:
            gate.validate_result(valid_report(), "b" * 40)
        self.assertEqual("STALE_REVISION", raised.exception.code)

    def test_rejects_global_claim_short_duration_and_non_native(self) -> None:
        report = valid_report()
        report["global_gate_status"] = "PASS"
        self.assert_code(report, "SCOPE")
        report = valid_report()
        report["requested_duration_seconds"] = 3600
        self.assert_code(report, "DURATION")
        report = valid_report()
        report["environment"]["runner"]["system"] = "Linux"
        self.assert_code(report, "NON_NATIVE_WINDOWS")
        report = valid_report()
        report["platform"] = "linux-x86_64"
        self.assert_code(report, "PLATFORM")

    def test_rejects_unmeasured_resources_and_trend_failure(self) -> None:
        report = valid_report()
        report["resources"]["coverage"]["socket_count"] = "UNAVAILABLE"
        self.assert_code(report, "RESOURCES")
        report = valid_report()
        report["resources"]["trend"] = {"decision": "FAIL"}
        self.assert_code(report, "RESOURCE_TREND")
        report = valid_report()
        report["resources"]["aggregate"]["rss_kib"]["last"] += 1
        self.assert_code(report, "RESOURCE_AGGREGATE")
        report = valid_report()
        report["minimum_samples"] = 20
        self.assert_code(report, "SAMPLES")

    def test_rejects_skipped_status_and_incomplete_workload(self) -> None:
        report = valid_report()
        report["resources"]["sampler_errors"] = {"SKIPPED": 1}
        self.assert_code(report, "RESOURCE_QUERY")
        report = valid_report()
        report["workload"]["decision"] = "SKIPPED"
        self.assert_code(report, "WORKLOAD_STATUS")
        report = valid_report()
        report["diagnostics"] = {"status": ["PASS"]}
        self.assertEqual("PASS", gate.validate_result(report)["status"])

    def test_requires_windows_probe_gc_cadence(self) -> None:
        report = valid_report()
        report["workload"].pop("gc_every_iterations")
        self.assert_code(report, "PROBE_CLEANUP")
        report = valid_report()
        report["workload"]["gc_every_iterations"] = 1
        self.assert_code(report, "PROBE_CLEANUP")
        report = valid_report()
        report["workload"]["gc_every_iterations"] = -1
        self.assert_code(report, "PROBE_CLEANUP")

    def test_windows_probe_variant_isolated_from_linux_source(self) -> None:
        source = gate.windows_probe_source()
        self.assertNotIn("gcEvery", gate.STRESS_SOURCE)
        self.assertEqual(1, source.count("gc(heavy: true)"))
        self.assertEqual(2, source.count("gcEvery=${gcEvery}"))

    def test_atomic_report_has_no_temporary_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "report.json"
            target.write_text("old", encoding="utf-8")
            gate.atomic_json(target, {"status": "PASS"})
            self.assertIn('"PASS"', target.read_text(encoding="utf-8"))
            self.assertEqual([target], list(Path(directory).iterdir()))

    def test_missing_report_uses_stable_io_failure_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "validation.json"
            with contextlib.redirect_stderr(io.StringIO()):
                result = gate.main([
                    "--validate-report",
                    str(Path(directory) / "missing.json"),
                    "--output",
                    str(output),
                ])
            self.assertEqual(1, result)
            self.assertEqual("REPORT_IO", json.loads(output.read_text())["failures"][0])

    def test_environment_report_is_truthful(self) -> None:
        with (
            mock.patch.object(gate.platform, "system", return_value="Windows"),
            mock.patch.object(gate.platform, "machine", return_value="AMD64"),
            mock.patch.object(gate.os, "name", "nt"),
            mock.patch.object(gate.shutil, "which", return_value="C:/tool.exe"),
            mock.patch.object(gate, "command_version", return_value="version"),
        ):
            report = gate.environment_report("a" * 40)
        self.assertEqual("READY", report["status"])
        self.assertEqual("Windows", report["runner"]["system"])

    def test_environment_report_blocks_non_native_host(self) -> None:
        with (
            mock.patch.object(gate.platform, "system", return_value="Linux"),
            mock.patch.object(gate.platform, "machine", return_value="x86_64"),
            mock.patch.object(gate.os, "name", "posix"),
        ):
            report = gate.environment_report("a" * 40)
        self.assertEqual("BLOCKED", report["status"])
        self.assertIn("NON_NATIVE_WINDOWS", {item["code"] for item in report["blockers"]})

    def test_thread_and_socket_parsers_are_bounded(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="7")
        with (
            mock.patch.object(gate.shutil, "which", return_value="pwsh"),
            mock.patch.object(gate.subprocess, "run", return_value=completed),
        ):
            self.assertEqual(7, gate.WindowsProcessSampler._thread_count(42))
        netstat = SimpleNamespace(
            returncode=0,
            stdout=(
                "  TCP    127.0.0.1:1    127.0.0.1:2    ESTABLISHED    42\n"
                "  TCP    127.0.0.1:3    127.0.0.1:4    TIME_WAIT      7\n"
            ),
        )
        with mock.patch.object(gate.subprocess, "run", return_value=netstat):
            self.assertEqual(1, gate.WindowsProcessSampler._socket_count(42))


if __name__ == "__main__":
    unittest.main()
