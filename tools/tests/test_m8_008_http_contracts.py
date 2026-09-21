from __future__ import annotations

import os
import subprocess
import signal
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

from tools import m8_008_http_contracts as gate


class M8008HttpContractsTest(unittest.TestCase):
    def test_real_nonzero_subprocess_stops_ordered_chain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = gate.CommandRunner(root / "run")
            marker = root / "must-not-run"
            commands = [
                gate.CommandSpec(
                    "provider",
                    (sys.executable, "-c", "import sys; sys.exit(23)"),
                    root,
                ),
                gate.CommandSpec(
                    "resolver",
                    (
                        sys.executable,
                        "-c",
                        f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')",
                    ),
                    root,
                ),
            ]
            with self.assertRaises(gate.PipelineError) as raised:
                runner.run_chain(commands, os.environ)
            self.assertEqual("COMMAND_FAILED", raised.exception.code)
            self.assertFalse(marker.exists())
            log = next((root / "run/logs").glob("*.log"))
            self.assertIn("returncode=23", log.read_text(encoding="utf-8"))

    @unittest.skipUnless(sys.platform == "linux", "Linux process-group ownership")
    def test_timeout_stops_descendants_before_returning(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid_file = root / "child-pid"
            script = (
                "import subprocess, sys, time; from pathlib import Path; "
                "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
                "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                f"Path({str(child_pid_file)!r}).write_text(str(child.pid)); time.sleep(60)"
            )
            runner = gate.CommandRunner(root / "run")
            try:
                with self.assertRaises(gate.PipelineError) as raised:
                    runner.run(
                        gate.CommandSpec("stalled-tree", (sys.executable, "-c", script), root, timeout=1),
                        os.environ,
                    )
                self.assertEqual("COMMAND_TIMEOUT", raised.exception.code)
                self.assertTrue(child_pid_file.exists(), "child must start before timeout")
                child_pid = int(child_pid_file.read_text())
                stopped = False
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline:
                    try:
                        state = Path(f"/proc/{child_pid}/stat").read_text().split(") ", 1)[1].split()[0]
                        stopped = state == "Z"
                    except FileNotFoundError:
                        stopped = True
                    if stopped:
                        break
                    time.sleep(0.01)
                self.assertTrue(stopped, "timed-out command left a running descendant")
            finally:
                if child_pid_file.exists():
                    try:
                        os.kill(int(child_pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_raw_artifact_mismatch_rejects_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pairs: dict[str, tuple[Path, Path]] = {}
            for name in gate.REPRODUCIBLE_ARTIFACTS:
                left = root / "A" / name
                right = root / "B" / name
                left.parent.mkdir(parents=True, exist_ok=True)
                right.parent.mkdir(parents=True, exist_ok=True)
                left.write_bytes(b"same")
                right.write_bytes(b"same")
                pairs[name] = (left, right)
            mismatched = pairs["release_archive"]
            mismatched[1].write_bytes(b"different")
            with self.assertRaises(gate.PipelineError) as raised:
                gate.compare_artifacts(pairs)
            self.assertEqual("ARTIFACT_MISMATCH", raised.exception.code)

    def test_run_roots_are_unique_and_outputs_cannot_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repo"
            repository.mkdir()
            first = gate.create_run_root(repository)
            second = gate.create_run_root(repository)
            expected_parent = (repository / "build/m8-008").resolve()
            self.assertEqual(expected_parent, first.parent)
            self.assertEqual(expected_parent, second.parent)
            self.assertNotEqual(first, second)
            self.assertEqual(first / "report.json", gate.confined_path(first, first / "report.json"))
            with self.assertRaises(gate.PipelineError) as raised:
                gate.confined_path(first, repository / "outside.json")
            self.assertEqual("OUTPUT_ESCAPE", raised.exception.code)



    def test_cjdoc_version_gate_rejects_non_exact_tool(self) -> None:
        gate._require_cjdoc_version("cjdoc 0.7.2")
        for output in ("cjdoc 0.7.1", "cjdoc 0.7.20", ""):
            with self.subTest(output=output):
                with self.assertRaises(gate.PipelineError) as raised:
                    gate._require_cjdoc_version(output)
                self.assertEqual("CJDOC_VERSION", raised.exception.code)

    def test_snapshot_captures_dirty_and_nonignored_bytes_but_not_caches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repo"
            repository.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "core.excludesFile", os.devnull],
                cwd=repository,
                check=True,
            )
            (repository / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
            (repository / "tracked.txt").write_text("original", encoding="utf-8")
            subprocess.run(
                ["git", "add", "-f", ".gitignore", "tracked.txt"],
                cwd=repository,
                check=True,
            )
            (repository / "tracked.txt").write_text("dirty working bytes", encoding="utf-8")
            (repository / "untracked.txt").write_text("included", encoding="utf-8")
            (repository / "ignored.txt").write_text("excluded", encoding="utf-8")
            (repository / "build").mkdir()
            (repository / "build/generated.txt").write_text("excluded", encoding="utf-8")

            run_root = gate.create_run_root(repository)
            runner = gate.CommandRunner(run_root)
            frozen = run_root / "frozen"
            manifest = gate.freeze_repository(repository, frozen, runner)

            self.assertEqual("dirty working bytes", (frozen / "tracked.txt").read_text())
            self.assertEqual("included", (frozen / "untracked.txt").read_text())
            self.assertFalse((frozen / "ignored.txt").exists())
            self.assertFalse((frozen / "build").exists())
            self.assertEqual(
                {".gitignore", "tracked.txt", "untracked.txt"},
                {entry["path"] for entry in manifest["files"]},
            )
            isolated_repository = run_root / "leg/repo"
            isolated_repository.parent.mkdir(parents=True)
            shutil.copytree(frozen, isolated_repository)
            environment = gate.initialize_isolated_repository(
                isolated_repository,
                os.environ,
                {"git": shutil.which("git") or "git"},
                runner,
                "fixture",
            )
            discovered = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                cwd=isolated_repository,
                env=environment,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            self.assertEqual(str(isolated_repository.resolve()), discovered)
            tracked = subprocess.run(
                ["git", "ls-files"],
                cwd=isolated_repository,
                env=environment,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.splitlines()
            self.assertEqual([".gitignore", "tracked.txt", "untracked.txt"], tracked)
            sibling_temporary = isolated_repository.parent / "tmp"
            sibling_temporary.mkdir()
            escaped = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                cwd=sibling_temporary,
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertNotEqual(
                0, escaped.returncode, "sibling temporary directory discovered outer Git root"
            )


if __name__ == "__main__":
    unittest.main()
