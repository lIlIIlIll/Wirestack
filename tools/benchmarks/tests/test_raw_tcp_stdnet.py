from __future__ import annotations

import json
import socket
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPOSITORY_ROOT / "tools" / "benchmarks"))

import raw_tcp_stdnet as baseline  # noqa: E402


class RawTcpBaselineTests(unittest.TestCase):
    def test_default_cases_cover_required_payload_totals(self) -> None:
        cases = [baseline.BenchmarkCase(*item) for item in baseline.DEFAULT_CASES]
        self.assertEqual(
            [0, 1024, 16 * 1024, 64 * 1024, 1024 * 1024, 100 * 1024 * 1024],
            [case.payload_bytes for case in cases],
        )
        self.assertLessEqual(max(case.chunk_size for case in cases), 64 * 1024)

    def test_render_source_expands_values(self) -> None:
        template = "port={{PORT}} size={{CHUNK_SIZE}} iterations={{ITERATIONS}} " + baseline.MARKER
        rendered = baseline.render_source(template, port=1234, chunk_size=64, iterations=2)
        self.assertEqual("port=1234 size=64 iterations=2 " + baseline.MARKER, rendered)

    def test_render_source_requires_marker(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline.render_source(
                "{{PORT}} {{CHUNK_SIZE}} {{ITERATIONS}}",
                port=1,
                chunk_size=1,
                iterations=1,
            )

    def test_percentile_uses_nearest_rank(self) -> None:
        values = [1.0, 2.0, 3.0, 4.0, 5.0]
        self.assertEqual(3.0, baseline.percentile(values, 50))
        self.assertEqual(5.0, baseline.percentile(values, 95))
        self.assertEqual(5.0, baseline.percentile(values, 99))
        self.assertIsNone(baseline.percentile([], 50))

    def test_echo_server_verifies_and_echoes_exact_bytes(self) -> None:
        port = baseline.reserve_loopback_port()
        payload = bytes([baseline.PATTERN_BYTE]) * 4096
        server = baseline.EchoServer(port, len(payload), 5)
        server.start()
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(payload)
            echoed = bytearray()
            while len(echoed) < len(payload):
                chunk = client.recv(len(payload) - len(echoed))
                self.assertTrue(chunk)
                echoed.extend(chunk)
        observation = server.join()
        self.assertEqual(payload, bytes(echoed))
        self.assertEqual(len(payload), observation.bytes_received)
        self.assertEqual(len(payload), observation.bytes_echoed)

    def test_echo_server_rejects_wrong_payload(self) -> None:
        port = baseline.reserve_loopback_port()
        server = baseline.EchoServer(port, 4, 5)
        server.start()
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(b"xxxx")
        with self.assertRaises(baseline.BaselineError):
            server.join()

    def test_aggregate_keeps_raw_samples(self) -> None:
        case = baseline.BenchmarkCase("1KiB", 1024, 1)
        samples = [
            {"client_process_ms": 3.0, "server_first_to_last_byte_ms": 1.0, "client_roundtrip_mib_per_second": 1.0},
            {"client_process_ms": 1.0, "server_first_to_last_byte_ms": 2.0, "client_roundtrip_mib_per_second": 3.0},
            {"client_process_ms": 2.0, "server_first_to_last_byte_ms": 3.0, "client_roundtrip_mib_per_second": 2.0},
        ]
        result = baseline.aggregate(case, samples)
        self.assertEqual(2.0, result["client_process_ms"]["p50"])
        self.assertEqual(3, result["sample_count"])
        self.assertEqual(samples, result["samples"])

    def test_atomic_json_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested" / "report.json"
            baseline.atomic_write_json(output, {"status": "PASS"})
            self.assertEqual({"status": "PASS"}, json.loads(output.read_text(encoding="utf-8")))
            self.assertEqual([], list(output.parent.glob(f".{output.name}.*.tmp")))


if __name__ == "__main__":
    unittest.main()
