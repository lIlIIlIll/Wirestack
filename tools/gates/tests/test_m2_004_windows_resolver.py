from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.gates import m2_004_windows_resolver as gate


def valid_process() -> dict[str, object]:
    return {
        "timed_out": False,
        "exit_code": 0,
        "output": "[ PASSED ] CASE:\n" * gate.EXPECTED_TESTS + "FAILED: 0\nERROR: 0\n",
    }


def valid_report() -> dict[str, object]:
    return {
        "schema_version": 1,
        "task_id": "M2-004",
        "revision": "abc",
        "platform": {"system": "Windows"},
        "decision": "PASS",
        "failures": [],
        "resolver_test": valid_process(),
        "resolver_manifest": {
            "platform": "windows-x86_64",
            "private_runtime_abi": False,
            "test_fixture": True,
        },
    }


class M2004WindowsResolverGateTests(unittest.TestCase):
    def test_valid_report_passes(self) -> None:
        self.assertEqual([], gate.validate_report(valid_report(), "abc"))

    def test_rejects_unknown_schema_stale_revision_and_wrong_platform(self) -> None:
        report = valid_report()
        report["schema_version"] = 9
        report["revision"] = "old"
        report["platform"] = {"system": "Linux"}
        failures = gate.validate_report(report, "abc")
        self.assertIn("REPORT:UNKNOWN_SCHEMA", failures)
        self.assertIn("REPORT:STALE_REVISION", failures)
        self.assertIn("REPORT:NON_NATIVE_WINDOWS", failures)

    def test_rejects_skipped_case_even_with_zero_exit(self) -> None:
        report = valid_report()
        report["resolver_test"] = {
            "timed_out": False,
            "exit_code": 0,
            "output": "[ PASSED ] CASE:\n" * 6 + "[ SKIPPED ] CASE:\nFAILED: 0\nERROR: 0\n",
        }
        self.assertIn(
            "RESOLVER_TEST:NON_PASS_CASE",
            gate.validate_report(report, "abc"),
        )

    def test_rejects_timeout_and_missing_fixture_binding(self) -> None:
        report = valid_report()
        process = valid_process()
        process["timed_out"] = True
        report["resolver_test"] = process
        manifest = dict(report["resolver_manifest"])
        manifest["test_fixture"] = False
        report["resolver_manifest"] = manifest
        failures = gate.validate_report(report, "abc")
        self.assertIn("RESOLVER_TEST:TIMEOUT", failures)
        self.assertIn("REPORT:FIXTURE_NOT_BOUND", failures)

    def test_atomic_json_replaces_complete_document_without_temp_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            gate.atomic_json(output, {"status": "PASS"})
            self.assertEqual('{\n  "status": "PASS"\n}\n', output.read_text())
            self.assertEqual([output], list(Path(directory).iterdir()))


if __name__ == "__main__":
    unittest.main()
