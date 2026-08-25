from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "http2_benchmark.py"
SPEC = importlib.util.spec_from_file_location("http2_benchmark", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def benchmark_case(concurrency: int, connections: int = 1,
                   max_writes: int = 20, max_bytes: int = 4096,
                   pending_permits: int = 0) -> dict[str, int | float]:
    return {
        "concurrency": concurrency, "connections": connections,
        "maximum_pending_writes": max_writes,
        "maximum_pending_write_bytes": max_bytes,
        "maximum_observed_pending_flow_permits": pending_permits,
        "requests_per_second": 1000.0, "p99_latency_ns": 1000,
    }


class Http2BenchmarkTest(unittest.TestCase):
    def test_nearest_rank_percentiles(self) -> None:
        values = list(range(1, 101))
        self.assertEqual(MODULE.nearest_rank(values, 0.50), 50)
        self.assertEqual(MODULE.nearest_rank(values, 0.95), 95)
        self.assertEqual(MODULE.nearest_rank(values, 0.99), 99)

    def test_aggregate_combines_reversed_passes(self) -> None:
        base = {
            "concurrency": 10, "measured_requests": 2, "duration_ns": 1_000_000,
            "connections": 1, "maximum_pending_writes": 2,
            "maximum_pending_write_bytes": 100, "pending_writes": 1,
            "pending_flow_permits": 0, "flow_control_stalls": 0,
            "peak_rss_kib": 1000, "peak_fd_count": 5, "latencies_ns": [10, 20],
        }
        other = dict(base, duration_ns=2_000_000, latencies_ns=[30, 40], peak_rss_kib=1200)
        result = MODULE.aggregate([base, other])
        self.assertEqual(result["measured_requests"], 4)
        self.assertEqual(result["p50_latency_ns"], 20)
        self.assertEqual(result["peak_rss_kib"], 1200)

    def test_classification_requires_bounds_and_connection_reduction(self) -> None:
        cases = {"streams_1": benchmark_case(1), "streams_10": benchmark_case(10),
                 "streams_100": benchmark_case(100)}
        passed = MODULE.classify(cases, {"connections": 100})
        self.assertEqual(passed["decision"], "PASS")
        self.assertEqual(passed["connection_reduction"]["reduction_percent"], 99.0)
        cases["streams_100"] = benchmark_case(100, connections=30)
        self.assertEqual(MODULE.classify(cases, {"connections": 100})["decision"], "FAIL")

    def test_descendant_totals_include_recursive_children(self) -> None:
        snapshot = {10: (1, 100, 2), 11: (10, 200, 3), 12: (11, 300, 4), 99: (1, 999, 9)}
        self.assertEqual(MODULE.descendant_totals(10, snapshot), (600, 9))


if __name__ == "__main__":
    unittest.main()
