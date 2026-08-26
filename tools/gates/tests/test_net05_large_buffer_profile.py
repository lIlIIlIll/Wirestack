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


if __name__ == "__main__":
    unittest.main()
