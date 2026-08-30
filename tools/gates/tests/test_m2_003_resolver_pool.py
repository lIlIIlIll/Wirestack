from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "m2_003_resolver_pool.py"
SPEC = importlib.util.spec_from_file_location("m2_003_resolver_pool", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class M2003ResolverPoolGateTests(unittest.TestCase):
    def test_parser_requires_complete_native_calls(self) -> None:
        with self.assertRaisesRegex(gate.GateError, "incomplete shim call"):
            gate.parse_shim_log(
                "GAI phase=enter seq=0 pid=1 tid=2 ns=100 result=0 node=localhost\n"
            )

    def test_parser_counts_threads_concurrency_and_delay(self) -> None:
        parsed = gate.parse_shim_log("\n".join([
            "GAI phase=enter seq=0 pid=1 tid=2 ns=0 result=0 node=localhost",
            "GAI phase=enter seq=1 pid=1 tid=3 ns=10 result=0 node=localhost",
            "GAI phase=exit seq=0 pid=1 tid=2 ns=200000000 result=0 node=localhost",
            "GAI phase=exit seq=1 pid=1 tid=3 ns=200000010 result=0 node=localhost",
        ]))
        self.assertEqual(2, parsed["call_count"])
        self.assertEqual(2, parsed["unique_thread_count"])
        self.assertEqual(2, parsed["maximum_concurrent"])
        self.assertEqual(200.0, parsed["duration_ms"]["minimum"])

    def test_validation_rejects_missing_focused_cases(self) -> None:
        failures = gate.validate(
            {
                "timed_out": False,
                "exit_code": 0,
                "output": "[ PASSED ] CASE:\n" * (gate.EXPECTED_TESTS - 1),
            },
            {
                "call_count": gate.EXPECTED_CALLS,
                "maximum_concurrent": 2,
                "duration_ms": {"minimum": 200.0},
            },
            {
                "timed_out": False,
                "exit_code": 0,
                "output": "GLOBAL_POOL_BOUND PASS live_pool_limit=8\n",
            },
        )
        self.assertTrue(any(
            f"{gate.EXPECTED_TESTS} passed" in failure for failure in failures
        ))


if __name__ == "__main__":
    unittest.main()
