#!/usr/bin/env python3
"""Regression fixtures for fail-closed CI gates and clean release candidates."""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import sys
import pathlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock


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

class CiGateRegressionTests(unittest.TestCase):
    """Exercise real gate entrypoints with isolated inputs, not copies of their logic."""

    def run_command(self, command, *, cwd=None, env=None, timeout=120):
        return subprocess.run(command, cwd=cwd, env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout)

    def test_required_gate_accepts_only_complete_success(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        gate = workflow.split("\n  ci-required:\n", 1)[1]
        needs = gate.split("    needs:\n", 1)[1].split("    runs-on:", 1)[0]
        names = set(re.findall(r"^      - ([\w-]+)$", needs, re.MULTILINE))
        jobs = set(re.findall(r"^  ([\w-]+):$", workflow.split("jobs:\n", 1)[1], re.MULTILINE))
        self.assertEqual(names, jobs - {"pages", "ci-required"})
        self.assertIn("if: ${{ always() }}", gate)
        code = gate.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0]
        code = textwrap.dedent(code)
        success = {name: {"result": "success"} for name in names}
        fixtures = [(success, True), ({}, False), ([], False), (None, False)]
        for name in sorted(names):
            for status in ("failure", "cancelled", "skipped", None):
                fixtures.append(({**success, name: {"result": status}}, False))
            fixtures.append(({k: v for k, v in success.items() if k != name}, False))
        fixtures += [({**success, "unexpected": {"result": "success"}}, False),
                     ({**success, "tests": None}, False)]
        compiled = compile(code, "CI Required embedded script", "exec")
        for value, accepted in fixtures:
            with self.subTest(value=value), mock.patch.dict(os.environ, {"NEEDS_JSON": json.dumps(value)}):
                with contextlib.redirect_stdout(io.StringIO()):
                    if accepted:
                        exec(compiled, {})
                    else:
                        with self.assertRaises(SystemExit):
                            exec(compiled, {})
        with mock.patch.dict(os.environ, {"NEEDS_JSON": "not-json"}):
            with self.assertRaises(json.JSONDecodeError):
                exec(compiled, {})

    def test_workflow_retains_strict_build_and_deployment_dependencies(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertNotIn("run: scripts/harden_llc.sh", workflow)
        self.assertIn("resolution=pinned-sts", workflow)
        self.assertNotIn("resolution=seven-day-cache-window", workflow)
        self.assertNotIn("Resolve latest complete STS", workflow)
        self.assertIn("needs: [api-docs, ci-required]", workflow)
        self.assertIn("group: pages-main", workflow)
        self.assertIn("if: steps.current.outputs.deploy == 'true'", workflow)
        self.assertIn("git/ref/heads/main", workflow)
        retry = ROOT / ".github/workflows/ci-retry.yml"
        self.assertFalse(retry.exists(), "unclassified automatic reruns must remain disabled")

    def coverage(self, diff, lcov):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "patch.diff").write_text(diff, encoding="utf-8")
            (root / "coverage.info").write_text(lcov, encoding="utf-8")
            (root / "baseline.toml").write_text(
                "patch_line_percent = 90.0\npatch_branch_percent = 80.0\n", encoding="utf-8")
            return self.run_command([
                sys.executable, str(ROOT / "scripts/check_patch_coverage.py"),
                "--diff", str(root / "patch.diff"), "--lcov", str(root / "coverage.info"),
                "--baseline", str(root / "baseline.toml"),
            ])

    def test_patch_report_missing_changed_file_fails(self) -> None:
        diff = "+++ b/src/lib_new.cj\n@@ -0,0 +1 @@\n+func value(): Int64 { 1 }\n"
        result = self.coverage(diff, "SF:src/lib_old.cj\nDA:1,1\nend_of_record\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("src/lib_new.cj", result.stdout)
        self.assertIn("missing", result.stdout)

    def test_empty_patch_report_fails(self) -> None:
        result = self.coverage("", "")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("no executable line records", result.stdout)

    def test_patch_coverage_retains_positive_and_negative_thresholds(self) -> None:
        diff = "+++ b/src/lib_test.cj\n@@ -0,0 +1 @@\n+if (value) { work() }\n"
        for line_hit, branch_hit, accepted in ((1, 1, True), (0, 1, False), (1, 0, False)):
            with self.subTest(line=line_hit, branch=branch_hit):
                result = self.coverage(diff,
                    f"SF:src/lib_test.cj\nDA:1,{line_hit}\nBRDA:1,0,0,{branch_hit}\nend_of_record\n")
                self.assertEqual(result.returncode == 0, accepted, result.stdout)

    def test_comment_only_patch_is_na_not_false_full_coverage(self) -> None:
        diff = "+++ b/src/lib_test.cj\n@@ -1,0 +2 @@\n+// documentation\n"
        result = self.coverage(diff, "SF:src/lib_test.cj\nDA:1,1\nend_of_record\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("N/A", result.stdout)
        self.assertNotIn("100.0%", result.stdout)

    def fixture(self, root):
        scripts = root / "scripts"
        scripts.mkdir()
        fake = root / "bin"
        fake.mkdir()
        for name in ("ci_job.sh", "release_native_checks.sh", "release_yyjson_colink_check.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts)
        for name in ("yjson_native_primitives", "yjson_native_accel", "yjson_native", "yjson_algorithms"):
            (root / "packages" / name).mkdir(parents=True)
        for name in ("release_package_stage.py", "release_consumer_checks.py"):
            (scripts / name).write_text("# Isolated build prerequisite stub.\n", encoding="utf-8")
        for name in ("cjc", "cjpm"):
            write_executable(fake / name, "#!/usr/bin/env bash\nexit 0\n")
        env = os.environ.copy()
        env.pop("YJSON_CI_DEPENDENCY_OVERRIDE", None)
        env["PATH"] = str(fake) + os.pathsep + env["PATH"]
        return scripts, fake, env

    def test_custom_native_symbol_checker_errors_and_leaks_fail(self) -> None:
        for status, symbol, accepted in ((0, "YJ_Scan", True), (7, "", False),
                                         (0, "yyjson_read", False), (0, "unsafe_yyjson_read", False)):
            with self.subTest(status=status, symbol=symbol), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                scripts, fake, env = self.fixture(root)
                write_executable(fake / "nm", f"#!/usr/bin/env bash\necho '00000000 T {symbol}'\nexit {status}\n")
                result = self.run_command(["bash", str(scripts / "ci_job.sh"), "custom-native"], env=env)
                self.assertEqual(result.returncode == 0, accepted, result.stdout)
                if status:
                    self.assertEqual(result.returncode, status, result.stdout)

    def test_colink_symbol_checker_errors_and_leaks_fail(self) -> None:
        for status, symbol, accepted in ((0, "YJ_Parse", True), (7, "", False), (0, "yyjson_read", False)):
            with self.subTest(status=status, symbol=symbol), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                scripts, fake, env = self.fixture(root)
                second = root / "second/src"
                second.mkdir(parents=True)
                (second / "yyjson.c").write_text("", encoding="utf-8")
                env["YJSON_SECOND_YYJSON_ROOT"] = str(second.parent)
                env["CC"] = str(fake / "cc")
                # Exercise the real shell gate, replacing only compilation and its
                # fixture executables. Loader evidence remains required by the gate.
                write_executable(fake / "cc", r'''
                    #!/usr/bin/env bash
                    while [[ "$1" != "-o" ]]; do shift; done
                    output=$2
                    printf '#!/bin/sh\necho "libyjson-visible libyyjson-second yyjson_read" >&2\nexit 0\n' > "$output"
                    chmod +x "$output"
                ''')
                write_executable(fake / "nm", f"#!/usr/bin/env bash\necho '00000000 T {symbol}'\nexit {status}\n")
                result = self.run_command(["bash", str(scripts / "release_yyjson_colink_check.sh")], env=env)
                self.assertEqual(result.returncode == 0, accepted, result.stdout)
                if status:
                    self.assertEqual(result.returncode, status, result.stdout)

    def test_pure_gate_does_not_retry_test_failure_or_rewrite_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            scripts, fake, env = self.fixture(root)
            manifest = root / "cjpm.toml"
            text = 'compile-option = "-O2"\noverride-compile-option = ""\n'
            manifest.write_text(text, encoding="utf-8")
            counter = root / "attempts"
            env["PROBE_COUNTER"] = str(counter)
            write_executable(fake / "uname", "#!/bin/sh\necho MINGW64_NT\n")
            write_executable(fake / "cjpm", r'''
                #!/usr/bin/env python3
                import os, pathlib
                path = pathlib.Path(os.environ['PROBE_COUNTER'])
                count = int(path.read_text()) if path.exists() else 0
                path.write_text(str(count + 1))
                raise SystemExit(45 if count == 0 else 0)
            ''')
            result = self.run_command(["bash", str(scripts / "ci_job.sh"), "pure-platform"], env=env)
            self.assertEqual(result.returncode, 45, result.stdout)
            self.assertEqual(counter.read_text(), "1")
            self.assertEqual(manifest.read_text(), text)

    def test_runtime_freeze_retry_clears_previous_failure_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            scripts = root / "scripts"
            package = root / "packages/runtime_freeze_contract"
            fake = root / "bin"
            scripts.mkdir()
            package.mkdir(parents=True)
            fake.mkdir()
            shutil.copy2(ROOT / "scripts/runtime_freeze_contract_checks.sh", scripts)
            counter = root / "attempts"
            write_executable(fake / "cjpm", r'''
                #!/usr/bin/env python3
                import os
                import pathlib
                import sys
                counter = pathlib.Path(os.environ["PROBE_COUNTER"])
                attempts = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(attempts + 1))
                if attempts == 0:
                    print("llc command failed with exit code 139")
                    raise SystemExit(139)
                print(f"runtime freeze contract passed: {sys.argv[-1]}")
            ''')
            env = os.environ.copy()
            env["PATH"] = str(fake) + os.pathsep + env["PATH"]
            env["PROBE_COUNTER"] = str(counter)
            result = self.run_command(
                ["bash", str(scripts / "runtime_freeze_contract_checks.sh")],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(counter.read_text(), "9")
            self.assertIn("runtime freeze contract checks passed", result.stdout)

    def test_runtime_freeze_contract_failure_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            scripts = root / "scripts"
            package = root / "packages/runtime_freeze_contract"
            fake = root / "bin"
            scripts.mkdir()
            package.mkdir(parents=True)
            fake.mkdir()
            shutil.copy2(ROOT / "scripts/runtime_freeze_contract_checks.sh", scripts)
            counter = root / "attempts"
            write_executable(fake / "cjpm", r'''
                #!/usr/bin/env python3
                import os
                import pathlib
                counter = pathlib.Path(os.environ["PROBE_COUNTER"])
                attempts = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(attempts + 1))
                print("runtime contract assertion failed")
                raise SystemExit(45)
            ''')
            env = os.environ.copy()
            env["PATH"] = str(fake) + os.pathsep + env["PATH"]
            env["PROBE_COUNTER"] = str(counter)
            result = self.run_command(
                ["bash", str(scripts / "runtime_freeze_contract_checks.sh")],
                env=env,
            )
            self.assertEqual(result.returncode, 45, result.stdout)
            self.assertEqual(counter.read_text(), "1")

    def test_unknown_native_mode_fails_before_compilation(self) -> None:
        result = self.run_command(["bash", str(ROOT / "scripts/release_native_checks.sh")],
                                 env={**os.environ, "YJSON_NATIVE_CHECK_MODE": "typo"})
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("unknown native check mode", result.stdout)

    def test_real_ubsan_failure_propagates_through_native_gate(self) -> None:
        compiler = shutil.which("clang")
        if compiler is None:
            if os.environ.get("YJSON_REQUIRE_UBSAN_PROBE") == "1":
                self.fail("clang is required for the CI sanitizer negative probe")
            self.skipTest("clang is not installed")
        for undefined in (False, True):
            with self.subTest(undefined=undefined), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                scripts = root / "scripts"
                native = root / "native"
                scripts.mkdir()
                (native / "vendor/yyjson").mkdir(parents=True)
                shutil.copy2(ROOT / "scripts/release_native_checks.sh", scripts)
                for name in ("yjson_scanner.c", "yjson_compact.c", "yjson_yyjson.c", "vendor/yyjson/yyjson.c"):
                    (native / name).write_text("/* isolated translation unit */\n", encoding="utf-8")
                for name in ("test_yjson_scanner.c", "test_yjson_compact.c", "test_yjson_yyjson.c"):
                    (native / name).write_text("int main(void) { return 0; }\n", encoding="utf-8")
                if undefined:
                    (native / "test_yjson_scanner.c").write_text(
                        "#include <limits.h>\nint main(void) { volatile int n = INT_MAX; "
                        "volatile int v = n + 1; (void)v; return 0; }\n", encoding="utf-8")
                result = self.run_command(["bash", str(scripts / "release_native_checks.sh")],
                    env={**os.environ, "CC": compiler, "YJSON_NATIVE_CHECK_MODE": "sanitizer"})
                if undefined:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("runtime error: signed integer overflow", result.stdout)
                    self.assertNotIn("native release checks passed", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertIn("native release checks passed", result.stdout)


@unittest.skipUnless(os.environ.get("YJSON_TEST_STANDARDS_ORACLE") == "1",
                     "run explicitly in standards-conformance with a Cangjie SDK")
class StandardsOracleTests(unittest.TestCase):
    def test_schema_exception_is_not_a_negative_case_pass(self) -> None:
        groups = [
            {"description": "valid", "schema": True,
             "tests": [{"description": "normal valid", "data": 1, "valid": True}]},
            {"description": "invalid", "schema": False,
             "tests": [{"description": "normal invalid", "data": 1, "valid": False}]},
            {"description": "malformed schema", "schema": 17,
             "tests": [{"description": "exception is failure", "data": 1, "valid": False}]},
        ]
        manifest = {"schema": {"remotes": {}, "files": [{"source": "oracle-probe", "groups": groups}]},
                    "jsonpath": [], "jsonpatch": []}
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            result = subprocess.run(["cjpm", "run", "--", str(path)],
                cwd=ROOT / "packages/standards_conformance", text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
        # A compile/startup failure must not satisfy the negative test either.
        summaries = [line for line in result.stdout.splitlines() if line.startswith("SUMMARY\t")]
        self.assertEqual(summaries, ["SUMMARY\tpassed=2\tfailed=1\ttotal=3"], result.stdout)
        self.assertIn("FAIL\tjson-schema\toracle-probe", result.stdout)
        self.assertIn("exception:", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
