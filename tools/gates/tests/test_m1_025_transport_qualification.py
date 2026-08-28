import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "m1_025_transport_qualification.py"
SPEC = importlib.util.spec_from_file_location("m1_025_transport_qualification", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class M1025TransportQualificationTests(unittest.TestCase):
    def test_percentile_uses_nearest_rank(self):
        self.assertEqual(4, gate.percentile([1, 2, 3, 4], 95))

    def test_cancellation_parser_requires_both_complete_scenarios(self):
        lines = []
        for scenario in ("blocked-read", "blocked-write"):
            for index in range(3):
                lines.append(
                    f"M125_CANCEL scenario={scenario} index={index} "
                    f"measured={'true' if index >= 1 else 'false'} active=true "
                    "terminal=cancelled latencyNs=1000 completed=true progress=1"
                )
        result = gate.parse_cancellation("\n".join(lines), 1, 2)
        self.assertEqual(1000, result["blocked-read"]["p99_ns"])
        self.assertEqual(1000, result["blocked-write"]["p99_ns"])

    def test_cancellation_parser_fails_closed_above_limit(self):
        lines = []
        for scenario in ("blocked-read", "blocked-write"):
            for index in range(2):
                latency = gate.MAX_CANCELLATION_NS + 1 if scenario == "blocked-write" else 1
                lines.append(
                    f"M125_CANCEL scenario={scenario} index={index} measured=true "
                    f"active=true terminal=cancelled latencyNs={latency} "
                    "completed=true progress=1"
                )
        with self.assertRaises(gate.QualificationError):
            gate.parse_cancellation("\n".join(lines), 0, 2)

    def test_net05_validation_enforces_payloads_and_thresholds(self):
        report = {
            "configuration": {
                "warmup": 1,
                "repetitions": 11,
                "comparison_process_shape": "same_unittest_binary",
            },
            "cases": [
                {
                    "name": str(payload),
                    "payload_bytes": payload,
                    "decision": "PASS",
                    "comparison": {
                        "decision": "PASS",
                        "throughput_minimum": 0.95,
                        "throughput_ratio": 0.95,
                        "p95_latency_maximum": 1.1,
                        "p95_latency_ratio": 1.1,
                    },
                }
                for payload in gate.EXPECTED_PAYLOADS
            ],
        }
        self.assertEqual(5, len(gate.validate_net05(report)))
        report["cases"][0]["comparison"]["throughput_ratio"] = 0.949
        with self.assertRaises(gate.QualificationError):
            gate.validate_net05(report)


if __name__ == "__main__":
    unittest.main()
