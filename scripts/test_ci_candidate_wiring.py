#!/usr/bin/env python3
"""Integration fixtures for clean release-candidate CI wiring."""

from __future__ import annotations

import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def write_executable(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class CandidateCiWiringTests(unittest.TestCase):
    def test_outer_fresh_checkout_creates_clean_provenance_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary)
            scripts = fixture / "scripts"
            fake_bin = fixture / "fake-bin"
            scripts.mkdir()
            fake_bin.mkdir()
            shutil.copy2(ROOT / "scripts/ci_fresh_checkout.sh", scripts)
            marker = fixture / "outer-registry-ran"
            write_executable(
                scripts / "release_temp_tree.py",
                """
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import shutil
                import sys

                if len(sys.argv) != 3 or sys.argv[2] != "--enforce-clean":
                    raise SystemExit("outer fresh checkout did not enforce clean staging")
                destination = pathlib.Path(sys.argv[1])
                (destination / "scripts").mkdir(parents=True)
                (destination / "release").mkdir()
                (destination / "release/candidate-provenance.json").write_text(
                    json.dumps({"clean_enforced": True}), encoding="utf-8")
                shutil.copy2(
                    os.environ["YJSON_REAL_CI_JOB"],
                    destination / "scripts/ci_job.sh")
                (destination / "scripts/check_api_inventory.py").write_text(
                    "#!/usr/bin/env python3\\n", encoding="utf-8")
                (destination / "scripts/release_registry_rehearsal.py").write_text(
                    "#!/usr/bin/env python3\\n"
                    "import os, pathlib, sys\\n"
                    "args = sys.argv[1:]\\n"
                    "assert '--require-clean-candidate' in args\\n"
                    "index = args.index('--candidate-root')\\n"
                    "candidate = pathlib.Path(args[index + 1]).resolve()\\n"
                    "expected = pathlib.Path(__file__).resolve().parents[1]\\n"
                    "assert candidate == expected\\n"
                    "pathlib.Path(os.environ['YJSON_TEST_MARKER']).write_text("
                    "' '.join(args), encoding='utf-8')\\n",
                    encoding="utf-8")
                """,
            )
            for command in ("cjc", "cjpm"):
                write_executable(
                    fake_bin / command,
                    """
                    #!/usr/bin/env bash
                    exit 0
                    """,
                )
            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env["PATH"]
            env["YJSON_CI_JOBS"] = "registry-rehearsal"
            env["YJSON_REAL_CI_JOB"] = str(ROOT / "scripts/ci_job.sh")
            env["YJSON_TEST_MARKER"] = str(marker)
            subprocess.run(
                ["bash", str(scripts / "ci_fresh_checkout.sh")],
                cwd=fixture,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            recorded = marker.read_text(encoding="utf-8")
            self.assertIn("--require-clean-candidate", recorded)
            self.assertIn("--candidate-root", recorded)

    def test_registry_gate_reuses_existing_clean_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = pathlib.Path(temporary)
            scripts = candidate / "scripts"
            release = candidate / "release"
            fake_bin = candidate / "fake-bin"
            scripts.mkdir()
            release.mkdir()
            fake_bin.mkdir()
            shutil.copy2(ROOT / "scripts/ci_job.sh", scripts)
            (release / "candidate-provenance.json").write_text(
                '{"clean_enforced": true}\n', encoding="utf-8"
            )
            restage_marker = candidate / "unexpected-restage"
            registry_marker = candidate / "registry-args"
            write_executable(
                scripts / "release_temp_tree.py",
                f"""
                #!/usr/bin/env python3
                import pathlib
                pathlib.Path({str(restage_marker)!r}).write_text("called", encoding="utf-8")
                raise SystemExit(99)
                """,
            )
            write_executable(
                scripts / "check_api_inventory.py",
                """
                #!/usr/bin/env python3
                """,
            )
            write_executable(
                scripts / "release_registry_rehearsal.py",
                """
                #!/usr/bin/env python3
                import os
                import pathlib
                import sys

                args = sys.argv[1:]
                if "--require-clean-candidate" not in args:
                    raise SystemExit("clean candidate was not required")
                index = args.index("--candidate-root")
                candidate = pathlib.Path(args[index + 1]).resolve()
                expected = pathlib.Path(__file__).resolve().parents[1]
                if candidate != expected:
                    raise SystemExit("registry runner did not receive the staged candidate")
                if (candidate / ".diagnostic-build").exists():
                    raise SystemExit("diagnostic build modified the formal candidate")
                pathlib.Path(os.environ["YJSON_TEST_MARKER"]).write_text(
                    " ".join(args), encoding="utf-8")
                """,
            )
            for command in ("cjc", "cjpm"):
                write_executable(
                    fake_bin / command,
                    """
                    #!/usr/bin/env bash
                    if [[ "$(basename "$0")" == "cjpm" ]]; then
                        : > .diagnostic-build
                    fi
                    exit 0
                    """,
                )
            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env["PATH"]
            env["YJSON_TEST_MARKER"] = str(registry_marker)
            subprocess.run(
                ["bash", str(scripts / "ci_job.sh"), "registry-rehearsal"],
                cwd=ROOT,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertFalse(restage_marker.exists())
            self.assertFalse((candidate / ".diagnostic-build").exists())
            recorded = registry_marker.read_text(encoding="utf-8")
            self.assertIn("--require-clean-candidate", recorded)
            self.assertIn(f"--candidate-root {candidate}", recorded)


if __name__ == "__main__":
    unittest.main(verbosity=2)
