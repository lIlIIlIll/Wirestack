from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import http1_quality as gate


class Tests(unittest.TestCase):
    def output(self, passed=3, skipped=2, errors=0, failed=0, cases=()):
        total = passed + skipped + errors + failed
        lines = [f"[ PASSED ] CASE: {case}" for case in cases]
        lines.append(
            f"Summary: TOTAL: {total}\n    PASSED: {passed}, SKIPPED: {skipped}, ERROR: {errors}\n"
            f"    FAILED: {failed}\n"
        )
        return "\n".join(lines)

    def process(self, output, exit_code=0, timed_out=False):
        return {"stdout": output, "stderr": "", "exit_code": exit_code, "timed_out": timed_out}

    def test_parse_summary_uses_last_project_total(self):
        output = self.output(1, 0) + self.output(3, 2)
        self.assertEqual({"total": 5, "passed": 3, "skipped": 2, "errors": 0, "failed": 0},
                         gate.parse_summary(output))

    def test_classification_requires_count_cases_and_clean_exit(self):
        decision, summary, reasons = gate.classify(
            self.process(self.output(3, 2, cases=("required",))), 3, ["required"]
        )
        self.assertEqual("PASS", decision)
        self.assertEqual(3, summary["passed"])
        self.assertEqual([], reasons)
        decision, _, reasons = gate.classify(self.process(self.output(2, 0)), 3, ["required"])
        self.assertEqual("FAIL", decision)
        self.assertGreaterEqual(len(reasons), 2)

    def test_rejects_inconsistent_or_missing_summary(self):
        with self.assertRaises(gate.GateError):
            gate.parse_summary("no summary")
        with self.assertRaises(gate.GateError):
            gate.parse_summary("Summary: TOTAL: 2\n PASSED: 1, SKIPPED: 0, ERROR: 0\n FAILED: 0")

    def test_source_fingerprint_is_stable_and_content_sensitive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/http").mkdir(parents=True)
            (root / "src/internal/http1").mkdir(parents=True)
            file = root / "src/http/a.cj"
            file.write_text("one", encoding="utf-8")
            first = gate.source_fingerprint(root)
            self.assertEqual(first, gate.source_fingerprint(root))
            file.write_text("two", encoding="utf-8")
            self.assertNotEqual(first, gate.source_fingerprint(root))


if __name__ == "__main__":
    unittest.main()
