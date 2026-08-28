from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "m2_016_dns_to_connected.py"
SPEC = importlib.util.spec_from_file_location("m2_016_dns_to_connected", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def line(profile: str = "ipv6-available", round_index: int = 0, index: int = 0,
         terminal: str = "success", winner: int = 30, connections: int = 1,
         cancellation: int = -1) -> str:
    return (
        f"M2016_SAMPLE profile={profile} round={round_index} index={index} "
        f"terminal={terminal} source=system dnsNs=10 firstAttemptNs=20 "
        f"winnerNs={winner} totalNs=40 connectionCount={connections} "
        f"cancellationNs={cancellation}\n"
    )


class M2016BenchmarkTest(unittest.TestCase):
    def test_parse_success_sample(self) -> None:
        result = MODULE.parse_samples(line(), "ipv6-available", 0, 1)
        self.assertEqual(result[0]["dns_ns"], 10)

    def test_parse_cancellation_sample(self) -> None:
        output = line("cancellation", terminal="cancelled", winner=-1, cancellation=12)
        result = MODULE.parse_samples(output, "cancellation", 0, 1)
        self.assertEqual(result[0]["cancellation_ns"], 12)

    def test_duplicate_indexes_fail_closed(self) -> None:
        with self.assertRaises(MODULE.BenchmarkError):
            MODULE.parse_samples(line() + line(), "ipv6-available", 0, 2)

    def test_blackhole_requires_two_connections(self) -> None:
        with self.assertRaises(MODULE.BenchmarkError):
            MODULE.parse_samples(line("ipv6-blackhole"), "ipv6-blackhole", 0, 1)

    def test_loss_allows_delayed_second_attempt(self) -> None:
        result = MODULE.parse_samples(
            line("loss-1pct", connections=2), "loss-1pct", 0, 1
        )
        self.assertEqual(result[0]["connection_count"], 2)

    def test_nearest_rank(self) -> None:
        values = list(range(1, 101))
        self.assertEqual(MODULE.nearest_rank(values, 50), 50)
        self.assertEqual(MODULE.nearest_rank(values, 95), 95)
        self.assertEqual(MODULE.nearest_rank(values, 99), 99)

    def test_o2_snapshot_does_not_touch_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "cjpm.toml"
            manifest.write_text('[package]\ncompile-option = ""\n', encoding="utf-8")
            MODULE.enable_o2_manifest(manifest)
            self.assertIn('compile-option = "-O2"', manifest.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
