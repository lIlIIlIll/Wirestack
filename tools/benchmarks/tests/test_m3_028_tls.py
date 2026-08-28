import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "m3_028_tls.py"
SPEC = importlib.util.spec_from_file_location("m3_028_tls", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class M3028TlsGateTest(unittest.TestCase):
    def test_parses_exact_wirestack_marker(self):
        value = gate.parse_marker(
            "M3028_WIRESTACK scenario=bulk_tls13 iterations=1 "
            "durationNs=20 bytes=1048576 resumed=false\n",
            gate.WIRE_RE, "bulk_tls13",
        )
        self.assertEqual(20, value["duration_ns"])
        self.assertEqual(1048576, value["bytes"])
        self.assertFalse(value["resumed"])

    def test_rejects_duplicate_or_wrong_marker(self):
        line = (
            "M3028_WIRESTACK scenario=full_tls13 iterations=2 "
            "durationNs=20 bytes=0 resumed=false\n"
        )
        with self.assertRaises(gate.GateError):
            gate.parse_marker(line + line, gate.WIRE_RE, "full_tls13")
        with self.assertRaises(gate.GateError):
            gate.parse_marker(line, gate.WIRE_RE, "bulk_tls13")

    def test_nearest_rank_is_not_interpolated(self):
        values = list(range(1, 12))
        self.assertEqual(6, gate.nearest_rank(values, 50))
        self.assertEqual(11, gate.nearest_rank(values, 95))

    def test_o2_snapshot_rewrite_is_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "cjpm.toml"
            manifest.write_text(
                '[package]\ncompile-option = ""\nname = "probe"\n', encoding="utf-8"
            )
            gate.enable_o2(manifest)
            self.assertIn('compile-option = "-O2"', manifest.read_text(encoding="utf-8"))

    def test_classification_enforces_every_threshold(self):
        def samples(duration):
            return [
                {"duration_ns": duration, "iterations": 1, "bytes": 100,
                 "resumed": False}
                for _ in range(11)
            ]

        cases = {
            "bulk_tls13": {"wirestack": samples(100), "stdx": samples(100)},
            "full_tls13": {"wirestack": samples(100), "stdx": samples(100)},
        }
        resumed = [{"resumed": True} for _ in range(11)]
        passed = {"decision": "PASS"}
        result = gate.classify(cases, resumed, passed, passed, passed, passed)
        self.assertEqual("PASS", result["decision"])
        cases["bulk_tls13"]["wirestack"] = samples(200)
        result = gate.classify(cases, resumed, passed, passed, passed, passed)
        self.assertEqual("FAIL", result["decision"])


if __name__ == "__main__":
    unittest.main()
