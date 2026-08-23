from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

GATES_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GATES_DIR))
MODULE_PATH = GATES_DIR / "net03_absolute_deadline.py"
SPEC = importlib.util.spec_from_file_location("net03_absolute_deadline", MODULE_PATH)
assert SPEC and SPEC.loader
net03 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(net03)


class Net03AbsoluteDeadlineTests(unittest.TestCase):
    def process(self) -> dict[str, object]:
        return {
            "command": ["probe"],
            "exit_code": 0,
            "timed_out": False,
            "duration_ms": 51.0,
            "stdout": "",
            "stderr": "",
        }

    def base_values(self, scenario: str = "idle-read") -> dict[str, str]:
        return {
            "scenario": scenario,
            "budgetMs": "50",
            "budgetStartNs": "1000000",
            "opStartNs": "1100000",
            "terminalBeforeClose": "false",
            "closeStartNs": "51100000",
            "closeDoneNs": "51200000",
            "terminalNs": "51400000",
            "terminalCode": "4" if scenario == "idle-read" else "3",
            "closeCode": "0",
        }

    def test_parse_result_requires_one_marker(self) -> None:
        values = net03.parse_result(
            "noise\nRESULT scenario=idle-read budgetMs=50 budgetStartNs=1 "
            "opStartNs=2 terminalBeforeClose=false closeStartNs=3 closeDoneNs=4 "
            "terminalNs=5 terminalCode=4 closeCode=0\n"
        )
        self.assertEqual("idle-read", values["scenario"])
        with self.assertRaises(net03.GateError):
            net03.parse_result("RESULT scenario=x\nRESULT scenario=y\n")

    def test_classify_accepts_absolute_budget_with_small_overshoot(self) -> None:
        result = net03.classify(self.base_values(), self.process())
        self.assertEqual("PASS", result["decision"])
        self.assertAlmostEqual(0.4, result["overshoot_ms"])
        self.assertAlmostEqual(0.1, result["operation_start_delay_ms"])

    def test_classify_rejects_early_terminal(self) -> None:
        values = self.base_values()
        values["terminalBeforeClose"] = "true"
        values["terminalNs"] = "20000000"
        result = net03.classify(values, self.process())
        self.assertEqual("NOT_BLOCKED", result["decision"])

    def test_classify_rejects_excessive_overshoot(self) -> None:
        values = self.base_values()
        values["terminalNs"] = "80000000"
        result = net03.classify(values, self.process())
        self.assertEqual("FAIL", result["decision"])
        self.assertGreater(result["overshoot_ms"], result["tolerance_ms"])

    def test_partial_write_requires_stable_progress_window(self) -> None:
        values = self.base_values("partial-write")
        values.update(
            {
                "terminalCode": "2",
                "checkpointFired": "true",
                "checkpointNs": "21000000",
                "countA": "2",
                "countB": "2",
            }
        )
        self.assertEqual("PASS", net03.classify(values, self.process())["decision"])
        values["countB"] = "3"
        self.assertEqual("NOT_BLOCKED", net03.classify(values, self.process())["decision"])

    def test_parse_budgets(self) -> None:
        self.assertEqual((50, 200, 1000), net03.parse_budgets("50,200,1000"))
        with self.assertRaises(Exception):
            net03.parse_budgets("50,0")


if __name__ == "__main__":
    unittest.main()
