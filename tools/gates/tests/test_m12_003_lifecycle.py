"""Evidence decisions must reject missing fault proof and damaged fault scope."""
import unittest
from tools.gates.m12_003_lifecycle import bounded_cleanup, classify_wire, main


class BoundedCleanupTests(unittest.TestCase):
    def test_live_sampler_or_unreaped_process_is_not_bounded_cleanup(self):
        good = {"process_reaped": True, "remaining_live_owned_processes": 0, "sampler_alive": False}
        self.assertTrue(bounded_cleanup(good))
        for field, value in (("sampler_alive", True), ("process_reaped", False),
                             ("remaining_live_owned_processes", 1)):
            cleanup = dict(good)
            cleanup[field] = value
            with self.subTest(field=field):
                self.assertFalse(bounded_cleanup(cleanup))
        self.assertFalse(bounded_cleanup({}))


class WireAcceptanceTests(unittest.TestCase):
    def proof(self, fault, same=False):
        return {"requests": [{"path": "/sibling", "connection": 1, "stream": 1},
                             {"path": fault, "connection": 1, "stream": 3},
                             {"path": "/healthy", "connection": 1 if same else 2, "stream": 3}],
                "goaway_sent": [{"last_stream_id": 0}], "rst_stream_sent": [{"stream": 1}],
                "window_exhaustions": [{"available_window": 0}],
                "window_updates": [{"delta": 32768}], "data_bytes": 1048576}

    def test_goaway_requires_new_connection(self):
        with self.assertRaisesRegex(ValueError, "repooled"):
            classify_wire("h2_goaway", self.proof("/goaway", same=True))
        classify_wire("h2_goaway", self.proof("/goaway"))

    def test_goaway_requires_emitted_frame(self):
        proof = self.proof("/goaway")
        proof["goaway_sent"] = []
        with self.assertRaisesRegex(ValueError, "not sent"):
            classify_wire("h2_goaway", proof)

    def test_stream_fault_must_preserve_connection(self):
        with self.assertRaisesRegex(ValueError, "healthy connection"):
            classify_wire("h2_streamscope", self.proof("/reset"))
        classify_wire("h2_streamscope", self.proof("/reset", same=True))

    def test_stream_fault_requires_reset(self):
        proof = self.proof("/reset", same=True)
        proof["rst_stream_sent"] = []
        with self.assertRaises(ValueError):
            classify_wire("h2_streamscope", proof)

    def test_stream_fault_requires_concurrent_sibling(self):
        proof = self.proof("/reset", same=True)
        proof["requests"] = proof["requests"][1:]
        with self.assertRaisesRegex(ValueError, "concurrently admitted sibling"):
            classify_wire("h2_streamscope", proof)

    def test_slow_consumer_needs_flow_and_exact_bytes(self):
        for missing in ("window_updates", "window_exhaustions", "data_bytes"):
            with self.subTest(missing=missing):
                proof = self.proof("/reset")
                proof[missing] = [] if missing != "data_bytes" else 1048575
                with self.assertRaisesRegex(ValueError, "window/backpressure/recovery"):
                    classify_wire("h2_slowconsumer", proof)
        classify_wire("h2_slowconsumer", self.proof("/reset"))

    def test_non_sts_sdk_rejected_before_any_execution(self):
        with self.assertRaises(SystemExit) as error:
            main(["--sdk-root", "/non-sts-sdk", "--archive", "/not-read", "--scratch", "/not-created", "--output", "/not-created"])
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
