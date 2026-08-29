from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import m7_022_linux_release_soak as gate


class M7022LinuxReleaseSoakTest(unittest.TestCase):
    def sample(self, index: int, elapsed: int, cycles: int) -> str:
        values = {
            "index": index,
            "elapsedMs": elapsed,
            "usedHeapBytes": 1000,
            "activeWaiters": 0,
            "activeBuffers": 0,
            "backgroundTasks": 2,
            "cycles": cycles,
            "h1Requests": cycles,
            "h2Requests": cycles * 5,
            "sseEvents": cycles * 8,
        }
        return gate.SAMPLE_PREFIX + " ".join(f"{key}={value}" for key, value in values.items())

    def result(self, duration: int = 10, elapsed: int = 10_000) -> str:
        values = {
            "durationSeconds": duration,
            "elapsedMs": elapsed,
            "cycles": 8,
            "activePhases": 8,
            "idlePhases": 8,
            "connects": 5,
            "h1Requests": 10,
            "h2Requests": 42,
            "h2MultiplexBatches": 8,
            "sseH1Events": 32,
            "sseH2Events": 32,
            "requestCancels": 8,
            "streamResets": 8,
            "connectionCancels": 1,
            "reconnects": 1,
            "spawnedTasks": 32,
            "joinedTasks": 32,
            "sequenceErrors": 0,
            "maxCancelLatencyNs": 1_000_000,
            "activeWaiters": 0,
            "activeBuffers": 0,
            "backgroundTasks": 0,
            "serverTasks": 0,
        }
        return gate.RESULT_PREFIX + " ".join(f"{key}={value}" for key, value in values.items())

    def test_marker_parser_accepts_exact_ordered_samples_and_one_result(self) -> None:
        text = "\n".join([
            self.sample(0, 1000, 1),
            self.sample(1, 2000, 2),
            self.sample(2, 2000, 2),
            self.result(),
        ])
        samples, result = gate.parse_output(text)
        self.assertEqual(3, len(samples))
        self.assertEqual(8, result["cycles"])

    def test_marker_parser_rejects_missing_duplicate_reordered_unknown_and_skipped(self) -> None:
        valid = "\n".join([self.sample(0, 1000, 1), self.result()])
        variants = (
            self.sample(0, 1000, 1),
            valid + "\n" + self.result(),
            self.sample(1, 1000, 1) + "\n" + self.result(),
            "\n".join([
                self.sample(0, 2000, 2),
                self.sample(1, 1999, 2),
                self.result(),
            ]),
            "\n".join([
                self.sample(0, 1000, 2),
                self.sample(1, 2000, 1),
                self.result(),
            ]),
            valid.replace(" cycles=1", " unknown=1 cycles=1", 1),
            valid + "\nSKIPPED",
        )
        for value in variants:
            with self.subTest(value=value[-80:]):
                with self.assertRaises(gate.SoakError):
                    gate.parse_output(value)

    def test_metric_trend_accepts_limit_and_rejects_growth_or_monotonic_count(self) -> None:
        equality = gate.metric_trend([0, 0, 0, 0, 0, 2, 2, 2, 2, 2], 2, count_metric=False)
        self.assertEqual("PASS", equality["decision"])
        startup_step = gate.metric_trend(
            [10, 11, 11, 11, 12, 12, 12, 12, 12, 12], 2, count_metric=True
        )
        self.assertEqual("PASS", startup_step["decision"])
        self.assertFalse(startup_step["monotonic_growth"])
        over = gate.metric_trend([0, 0, 0, 0, 0, 3, 3, 3, 3, 3], 2, count_metric=False)
        self.assertEqual("FAIL", over["decision"])
        monotonic = gate.metric_trend(list(range(10)), 20, count_metric=True)
        self.assertEqual("FAIL", monotonic["decision"])
        self.assertGreaterEqual(monotonic["positive_steps"], 3)

    def test_resource_and_application_trends_fail_closed(self) -> None:
        self.assertEqual(
            "INCONCLUSIVE", gate.resource_trend([], minimum_samples=5)["decision"]
        )
        samples = []
        for index in range(10):
            samples.append({
                "rss_kib": 1000,
                "fd_count": 4,
                "socket_count": 2,
                "timerfd_count": 0,
                "process_count": 1,
                "thread_count": 4,
            })
        self.assertEqual("PASS", gate.resource_trend(samples, minimum_samples=5)["decision"])
        application = [{
            "usedHeapBytes": 1000,
            "activeWaiters": 0,
            "activeBuffers": 0,
            "backgroundTasks": 2,
            "cycles": index,
        } for index in range(10)]
        self.assertEqual(
            "PASS", gate.application_trend(application, minimum_samples=5)["decision"]
        )
        application[-1]["activeBuffers"] = 1
        self.assertEqual(
            "FAIL", gate.application_trend(application, minimum_samples=5)["decision"]
        )

    def test_workload_requires_duration_mix_cancellation_reset_and_terminal_cleanup(self) -> None:
        _, result = gate.parse_output(self.sample(0, 1000, 1) + "\n" + self.result())
        checks = gate.validate_workload(result, 10, 10_000)
        self.assertTrue(all(checks.values()))
        self.assertFalse(gate.validate_workload(result, gate.FORMAL_SECONDS, 10_000)["requested_duration"])
        result["backgroundTasks"] = 1
        self.assertFalse(gate.validate_workload(result, 10, 10_000)["terminal_owners"])

    def test_platform_rejects_other_os_cpu_and_musl(self) -> None:
        for values, code in (
            (("Darwin", "x86_64", "glibc"), "UNSUPPORTED_PLATFORM"),
            (("Linux", "aarch64", "glibc"), "UNSUPPORTED_PLATFORM"),
            (("Linux", "x86_64", "musl"), "UNSUPPORTED_LIBC"),
        ):
            with self.assertRaises(gate.SoakError) as caught:
                gate.require_platform(*values)
            self.assertEqual(code, caught.exception.code)

    def test_artifact_missing_and_digest_drift_fail_before_execution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qualification = root / "qualification.json"
            artifact = root / "artifact.tar.gz"
            qualification.write_text(json.dumps({"artifact": {"sha256": "0" * 64}}))
            with mock.patch.object(gate.release, "validate_report"):
                with self.assertRaises(gate.SoakError) as missing:
                    gate.load_qualified_artifact(root, qualification, artifact)
                self.assertEqual("ARTIFACT_MISSING", missing.exception.code)
                artifact.write_bytes(b"changed")
                with self.assertRaises(gate.SoakError) as drift:
                    gate.load_qualified_artifact(root, qualification, artifact)
                self.assertEqual("ARTIFACT_DIGEST", drift.exception.code)

    def test_exact_artifact_digest_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "artifact.tar.gz"
            artifact.write_bytes(b"artifact")
            digest = hashlib.sha256(b"artifact").hexdigest()
            qualification = root / "qualification.json"
            qualification.write_text(json.dumps({"artifact": {"sha256": digest}}))
            with mock.patch.object(gate.release, "validate_report"):
                _, actual = gate.load_qualified_artifact(root, qualification, artifact)
            self.assertEqual(digest, actual)

    def test_internal_import_and_package_drift_fail_closed(self) -> None:
        source = "package wirestack_m7_022_soak\nimport wirestack.http.*\n"
        gate.validate_consumer_sources(source, "package wirestack_m7_022_soak\n")
        with self.assertRaises(gate.SoakError) as internal:
            gate.validate_consumer_sources(source + "import wirestack.internal.transport.*\n", "")
        self.assertEqual("INTERNAL_IMPORT", internal.exception.code)
        with self.assertRaises(gate.SoakError) as package:
            gate.validate_consumer_sources(source + "package wirestack_m7_022_soak\n", "")
        self.assertEqual("SOURCE_PACKAGE", package.exception.code)

    def test_atomic_report_replaces_and_preserves_old_target_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text("old\n")
            gate.atomic_json(path, {"decision": "PASS"})
            self.assertEqual("PASS", json.loads(path.read_text())["decision"])

            def fail_replace(_source: object, _target: object) -> None:
                raise OSError("injected replace failure")

            before = path.read_bytes()
            with self.assertRaises(OSError):
                gate.atomic_json(path, {"decision": "FAIL"}, replace=fail_replace)
            self.assertEqual(before, path.read_bytes())
            self.assertEqual([path], list(path.parent.iterdir()))

    def test_exclusive_task_run_rejects_a_second_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "m7-022.lock"
            with gate.exclusive_task_run(lock):
                with self.assertRaises(gate.SoakError) as caught:
                    with gate.exclusive_task_run(lock):
                        self.fail("second invocation acquired the lock")
                self.assertEqual("SOAK_ALREADY_RUNNING", caught.exception.code)

                script = """
import sys
from pathlib import Path
from tools import m7_022_linux_release_soak as gate
try:
    with gate.exclusive_task_run(Path(sys.argv[1])):
        print("ACQUIRED")
except gate.SoakError as error:
    print(error.code)
    raise SystemExit(7)
"""
                child = subprocess.run(
                    [sys.executable, "-c", script, str(lock)],
                    cwd=gate.ROOT,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                self.assertEqual(7, child.returncode)
                self.assertEqual("SOAK_ALREADY_RUNNING", child.stdout.strip())

    def test_isolated_raw_log_promotes_atomically_and_preserves_old_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "soak.log"
            target.write_text("old\n")
            running = gate.isolated_raw_log(target, root / "runs")
            running.write_text("complete\n")
            gate.promote_raw_log(running, target)
            self.assertEqual("complete\n", target.read_text())
            self.assertFalse(running.exists())

            failed = gate.isolated_raw_log(target, root / "runs")
            failed.write_text("partial\n")

            def fail_replace(_source: object, _target: object) -> None:
                raise OSError("injected log promotion failure")

            with self.assertRaises(OSError):
                gate.promote_raw_log(failed, target, replace=fail_replace)
            self.assertEqual("complete\n", target.read_text())
            self.assertEqual("partial\n", failed.read_text())

    def test_lock_failure_does_not_replace_active_run_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text('{"decision":"RUNNING"}\n')
            with mock.patch.object(
                gate,
                "exclusive_task_run",
                side_effect=gate.SoakError(
                    "SOAK_ALREADY_RUNNING", "another invocation is active"
                ),
            ):
                result = gate.main(["--output", str(output)])
            self.assertEqual(1, result)
            self.assertEqual('{"decision":"RUNNING"}\n', output.read_text())

    def test_bounded_tail_keeps_only_the_configured_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "output.log"
            path.write_text("a" * 100 + "tail")
            self.assertEqual("aaaaaatail", gate.bounded_tail(path, 10))

    def test_terminate_process_group_stops_running_child(self) -> None:
        process = subprocess.Popen(
            ["bash", "-c", "sleep 30"], start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        gate.terminate_process_group(process)
        self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main()
