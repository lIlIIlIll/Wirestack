#!/usr/bin/env python3
"""Native Windows capability probe and strict M0-014 report validator."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
EXIT = {"READY": 0, "PASS": 0, "FAIL": 1, "INVALID": 2, "BLOCKED": 3}
REQUIRED_PAYLOADS = (1024, 16 * 1024, 64 * 1024, 1024 * 1024, 100 * 1024 * 1024)
CAPTURE_LIMIT = 8192


class GateError(ValueError):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def command_version(argv: Sequence[str]) -> str | None:
    if shutil.which(argv[0]) is None:
        return None
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, errors="replace", timeout=15, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout + result.stderr).strip()
    return value[:CAPTURE_LIMIT] if value else None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def environment_report(revision: str) -> dict[str, Any]:
    is_windows = platform.system() == "Windows" and os.name == "nt"
    tools = {
        name: shutil.which(name)
        for name in ("cjc", "cjpm", "wpr", "xperf", "wpaexporter", "tracerpt")
    }
    cjc = command_version(["cjc", "--version"])
    cjpm = command_version(["cjpm", "--version"])
    blockers: list[dict[str, str]] = []
    if not is_windows:
        blockers.append({"code": "NON_NATIVE_WINDOWS", "detail": platform.platform()})
    if cjc is None:
        blockers.append({"code": "CJC_UNAVAILABLE", "detail": "cjc --version unavailable"})
    if cjpm is None:
        blockers.append({"code": "CJPM_UNAVAILABLE", "detail": "cjpm --version unavailable"})
    if tools["wpr"] is None:
        blockers.append({"code": "WPR_UNAVAILABLE", "detail": "heap trace collector unavailable"})
    if tools["xperf"] is None and tools["wpaexporter"] is None:
        blockers.append({
            "code": "HEAP_EXPORTER_UNAVAILABLE",
            "detail": "neither xperf nor wpaexporter can export allocation events",
        })
    status = "READY" if not blockers else "BLOCKED"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-014",
        "report_kind": "environment-capabilities",
        "status": status,
        "generated_at_utc": utc_now(),
        "repository_revision": revision,
        "runner": {
            "os": platform.platform(),
            "system": platform.system(),
            "machine": platform.machine(),
            "python": sys.version.splitlines()[0],
            "github_actions": os.environ.get("GITHUB_ACTIONS") == "true",
            "runner_name": os.environ.get("RUNNER_NAME"),
            "runner_environment": os.environ.get("RUNNER_ENVIRONMENT"),
            "runner_arch": os.environ.get("RUNNER_ARCH"),
            "runner_os": os.environ.get("RUNNER_OS"),
        },
        "toolchain": {"cjc": cjc, "cjpm": cjpm, "cangjie_home": os.environ.get("CANGJIE_HOME")},
        "tools": tools,
        "blockers": blockers,
        "non_claims": [
            "environment readiness is not copy-profile acceptance",
            "cross-compilation is not native Windows evidence",
            "missing allocation or copy instrumentation cannot be recorded as PASS",
        ],
    }


def _expect(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise GateError(code, detail)


def validate_result(report: Any, expected_revision: str | None = None) -> dict[str, Any]:
    _expect(isinstance(report, dict), "TYPE", "report must be an object")
    _expect(report.get("schema_version") == SCHEMA_VERSION, "UNKNOWN_SCHEMA", "schema mismatch")
    _expect(report.get("task_id") == "M0-014", "TASK_ID", "wrong source task")
    _expect(report.get("report_kind") == "windows-copy-profile", "REPORT_KIND", "wrong report kind")
    _expect(report.get("platform") == "windows-x86_64", "NON_NATIVE_WINDOWS", "wrong platform")
    _expect(report.get("native_execution") is True, "NON_NATIVE_WINDOWS", "native execution absent")
    revision = report.get("repository_revision")
    _expect(isinstance(revision, str) and len(revision) == 40, "REVISION", "full revision required")
    if expected_revision is not None:
        _expect(revision == expected_revision, "STALE_REVISION", "report revision differs")
    metrics = report.get("metric_availability")
    _expect(isinstance(metrics, dict), "METRICS", "metric availability missing")
    _expect(metrics.get("application_visible_read_sizes") == "MEASURED", "READ_SIZES", "read sizes not measured")
    _expect(metrics.get("allocation_count") == "MEASURED_BY_ETW_HEAP", "ALLOCATIONS", "allocation count not measured")
    _expect(metrics.get("peak_private_bytes") == "MEASURED_BY_WIN32", "PRIVATE_BYTES", "private bytes not measured")
    _expect(metrics.get("copied_bytes_per_operation") == "MEASURED", "COPY_BYTES", "copy bytes not measured")
    cases = report.get("cases")
    _expect(isinstance(cases, list) and len(cases) == len(REQUIRED_PAYLOADS), "CASES", "payload matrix incomplete")
    by_payload = {item.get("payload_bytes"): item for item in cases if isinstance(item, dict)}
    _expect(tuple(sorted(by_payload)) == REQUIRED_PAYLOADS, "CASES", "payload set differs")
    for payload in REQUIRED_PAYLOADS:
        case = by_payload[payload]
        _expect(case.get("decision") == "PASS", "CASE_FAIL", f"payload {payload} failed")
        _expect(case.get("bytes_read") == payload, "BYTE_COUNT", f"payload {payload} not exact")
        reads = case.get("read_sizes")
        _expect(isinstance(reads, list) and reads and sum(reads) == payload, "READ_SIZES", f"payload {payload} trace invalid")
        _expect(all(isinstance(value, int) and 0 < value <= 65536 for value in reads), "READ_SIZES", f"payload {payload} read out of range")
        _expect(isinstance(case.get("allocation_count"), int) and case["allocation_count"] > 0, "ALLOCATIONS", f"payload {payload} allocation count invalid")
        _expect(isinstance(case.get("peak_private_bytes"), int) and case["peak_private_bytes"] > 0, "PRIVATE_BYTES", f"payload {payload} private bytes invalid")
        _expect(case.get("copied_bytes_per_operation") == payload, "COPY_BYTES", f"payload {payload} copied bytes invalid")
        latency = case.get("latency_ms")
        throughput = case.get("throughput_mib_per_second")
        _expect(isinstance(latency, dict) and all(latency.get(key) is not None for key in ("p50", "p95", "p99")), "LATENCY", f"payload {payload} latency incomplete")
        _expect(isinstance(throughput, dict) and all(throughput.get(key) is not None for key in ("p50", "p95", "p99")), "THROUGHPUT", f"payload {payload} throughput incomplete")
    _expect(any(payload > 4096 and by_payload[payload].get("fixed_4k_cap") is True for payload in REQUIRED_PAYLOADS), "FOUR_K_CAP", "fixed 4 KiB cap was not demonstrated")
    cleanup = report.get("cleanup")
    _expect(isinstance(cleanup, dict) and cleanup.get("decision") == "PASS", "CLEANUP", "bounded cleanup failed")
    _expect(report.get("status") == "PASS", "STATUS", "report does not claim PASS")
    return report


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("JSON", f"cannot read {path}") from error


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository-revision", default=os.environ.get("GITHUB_SHA", "unknown"))
    parser.add_argument("--environment-only", action="store_true")
    parser.add_argument("--validate-report", type=Path)
    parser.add_argument("--expected-revision")
    args = parser.parse_args(argv)
    if args.environment_only == (args.validate_report is not None):
        parser.error("select exactly one of --environment-only or --validate-report")
    if args.environment_only:
        report = environment_report(args.repository_revision)
        atomic_json(args.output.resolve(), report)
        print(f"M0-014 environment: {report['status']}")
        for blocker in report["blockers"]:
            print(f"- {blocker['code']}: {blocker['detail']}")
        return EXIT[report["status"]]
    try:
        validated = validate_result(load_json(args.validate_report.resolve()), args.expected_revision)
        result = {"schema_version": 1, "task_id": "M0-014", "status": "PASS", "validated_report_sha256": sha256(args.validate_report.resolve())}
        atomic_json(args.output.resolve(), result)
        print("M0-014 report validation: PASS")
        return 0
    except GateError as error:
        result = {"schema_version": 1, "task_id": "M0-014", "status": "FAIL", "code": error.code, "detail": error.detail}
        atomic_json(args.output.resolve(), result)
        print(f"M0-014 report validation: FAIL: {error.code}: {error.detail}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
