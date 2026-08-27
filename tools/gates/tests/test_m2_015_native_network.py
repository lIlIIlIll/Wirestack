import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "m2_015_native_network.py"
SPEC = importlib.util.spec_from_file_location("m2_015_native_network", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class M2015NativeNetworkGateTest(unittest.TestCase):
    def test_parses_success_marker(self):
        process = {
            "stdout": (
                "M2015_RESULT scenario=ipv6-blackhole outcome=success "
                "winners=64 attempts=128 cancelledLosers=64 elapsedMs=2100\n"
            )
        }
        self.assertEqual(MODULE.parse_result(process, "ipv6-blackhole"), {
            "scenario": "ipv6-blackhole", "outcome": "success", "winners": 64,
            "attempts": 128, "cancelled_losers": 64, "terminal": None,
            "elapsed_ms": 2100,
        })

    def test_parses_deadline_marker(self):
        process = {
            "stdout": (
                "M2015_RESULT scenario=deadline-8 outcome=deadline terminal=TimedOut "
                "attempts=8 elapsedMs=352\n"
            )
        }
        result = MODULE.parse_result(process, "deadline-8")
        self.assertEqual(result["terminal"], "TimedOut")
        self.assertEqual(result["attempts"], 8)
        self.assertEqual(result["elapsed_ms"], 352)

    def test_rejects_missing_or_duplicate_result(self):
        with self.assertRaises(MODULE.GateError):
            MODULE.parse_result({"stdout": ""}, "ipv6-available")
        marker = (
            "M2015_RESULT scenario=ipv6-available outcome=success "
            "winners=1 attempts=1 cancelledLosers=0 elapsedMs=3\n"
        )
        with self.assertRaises(MODULE.GateError):
            MODULE.parse_result({"stdout": marker + marker}, "ipv6-available")

    def test_resource_trend_is_fail_closed_and_detects_growth(self):
        self.assertEqual(MODULE.resource_trend([])["decision"], "INCONCLUSIVE")
        stable = [
            {"process_count": 2, "socket_count": index % 2, "thread_count": 12,
             "fd_count": 20 + index % 2, "rss_kib": 50000 + index}
            for index in range(50)
        ]
        self.assertEqual(MODULE.resource_trend(stable)["decision"], "PASS")
        growing = [dict(item, socket_count=index) for index, item in enumerate(stable)]
        self.assertEqual(MODULE.resource_trend(growing)["decision"], "FAIL")


if __name__ == "__main__":
    unittest.main()
