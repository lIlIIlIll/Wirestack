from __future__ import annotations

import sys
import json
import tempfile
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
        fields["connected"] = "2"
        self.assertEqual("PASS", gate.classify(
            scenario, fields, self.process(), server, self.sampler())["decision"])

    def test_resource_aggregate(self):
        aggregate = gate.resource_aggregate(self.sampler().samples)
        self.assertEqual(110, aggregate["rss_kib"]["max"])
        self.assertEqual(5, aggregate["fd_count"]["max"])

    def test_resource_trend_excludes_warmup_and_accepts_bounded_plateau(self):
        samples = [
            {"elapsed_ms": index * 10,
             "rss_kib": 100 + min(index, 4) * 100,
             "fd_count": 4 + (1 if index % 2 else 0)}
            for index in range(100)
        ]
        trend = gate.resource_trend(samples)
        self.assertEqual("PASS", trend["decision"])
        self.assertEqual(20, trend["warmup_samples_excluded"])

    def test_resource_trend_rejects_sustained_rss_or_fd_growth(self):
        rss = [
            {"elapsed_ms": index * 10, "rss_kib": index * 1024,
             "fd_count": 4}
            for index in range(100)
        ]
        fds = [
            {"elapsed_ms": index * 10, "rss_kib": 100,
             "fd_count": index}
            for index in range(100)
        ]
        self.assertEqual("FAIL", gate.resource_trend(rss)["decision"])
        self.assertEqual("FAIL", gate.resource_trend(fds)["decision"])

    def test_resource_trend_is_inconclusive_without_enough_samples(self):
        self.assertEqual("INCONCLUSIVE", gate.resource_trend(
            self.sampler().samples)["decision"])

    def test_scenario_parser(self):
        parsed = gate.parse_scenarios("connect-close:10,echo-close:5")
        self.assertEqual(("connect-close", "echo-close"),
                         tuple(item.mode for item in parsed))
        with self.assertRaises(Exception):
            gate.parse_scenarios("connect-close:0")

    def test_full_linux_profile_uses_required_counts(self):
        self.assertEqual(
            (("connect-close", 100000), ("peer-reset", 100000),
             ("close-during-read", 100000)),
            tuple((item.mode, item.iterations) for item in gate.FULL_LINUX_SCENARIOS),
        )

    def test_transport_cleanup_pass_consumes_serialized_scenario_records(self):
        records = [
            {"mode": mode, "decision": "PASS", "iterations": 100000}
            for mode in ("connect-close", "peer-reset", "close-during-read")
        ]
        self.assertTrue(gate.transport_cleanup_pass(records))
        records[0]["iterations"] = 99999
        self.assertFalse(gate.transport_cleanup_pass(records))

    def test_tls_cleanup_report_is_fail_closed(self):
        report = {
            "schema_version": 1, "task_id": "M0-011",
            "scenario": "tls-handshake-failure-cleanup",
            "requested_cycles": 100000, "completed_cycles": 100000,
            "decision": "PASS",
            "resources": {"trend": {"decision": "PASS"}},
            "build": {"system_tls_dependencies": [],
                      "runtime_loader_library_strings": []},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tls.json"
            path.write_text(json.dumps(report))
            self.assertEqual("PASS", gate.load_tls_cleanup_report(path)["decision"])
            report["completed_cycles"] = 99999
            path.write_text(json.dumps(report))
            with self.assertRaises(gate.GateError):
                gate.load_tls_cleanup_report(path)


if __name__ == "__main__":
    unittest.main()
