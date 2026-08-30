#!/usr/bin/env python3
"""Run and validate the native Windows M2-004 resolver acceptance gate."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


TASK_ID = "M2-004"
SCHEMA_VERSION = 1
EXPECTED_TESTS = 6


class GateError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def run_command(
    command: list[str], *, cwd: Path, env: dict[str, str], timeout: int
) -> dict[str, Any]:
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
        output = completed.stdout
        exit_code: int | None = completed.returncode
        timed_out = False
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or "") + (error.stderr or "")
        exit_code = None
        timed_out = True
    return {
        "command": command,
        "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        "exit_code": exit_code,
        "output": output[-20000:],
        "timed_out": timed_out,
    }


def process_failures(process: dict[str, Any], expected: int, label: str) -> list[str]:
    failures: list[str] = []
    if process.get("timed_out"):
        failures.append(f"{label}:TIMEOUT")
    if process.get("exit_code") != 0:
        failures.append(f"{label}:EXIT")
    output = process.get("output", "")
    if output.count("[ PASSED ] CASE:") != expected:
        failures.append(f"{label}:CASE_COUNT")
    if "[ SKIPPED ] CASE:" in output or "[ FAILED ] CASE:" in output:
        failures.append(f"{label}:NON_PASS_CASE")
    if re.search(r"(?:FAILED|ERROR): [1-9]", output):
        failures.append(f"{label}:SUMMARY_FAILURE")
    return failures


def validate_report(report: object, expected_revision: str) -> list[str]:
    failures: list[str] = []
    if not isinstance(report, dict):
        return ["REPORT:TYPE"]
    if report.get("schema_version") != SCHEMA_VERSION:
        failures.append("REPORT:UNKNOWN_SCHEMA")
    if report.get("task_id") != TASK_ID:
        failures.append("REPORT:TASK")
    if report.get("revision") != expected_revision:
        failures.append("REPORT:STALE_REVISION")
    platform_data = report.get("platform")
    if not isinstance(platform_data, dict) or platform_data.get("system") != "Windows":
        failures.append("REPORT:NON_NATIVE_WINDOWS")
    if report.get("decision") != "PASS":
        failures.append("REPORT:DECISION")
    if report.get("failures") != []:
        failures.append("REPORT:FAILURES")
    resolver_test = report.get("resolver_test")
    if not isinstance(resolver_test, dict):
        failures.append("REPORT:TEST_MISSING")
    else:
        failures.extend(process_failures(resolver_test, EXPECTED_TESTS, "RESOLVER_TEST"))
    manifest = report.get("resolver_manifest")
    if not isinstance(manifest, dict):
        failures.append("REPORT:MANIFEST_MISSING")
    else:
        if manifest.get("platform") != "windows-x86_64":
            failures.append("REPORT:MANIFEST_PLATFORM")
        if manifest.get("private_runtime_abi") is not False:
            failures.append("REPORT:PRIVATE_RUNTIME_ABI")
        if manifest.get("test_fixture") is not True:
            failures.append("REPORT:FIXTURE_NOT_BOUND")
    return failures


def run_gate(root: Path, output: Path, revision: str) -> dict[str, Any]:
    if platform.system() != "Windows":
        raise GateError("M2-004 acceptance requires a native Windows host")
    cjpm = shutil.which("cjpm")
    cjc = shutil.which("cjc")
    if cjpm is None or cjc is None:
        raise GateError("cjc and cjpm are required")
    env = dict(os.environ)
    env["WIRESTACK_RESOLVER_TEST_FIXTURE"] = "1"
    build = run_command(
        [
            "python", str(root / "tools" / "build_resolver.py"),
            "--root", str(root), "--platform", "windows-x86_64",
            "--test-fixture", "--quiet",
        ],
        cwd=root,
        env=env,
        timeout=120,
    )
    if build["timed_out"] or build["exit_code"] != 0:
        raise GateError("Windows resolver build failed: " + build["output"][-4000:])
    manifest_path = root / "target/native/resolver/current/resolver-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"resolver manifest is unavailable: {error}") from error
    resolver_test = run_command(
        [
            cjpm, "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
            "--filter", "M2004WindowsSystemResolverTest", "--show-all-output",
            "--no-color", "--no-progress",
        ],
        cwd=root,
        env=env,
        timeout=180,
    )
    toolchain = run_command([cjc, "-v"], cwd=root, env=env, timeout=15)
    failures = process_failures(resolver_test, EXPECTED_TESTS, "RESOLVER_TEST")
    if manifest.get("platform") != "windows-x86_64":
        failures.append("MANIFEST:PLATFORM")
    if manifest.get("private_runtime_abi") is not False:
        failures.append("MANIFEST:PRIVATE_RUNTIME_ABI")
    if manifest.get("test_fixture") is not True:
        failures.append("MANIFEST:FIXTURE")
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "gate_id": "M2-004-WINDOWS-SYSTEM-RESOLVER",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "revision": revision,
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "runner_image": os.environ.get("ImageOS", "unknown"),
            "runner_image_version": os.environ.get("ImageVersion", "unknown"),
            "toolchain": toolchain,
        },
        "resolver_manifest": manifest,
        "resolver_manifest_sha256": sha256_path(manifest_path),
        "build": build,
        "resolver_test": resolver_test,
        "failures": failures,
        "decision": "PASS" if not failures else "FAIL",
        "scope": "native Windows x86_64 resolver only",
    }
    atomic_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--validate-report", type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--validation-output", type=Path)
    args = parser.parse_args()
    if args.validate_report is not None:
        if not args.expected_revision:
            print("M2-004: --expected-revision is required")
            return 2
        try:
            payload = json.loads(args.validate_report.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"M2-004: invalid report: {error}")
            return 2
        failures = validate_report(payload, args.expected_revision)
        validation = {
            "schema_version": 1,
            "task_id": TASK_ID,
            "expected_revision": args.expected_revision,
            "failures": failures,
            "status": "PASS" if not failures else "FAIL",
        }
        if args.validation_output:
            atomic_json(args.validation_output, validation)
        print(json.dumps(validation, sort_keys=True))
        return 0 if not failures else 1
    if args.output is None or not args.revision:
        print("M2-004: --output and --revision are required")
        return 2
    try:
        report = run_gate(args.repo_root.resolve(), args.output.resolve(), args.revision)
    except GateError as error:
        print(f"M2-004-WINDOWS-SYSTEM-RESOLVER: ERROR: {error}")
        return 2
    print(json.dumps({
        "decision": report["decision"],
        "failures": report["failures"],
        "report": str(args.output.resolve()),
    }, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
