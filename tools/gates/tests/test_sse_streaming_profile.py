import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import sse_streaming_profile as gate


class Tests(unittest.TestCase):
    def test_parse_output_requires_one_protocol_result(self):
        text = """
SSE_SAMPLE protocol=h2 elapsedMs=1000 events=10 produced=12 leadEvents=2 usedHeapBytes=100
SSE_RESULT protocol=h2 requestedSeconds=3 elapsedMs=3000 minimumEvents=10 events=20 sequenceErrors=0
"""
        samples, result = gate.parse_output(text, "h2")
        self.assertEqual(samples[0]["usedHeapBytes"], 100)
        self.assertEqual(result["events"], "20")
        with self.assertRaises(gate.GateError):
            gate.parse_output(text + text, "h2")

    def test_heap_trend_excludes_warmup_and_fails_growth(self):
        stable = [{"usedHeapBytes": value} for value in (1, 100, 100, 101, 99, 100, 101, 100, 99, 100)]
        self.assertEqual(gate.heap_trend(stable)["decision"], "PASS")
        growing = [{"usedHeapBytes": index * 16 * 1024 * 1024} for index in range(10)]
        self.assertEqual(gate.heap_trend(growing)["decision"], "FAIL")

    def test_resource_trend_checks_every_resource_class(self):
        stable = [{"rss_kib": 1000, "fd_count": 8, "socket_count": 2,
                   "thread_count": 4} for _ in range(20)]
        self.assertEqual(gate.resource_trend(stable)["decision"], "PASS")
        growing = [dict(item) for item in stable]
        for item in growing[-4:]:
            item["socket_count"] = 5
        self.assertEqual(gate.resource_trend(growing)["decision"], "FAIL")

    def test_short_runs_cannot_be_formal(self):
        self.assertEqual(gate.FORMAL_SECONDS, 3600)
        self.assertEqual(gate.FORMAL_EVENTS, 1_000_000)


if __name__ == "__main__":
    unittest.main()
