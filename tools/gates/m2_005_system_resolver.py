#!/usr/bin/env python3
"""Run one native-libc leg of the M2-005 SystemResolver gate."""

from __future__ import annotations

from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any


TASK_ID = "M2-005"
EXPECTED_RESOLVER_TESTS = 6
EXPECTED_INTEGRATION_TESTS = 1
EXPECTED_HOSTS = Counter({
    "localhost": 2,
    "all.m2-005.test": 3,
    "noname.m2-005.test": 1,
    "nodata.m2-005.test": 1,
    "again.m2-005.test": 1,
    "family.m2-005.test": 1,
    "system.m2-005.test": 1,
    "delay.m2-005.test": 1,
})
LOG_RE = re.compile(
    r"^M2005_GAI phase=(enter|exit) seq=(\d+) pid=(\d+) tid=(\d+) "
    r"ns=(\d+) family=(-?\d+) result=(-?\d+) host=(.*)$"
)


class GateError(RuntimeError):
    pass


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
        timed_out = False
        exit_code = completed.returncode
        output = completed.stdout
    except subprocess.TimeoutExpired as error:
        timed_out = True
        exit_code = None
        output = (error.stdout or "") + (error.stderr or "")
    return {
        "command": command,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        "output": output,
    }


def detect_libc(root: Path, env: dict[str, str]) -> dict[str, str]:
    reported_name, reported_version = platform.libc_ver()
    ldd = run_command(["ldd", "--version"], cwd=root, env=env, timeout=10)
    text = ldd["output"].lower()
    if "musl" in text or "musl" in reported_name.lower():
        name = "musl"
    elif "glibc" in text or "gnu libc" in text or reported_name == "glibc":
        name = "glibc"
    else:
        raise GateError("native libc is neither identified glibc nor identified musl")
    return {
        "name": name,
        "reported_name": reported_name,
        "reported_version": reported_version,
        "ldd_output": ldd["output"],
    }


def parse_fixture_log(text: str) -> dict[str, Any]:
    calls: dict[tuple[int, int], dict[str, dict[str, Any]]] = {}
    for line in text.splitlines():
        match = LOG_RE.fullmatch(line)
        if match is None:
            raise GateError(f"malformed fixture log line: {line!r}")
        event = {
            "phase": match.group(1),
            "sequence": int(match.group(2)),
            "pid": int(match.group(3)),
            "tid": int(match.group(4)),
            "monotonic_ns": int(match.group(5)),
            "family": int(match.group(6)),
            "result": int(match.group(7)),
            "host": match.group(8),
        }
        key = (event["pid"], event["sequence"])
        phases = calls.setdefault(key, {})
        if event["phase"] in phases:
            raise GateError(
                f"duplicate {event['phase']} for fixture process/sequence {key}"
            )
        phases[event["phase"]] = event

    hosts: Counter[str] = Counter()
    completed: list[dict[str, Any]] = []
    for (pid, sequence), phases in sorted(calls.items()):
        if set(phases) != {"enter", "exit"}:
            raise GateError(
                f"incomplete fixture process/sequence {(pid, sequence)}: {sorted(phases)}"
            )
        entered = phases["enter"]
        exited = phases["exit"]
        for field in ("pid", "tid", "family", "host"):
            if entered[field] != exited[field]:
                raise GateError(f"fixture sequence {sequence} changed {field}")
        if exited["monotonic_ns"] < entered["monotonic_ns"]:
            raise GateError(f"fixture sequence {sequence} has negative duration")
        hosts[entered["host"]] += 1
        completed.append({
            "pid": pid,
            "sequence": sequence,
            "host": entered["host"],
            "family": entered["family"],
            "result": exited["result"],
            "duration_ms": round(
                (exited["monotonic_ns"] - entered["monotonic_ns"]) / 1_000_000,
                3,
            ),
        })
    return {
        "call_count": len(completed),
        "host_counts": dict(sorted(hosts.items())),
        "calls": completed,
    }


def validate_process(process: dict[str, Any], expected_cases: int, label: str) -> list[str]:
    failures: list[str] = []
    if process["timed_out"]:
        failures.append(f"{label} timed out")
    if process["exit_code"] != 0:
        failures.append(f"{label} exited {process['exit_code']}")
    output = process["output"]
    if output.count("[ PASSED ] CASE:") != expected_cases:
        failures.append(f"{label} did not report {expected_cases} passed cases")
    if "[ FAILED ] CASE:" in output or re.search(r"(?:FAILED|ERROR): [1-9]", output):
        failures.append(f"{label} reported failed cases")
    return failures


