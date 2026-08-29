#!/usr/bin/env python3
"""Run the deterministic M2-003 bounded resolver-pool acceptance profile."""

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


TASK_ID = "M2-003"
GATE_ID = "M2-003-BOUNDED-RESOLVER-POOL"
EXPECTED_TESTS = 9
EXPECTED_CALLS = 14
SHIM_RE = re.compile(
    r"^GAI phase=(enter|exit) seq=(\d+) pid=(\d+) tid=(\d+) "
    r"ns=(\d+) result=(-?\d+) node=(.*)$"
)


class GateError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_shim_log(text: str) -> dict[str, Any]:
    calls: dict[int, dict[str, dict[str, Any]]] = {}
    for line in text.splitlines():
        match = SHIM_RE.fullmatch(line)
        if match is None:
            raise GateError(f"malformed shim log line: {line!r}")
        event = {
            "phase": match.group(1),
            "sequence": int(match.group(2)),
            "pid": int(match.group(3)),
            "tid": int(match.group(4)),
            "monotonic_ns": int(match.group(5)),
            "result": int(match.group(6)),
            "node": match.group(7),
        }
        phases = calls.setdefault(event["sequence"], {})
        if event["phase"] in phases:
            raise GateError(
                f"duplicate {event['phase']} for shim sequence {event['sequence']}"
            )
        phases[event["phase"]] = event

    intervals: list[tuple[int, int]] = []
    thread_ids: set[int] = set()
    durations_ms: list[float] = []
    for sequence, phases in sorted(calls.items()):
        if set(phases) != {"enter", "exit"}:
            raise GateError(f"incomplete shim call sequence {sequence}: {sorted(phases)}")
        entered = phases["enter"]
        exited = phases["exit"]
        if entered["tid"] != exited["tid"]:
            raise GateError(f"shim call {sequence} changed native thread")
        if exited["monotonic_ns"] < entered["monotonic_ns"]:
            raise GateError(f"shim call {sequence} has negative duration")
        intervals.append((entered["monotonic_ns"], exited["monotonic_ns"]))
        thread_ids.add(entered["tid"])
        durations_ms.append(
            round((exited["monotonic_ns"] - entered["monotonic_ns"]) / 1_000_000, 3)
        )

    timeline: list[tuple[int, int]] = []
    for entered, exited in intervals:
        timeline.append((entered, 1))
        timeline.append((exited, -1))
    concurrent = 0
    maximum_concurrent = 0
    for _, delta in sorted(timeline, key=lambda item: (item[0], item[1])):
        concurrent += delta
        maximum_concurrent = max(maximum_concurrent, concurrent)
    return {
        "call_count": len(calls),
        "unique_thread_count": len(thread_ids),
        "thread_ids": sorted(thread_ids),
        "maximum_concurrent": maximum_concurrent,
        "duration_ms": {
            "minimum": min(durations_ms) if durations_ms else None,
            "maximum": max(durations_ms) if durations_ms else None,
        },
    }


def validate(
    process: dict[str, Any], shim: dict[str, Any], global_bound: dict[str, Any]
) -> list[str]:
    failures: list[str] = []
    if process["timed_out"]:
        failures.append("focused unittest timed out")
    if process["exit_code"] != 0:
        failures.append(f"focused unittest exited {process['exit_code']}")
    output = process["output"]
    if output.count("[ PASSED ] CASE:") != EXPECTED_TESTS:
        failures.append(f"focused unittest did not report {EXPECTED_TESTS} passed cases")
    if "[ FAILED ] CASE:" in output or re.search(r"(?:FAILED|ERROR): [1-9]", output):
        failures.append("focused unittest reported failed cases")
    if shim["call_count"] != EXPECTED_CALLS:
        failures.append(
            f"expected {EXPECTED_CALLS} intercepted getaddrinfo calls, got {shim['call_count']}"
        )
    # A cancelled job may remain quarantined in the prior one-worker pool while
    # the following two-worker profile starts. The process-wide shim can then
    # observe three calls even though each individual pool stays bounded.
    if shim["maximum_concurrent"] < 2 or shim["maximum_concurrent"] > 3:
        failures.append(
            "resolver profile did not stay within the expected 2-3 concurrent native calls"
        )
    if shim["duration_ms"]["minimum"] is None or shim["duration_ms"]["minimum"] < 180:
        failures.append("delay shim did not hold every native getaddrinfo call for at least 180 ms")
    if global_bound["timed_out"]:
        failures.append("global resolver-pool bound probe timed out")
    if global_bound["exit_code"] != 0:
        failures.append(
            f"global resolver-pool bound probe exited {global_bound['exit_code']}"
        )
    if "GLOBAL_POOL_BOUND PASS live_pool_limit=8" not in global_bound["output"]:
        failures.append("global resolver-pool bound probe did not report its fixed limit")
    return failures


def run_command(command: list[str], *, cwd: Path, env: dict[str, str], timeout: int) -> dict[str, Any]:
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
    ended = time.monotonic_ns()
    return {
        "command": command,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "duration_ms": round((ended - started) / 1_000_000, 3),
        "output": output,
    }


