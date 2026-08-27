from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "m2_005_system_resolver.py"
SPEC = importlib.util.spec_from_file_location("m2_005_system_resolver", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class M2005SystemResolverGateTests(unittest.TestCase):
    def test_parser_requires_complete_calls(self) -> None:
        with self.assertRaisesRegex(gate.GateError, "incomplete fixture process/sequence"):
            gate.parse_fixture_log(
                "M2005_GAI phase=enter seq=0 pid=1 tid=2 ns=3 family=0 "
                "result=0 host=localhost\n"
            )

    def test_parser_retains_host_result_and_duration(self) -> None:
        parsed = gate.parse_fixture_log("\n".join([
            "M2005_GAI phase=enter seq=0 pid=1 tid=2 ns=100 family=0 result=0 host=localhost",
            "M2005_GAI phase=exit seq=0 pid=1 tid=2 ns=1100 family=0 result=0 host=localhost",
        ]))
        self.assertEqual(1, parsed["call_count"])
        self.assertEqual({"localhost": 1}, parsed["host_counts"])
        self.assertEqual(0.001, parsed["calls"][0]["duration_ms"])

    def test_parser_allows_sequence_restart_in_another_process(self) -> None:
        parsed = gate.parse_fixture_log("\n".join([
            "M2005_GAI phase=enter seq=0 pid=1 tid=2 ns=100 family=0 result=0 host=localhost",
            "M2005_GAI phase=exit seq=0 pid=1 tid=2 ns=200 family=0 result=0 host=localhost",
            "M2005_GAI phase=enter seq=0 pid=3 tid=4 ns=300 family=0 result=0 host=localhost",
            "M2005_GAI phase=exit seq=0 pid=3 tid=4 ns=400 family=0 result=0 host=localhost",
        ]))
        self.assertEqual(2, parsed["call_count"])
        self.assertEqual({"localhost": 2}, parsed["host_counts"])

    def test_process_validation_rejects_skipped_gate_cases(self) -> None:
        failures = gate.validate_process(
            {
                "timed_out": False,
                "exit_code": 0,
                "output": "[ PASSED ] CASE:\n" * 5 + "FAILED: 0\nERROR: 0\n",
            },
            6,
            "resolver",
        )
        self.assertTrue(any("6 passed" in failure for failure in failures))

    def test_fixture_validation_rejects_missing_hosts(self) -> None:
        failures = gate.validate_fixture({
            "host_counts": {"localhost": 1},
            "calls": [{"host": "localhost", "result": 0}],
        })
        self.assertTrue(any("host counts differ" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
