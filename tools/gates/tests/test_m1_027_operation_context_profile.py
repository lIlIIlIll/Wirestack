from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import m1_027_operation_context_profile as profile


class Tests(unittest.TestCase):
    def test_parse_profile_requires_one_expected_stage(self):
        parsed = profile.parse_profile(
            "M127_PROFILE stage=operation-gate iterations=100 "
            "durationNs=3100 checksum=100\n",
            "operation-gate",
        )
        self.assertEqual(parsed["iterations"], 100)
        self.assertEqual(parsed["nanoseconds_per_call"], 31.0)
        with self.assertRaises(profile.GateError):
            profile.parse_profile("", "operation-gate")
        with self.assertRaises(profile.GateError):
            profile.parse_profile(
                "M127_PROFILE stage=control-loop iterations=1 durationNs=1 checksum=0\n",
                "operation-gate",
            )

    def test_aggregate_timing_keeps_repetitions_and_range(self):
        result = profile.aggregate_timing([
            {"nanoseconds_per_call": 3.0},
            {"nanoseconds_per_call": 1.0},
            {"nanoseconds_per_call": 2.0},
        ])
        self.assertEqual(result["repetitions"], 3)
        self.assertEqual(result["nanoseconds_per_call"], {
            "p50": 2.0, "min": 1.0, "max": 3.0,
        })

    def test_perf_output_parser_accepts_user_counters(self):
        parsed = {
            name: int(value)
            for value, name in profile.PERF_RE.findall(
                "385736;;cycles:u;555963;100.00;;\n"
                "179133;;instructions:u;555963;100.00;;\n"
            )
        }
        self.assertEqual(parsed["cycles:u"], 385736)
        self.assertEqual(parsed["instructions:u"], 179133)


if __name__ == "__main__":
    unittest.main()