def validate_fixture(parsed: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    actual_hosts = Counter(parsed["host_counts"])
    if actual_hosts != EXPECTED_HOSTS:
        failures.append(
            f"fixture host counts differ: expected {dict(EXPECTED_HOSTS)}, "
            f"got {dict(actual_hosts)}"
        )
    for call in parsed["calls"]:
        host = call["host"]
        result = call["result"]
        if host in {"localhost", "all.m2-005.test", "nodata.m2-005.test", "delay.m2-005.test"}:
            if result != 0:
                failures.append(f"fixture host {host} unexpectedly returned {result}")
        elif result == 0:
            failures.append(f"fixture error host {host} unexpectedly succeeded")
    return failures


def run_gate(root: Path, output_dir: Path) -> dict[str, Any]:
    if platform.system() != "Linux":
        raise GateError("M2-005 acceptance requires a native Linux host")
    cc = shutil.which("clang") or shutil.which("cc")
    cjpm = shutil.which("cjpm")
    if cc is None or cjpm is None:
        raise GateError("clang/cc and cjpm must be available")
    base_env = dict(os.environ)
    libc = detect_libc(root, base_env)
    gate_id = f"M2-005-SYSTEM-RESOLVER-{libc['name'].upper()}"
    output_dir.mkdir(parents=True, exist_ok=True)
    fixture_log = output_dir / "gai-fixture.log"
    if fixture_log.exists():
        fixture_log.unlink()

    with tempfile.TemporaryDirectory(prefix="wirestack-m2-005-") as directory:
        fixture = Path(directory) / "libwirestack-m2-005-gai-fixture.so"
        compiled = run_command(
            [
                cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                str(root / "tools" / "gates" / "native" / "m2_005_gai_fixture.c"),
                "-o", str(fixture), "-ldl", "-pthread",
            ],
            cwd=root,
            env=base_env,
            timeout=60,
        )
        if compiled["exit_code"] != 0 or not fixture.is_file():
            raise GateError("fixture compilation failed:\n" + compiled["output"][-4000:])
        fixture_digest = evidence_digest.artifact_byte_sha256(fixture)
        test_env = dict(base_env)
        test_env.update({
            "LD_PRELOAD": str(fixture),
            "WIRESTACK_M2_005_FIXTURE": "1",
            "WIRESTACK_M2_005_GAI_LOG": str(fixture_log),
        })
        resolver_test = run_command(
            [
                cjpm, "test", "src/http", "-j", "1", "--parallel", "1",
                "--filter", "M2005SystemResolverTest", "--show-all-output",
                "--no-color", "--no-progress",
            ],
            cwd=root,
            env=test_env,
            timeout=120,
        )
        integration_test = run_command(
            [
                cjpm, "test", "src/http", "--skip-build", "-j", "1",
                "--parallel", "1", "--filter",
                "HttpFacadeTest.defaultSystemResolverConnectsPublicClientAndServer",
                "--show-all-output", "--no-color", "--no-progress",
            ],
            cwd=root,
            env=test_env,
            timeout=120,
        )

    if not fixture_log.is_file():
        raise GateError("fixture did not record any getaddrinfo calls")
    parsed = parse_fixture_log(fixture_log.read_text(encoding="utf-8"))
    failures = validate_process(
        resolver_test, EXPECTED_RESOLVER_TESTS, "SystemResolver public test"
    )
    failures.extend(validate_process(
        integration_test, EXPECTED_INTEGRATION_TESTS, "default HttpClient integration"
    ))
    failures.extend(validate_fixture(parsed))
    cjc = run_command(["cjc", "-v"], cwd=root, env=base_env, timeout=10)
    report = {
        "schema_version": 1,
        "task_id": TASK_ID,
        "gate_id": gate_id,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "libc": libc,
            "cjc": cjc,
        },
        "configuration": {
            "expected_resolver_tests": EXPECTED_RESOLVER_TESTS,
            "expected_integration_tests": EXPECTED_INTEGRATION_TESTS,
            "expected_hosts": dict(EXPECTED_HOSTS),
        },
        "artifacts": {
            "fixture_sha256": fixture_digest,
            "fixture_log_sha256": evidence_digest.text_evidence_sha256(fixture_log),
        },
        "fixture_compile": compiled,
        "resolver_test": resolver_test,
        "integration_test": integration_test,
        "fixture": parsed,
        "failures": failures,
        "decision": "PASS" if not failures else "FAIL",
        "scope": f"native Linux {libc['name']} leg only",
    }
    (output_dir / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "resolver-test.log").write_text(
        resolver_test["output"], encoding="utf-8"
    )
    (output_dir / "integration-test.log").write_text(
        integration_test["output"], encoding="utf-8"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = run_gate(args.repo_root.resolve(), args.output_dir.resolve())
    except GateError as error:
        print(f"M2-005-SYSTEM-RESOLVER: ERROR: {error}")
        return 2
    print(json.dumps({
        "gate_id": report["gate_id"],
        "decision": report["decision"],
        "failures": report["failures"],
        "report": str(args.output_dir.resolve() / "report.json"),
        "scope": report["scope"],
    }, indent=2, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
