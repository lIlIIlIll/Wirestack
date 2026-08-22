from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPOSITORY_ROOT / "tools" / "gates"))

import gate_runner as runner  # noqa: E402


class GateRunnerTests(unittest.TestCase):
    def temporary_root(self) -> tempfile.TemporaryDirectory[str]:
        return tempfile.TemporaryDirectory(prefix="wirestack-gate-runner-")

    @staticmethod
    def manifest(command: list[str], **scenario_overrides: object) -> dict[str, object]:
        scenario: dict[str, object] = {
            "id": "scenario",
            "steps": [{"id": "step", "command": command, "timeout_seconds": 5}],
        }
        scenario.update(scenario_overrides)
        return {
            "schema_version": runner.SCHEMA_VERSION,
            "gate_id": "TEST-GATE",
            "scenarios": [scenario],
        }

    @staticmethod
    def execute(root: Path, manifest: dict[str, object], capture_bytes: int = 4096) -> dict[str, object]:
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        validated, digest = runner.load_manifest(manifest_path)
        return runner.execute_manifest(
            manifest=validated,
            manifest_sha256=digest,
            manifest_path=manifest_path,
            repo_root=root,
            artifact_dir=root / "artifacts",
            capture_bytes=capture_bytes,
        )

    def test_successful_scenario_passes(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            report = self.execute(
                root,
                self.manifest([sys.executable, "-c", "print('ok')"]),
            )
            self.assertEqual("PASS", report["status"])
            step = report["scenarios"][0]["steps"][0]
            self.assertEqual("PASS", step["status"])
            self.assertEqual(0, step["exit_code"])
            self.assertIn("ok", step["stdout_excerpt"])

    def test_nonzero_exit_fails(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            report = self.execute(
                root,
                self.manifest([sys.executable, "-c", "import sys; sys.exit(7)"]),
            )
            self.assertEqual("FAIL", report["status"])
            step = report["scenarios"][0]["steps"][0]
            self.assertEqual(7, step["exit_code"])
            self.assertFalse(step["timed_out"])

    @unittest.skipIf(os.name == "nt", "POSIX process-group assertion")
    def test_timeout_terminates_child_process_group(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            pid_path = root / "child.pid"
            script = (
                "import pathlib, subprocess, sys, time; "
                "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                f"pathlib.Path({str(pid_path)!r}).write_text(str(child.pid)); "
                "time.sleep(60)"
            )
            manifest = self.manifest([sys.executable, "-c", script])
            manifest["scenarios"][0]["steps"][0]["timeout_seconds"] = 0.2
            report = self.execute(root, manifest)
            step = report["scenarios"][0]["steps"][0]
            self.assertEqual("FAIL", report["status"])
            self.assertTrue(step["timed_out"])
            child_pid = int(pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail(f"timed-out child process still exists: {child_pid}")

    def test_missing_required_tool_is_blocked(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            report = self.execute(
                root,
                self.manifest(
                    [sys.executable, "-c", "raise SystemExit('must not run')"],
                    required_tools=["wirestack-tool-that-does-not-exist"],
                ),
            )
            self.assertEqual("BLOCKED", report["status"])
            self.assertEqual([], report["scenarios"][0]["steps"])

    def test_disabled_or_wrong_platform_is_skipped(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            disabled = self.execute(
                root,
                self.manifest([sys.executable, "-c", "pass"], enabled=False),
            )
            self.assertEqual("SKIPPED", disabled["status"])
            impossible_platform = "windows" if runner.platform_name() != "windows" else "linux"
            skipped = self.execute(
                root,
                self.manifest([sys.executable, "-c", "pass"], platforms=[impossible_platform]),
            )
            self.assertEqual("SKIPPED", skipped["status"])

    def test_pass_plus_skip_does_not_pass_overall(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            manifest = {
                "schema_version": runner.SCHEMA_VERSION,
                "gate_id": "TEST-GATE",
                "scenarios": [
                    {
                        "id": "pass",
                        "steps": [{"id": "pass", "command": [sys.executable, "-c", "pass"]}],
                    },
                    {
                        "id": "skip",
                        "enabled": False,
                        "steps": [{"id": "skip", "command": [sys.executable, "-c", "pass"]}],
                    },
                ],
            }
            report = self.execute(root, manifest)
            self.assertEqual("SKIPPED", report["status"])

    def test_report_capture_is_bounded_while_full_log_is_retained(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            report = self.execute(
                root,
                self.manifest([sys.executable, "-c", "print('x' * 10000)"]),
                capture_bytes=128,
            )
            step = report["scenarios"][0]["steps"][0]
            self.assertEqual(128, len(step["stdout_excerpt"].encode("utf-8")))
            self.assertTrue(step["stdout_truncated"])
            self.assertGreater(Path(step["stdout_path"]).stat().st_size, 128)

    def test_unknown_schema_and_fields_fail_closed(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            path = root / "manifest.json"
            for raw in (
                {"schema_version": 999, "gate_id": "x", "scenarios": []},
                {
                    "schema_version": runner.SCHEMA_VERSION,
                    "gate_id": "x",
                    "unexpected": True,
                    "scenarios": [],
                },
            ):
                path.write_text(json.dumps(raw), encoding="utf-8")
                with self.assertRaises(runner.ManifestError):
                    runner.load_manifest(path)

    def test_atomic_json_output_replaces_without_temporary_files(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            output = root / "evidence" / "report.json"
            runner.atomic_write_json(output, {"first": True})
            runner.atomic_write_json(output, {"second": True})
            self.assertEqual({"second": True}, json.loads(output.read_text(encoding="utf-8")))
            self.assertEqual([], list(output.parent.glob(f".{output.name}.*.tmp")))

    def test_cli_writes_error_report_for_malformed_manifest(self) -> None:
        with self.temporary_root() as directory:
            root = Path(directory)
            manifest = root / "bad.json"
            manifest.write_text("{not-json", encoding="utf-8")
            output = root / "report.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(REPOSITORY_ROOT / "tools" / "gates" / "gate_runner.py"),
                    "--manifest", str(manifest),
                    "--repo-root", str(root),
                    "--artifact-dir", str(root / "artifacts"),
                    "--output", str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(runner.EXIT_CODES["ERROR"], completed.returncode)
            self.assertEqual("ERROR", json.loads(output.read_text(encoding="utf-8"))["status"])


if __name__ == "__main__":
    unittest.main()
