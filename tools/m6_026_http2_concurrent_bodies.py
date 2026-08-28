#!/usr/bin/env python3
"""Run the bounded M6-026 HTTP/2 concurrent-body acceptance gate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence

ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M6-026"
PROFILE = "linux-x86_64-glibc"
REPORT = ROOT / "docs/evidence/M6-026/linux_x86_64/concurrent-bodies.json"
ENV_WRAPPER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")
PROFILE_CASE = "oneThousandOverlappingBatchesCompleteAndTerminate"
RESULT = re.compile(
    r"^\s*M6_026_RESULT batches=(\d+) responses=(\d+) bytes=(\d+) "
    r"failures=(\d+) timeouts=(\d+) activeHandlers=(\d+)$",
    re.MULTILINE,
)
SOURCE_PATHS = (
    "src/http/facade_test.cj",
    "src/internal/http2/client_connection.cj",
    "src/internal/http2/client_connection_test.cj",
    "tools/m6_026_http2_concurrent_bodies.py",
)


class ConcurrentBodyGateError(RuntimeError):
    pass


def require_linux(system: str | None = None, machine: str | None = None) -> None:
    actual_system = system or platform.system()
    actual_machine = machine or platform.machine()
    if actual_system != "Linux" or actual_machine not in {"x86_64", "AMD64"}:
        raise ConcurrentBodyGateError(
            f"BLOCKED: requires Linux x86_64, got {actual_system}/{actual_machine}"
        )


def atomic_json(
    path: Path,
    value: dict[str, Any],
    replace: Callable[[str, str], None] = os.replace,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        replace(str(temporary), str(path))
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def validate_profile_output(output: str) -> dict[str, int]:
    passed = f"[ PASSED ] CASE: {PROFILE_CASE}"
    skipped = f"[ SKIPPED ] CASE: {PROFILE_CASE}"
    if skipped in output or passed not in output:
        raise ConcurrentBodyGateError("profile target was skipped or did not report PASSED")
    matches = RESULT.findall(output)
    if len(matches) != 1:
        raise ConcurrentBodyGateError("profile emitted no unique M6_026_RESULT marker")
    values = tuple(int(value) for value in matches[0])
    expected = (1000, 2000, 4000, 0, 0, 0)
    if values != expected:
        raise ConcurrentBodyGateError(
            f"profile result {values} does not match required {expected}"
        )
    return dict(zip(
        ("batches", "responses", "bytes", "failures", "timeouts", "activeHandlers"),
        values,
    ))


def run(command: Sequence[str], timeout: int) -> str:
    completed = subprocess.run(
        list(command), cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout, check=False,
    )
    output = completed.stdout[-65536:]
    if completed.returncode != 0:
        raise ConcurrentBodyGateError(
            f"command failed with exit {completed.returncode}: {' '.join(command)}\n{output}"
        )
    return output


def tool_version(command: Sequence[str]) -> str:
    completed = subprocess.run(
        list(command), cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=10, check=False,
    )
    if completed.returncode != 0:
        raise ConcurrentBodyGateError(f"tool unavailable: {' '.join(command)}")
    return completed.stdout.strip()[:4096]


def sha256(relative: str) -> str:
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


def validate() -> dict[str, Any]:
    require_linux()
    if not ENV_WRAPPER.is_file():
        raise ConcurrentBodyGateError(f"missing Cangjie environment wrapper: {ENV_WRAPPER}")
    base = [str(ENV_WRAPPER), "--cwd", str(ROOT), "cjpm", "test"]
    internal_output = run(base + [
        "src/internal/http2", "-j", "1", "--parallel", "1",
        "--filter=Http2ClientConnectionTest", "--show-all-output",
        "--no-progress", "--no-color",
    ], 300)
    if "[ PASSED ] CASE: claimedStreamsPublishInitialHeadersInStreamIdOrder" not in internal_output:
        raise ConcurrentBodyGateError("ordered initial-headers regression did not pass")
    if "[ PASSED ] CASE: cancelledUnpublishedStreamDoesNotBlockNextClaim" not in internal_output:
        raise ConcurrentBodyGateError("unpublished-stream cancellation regression did not pass")
    profile_output = run(base + [
        "src/http", "-j", "1", "--parallel", "1",
        f"--filter=Http2ConcurrentResponseBodyProfileTest.{PROFILE_CASE}",
        "--show-all-output", "--no-progress", "--no-color",
    ], 300)
    result = validate_profile_output(profile_output)
    report = {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "acceptance_status": "PASS",
        "status": "PASS",
        "decision": "PASS",
        "platform": PROFILE,
        "toolchain": {
            "cjc": tool_version([str(ENV_WRAPPER), "cjc", "-v"]),
            "cjpm": tool_version([str(ENV_WRAPPER), "cjpm", "-v"]),
        },
        "checks": {
            "orderedInitialHeaders": "PASS",
            "unpublishedCancellation": "PASS",
            "publicRealTlsProfile": "PASS",
            "skippedAsPass": False,
        },
        "result": result,
        "commands": [
            "cjpm test src/internal/http2 --filter=Http2ClientConnectionTest",
            f"cjpm test src/http --filter=Http2ConcurrentResponseBodyProfileTest.{PROFILE_CASE}",
        ],
        "source_sha256": {relative: sha256(relative) for relative in SOURCE_PATHS},
    }
    atomic_json(REPORT, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = validate()
    except (ConcurrentBodyGateError, subprocess.TimeoutExpired) as error:
        failure = {
            "schemaVersion": 1,
            "taskId": TASK_ID,
            "source_task": TASK_ID,
            "acceptance_status": "FAIL",
            "status": "FAIL",
            "decision": "FAIL",
            "platform": PROFILE,
            "error": str(error)[-8192:],
        }
        atomic_json(REPORT, failure)
        print(json.dumps(failure, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True) if args.json else f"{TASK_ID} PASS: 1000 concurrent H2 batches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
