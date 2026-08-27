from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "http1_benchmark.py"
SPEC = importlib.util.spec_from_file_location("http1_benchmark", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def sample(rps: float = 1000.0, rss16: int = 100_000,
           rss64: int = 108_000) -> dict[str, dict[str, float | int]]:
    return {
        "keep_alive_small": {"requests_per_second": rps, "peak_rss_kib": 90_000},
        "stream_16mib": {"requests_per_second": 1.0, "peak_rss_kib": rss16},
        "stream_64mib": {"requests_per_second": 1.0, "peak_rss_kib": rss64},
    }


class Http1BenchmarkTest(unittest.TestCase):
    def test_missing_baseline_is_partial_not_pass(self) -> None:
        result = MODULE.classify(sample(), None)
        self.assertEqual(result["decision"], "PARTIAL")
        self.assertEqual(result["stdx_comparison"]["decision"], "NOT_RUN")
        self.assertEqual(result["streaming_memory"]["decision"], "PASS")

    def test_baseline_threshold_is_ninety_percent(self) -> None:
        self.assertEqual(MODULE.classify(sample(900.0), 1000.0)["decision"], "PASS")
        self.assertEqual(MODULE.classify(sample(899.9), 1000.0)["decision"], "FAIL")

    def test_linear_memory_growth_fails(self) -> None:
        result = MODULE.classify(sample(rss16=50_000, rss64=200_000), 1000.0)
        self.assertEqual(result["decision"], "FAIL")
        self.assertEqual(result["streaming_memory"]["decision"], "FAIL")

    def test_descendant_totals_include_recursive_children(self) -> None:
        snapshot = {10: (1, 100, 2), 11: (10, 200, 3), 12: (11, 300, 4), 99: (1, 999, 9)}
        self.assertEqual(MODULE.descendant_totals(10, snapshot), (600, 9))

    def test_round_summary_uses_median_duration(self) -> None:
        rounds = [
            {"iterations": 2000, "checksum": 400000, "duration_ns": duration,
             "peak_rss_kib": rss, "peak_fd_count": 7}
            for duration, rss in ((300, 10), (100, 30), (200, 20))
        ]
        result = MODULE.summarize_rounds(rounds)
        self.assertEqual(result["duration_ns"], 200)
        self.assertEqual(result["requests_per_second"], 10_000_000_000.0)
        self.assertEqual(result["peak_rss_kib"], 30)

    def test_round_summary_rejects_inconsistent_checksums(self) -> None:
        rounds = [
            {"iterations": 2000, "checksum": 1, "duration_ns": 100,
             "peak_rss_kib": 10, "peak_fd_count": 7},
            {"iterations": 2000, "checksum": 2, "duration_ns": 200,
             "peak_rss_kib": 10, "peak_fd_count": 7},
        ]
        with self.assertRaises(MODULE.BenchmarkError):
            MODULE.summarize_rounds(rounds)

    def test_benchmark_snapshot_enables_o2_without_touching_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "cjpm.toml"
            manifest.write_text(
                '[package]\ncompile-option = ""\noverride-compile-option = ""\n',
                encoding="utf-8",
            )
            MODULE.enable_o2_manifest(manifest)
            self.assertIn('compile-option = "-O2"', manifest.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
