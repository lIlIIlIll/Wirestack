from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))

import net05_large_buffer_profile as gate


class Tests(unittest.TestCase):
    def process(self):
        return {
            "command": ["probe"], "exit_code": 0, "timed_out": False,
            "duration_ms": 1.0, "stdout": "", "stderr": "",
        }

    def test_parse_output(self):
        sizes, fields = gate.parse_probe_output(
            "READ size=65536\nREAD size=4096\n"
            "RESULT bytes=69632 readCalls=2 invalid=0 eof=false "
            "durationNs=1000 closeCode=0 bufferSize=65536\n"
        )
        self.assertEqual([65536, 4096], sizes)
        self.assertEqual("2", fields["readCalls"])

    def test_parse_rejects_missing_result(self):
        with self.assertRaises(gate.GateError):
            gate.parse_probe_output("READ size=1\n")

    def test_fixed_4k_cap(self):
        self.assertTrue(gate.fixed_4k_cap([4096, 4096], 65536))
        self.assertFalse(gate.fixed_4k_cap([4096, 8192], 65536))
        self.assertFalse(gate.fixed_4k_cap([], 65536))

    def test_small_payload_is_not_classified_as_a_fixed_4k_cap(self):
        case = gate.Case("1KiB", 1024)
        server = type("Server", (), {"bytes_sent": 1024, "send_sizes": [1024]})()
        rss = type("Rss", (), {
            "peak_kib": 100, "samples_kib": [100],
            "peak_threads": 1, "thread_samples": [1],
        })()
        fields = {
            "bytes": "1024", "readCalls": "1", "invalid": "0",
            "eof": "false", "durationNs": "1000", "closeCode": "0",
            "bufferSize": "65536",
        }
        result = gate.classify_sample(case, 65536, self.process(), [1024], fields, server, rss)
        self.assertEqual("PASS", result["decision"])
        self.assertFalse(result["fixed_4k_cap"])

    def test_classify_exact_sample(self):
        case = gate.Case("test", 8192)
        server = type("Server", (), {"bytes_sent": 8192, "send_sizes": [8192]})()
        rss = type("Rss", (), {
            "peak_kib": 100, "samples_kib": [90, 100],
            "peak_threads": 2, "thread_samples": [2, 2],
        })()
        fields = {
            "bytes": "8192", "readCalls": "2", "invalid": "0",
            "eof": "false", "durationNs": "1000000", "closeCode": "0",
            "bufferSize": "65536",
        }
        result = gate.classify_sample(
            case, 65536, self.process(), [4096, 4096], fields, server, rss
        )
        self.assertEqual("PASS", result["decision"])
        self.assertTrue(result["exact_bytes"])
        self.assertEqual(2, result["peak_thread_count"])

    def test_zero_byte_sample_needs_no_read_and_aggregates_empty_read_sizes(self):
        case = gate.Case("0B", 0)
        server = type("Server", (), {"bytes_sent": 0, "send_sizes": []})()
        rss = type("Rss", (), {
            "peak_kib": 100, "samples_kib": [100],
            "peak_threads": 1, "thread_samples": [1],
        })()
        fields = {
            "bytes": "0", "readCalls": "0", "invalid": "0",
            "eof": "false", "durationNs": "1000", "closeCode": "0",
            "bufferSize": "65536",
        }
        result = gate.classify_sample(case, 65536, self.process(), [], fields, server, rss)
        self.assertEqual("PASS", result["decision"])
        summary = gate.aggregate(case, [result])
        self.assertIsNone(summary["read_size_bytes"]["max"])
        self.assertEqual(1.0, summary["peak_thread_count"]["max"])

    def test_classify_rejects_byte_mismatch(self):
        case = gate.Case("test", 8192)
        server = type("Server", (), {"bytes_sent": 4096, "send_sizes": [4096]})()
        rss = type("Rss", (), {
            "peak_kib": 100, "samples_kib": [100],
            "peak_threads": 2, "thread_samples": [2],
        })()
        fields = {
            "bytes": "4096", "readCalls": "1", "invalid": "0",
            "eof": "true", "durationNs": "1000000", "closeCode": "0",
            "bufferSize": "65536",
        }
        result = gate.classify_sample(
            case, 65536, self.process(), [4096], fields, server, rss
        )
        self.assertEqual("FAIL", result["decision"])

    def test_percentile_nearest_rank(self):
        self.assertEqual(2.0, gate.percentile([1, 2, 3, 4], 50))
        self.assertEqual(4.0, gate.percentile([1, 2, 3, 4], 95))

    def test_gate_covers_every_prd_payload(self):
        self.assertEqual(
            [1024, 16384, 65536, 1048576, 104857600],
            [case.payload_bytes for case in gate.CASES],
        )

    def test_comparison_uses_one_unittest_binary_shape(self):
        binary = Path("/tmp/net05-comparison")
        raw = gate.unittest_probe_command(binary, gate.RAW_TEST_FILTER)
        adapter = gate.unittest_probe_command(binary, gate.ADAPTER_TEST_FILTER)
        self.assertEqual(raw[0], adapter[0])
        self.assertEqual(raw[2:], adapter[2:])
        self.assertEqual("--filter=Net05RawStdNetBenchmarkTest.receive", raw[1])
        self.assertEqual(
            "--filter=Net05StdNetTransportBenchmarkTest.receive", adapter[1]
        )

    def test_adapter_sample_requires_zero_staging_copies(self):
        case = gate.Case("1KiB", 1024)
        server = type("Server", (), {"bytes_sent": 1024, "send_sizes": [1024]})()
        rss = type("Rss", (), {
            "peak_kib": 100, "samples_kib": [100],
            "peak_threads": 1, "thread_samples": [1],
        })()
        fields = {
            "bytes": "1024", "readCalls": "1", "invalid": "0",
            "eof": "false", "durationNs": "1000", "closeCode": "0",
            "bufferSize": "65536", "copiedReadBytes": "0",
            "copiedWriteBytes": "0",
        }
        passing = gate.classify_sample(
            case, 65536, self.process(), [1024], fields, server, rss,
            implementation="StdNetTransport",
        )
        self.assertEqual("PASS", passing["decision"])
        fields["copiedReadBytes"] = "1"
        failing = gate.classify_sample(
            case, 65536, self.process(), [1024], fields, server, rss,
            implementation="StdNetTransport",
        )
        self.assertEqual("FAIL", failing["decision"])

    def test_comparison_applies_both_prd_thresholds(self):
        raw = {
            "throughput_mib_per_second": {"p50": 100.0},
            "transfer_ms": {"p95": 10.0},
        }
        passing = {
            "throughput_mib_per_second": {"p50": 95.0},
            "transfer_ms": {"p95": 11.0},
        }
        failing = {
            "throughput_mib_per_second": {"p50": 94.999},
            "transfer_ms": {"p95": 11.001},
        }
        self.assertEqual("PASS", gate.compare_implementations(raw, passing)["decision"])
        self.assertEqual("FAIL", gate.compare_implementations(raw, failing)["decision"])

    def test_parses_native_instrumentation(self):
        self.assertEqual(
            9160,
            gate.parse_heaptrack_allocations(
                "heaptrack stats:\n\tallocations:\t9,160\n\tleaked allocations:\t4\n"
            ),
        )
        trace = (
            '1 recvfrom(3, "", 65536, 0, NULL, NULL) = 65536\n'
            '1 recvfrom(3, "", 65536, 0, NULL, NULL) = -1 EAGAIN\n'
        )
        self.assertEqual([65536, -1], gate.parse_strace_recvfrom_results(trace))


if __name__ == "__main__":
    unittest.main()
