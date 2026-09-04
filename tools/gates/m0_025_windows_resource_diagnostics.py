#!/usr/bin/env python3
"""Run bounded, mode-isolated diagnostics for the M0-011 Windows failure.

The diagnostic process intentionally exercises the same public ``std.net``
probe as M0-011 one mode at a time. It is evidence for attribution, not a
replacement for the fixed four-hour acceptance profile.
"""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import argparse
import datetime as dt
import json
import os
import platform
import re
import sys
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

from tools.gates import m0_011_windows_long as m0011


TASK_ID = "M0-025"
SCHEMA_VERSION = 1
REPORT_KIND = "windows-resource-diagnostics"
PLATFORM_ID = "windows-x86_64"
DIAGNOSTIC_MODES = (
    "connect-close",
    "echo-close",
    "peer-reset",
    "close-during-read",
)
DEFAULT_DURATION_SECONDS = 600
MAX_DURATION_SECONDS = 600
DEFAULT_SAMPLE_INTERVAL_SECONDS = 1.0
DEFAULT_ITERATIONS_PER_MODE = 16_384
MIN_ITERATIONS_PER_MODE = 8_192
MAX_ITERATIONS_PER_MODE = 100_000
CONNECT_CLOSE_ITERATIONS = 65_536
DEFAULT_TIMEOUT_SECONDS = 600.0
MAX_TIMEOUT_SECONDS = 900.0
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class DiagnosticError(RuntimeError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    m0011.atomic_json(path, value)


def environment_report(revision: str) -> dict[str, Any]:
    base = m0011.environment_report(revision)
    return {
        **base,
        "task_id": TASK_ID,
        "report_kind": f"{REPORT_KIND}-environment",
        "diagnostic_modes": list(DIAGNOSTIC_MODES),
        "non_claims": [
            "diagnostic readiness is not four-hour acceptance",
            "the public std.net probe is not Wirestack production-path evidence",
            "this report does not close M0-011",
        ],
    }


def diagnostic_command(binary: Path, mode: str, port: int, iterations: int) -> list[str]:
    if mode not in DIAGNOSTIC_MODES:
        raise DiagnosticError("MODE", "unknown diagnostic mode")
    if iterations <= 0:
        raise DiagnosticError("ITERATIONS", "diagnostic iteration budget must be positive")
    return [
        str(binary),
        mode,
        str(port),
        str(iterations),
        str(m0011.WINDOWS_GC_INTERVAL_ITERATIONS),
    ]


def validate_budget(
    duration_seconds: int,
    sample_interval_seconds: float,
    timeout_seconds: float,
    iterations_per_mode: int,
) -> None:
    """Validate an explicit mode budget before compiling or running a probe."""

    if duration_seconds <= 0 or duration_seconds > MAX_DURATION_SECONDS:
        raise DiagnosticError("DURATION", "mode timeout is outside the bounded range")
    if (
        sample_interval_seconds <= 0
        or timeout_seconds <= 0
        or timeout_seconds > MAX_TIMEOUT_SECONDS
    ):
        raise DiagnosticError("TIMEOUT", "diagnostic timeout or sample interval is invalid")
    if (
        iterations_per_mode < MIN_ITERATIONS_PER_MODE
        or iterations_per_mode > MAX_ITERATIONS_PER_MODE
    ):
        raise DiagnosticError(
            "ITERATIONS",
            "mode iteration budget is outside the bounded evidence range",
        )


def mode_iteration_budget(iterations_per_mode: int) -> dict[str, int]:
    """Return explicit per-mode budgets, including a longer fast-path run."""

    if iterations_per_mode < MIN_ITERATIONS_PER_MODE or iterations_per_mode > MAX_ITERATIONS_PER_MODE:
        raise DiagnosticError(
            "ITERATIONS",
            "mode iteration budget is outside the bounded evidence range",
        )
    return {
        mode: CONNECT_CLOSE_ITERATIONS if mode == "connect-close" else iterations_per_mode
        for mode in DIAGNOSTIC_MODES
    }


def _parse_fields(process: Mapping[str, Any]) -> tuple[dict[str, str] | None, str | None]:
    stdout = process.get("stdout")
    if not isinstance(stdout, str) or not stdout:
        return None, None
    try:
        return m0011.parse_result(stdout), None
    except Exception as error:  # retain only a stable class, never a message
        return None, type(error).__name__


def _mode_workload(fields: Mapping[str, str] | None, requested: int) -> dict[str, Any]:
    if fields is None:
        return {
            "mode": None,
            "requested_iterations": requested,
            "iterations": 0,
            "connected": 0,
            "completed": 0,
            "socket_errors": 0,
            "other_errors": 0,
            "close_errors": 0,
            "unknown_mode": "unknown",
            "gc_every_iterations": 0,
            "decision": "INCOMPLETE",
        }
    try:
        values = {
            "mode": fields["mode"],
            "requested_iterations": requested,
            "iterations": int(fields["iterations"]),
            "connected": int(fields["connected"]),
            "completed": int(fields["completed"]),
            "socket_errors": int(fields["socketErrors"]),
            "other_errors": int(fields["otherErrors"]),
            "close_errors": int(fields["closeErrors"]),
            "unknown_mode": fields["unknownMode"],
            "gc_every_iterations": int(fields.get("gcEvery", "-1")),
        }
    except (KeyError, TypeError, ValueError):
        return {
            "mode": fields.get("mode"),
            "requested_iterations": requested,
            "iterations": 0,
            "connected": 0,
            "completed": 0,
            "socket_errors": 0,
            "other_errors": 0,
            "close_errors": 0,
            "unknown_mode": "malformed",
            "gc_every_iterations": -1,
            "decision": "FAIL",
        }
    values["decision"] = "PASS" if (
        values["mode"] == fields["mode"]
        and values["unknown_mode"] == "false"
        and values["iterations"] == requested
        and values["completed"] == requested
        and values["other_errors"] == 0
        and values["close_errors"] == 0
        and values["gc_every_iterations"] == m0011.WINDOWS_GC_INTERVAL_ITERATIONS
    ) else "FAIL"
    return values


def _mode_status(
    process: Mapping[str, Any],
    workload: Mapping[str, Any],
    trend: Mapping[str, Any],
    sampler_errors: Mapping[str, int],
    parse_error_class: str | None,
    server_error_class: str | None,
) -> str:
    """Classify one mode without allowing a bad process to appear successful."""

    if process.get("timed_out"):
        return "INCOMPLETE"
    if parse_error_class or server_error_class or process.get("exit_code") != 0:
        return "FAIL"
    if workload.get("decision") != "PASS":
        return "FAIL"
    if trend.get("decision") == "FAIL" or sampler_errors:
        return "FAIL"
    if trend.get("decision") != "PASS":
        return "INCOMPLETE"
    return "PASS"


def _mode_report(
    binary: Path,
    artifact_dir: Path,
    mode: str,
    requested_iterations: int,
    timeout_seconds: float,
    sample_interval_seconds: float,
) -> dict[str, Any]:
    sampler = m0011.WindowsProcessSampler(sample_interval_seconds)
    process: dict[str, Any] = {}
    server_error_class: str | None = None
    server: m0011.StressServer | None = None
    started = time.monotonic_ns()
    try:
        with m0011.StressServer(mode, sys.maxsize, min(30.0, timeout_seconds)) as active_server:
            server = active_server
            process = m0011.run_process(
                diagnostic_command(binary, mode, active_server.port, requested_iterations),
                artifact_dir,
                timeout_seconds,
                sampler,
            )
    except Exception as error:  # the report keeps only a stable class
        server_error_class = type(error).__name__
        if not process:
            process = {
                "command": [str(binary), mode],
                "exit_code": None,
                "timed_out": False,
                "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
                "stdout": "",
                "stderr": "",
            }
    fields, parse_error_class = _parse_fields(process)
    workload = _mode_workload(fields, requested_iterations)
    samples = sampler.samples
    trend = m0011.resource_trend(samples)
    workload["server_accepted"] = server.accepted if server is not None else 0
    workload["timed_out"] = bool(process.get("timed_out"))
    status = _mode_status(
        process,
        workload,
        trend,
        sampler.error_codes,
        parse_error_class,
        server_error_class,
    )
    return {
        "mode": mode,
        "status": status,
        "ownership_basis": "public-cangjie-std.net-probe",
        "workload": workload,
        "process": {
            key: value
            for key, value in process.items()
            if key not in {"stdout", "stderr"}
        },
        "output": {
            "stdout": m0011.bounded_text(process.get("stdout"), 16_384),
            "stderr": m0011.bounded_text(process.get("stderr"), 16_384),
        },
        "resources": {
            "coverage": {
                "rss_kib": "MEASURED_BY_WIN32",
                "private_kib": "MEASURED_BY_WIN32",
                "handle_count": "MEASURED_BY_WIN32",
                "thread_count": "MEASURED_BY_POWERSHELL",
                "socket_count": "MEASURED_BY_NETSTAT",
            },
            "aggregate": m0011.resource_aggregate(samples),
            "trend": trend,
            "samples": samples,
            "sampler_errors": dict(sampler.error_codes),
        },
        "diagnostics": {
            "parse_error_class": parse_error_class,
            "server_error_class": server_error_class,
        },
    }


def run_diagnostics(
    root: Path,
    artifact_dir: Path,
    revision: str,
    duration_seconds: int,
    sample_interval_seconds: float,
    timeout_seconds: float,
    iterations_per_mode: int = DEFAULT_ITERATIONS_PER_MODE,
) -> dict[str, Any]:
    environment = environment_report(revision)
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "report_kind": REPORT_KIND,
        "platform": PLATFORM_ID,
        "classification": "WINDOWS_MODE_ISOLATION",
        "status": "BLOCKED",
        "generated_at_utc": utc_now(),
        "revision": revision,
        "environment": environment,
        "diagnostic_duration_seconds": duration_seconds,
        "sample_interval_seconds": sample_interval_seconds,
        "diagnostic_budget": {
            "mode_timeout_seconds": duration_seconds,
            "compile_timeout_seconds": timeout_seconds,
            "iterations_per_mode": iterations_per_mode,
            "sample_interval_seconds": sample_interval_seconds,
            "budget_is_explicit": True,
        },
        "m0_011_resource_limits": dict(m0011.RESOURCE_LIMITS),
        "modes": [],
        "non_claims": [
            "diagnostic results do not replace the M0-011 four-hour profile",
            "the public std.net probe is not Wirestack production-path evidence",
            "no runtime/std/SDK source is modified by this task",
        ],
    }
    if environment["status"] != "READY":
        report["blockers"] = environment["blockers"]
        return report
    if SHA_RE.fullmatch(revision) is None:
        report["blockers"] = [{"code": "REVISION", "detail": "full lowercase repository SHA is required"}]
        return report
    validate_budget(
        duration_seconds,
        sample_interval_seconds,
        timeout_seconds,
        iterations_per_mode,
    )
    iterations_by_mode = mode_iteration_budget(iterations_per_mode)
    report["diagnostic_budget"]["iterations_by_mode"] = iterations_by_mode
    artifact_dir.mkdir(parents=True, exist_ok=True)
    binary, compile_info = m0011.compile_probe(root, artifact_dir, timeout_seconds)
    modes: list[dict[str, Any]] = []
    for mode in DIAGNOSTIC_MODES:
        modes.append(
            _mode_report(
                binary,
                artifact_dir,
                mode,
                iterations_by_mode[mode],
                float(duration_seconds),
                sample_interval_seconds,
            )
        )
    report["compile"] = compile_info
    report["requested_iterations_per_mode"] = iterations_per_mode
    report["requested_iterations_by_mode"] = iterations_by_mode
    report["modes"] = modes
    report["status"] = "PASS" if all(item["status"] == "PASS" for item in modes) else (
        "INCOMPLETE" if any(item["status"] == "INCOMPLETE" for item in modes) else "FAIL"
    )
    report["blockers"] = [] if report["status"] == "PASS" else [
        {
            "code": "MODE_DIAGNOSTIC_ASSERTION",
            "detail": "one or more isolated modes did not establish bounded resources",
        }
    ]
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--environment-only", action="store_true")
    modes.add_argument("--run", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, default=Path("build/gates/m0-025-windows-resource-diagnostics"))
    parser.add_argument("--duration-seconds", type=int, default=DEFAULT_DURATION_SECONDS)
    parser.add_argument(
        "--iterations-per-mode",
        type=int,
        default=DEFAULT_ITERATIONS_PER_MODE,
    )
    parser.add_argument("--sample-interval-seconds", type=float, default=DEFAULT_SAMPLE_INTERVAL_SECONDS)
    parser.add_argument("--timeout-seconds", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--repository-revision", default=os.environ.get("GITHUB_SHA", "unknown"))
    args = parser.parse_args(argv)
    output = args.output.resolve()
    if args.environment_only:
        report = environment_report(str(args.repository_revision))
        atomic_json(output, report)
        print(f"M0-025 Windows diagnostic environment: {report['status']}")
        return 0 if report["status"] == "READY" else 3
    try:
        report = run_diagnostics(
            Path(__file__).resolve().parents[2],
            args.artifact_dir.resolve(),
            str(args.repository_revision),
            args.duration_seconds,
            args.sample_interval_seconds,
            args.timeout_seconds,
            args.iterations_per_mode,
        )
        atomic_json(output, report)
        print(f"M0-025 Windows resource diagnostics: {report['status']}")
        return 0 if report["status"] in {"PASS", "FAIL", "INCOMPLETE"} else 3
    except DiagnosticError as error:
        report = {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "report_kind": REPORT_KIND,
            "platform": PLATFORM_ID,
            "status": "FAIL",
            "revision": str(args.repository_revision),
            "error_code": error.code,
            "non_claims": ["diagnostic command failed before acceptance"],
        }
        atomic_json(output, report)
        print(f"M0-025 Windows resource diagnostics: FAIL ({error.code})")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
