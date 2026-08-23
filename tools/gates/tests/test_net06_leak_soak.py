from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import net06_leak_soak as gate


class Tests(unittest.TestCase):
    def process(self):
        return {"command": ["probe"], "exit_code": 0, "timed_out": False,
                "duration_ms": 1.0, "stdout": "", "stderr": ""}

    def fields(self, mode="connect-close", iterations=3):
        return {
            "mode": mode, "iterations": str(iterations),
            "connected": str(iterations), "completed": str(iterations),
            "socketErrors": "0", "otherErrors": "0", "eof": "0",
            "bytesWritten": "0", "bytesRead": "0", "closeErrors": "0",
            "durationNs": "1000", "unknownMode": "false",
        }

    def sampler(self):
        return type("Sampler", (), {"samples": [
            {"elapsed_ms": 0, "rss_kib": 100, "fd_count": 4},
            {"elapsed_ms": 10, "rss_kib": 110, "fd_count": 5},
        ]})()

    def server(self, accepted=3):
        return type("Server", (), {
            "accepted": accepted, "bytes_received": 0,
            "bytes_echoed": 0, "reset_count": 0,
        })()

    def test_parse_result(self):
        fields = gate.parse_result(
            "RESULT mode=connect-close iterations=1 connected=1 completed=1 "
            "socketErrors=0 otherErrors=0 eof=0 bytesWritten=0 bytesRead=0 "
            "closeErrors=0 durationNs=1 unknownMode=false\n"
        )
        self.assertEqual("connect-close", fields["mode"])

    def test_parse_rejects_missing_result(self):
        with self.assertRaises(gate.GateError):
            gate.parse_result("nothing")

    def test_connect_close_classification(self):
        scenario = gate.Scenario("connect-close", 3)
        result = gate.classify(scenario, self.fields(), self.process(),
                               self.server(), self.sampler())
        self.assertEqual("PASS", result["decision"])

    def test_echo_requires_exact_totals(self):
        scenario = gate.Scenario("echo-close", 3)
        fields = self.fields("echo-close")
        fields["bytesWritten"] = "192"; fields["bytesRead"] = "192"
        server = self.server(); server.bytes_received = 192; server.bytes_echoed = 192
        result = gate.classify(scenario, fields, self.process(), server, self.sampler())
        self.assertEqual("PASS", result["decision"])
        fields["bytesRead"] = "128"
        self.assertEqual("FAIL", gate.classify(
            scenario, fields, self.process(), server, self.sampler())["decision"])

    def test_reset_requires_one_socket_exception_per_iteration(self):
        scenario = gate.Scenario("peer-reset", 3)
        fields = self.fields("peer-reset"); fields["socketErrors"] = "3"
        server = self.server(); server.reset_count = 3
        self.assertEqual("PASS", gate.classify(
            scenario, fields, self.process(), server, self.sampler())["decision"])

    def test_resource_aggregate(self):
        aggregate = gate.resource_aggregate(self.sampler().samples)
        self.assertEqual(110, aggregate["rss_kib"]["max"])
        self.assertEqual(5, aggregate["fd_count"]["max"])

    def test_scenario_parser(self):
        parsed = gate.parse_scenarios("connect-close:10,echo-close:5")
        self.assertEqual(("connect-close", "echo-close"),
                         tuple(item.mode for item in parsed))
        with self.assertRaises(Exception):
            gate.parse_scenarios("connect-close:0")


if __name__ == "__main__":
    unittest.main()
