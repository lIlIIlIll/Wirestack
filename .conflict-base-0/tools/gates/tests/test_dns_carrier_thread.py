from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "dns_carrier_thread.py"
SPEC = importlib.util.spec_from_file_location("dns_carrier_thread", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DnsCarrierThreadTests(unittest.TestCase):
    def test_percentile_uses_nearest_rank(self) -> None:
        self.assertEqual(4.0, MODULE.percentile([1.0, 2.0, 3.0, 4.0], 95))
        self.assertIsNone(MODULE.percentile([], 95))

    def test_probe_parser_retains_host_timestamps_and_gaps(self) -> None:
        events = [
            {"stream": "stdout", "host_monotonic_ns": 100, "line": "HEARTBEAT index=0 elapsedNs=1000000"},
            {"stream": "stdout", "host_monotonic_ns": 200, "line": "RELEASE tasks=1 elapsedNs=1500000"},
            {"stream": "stdout", "host_monotonic_ns": 300, "line": "HEARTBEAT index=1 elapsedNs=11000000"},
            {"stream": "stdout", "host_monotonic_ns": 400, "line": "RESOLVE index=0 startNs=2000000 endNs=12000000 code=1"},
            {"stream": "stdout", "host_monotonic_ns": 500, "line": "SUMMARY tasks=1 completed=1 heartbeats=2"},
        ]
        parsed = MODULE.parse_probe_events(events)
        self.assertEqual([10.0], parsed["heartbeat_gaps_ms"])
        self.assertEqual(300, parsed["heartbeats"][1]["host_monotonic_ns"])
        self.assertEqual(1, parsed["summary"]["completed"])

    def test_shim_parser_requires_paired_calls(self) -> None:
        text = "\n".join([
            "GAI phase=enter seq=0 pid=1 tid=2 ns=100 result=0 node=localhost",
            "GAI phase=exit seq=0 pid=1 tid=2 ns=200000100 result=0 node=localhost",
        ])
        parsed = MODULE.parse_shim_log(text)
        self.assertEqual(1, parsed["call_count"])
        self.assertEqual(1, parsed["unique_thread_count"])
        self.assertEqual(200.0, parsed["call_duration_ms"]["p50"])

    def test_shim_parser_rejects_missing_exit(self) -> None:
        with self.assertRaisesRegex(MODULE.GateError, "incomplete shim call"):
            MODULE.parse_shim_log(
                "GAI phase=enter seq=0 pid=1 tid=2 ns=100 result=0 node=localhost\n"
            )

    def test_validate_sample_rejects_unintercepted_resolution(self) -> None:
        sample = {
            "process": {"timed_out": False, "exit_code": 0, "output_overflow": False},
            "probe": {
                "release": {"tasks": 1},
                "summary": {"tasks": 1, "completed": 1},
                "resolves": [{"index": 0, "start_ns": 1, "end_ns": 2}],
                "heartbeats": [{"elapsed_ns": 1}, {"elapsed_ns": 2}],
            },
            "shim": {"call_count": 0},
        }
        with self.assertRaisesRegex(MODULE.GateError, "intercepted"):
            MODULE.validate_sample(sample, 1)

    def test_classification_detects_sustained_starvation(self) -> None:
        aggregates = [
            {"delay_ms": 0, "task_count": 32,
             "metrics": {"heartbeat_gap_ms": {"p95": 10.0, "max": 12.0}}},
            {"delay_ms": 200, "task_count": 32,
             "metrics": {"heartbeat_gap_ms": {"p95": 200.0, "max": 205.0}}},
        ]
        decision = MODULE.classify_aggregates(aggregates, 200)
        self.assertEqual("FAIL", decision["gate_decision"])
        self.assertEqual("UP-007", decision["conditional_upstream_candidate"])
        self.assertTrue(aggregates[1]["comparison"]["starvation_observed"])

    def test_classification_does_not_fail_on_normal_jitter(self) -> None:
        aggregates = [
            {"delay_ms": 0, "task_count": 32,
             "metrics": {"heartbeat_gap_ms": {"p95": 10.0, "max": 12.0}}},
            {"delay_ms": 200, "task_count": 32,
             "metrics": {"heartbeat_gap_ms": {"p95": 18.0, "max": 25.0}}},
        ]
        decision = MODULE.classify_aggregates(aggregates, 200)
        self.assertEqual("PASS", decision["gate_decision"])
        self.assertIsNone(decision["conditional_upstream_candidate"])

    def test_parse_int_list_rejects_duplicates(self) -> None:
        with self.assertRaises(Exception):
            MODULE.parse_int_list("1,2,2")


if __name__ == "__main__":
    unittest.main()
