from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.gates import net06_tls_failure_cleanup as gate


class Tests(unittest.TestCase):
    def test_parse_completed_cycles(self):
        self.assertEqual(100000, gate.parse_completed_cycles(
            "CAP repeated_cleanup=PASS\nMETRIC failure_cleanup_cycles=100000\n"))

    def test_parse_rejects_missing_or_duplicate_metric(self):
        with self.assertRaises(gate.CleanupError):
            gate.parse_completed_cycles("nothing")
        with self.assertRaises(gate.CleanupError):
            gate.parse_completed_cycles(
                "METRIC failure_cleanup_cycles=1\n"
                "METRIC failure_cleanup_cycles=1\n")


if __name__ == "__main__":
    unittest.main()
