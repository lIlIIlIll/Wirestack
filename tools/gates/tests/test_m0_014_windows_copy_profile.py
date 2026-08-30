from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE = Path(__file__).parents[1] / "m0_014_windows_copy_profile.py"
SPEC = importlib.util.spec_from_file_location("m0_014_windows_copy_profile", MODULE)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def valid_report() -> dict:
    payloads = (1024, 16384, 65536, 1048576, 104857600)
    cases = []
    for payload in payloads:
        size = min(payload, 4096)
        reads = [size] * (payload // size)
        if sum(reads) < payload:
            reads.append(payload - sum(reads))
        cases.append({
            "payload_bytes": payload,
            "decision": "PASS",
            "bytes_read": payload,
            "read_sizes": reads,
            "fixed_4k_cap": payload > 4096,
            "allocation_count": 100,
            "peak_private_bytes": 1000,
            "copied_bytes_per_operation": payload,
            "copied_bytes_status": "MEASURED_BY_LINK_WRAP",
            "latency_ms": {"p50": 1.0, "p95": 2.0, "p99": 3.0},
            "throughput_mib_per_second": {"p50": 1.0, "p95": 2.0, "p99": 3.0},
        })
    return {
        "schema_version": 1,
        "task_id": "M0-014",
        "report_kind": "windows-copy-profile",
        "platform": "windows-x86_64",
        "native_execution": True,
        "repository_revision": "a" * 40,
        "metric_availability": {
            "application_visible_read_sizes": "MEASURED",
            "allocation_count": "MEASURED_BY_ETW_HEAP",
            "peak_private_bytes": "MEASURED_BY_WIN32",
            "copied_bytes_per_operation": "MEASURED_BY_LINK_WRAP",
        },
        "cases": cases,
        "cleanup": {"decision": "PASS"},
        "status": "PASS",
    }


class M0014ValidatorTests(unittest.TestCase):
    def test_environment_report_always_returns_structured_status(self) -> None:
        with (
            mock.patch.object(gate.platform, "system", return_value="Windows"),
            mock.patch.object(gate.platform, "machine", return_value="AMD64"),
            mock.patch.object(gate.os, "name", "nt"),
            mock.patch.object(gate.shutil, "which", return_value="C:/tool.exe"),
            mock.patch.object(gate, "command_version", return_value="version"),
        ):
            report = gate.environment_report("a" * 40)
        self.assertEqual("READY", report["status"])
        self.assertEqual("windows-x86_64".split("-")[0].capitalize(), report["runner"]["system"])

    def assert_code(self, report: dict, code: str) -> None:
        with self.assertRaises(gate.GateError) as raised:
            gate.validate_result(report)
        self.assertEqual(code, raised.exception.code)

    def test_accepts_complete_native_windows_report(self) -> None:
        self.assertEqual("PASS", gate.validate_result(valid_report())["status"])

    def test_rejects_unknown_schema_and_stale_revision(self) -> None:
        report = valid_report()
        report["schema_version"] = 2
        self.assert_code(report, "UNKNOWN_SCHEMA")
        with self.assertRaises(gate.GateError) as raised:
            gate.validate_result(valid_report(), "b" * 40)
        self.assertEqual("STALE_REVISION", raised.exception.code)

    def test_rejects_cross_compile_and_incomplete_payloads(self) -> None:
        report = valid_report()
        report["native_execution"] = False
        self.assert_code(report, "NON_NATIVE_WINDOWS")
        report = valid_report()
        report["cases"].pop()
        self.assert_code(report, "CASES")

    def test_rejects_skipped_or_derived_metrics_as_pass(self) -> None:
        for key, value, code in (
            ("allocation_count", "SKIPPED", "ALLOCATIONS"),
            ("copied_bytes_per_operation", "SOURCE_BOUND_DERIVATION", "COPY_BYTES"),
            ("peak_private_bytes", "UNAVAILABLE", "PRIVATE_BYTES"),
        ):
            report = valid_report()
            report["metric_availability"][key] = value
            self.assert_code(report, code)

    def test_rejects_missing_four_k_cap_and_cleanup_failure(self) -> None:
        report = valid_report()
        for case in report["cases"]:
            case["fixed_4k_cap"] = False
        self.assert_code(report, "FOUR_K_CAP")
        report = valid_report()
        report["cleanup"]["decision"] = "FAIL"
        self.assert_code(report, "CLEANUP")

    def test_atomic_report_replaces_target_without_temp_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "report.json"
            target.write_text("old", encoding="utf-8")
            gate.atomic_json(target, {"status": "READY"})
            self.assertIn('"READY"', target.read_text(encoding="utf-8"))
            self.assertEqual([target], list(Path(directory).iterdir()))

    def test_xperf_parser_is_bounded_and_fail_closed(self) -> None:
        self.assertEqual(
            11246,
            gate.parse_xperf_allocation_count(
                "   11246, 1128.8, 5238, 657.7, 3, 1108.0, 1108.0, TOTAL"
            ),
        )
        self.assertIsNone(gate.parse_xperf_allocation_count("unrecognized output"))
        self.assertIsNone(gate.parse_xperf_allocation_count(
            "1, 1.0, 1, 1.0, 0, 1.0, 1.0, TOTAL\n"
            "2, 2.0, 2, 2.0, 0, 2.0, 2.0, TOTAL"
        ))

    def test_instrumentation_retries_empty_etw_heap_reports_with_a_bound(self) -> None:
        empty = {
            "allocation_count": None,
            "allocation_status": "ETW_UNPARSED",
            "etl_sha256": "a",
            "heap_report_sha256": "b",
        }
        measured = {
            "allocation_count": 10232,
            "allocation_status": "MEASURED_BY_ETW_HEAP",
            "etl_sha256": "c",
            "heap_report_sha256": "d",
        }
        with mock.patch.object(
            gate, "_instrumented_transfer_attempt", side_effect=[empty, empty, measured]
        ) as attempt:
            result = gate.instrumented_transfer(
                Path("receiver.exe"), 1024, Path("artifacts"), 180.0
            )
        self.assertEqual(3, attempt.call_count)
        self.assertEqual(10232, result["allocation_count"])
        self.assertEqual(3, result["attempt_count"])
        self.assertEqual("ETW_UNPARSED", result["attempts"][0]["allocation_status"])

    def test_counting_receiver_adds_dynamic_counter_fields_once(self) -> None:
        source = gate.counting_receiver_source()
        self.assertEqual(1, source.count("let copiedBytes = unsafe { WIRESTACK_M0014_CopyBytes() }"))
        self.assertEqual(1, source.count("copiedBytes=${copiedBytes}"))


if __name__ == "__main__":
    unittest.main()
