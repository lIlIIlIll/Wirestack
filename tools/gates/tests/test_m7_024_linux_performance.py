from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "tools/gates/m7_024_linux_performance.py"
SPEC = importlib.util.spec_from_file_location("m7_024_linux_performance", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)
MANIFEST_PATH = ROOT / "tools/gates/manifests/m7-024-linux-performance.json"


class M7024LinuxPerformanceGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = gate.load_manifest(ROOT, MANIFEST_PATH)
        cls.documents, cls.artifacts = gate.load_artifacts(ROOT, cls.manifest)

    def test_checked_in_baselines_pass_all_eight_domains(self):
        report = gate.evaluate(ROOT, self.manifest)
        self.assertEqual("PASS", report["decision"])
        self.assertEqual(list(gate.EXPECTED_DOMAINS), [item["name"] for item in report["domains"]])
        self.assertEqual([], report["failed_domains"])
        self.assertEqual(7, len(report["artifacts"]))
        for domain in report["domains"]:
            self.assertEqual("PASS", domain["decision"], domain)
            self.assertTrue(domain["checks"])

    def test_manifest_inventory_and_digest_fail_closed(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["domains"] = manifest["domains"][:-1]
        with self.assertRaises(gate.GateError):
            gate.validate_manifest(manifest)

        manifest = copy.deepcopy(self.manifest)
        manifest["artifacts"]["raw_tcp"]["sha256"] = "0" * 64
        with self.assertRaises(gate.GateError):
            gate.load_artifacts(ROOT, manifest)

    def test_path_escape_and_non_finite_json_fail_closed(self):
        with self.assertRaises(gate.GateError):
            gate.checked_path(ROOT, "../outside.json")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"metric": NaN}\n', encoding="utf-8")
            with self.assertRaises(gate.GateError):
                gate.load_json(path)

    def test_threshold_comparisons_accept_equality_and_reject_misses(self):
        self.assertTrue(gate.compare(0.95, "ge", 0.95))
        self.assertFalse(gate.compare(0.949999, "ge", 0.95))
        self.assertTrue(gate.compare(1.10, "le", 1.10))
        self.assertFalse(gate.compare(1.100001, "le", 1.10))
        self.assertTrue(gate.compare("PASS", "eq", "PASS"))
        with self.assertRaises(gate.GateError):
            gate.compare(float("inf"), "le", 1.0)

    def test_missing_workload_and_under_sampled_raw_tcp_fail(self):
        document = copy.deepcopy(self.documents["raw_tcp"])
        document["cases"].pop()
        report = gate.validate_raw_tcp(
            document, self.manifest["thresholds"]["raw_tcp"]
        ).report()
        self.assertEqual("FAIL", report["decision"])
        self.assertTrue(any(
            item["name"] == "payload inventory" and item["decision"] == "FAIL"
            for item in report["checks"]
        ))

        document = copy.deepcopy(self.documents["raw_tcp"])
        document["cases"][0]["sample_count_per_implementation"] = 10
        report = gate.validate_raw_tcp(
            document, self.manifest["thresholds"]["raw_tcp"]
        ).report()
        self.assertEqual("FAIL", report["decision"])

    def test_toolchain_environment_mismatch_fails_domain(self):
        document = copy.deepcopy(self.documents["http2"])
        document["toolchain"]["cjc"] = "Cangjie Compiler: unexpected"
        report = gate.validate_http2(
            document,
            self.manifest["thresholds"]["http2"],
            self.manifest["environment"],
        ).report()
        self.assertEqual("FAIL", report["decision"])
        self.assertTrue(any(
            item["name"] == "HTTP/2 Cangjie version" and item["decision"] == "FAIL"
            for item in report["checks"]
        ))

    def test_domain_schema_error_and_atomic_failure_report_are_explicit(self):
        outcome = gate.run_validator(
            "tls",
            lambda: gate.validate_tls({}, self.manifest["thresholds"]["tls"]),
        )
        self.assertEqual("FAIL", outcome["decision"])
        self.assertEqual("schema-and-values", outcome["checks"][0]["name"])

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            report = gate.failure_report(MANIFEST_PATH, "synthetic failure")
            gate.write_report(output, report)
            parsed = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual("FAIL", parsed["decision"])
            self.assertEqual(list(gate.EXPECTED_DOMAINS), parsed["failed_domains"])
            self.assertFalse(output.with_name(output.name + ".tmp").exists())


if __name__ == "__main__":
    unittest.main()