def run_gate(root: Path, output_dir: Path, delay_ms: int) -> dict[str, Any]:
    if platform.system() != "Linux":
        raise GateError("M2-003 acceptance requires a native Linux host")
    cc = shutil.which("clang") or shutil.which("cc")
    cjpm = shutil.which("cjpm")
    if cc is None or cjpm is None:
        raise GateError("clang/cc and cjpm must be available")
    output_dir.mkdir(parents=True, exist_ok=True)
    shim_log = output_dir / "gai-delay.log"
    if shim_log.exists():
        shim_log.unlink()

    build = run_command(
        [str(root / "scripts" / "build-linux-resolver"), "--quiet"],
        cwd=root,
        env=dict(os.environ),
        timeout=60,
    )
    if build["exit_code"] != 0:
        raise GateError("resolver bridge build failed:\n" + build["output"][-4000:])
    manifest_path = root / "target" / "native" / "resolver" / "current" / "resolver-manifest.json"
    try:
        resolver_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"resolver build manifest is unavailable: {error}") from error
    if resolver_manifest.get("private_runtime_abi") is not False:
        raise GateError("resolver build manifest does not reject private runtime ABI use")

    with tempfile.TemporaryDirectory(prefix="wirestack-m2-003-") as directory:
        native_dir = root / "native" / "resolver" / "linux"
        shim = Path(directory) / "libwirestack-gai-delay.so"
        compile_command = [
            cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
            "-o", str(shim), str(root / "tools" / "gates" / "native" / "gai_delay.c"),
            "-ldl", "-pthread",
        ]
        compiled = run_command(
            compile_command, cwd=root, env=dict(os.environ), timeout=60
        )
        if compiled["exit_code"] != 0 or not shim.is_file():
            raise GateError("delay shim build failed:\n" + compiled["output"][-4000:])
        environment = dict(os.environ)
        environment.update({
            "LD_PRELOAD": str(shim),
            "WIRESTACK_GAI_DELAY_MS": str(delay_ms),
            "WIRESTACK_GAI_LOG": str(shim_log),
        })
        process = run_command(
            [
                cjpm,
                "test",
                "--filter",
                "M2003BoundedResolverBackendTest",
                "--no-color",
                "--no-progress",
            ],
            cwd=root,
            env=environment,
            timeout=60,
        )
        shim_digest = sha256_path(shim)

        global_bound_binary = Path(directory) / "resolver-global-bound"
        global_bound_compile = run_command(
            [
                cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-pthread", f"-I{native_dir}",
                str(root / "tools" / "gates" / "native" / "resolver_global_bound.c"),
                str(native_dir / "wirestack_resolver.c"),
                "-Wl,--wrap=getaddrinfo", "-o", str(global_bound_binary),
            ],
            cwd=root,
            env=dict(os.environ),
            timeout=60,
        )
        if global_bound_compile["exit_code"] != 0 or not global_bound_binary.is_file():
            raise GateError(
                "global resolver-pool bound probe build failed:\n" +
                global_bound_compile["output"][-4000:]
            )
        global_bound = run_command(
            [str(global_bound_binary)], cwd=root, env=dict(os.environ), timeout=10
        )
        global_bound_digest = sha256_path(global_bound_binary)

    if not shim_log.is_file():
        raise GateError("delay shim did not record any getaddrinfo calls")
    parsed = parse_shim_log(shim_log.read_text(encoding="utf-8"))
    failures = validate(process, parsed, global_bound)
    report = {
        "schema_version": 1,
        "task_id": TASK_ID,
        "gate_id": GATE_ID,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "libc": platform.libc_ver(),
        },
        "configuration": {
            "delay_ms": delay_ms,
            "expected_tests": EXPECTED_TESTS,
            "expected_getaddrinfo_calls": EXPECTED_CALLS,
        },
        "artifacts": {
            "delay_shim_sha256": shim_digest,
            "shim_log_sha256": sha256_path(shim_log),
            "global_pool_bound_probe_sha256": global_bound_digest,
        },
        "resolver_build": build,
        "resolver_manifest": resolver_manifest,
        "shim_compile": compiled,
        "global_pool_bound_compile": global_bound_compile,
        "global_pool_bound": global_bound,
        "focused_test": process,
        "shim": parsed,
        "failures": failures,
        "decision": "PASS" if not failures else "FAIL",
    }
    (output_dir / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "focused-test.log").write_text(process["output"], encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--delay-ms", type=int, default=200)
    args = parser.parse_args()
    if args.delay_ms < 180 or args.delay_ms > 1000:
        parser.error("--delay-ms must be between 180 and 1000")
    try:
        report = run_gate(args.repo_root.resolve(), args.output_dir.resolve(), args.delay_ms)
    except GateError as error:
        print(f"{GATE_ID}: ERROR: {error}")
        return 2
    print(json.dumps({
        "gate_id": GATE_ID,
        "decision": report["decision"],
        "failures": report["failures"],
        "report": str(args.output_dir.resolve() / "report.json"),
    }, indent=2, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
