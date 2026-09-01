from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "m6_026_http2_concurrent_bodies.py"
SPEC = importlib.util.spec_from_file_location("m6_026_gate", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def accepted_output(marker: str | None = None) -> str:
    result = marker or (
        "M6_026_RESULT batches=1000 responses=2000 bytes=4000 "
        "failures=0 timeouts=0 activeHandlers=0"
    )
    return (
        f"[ PASSED ] CASE: {gate.PROFILE_CASE}\n"
        f"{result}\n"
    )


class M6026GateTest(unittest.TestCase):
    def test_accepts_exact_profile_contract(self) -> None:
        result = gate.validate_profile_output(accepted_output())
        self.assertEqual(result["responses"], 2000)
        self.assertEqual(result["activeHandlers"], 0)

    def test_accepts_test_runner_stdout_indentation(self) -> None:
        output = accepted_output().replace("M6_026_RESULT", "    M6_026_RESULT")
        self.assertEqual(gate.validate_profile_output(output)["batches"], 1000)

    def test_rejects_short_or_failed_profile(self) -> None:
        for marker in (
            "M6_026_RESULT batches=999 responses=1998 bytes=3996 failures=0 timeouts=0 activeHandlers=0",
            "M6_026_RESULT batches=1000 responses=2000 bytes=4000 failures=1 timeouts=0 activeHandlers=0",
        ):
            with self.subTest(marker=marker), self.assertRaises(gate.ConcurrentBodyGateError):
                gate.validate_profile_output(accepted_output(marker))

    def test_rejects_skipped_target_masquerading_as_pass(self) -> None:
        output = accepted_output().replace("[ PASSED ]", "[ SKIPPED ]")
        with self.assertRaises(gate.ConcurrentBodyGateError):
            gate.validate_profile_output(output)

    def test_rejects_missing_or_duplicate_result_marker(self) -> None:
        with self.assertRaises(gate.ConcurrentBodyGateError):
            gate.validate_profile_output(f"[ PASSED ] CASE: {gate.PROFILE_CASE}\n")
        with self.assertRaises(gate.ConcurrentBodyGateError):
            gate.validate_profile_output(accepted_output() + accepted_output())

    def test_atomic_report_replaces_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            gate.atomic_json(path, {"status": "PASS"})
            self.assertEqual(json.loads(path.read_text())["status"], "PASS")

    def test_atomic_report_preserves_old_target_on_replace_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"status":"OLD"}\n', encoding="utf-8")

            def fail_replace(source: str, target: str) -> None:
                raise OSError(f"injected replace failure for {source} -> {target}")

            with self.assertRaises(OSError):
                gate.atomic_json(path, {"status": "PASS"}, replace=fail_replace)
            self.assertEqual(json.loads(path.read_text())["status"], "OLD")
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_source_digests_resolve_paths_from_repository_root(self) -> None:
        expected = {
            relative: gate.evidence_digest.text_evidence_sha256(gate.ROOT / relative)
            for relative in gate.SOURCE_PATHS
        }
        self.assertEqual(expected, gate.source_digests())


if __name__ == "__main__":
    unittest.main()
