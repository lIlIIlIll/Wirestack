from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import m0_005_raw_tcp_baseline as baseline


def passing_sample(case: baseline.shared.Case) -> dict:
    return {
        "decision": "PASS",
        "payload_bytes": case.payload_bytes,
        "throughput_mib_per_second": 1.0 if case.payload_bytes else 0.0,
        "transfer_ms": 1.0,
        "peak_rss_kib": 100,
        "peak_thread_count": 2,
        "read_sizes": [] if case.payload_bytes == 0 else [case.payload_bytes],
        "read_calls": 0 if case.payload_bytes == 0 else 1,
        "fixed_4k_cap": False,
    }


def passing_instrumented_sample(case: baseline.shared.Case) -> dict:
    sample = passing_sample(case)
    sample["instrumentation"] = {
        "decision": "PASS",
        "native_allocation_events_per_process_operation": 10,
        "successful_recvfrom_calls": sample["read_calls"],
        "copied_bytes_per_process_operation": case.payload_bytes,
    }
    return sample


class Tests(unittest.TestCase):
    def test_required_payload_matrix_is_exact(self):
        self.assertEqual(
            [0, 1024, 16 * 1024, 64 * 1024, 1024 * 1024, 100 * 1024 * 1024],
            [case.payload_bytes for case in baseline.BASELINE_CASES],
        )

    def test_report_measures_counters_but_stays_blocked_without_lan(self):
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(baseline.shutil, "which", return_value="/sdk/bin/cjc"), \
             mock.patch.object(baseline.shared, "compile_probe",
                               return_value=(Path(directory) / "probe", {"process": {}})), \
             mock.patch.object(baseline.shared, "run_sample",
                               side_effect=lambda _binary, case, *_args: passing_sample(case)), \
             mock.patch.object(baseline, "run_instrumented_sample",
                               side_effect=lambda _binary, case, *_args, **_kwargs:
                               passing_instrumented_sample(case)):
            report = baseline.execute(
                Path(directory), 0, 1, 1.0, "revision", cases=baseline.BASELINE_CASES
            )
        self.assertEqual("PASS", report["loopback_status"])
        self.assertEqual("NOT_RUN", report["lan_status"])
        self.assertEqual("BLOCKED", report["task_status"])
        self.assertEqual(
            "MEASURED_BY_HEAPTRACK",
            report["metric_availability"]["allocation_count"],
        )
        self.assertEqual(
            ["native LAN peer measurements"], report["missing_requirements"]
        )
        self.assertEqual(6, len(report["cases"]))

    def test_complete_report_requires_passing_loopback_and_lan(self):
        results = []
        for case in baseline.BASELINE_CASES:
            sample = passing_sample(case)
            sample["instrumentation"] = {"decision": "PASS"}
            results.append({
                "name": case.name,
                "decision": "PASS",
                "instrumented_sample": sample,
            })
        peer = {
            "host": "192.0.2.2",
            "port": 19005,
            "image_id": "test-image",
            "image_sha256": "a" * 64,
            "hypervisor": "test-kvm",
            "peer_binary_sha256": "b" * 64,
        }
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(baseline.shutil, "which", return_value="/tool"), \
             mock.patch.object(baseline.shared, "compile_probe",
                               return_value=(Path(directory) / "probe", {"process": {}})), \
             mock.patch.object(baseline.shared, "command_text",
                               return_value="192.0.2.2 dev test0 src 192.0.2.1"), \
             mock.patch.object(baseline, "read_lan_peer_metadata", return_value={
                 "sysname": "Linux", "kernel_release": "test",
                 "machine": "x86_64", "payload_count": 6,
             }), \
             mock.patch.object(baseline, "run_topology",
                               side_effect=[results, results]):
            report = baseline.execute(
                Path(directory), 0, 1, 1.0, "revision",
                cases=baseline.BASELINE_CASES, lan_peer=peer,
            )
        self.assertEqual("COMPLETE", report["task_status"])
        self.assertEqual("PASS", report["lan_status"])
        self.assertEqual([], report["missing_requirements"])
        self.assertNotIn("not a complete M0-005 baseline", report["non_claims"])

    def test_lan_report_rejects_loopback_route(self):
        peer = {
            "host": "127.0.0.2", "port": 19005, "image_id": "test-image",
            "image_sha256": "a" * 64, "hypervisor": "test-kvm",
            "peer_binary_sha256": "b" * 64,
        }
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(baseline.shutil, "which", return_value="/tool"), \
             mock.patch.object(baseline.shared, "compile_probe",
                               return_value=(Path(directory) / "probe", {"process": {}})), \
             mock.patch.object(baseline.shared, "command_text",
                               return_value="local 127.0.0.2 dev lo src 127.0.0.1"), \
             mock.patch.object(baseline, "run_topology", return_value=[]):
            with self.assertRaises(baseline.shared.GateError):
                baseline.execute(
                    Path(directory), 0, 1, 1.0, "revision", lan_peer=peer
                )

    def test_parse_heaptrack_allocation_count(self):
        stderr = "heaptrack stats:\n\tallocations:\t9,160\n\tleaked allocations:\t4\n"
        self.assertEqual(9160, baseline.parse_heaptrack_allocations(stderr))

    def test_parse_heaptrack_rejects_missing_or_duplicate_count(self):
        with self.assertRaises(baseline.shared.GateError):
            baseline.parse_heaptrack_allocations("no stats")
        with self.assertRaises(baseline.shared.GateError):
            baseline.parse_heaptrack_allocations(
                "allocations: 1\nallocations: 2\n"
            )

    def test_parse_strace_recvfrom_counts_successful_copied_bytes(self):
        trace = (
            '10 recvfrom(7, "x", 4, 0, NULL, NULL) = 4\n'
            '10 recvfrom(7, "", 4, 0, NULL, NULL) = -1 EAGAIN\n'
            '10 <... recvfrom resumed>"x", 4, 0, NULL, NULL) = 2\n'
        )
        self.assertEqual((3, 2, 6), baseline.parse_strace_recvfrom(trace))

    def test_invalid_repetition_bounds_fail_before_compilation(self):
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(baseline.shutil, "which", return_value="/sdk/bin/cjc"):
            with self.assertRaises(baseline.shared.GateError):
                baseline.execute(Path(directory), -1, 1, 1.0, "revision")
            with self.assertRaises(baseline.shared.GateError):
                baseline.execute(Path(directory), 0, 0, 1.0, "revision")


if __name__ == "__main__":
    unittest.main()
