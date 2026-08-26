from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import net06_production_cleanup as gate


class Tests(unittest.TestCase):
    def test_parses_exact_markers_and_heap_plateau(self):
        output = (
            "NET06_HEAP scenario=cancellation index=0 usedHeapBytes=100\n"
            "NET06_HEAP scenario=cancellation index=100000 usedHeapBytes=200\n"
            "NET06_CANCELLATION requested=100000 completed=100000 joinedTasks=200000 "
            "activeReads=0 backgroundTasks=0\n"
        )
        self.assertEqual((100000, 100000, 200000, 0, 0),
                         gate.one_match(gate.CANCEL_RE, output, "cancellation"))
        self.assertEqual("PASS", gate.heap_trend(output, "cancellation")["decision"])

    def test_rejects_duplicate_marker(self):
        marker = ("NET06_TLS_TRANSPORT requested=1 completed=1 engineClosed=1 "
                  "transportAborted=1 terminalDisposals=1 backgroundTasks=0\n")
        with self.assertRaises(gate.GateError):
            gate.one_match(gate.TLS_RE, marker + marker, "TLS")

    def test_reused_evidence_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "soak.json"
            path.write_text(json.dumps({"task_id": "M0-011", "gate_id": "GATE-NET-06",
                                        "linux_profile_status": "PASS", "soak": {
                                            "requested_seconds": 86399, "decision": "PASS",
                                            "resources": {"trend": {"decision": "PASS"}}}}))
            with self.assertRaises(gate.GateError):
                gate.validate_soak(path)

    def test_process_tree_snapshot_has_resource_classes(self):
        sample = gate.process_tree_snapshot(__import__("os").getpid(), 7)
        self.assertGreaterEqual(sample["process_count"], 1)
        for key in ("rss_kib", "fd_count", "socket_count", "timerfd_count", "thread_count"):
            self.assertIn(key, sample)

    def test_resource_summary_checks_lifecycle_plateau(self):
        samples = [{"elapsed_ms": index, "rss_kib": 100, "fd_count": 5,
                    "process_count": 2, "socket_count": 1,
                    "timerfd_count": 0, "thread_count": 4}
                   for index in range(25)]
        summary = gate.resource_summary(samples)
        self.assertEqual("PASS", summary["trend"]["decision"])
        self.assertEqual("PASS", summary["lifecycle_trend"]["decision"])


if __name__ == "__main__":
    unittest.main()
