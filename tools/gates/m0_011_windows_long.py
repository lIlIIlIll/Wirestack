#!/usr/bin/env python3
"""Run the bounded Windows 4-hour supplemental profile for GATE-NET-06.

The global M0-011 contract still requires a 24-hour Linux release-candidate
soak and native evidence on every required platform.  This runner records one
truthful Windows x86_64 profile with a four-hour duration; it never promotes
that profile to global M0-011 completion.
"""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import sys
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from tools import evidence_digest
from tools.gates.net06_leak_soak import StressServer, parse_result, run_process
from tools.gates.net06_leak_soak_sources import STRESS_SOURCE

import argparse
import ctypes
import datetime as dt
import json
import math
import os
import platform
import re
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Any, Mapping, Sequence


TASK_ID = "M0-011"
SCHEMA_VERSION = 1
REPORT_KIND = "windows-gate-net06-4h"
PLATFORM_ID = "windows-x86_64"
REQUIRED_DURATION_SECONDS = 4 * 60 * 60
MIN_DURATION_TOLERANCE_SECONDS = 5
DEFAULT_SAMPLE_INTERVAL_SECONDS = 10.0
MAX_CAPTURE_BYTES = 32 * 1024
MAX_SAMPLES = 20_000
WINDOWS_GC_INTERVAL_ITERATIONS = 256

RESOURCE_LIMITS = {
    "rss_kib": 8 * 1024,
    "private_kib": 8 * 1024,
    "handle_count": 8,
    "thread_count": 2,
    "socket_count": 4,
}

EXIT_CODES = {"READY": 0, "PASS": 0, "FAIL": 1, "BLOCKED": 3}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class GateError(RuntimeError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def windows_probe_source() -> str:
    """Add Windows-only collection checkpoints without changing Linux probes."""

    source = STRESS_SOURCE
    replacements = (
        (
            "import std.net.*\n",
            "import std.net.*\nimport std.runtime.*\n",
            1,
        ),
        (
            "    let requested = Int64.parse(args[2])\n",
            "    let requested = Int64.parse(args[2])\n"
            "    let gcEvery = Int64.parse(args[3])\n"
            "    if (gcEvery <= 0) {\n"
            "        throw IllegalArgumentException(\"gc cadence must be positive\")\n"
            "    }\n",
            1,
        ),
        (
            "        iteration += 1\n",
            "        iteration += 1\n"
            "        if (iteration % gcEvery == 0) {\n"
            "            gc(heavy: true)\n"
            "        }\n",
            1,
        ),
        (
            "requested=${requested} iterations=${iteration}",
            "requested=${requested} gcEvery=${gcEvery} iterations=${iteration}",
            2,
        ),
    )
    for old, new, expected_count in replacements:
        if source.count(old) != expected_count:
            raise GateError("PROBE_SOURCE_TEMPLATE", "Windows probe template drifted")
        source = source.replace(old, new)
    return source


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def bounded_text(value: str | bytes | None, limit: int = MAX_CAPTURE_BYTES) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    return value[:limit]


def command_version(argv: Sequence[str]) -> str | None:
    if not argv or shutil.which(argv[0]) is None:
        return None
    try:
        result = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    output = bounded_text(result.stdout)
    return output.strip() or None


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    evidence_digest.atomic_json(path, value)


def environment_report(revision: str) -> dict[str, Any]:
    is_windows = platform.system() == "Windows" and os.name == "nt"
    machine = platform.machine()
    shell = shutil.which("pwsh") or shutil.which("powershell")
    tools = {
        name: shutil.which(name)
        for name in ("cjc", "cjpm", "netstat", "pwsh", "powershell")
    }
    if shell is not None:
        tools["shell"] = shell
    blockers: list[dict[str, str]] = []
    if not is_windows:
        blockers.append({"code": "NON_NATIVE_WINDOWS", "detail": platform.platform()})
    if machine.upper() not in {"AMD64", "X86_64"}:
        blockers.append({"code": "ARCHITECTURE", "detail": machine})
    for name in ("cjc", "cjpm", "netstat"):
        if tools[name] is None:
            blockers.append({"code": f"{name.upper()}_UNAVAILABLE", "detail": name})
    if shell is None:
        blockers.append({"code": "POWERSHELL_UNAVAILABLE", "detail": "pwsh or powershell"})
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "report_kind": "windows-gate-net06-4h-environment",
        "status": "READY" if not blockers else "BLOCKED",
        "generated_at_utc": utc_now(),
        "repository_revision": revision,
        "runner": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": machine,
            "platform": platform.platform(),
            "github_actions": os.environ.get("GITHUB_ACTIONS") == "true",
            "runner_name": os.environ.get("RUNNER_NAME"),
            "runner_os": os.environ.get("RUNNER_OS"),
            "runner_arch": os.environ.get("RUNNER_ARCH"),
            "image_os": os.environ.get("ImageOS"),
            "image_version": os.environ.get("ImageVersion"),
        },
        "toolchain": {
            "cjc": command_version(("cjc", "--version"))
            or command_version(("cjc", "-v")),
            "cjpm": command_version(("cjpm", "--version")),
        },
        "tools": tools,
        "blockers": blockers,
        "non_claims": [
            "environment readiness is not four-hour acceptance",
            "cross-compilation is not native Windows evidence",
            "this profile does not close global M0-011",
        ],
    }


class WindowsProcessSampler:
    """Bounded process metrics available through documented Win32 APIs."""

    def __init__(self, interval_seconds: float):
        self.interval_seconds = interval_seconds
        self.samples: list[dict[str, int]] = []
        self.error_codes: dict[str, int] = {}
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._handle: int | None = None
        self._pid: int | None = None
        self._kernel32: Any | None = None
        self._psapi: Any | None = None

    def _error(self, code: str) -> None:
        self.error_codes[code] = self.error_codes.get(code, 0) + 1

    @staticmethod
    def _thread_count(pid: int) -> int | None:
        shell = shutil.which("pwsh") or shutil.which("powershell")
        if shell is None:
            return None
        command = [
            shell,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            f"$p=Get-Process -Id {pid} -ErrorAction Stop; [Console]::Write($p.Threads.Count)",
        ]
        try:
            result = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                errors="replace",
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        value = result.stdout.strip()
        if result.returncode != 0 or re.fullmatch(r"[0-9]+", value) is None:
            return None
        return int(value)

    @staticmethod
    def _socket_count(pid: int) -> int | None:
        try:
            result = subprocess.run(
                ["netstat", "-ano", "-p", "tcp"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                errors="replace",
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        count = 0
        for line in result.stdout.splitlines():
            fields = line.split()
            if fields and fields[-1].isdigit() and int(fields[-1]) == pid:
                count += 1
        return count

    def start(self, pid: int) -> None:
        if platform.system() != "Windows" or os.name != "nt":
            self._error("NON_NATIVE_WINDOWS")
            return
        try:
            self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            self._psapi = ctypes.WinDLL("psapi", use_last_error=True)
            self._kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
            self._kernel32.OpenProcess.restype = ctypes.c_void_p
            self._kernel32.GetProcessHandleCount.argtypes = [
                ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_ulong),
            ]
            self._kernel32.GetProcessHandleCount.restype = ctypes.c_int

            class Counters(ctypes.Structure):
                _fields_ = [
                    ("cb", ctypes.c_ulong),
                    ("PageFaultCount", ctypes.c_ulong),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t),
                    ("PrivateUsage", ctypes.c_size_t),
                ]

            self._counters_type = Counters
            self._psapi.GetProcessMemoryInfo.argtypes = [
                ctypes.c_void_p,
                ctypes.POINTER(Counters),
                ctypes.c_ulong,
            ]
            self._psapi.GetProcessMemoryInfo.restype = ctypes.c_int
            handle = self._kernel32.OpenProcess(0x1000 | 0x0010, 0, pid)
            if not handle:
                self._error("OPEN_PROCESS")
                return
            self._handle = int(handle)
            self._pid = pid
        except (AttributeError, OSError):
            self._error("WIN32_API_UNAVAILABLE")
            return

        self._stop.clear()
        started = time.monotonic_ns()

        def sample_once() -> None:
            if self._handle is None or self._pid is None:
                return
            counters = self._counters_type()
            counters.cb = ctypes.sizeof(counters)
            if not self._psapi.GetProcessMemoryInfo(
                ctypes.c_void_p(self._handle), ctypes.byref(counters), counters.cb
            ):
                self._error("MEMORY_QUERY")
                return
            handles = ctypes.c_ulong()
            if not self._kernel32.GetProcessHandleCount(
                ctypes.c_void_p(self._handle), ctypes.byref(handles)
            ):
                self._error("HANDLE_QUERY")
                return
            threads = self._thread_count(self._pid)
            sockets = self._socket_count(self._pid)
            if threads is None:
                self._error("THREAD_QUERY")
                return
            if sockets is None:
                self._error("SOCKET_QUERY")
                return
            if len(self.samples) >= MAX_SAMPLES:
                self._error("SAMPLE_BOUND")
                return
            self.samples.append(
                {
                    "elapsed_ms": int((time.monotonic_ns() - started) / 1_000_000),
                    "rss_kib": int(counters.WorkingSetSize // 1024),
                    "private_kib": int(counters.PrivateUsage // 1024),
                    "handle_count": int(handles.value),
                    "thread_count": int(threads),
                    "socket_count": int(sockets),
                }
            )

        def sample_loop() -> None:
            sample_once()
            while not self._stop.wait(self.interval_seconds):
                sample_once()

        self._thread = threading.Thread(target=sample_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(15)
            if self._thread.is_alive():
                self._error("SAMPLER_STUCK")
        if self._handle is not None and self._kernel32 is not None:
            self._kernel32.CloseHandle(ctypes.c_void_p(self._handle))
            self._handle = None


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(1, math.ceil(percent / 100.0 * len(ordered))) - 1
    return round(ordered[index], 3)


def median(values: Sequence[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def resource_aggregate(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    result: dict[str, Any] = {"sample_count": len(samples)}
    for name in RESOURCE_LIMITS:
        values = [float(item[name]) for item in samples if name in item]
        result[name] = {
            "first": values[0] if values else None,
            "last": values[-1] if values else None,
            "min": min(values) if values else None,
            "max": max(values) if values else None,
            "p50": percentile(values, 50),
            "p95": percentile(values, 95),
            "p99": percentile(values, 99),
        }
    return result


def resource_trend(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    if len(samples) < 20:
        return {"decision": "INCONCLUSIVE", "reason": "fewer than 20 samples"}
    warmup = max(1, len(samples) // 5)
    steady = samples[warmup:]
    window = max(1, len(steady) // 5)
    first = steady[:window]
    last = steady[-window:]
    metrics: dict[str, Any] = {}
    passed = True
    for name, limit in RESOURCE_LIMITS.items():
        first_value = median([float(item[name]) for item in first])
        last_value = median([float(item[name]) for item in last])
        growth = last_value - first_value
        metric = {
            "first_median": first_value,
            "last_median": last_value,
            "growth": growth,
            "growth_limit": limit,
        }
        metrics[name] = metric
        passed = passed and growth <= limit
    return {
        "decision": "PASS" if passed else "FAIL",
        "warmup_samples_excluded": warmup,
        "comparison_window_samples": window,
        "metrics": metrics,
    }


def compile_probe(root: Path, artifact_dir: Path, timeout: float) -> tuple[Path, dict[str, Any]]:
    probe_dir = artifact_dir / "probe"
    probe_dir.mkdir(parents=True, exist_ok=True)
    source = probe_dir / "net06_stress_windows.cj"
    binary = probe_dir / "net06_stress_windows.exe"
    source.write_text(windows_probe_source(), encoding="utf-8", newline="\n")
    process = run_process(
        ["cjc", "-O2", str(source), "-o", str(binary)], probe_dir, timeout
    )
    if process["timed_out"] or process["exit_code"] != 0 or not binary.is_file():
        raise GateError("PROBE_COMPILE", "native Windows stress probe compilation failed")
    return binary, {
        "source_sha256": evidence_digest.text_evidence_sha256(source),
        "process": process,
        "binary_sha256": evidence_digest.artifact_byte_sha256(binary),
    }


def empty_report(revision: str, environment: Mapping[str, Any], status: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "report_kind": REPORT_KIND,
        "platform": PLATFORM_ID,
        "status": status,
        "global_gate_status": "INCOMPLETE",
        "classification": "WINDOWS_SUPPLEMENTAL_4H",
        "generated_at_utc": utc_now(),
        "repository_revision": revision,
        "requested_duration_seconds": REQUIRED_DURATION_SECONDS,
        "environment": dict(environment),
        "non_claims": [
            "not full GATE-NET-06 completion",
            "does not replace the required 24-hour Linux release-candidate soak",
            "does not close M0-012 or other native-platform requirements",
        ],
    }


def execute_profile(
    root: Path,
    artifact_dir: Path,
    revision: str,
    duration_seconds: int,
    sample_interval_seconds: float,
    timeout_seconds: float,
) -> dict[str, Any]:
    environment = environment_report(revision)
    report = empty_report(revision, environment, "BLOCKED")
    if environment["status"] != "READY":
        report["blockers"] = environment["blockers"]
        return report
    if SHA_RE.fullmatch(revision) is None:
        report["blockers"] = [
            {"code": "REVISION", "detail": "full lowercase repository SHA is required"}
        ]
        return report
    if duration_seconds < REQUIRED_DURATION_SECONDS:
        report["blockers"] = [
            {
                "code": "DURATION_TOO_SHORT",
                "detail": f"requires {REQUIRED_DURATION_SECONDS} seconds",
            }
        ]
        return report
    if sample_interval_seconds <= 0 or timeout_seconds <= 0:
        raise GateError("ARGUMENT", "sample interval and timeout must be positive")

    artifact_dir.mkdir(parents=True, exist_ok=True)
    binary, compile_info = compile_probe(root, artifact_dir, timeout_seconds)
    sampler = WindowsProcessSampler(sample_interval_seconds)
    process: dict[str, Any]
    server: StressServer | None = None
    server_error: str | None = None
    started = time.monotonic_ns()
    try:
        with StressServer("mixed-soak", sys.maxsize, min(30.0, timeout_seconds)) as active_server:
            server = active_server
            process = run_process(
                [
                    str(binary),
                    "mixed-soak",
                    str(server.port),
                    str(duration_seconds),
                    str(WINDOWS_GC_INTERVAL_ITERATIONS),
                ],
                artifact_dir / "probe",
                duration_seconds + int(timeout_seconds),
                sampler,
            )
    except Exception as error:  # the report records a stable class, not exception text
        process = {
            "command": [str(binary), "mixed-soak"],
            "exit_code": None,
            "timed_out": False,
            "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
            "stdout": "",
            "stderr": "",
        }
        server_error = type(error).__name__

    fields: dict[str, str] | None = None
    parse_error: str | None = None
    if process["stdout"]:
        try:
            fields = parse_result(process["stdout"])
        except Exception as error:  # stable class only
            parse_error = type(error).__name__

    gc_every_iterations = 0
    if fields and "gcEvery" in fields:
        try:
            gc_every_iterations = int(fields["gcEvery"])
        except (TypeError, ValueError):
            gc_every_iterations = -1
    workload: dict[str, Any] = {
        "mode": "mixed-soak",
        "requested_seconds": duration_seconds,
        "actual_duration_ns": int(fields["durationNs"]) if fields else 0,
        "iterations": int(fields["iterations"]) if fields else 0,
        "connected": int(fields["connected"]) if fields else 0,
        "completed": int(fields["completed"]) if fields else 0,
        "socket_errors": int(fields["socketErrors"]) if fields else 0,
        "other_errors": int(fields["otherErrors"]) if fields else 0,
        "eof": int(fields["eof"]) if fields else 0,
        "close_errors": int(fields["closeErrors"]) if fields else 0,
        "unknown_mode": fields["unknownMode"] if fields else "unknown",
        "gc_every_iterations": gc_every_iterations,
    }
    samples = sampler.samples
    trend = resource_trend(samples)
    minimum_samples = max(20, int(duration_seconds / sample_interval_seconds * 0.75))
    duration_ok = workload["actual_duration_ns"] >= (
        duration_seconds - MIN_DURATION_TOLERANCE_SECONDS
    ) * 1_000_000_000
    workload_ok = (
        fields is not None
        and process["exit_code"] == 0
        and not process["timed_out"]
        and server is not None
        and server_error is None
        and fields["mode"] == "mixed-soak"
        and fields["unknownMode"] == "false"
        and workload["iterations"] > 0
        and workload["completed"] == workload["iterations"]
        and workload["other_errors"] == 0
        and workload["close_errors"] == 0
        and workload["gc_every_iterations"] == WINDOWS_GC_INTERVAL_ITERATIONS
        and server.accepted == workload["iterations"]
        and duration_ok
    )
    resources_ok = (
        len(samples) >= minimum_samples
        and not sampler.error_codes
        and trend["decision"] == "PASS"
    )
    status = "PASS" if workload_ok and resources_ok else "FAIL"
    if parse_error is not None or server_error is not None:
        status = "FAIL"
    report.update(
        {
            "status": status,
            "requested_duration_seconds": duration_seconds,
            "sample_interval_seconds": sample_interval_seconds,
            "minimum_samples": minimum_samples,
            "compile": compile_info,
            "process": process,
            "workload": {
                **workload,
                "server_accepted": server.accepted if server is not None else 0,
                "decision": "PASS" if workload_ok else "FAIL",
            },
            "resources": {
                "coverage": {
                    "rss_kib": "MEASURED_BY_WIN32",
                    "private_kib": "MEASURED_BY_WIN32",
                    "handle_count": "MEASURED_BY_WIN32",
                    "thread_count": "MEASURED_BY_POWERSHELL",
                    "socket_count": "MEASURED_BY_NETSTAT",
                },
                "aggregate": resource_aggregate(samples),
                "trend": trend,
                "samples": samples,
                "sampler_errors": sampler.error_codes,
            },
            "diagnostics": {
                "parse_error_class": parse_error,
                "server_error_class": server_error,
            },
            "blockers": [] if status == "PASS" else [
                {"code": "WORKLOAD_OR_RESOURCE_ASSERTION", "detail": "profile did not satisfy all bounded assertions"}
            ],
        }
    )
    return report


def _contains_skipped(value: Any) -> bool:
    if isinstance(value, dict):
        for key, item in value.items():
            if (
                key in {"status", "decision", "acceptance_status"}
                and isinstance(item, str)
                and item in {"SKIPPED", "NOT_RUN"}
            ):
                return True
            if _contains_skipped(item):
                return True
    elif isinstance(value, list):
        return any(_contains_skipped(item) for item in value)
    return False


def _finite_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _strict_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_result(report: Any, expected_revision: str | None = None) -> dict[str, Any]:
    if not isinstance(report, dict):
        raise GateError("REPORT_TYPE", "report must be an object")
    if report.get("schema_version") != SCHEMA_VERSION:
        raise GateError("UNKNOWN_SCHEMA", "unsupported report schema")
    if report.get("task_id") != TASK_ID:
        raise GateError("TASK_ID", "wrong source task")
    if report.get("report_kind") != REPORT_KIND:
        raise GateError("REPORT_KIND", "wrong report kind")
    if report.get("platform") != PLATFORM_ID:
        raise GateError("PLATFORM", "wrong native platform")
    if report.get("classification") != "WINDOWS_SUPPLEMENTAL_4H":
        raise GateError("CLASSIFICATION", "report is not the Windows supplemental profile")
    if report.get("global_gate_status") != "INCOMPLETE":
        raise GateError("SCOPE", "supplemental profile cannot claim global completion")
    if report.get("status") != "PASS":
        raise GateError("STATUS", "report does not claim PASS")
    revision = report.get("repository_revision")
    if not isinstance(revision, str) or SHA_RE.fullmatch(revision) is None:
        raise GateError("REVISION", "full lowercase repository SHA is required")
    if expected_revision is not None and revision != expected_revision:
        raise GateError("STALE_REVISION", "report revision differs")
    environment = report.get("environment")
    runner = environment.get("runner") if isinstance(environment, dict) else None
    if not isinstance(runner, dict) or runner.get("system") != "Windows":
        raise GateError("NON_NATIVE_WINDOWS", "native Windows runner identity is missing")
    if str(runner.get("machine", "")).upper() not in {"AMD64", "X86_64"}:
        raise GateError("ARCHITECTURE", "native Windows x86_64 identity is missing")
    if report.get("requested_duration_seconds") != REQUIRED_DURATION_SECONDS:
        raise GateError("DURATION", "profile duration is not four hours")
    workload = report.get("workload")
    if not isinstance(workload, dict):
        raise GateError("WORKLOAD", "workload report is missing")
    if workload.get("mode") != "mixed-soak":
        raise GateError("WORKLOAD_MODE", "mixed-soak workload is required")
    if not _strict_int(workload.get("actual_duration_ns")) or workload["actual_duration_ns"] < (
        REQUIRED_DURATION_SECONDS - MIN_DURATION_TOLERANCE_SECONDS
    ) * 1_000_000_000:
        raise GateError("DURATION", "actual workload duration is shorter than four hours")
    if workload.get("decision") != "PASS":
        raise GateError("WORKLOAD_STATUS", "workload did not pass")
    for key in ("iterations", "connected", "completed", "server_accepted"):
        if not _strict_int(workload.get(key)) or workload[key] <= 0:
            raise GateError("WORKLOAD_COUNT", f"invalid workload count: {key}")
    if workload["completed"] != workload["iterations"] or workload["server_accepted"] != workload["iterations"]:
        raise GateError("WORKLOAD_COUNT", "server and client counts differ")
    if workload.get("other_errors") != 0 or workload.get("close_errors") != 0:
        raise GateError("WORKLOAD_ERRORS", "workload contains non-terminal errors")
    if workload.get("unknown_mode") != "false":
        raise GateError("WORKLOAD_MODE", "unknown mode marker is not false")
    if workload.get("gc_every_iterations") != WINDOWS_GC_INTERVAL_ITERATIONS:
        raise GateError("PROBE_CLEANUP", "Windows probe did not prove its GC cadence")
    resources = report.get("resources")
    if not isinstance(resources, dict):
        raise GateError("RESOURCES", "resource report is missing")
    coverage = resources.get("coverage")
    if not isinstance(coverage, dict) or any(
        coverage.get(key) not in {
            "MEASURED_BY_WIN32",
            "MEASURED_BY_POWERSHELL",
            "MEASURED_BY_NETSTAT",
        }
        for key in RESOURCE_LIMITS
    ):
        raise GateError("RESOURCES", "required resource metrics are not measured")
    sample_interval = report.get("sample_interval_seconds")
    if not _finite_number(sample_interval) or sample_interval <= 0:
        raise GateError("SAMPLES", "sample interval is invalid")
    minimum_samples = max(20, int(REQUIRED_DURATION_SECONDS / sample_interval * 0.75))
    if report.get("minimum_samples") != minimum_samples:
        raise GateError("SAMPLES", "minimum sample count is not derived from the profile")
    samples = resources.get("samples")
    if not isinstance(samples, list) or len(samples) < minimum_samples:
        raise GateError("SAMPLES", "resource sample series is incomplete")
    previous = -1
    for sample in samples:
        if not isinstance(sample, dict) or any(
            not _strict_int(sample.get(key)) for key in ("elapsed_ms", *RESOURCE_LIMITS)
        ):
            raise GateError("SAMPLES", "resource sample entry is invalid")
        if any(sample[key] < 0 for key in ("elapsed_ms", *RESOURCE_LIMITS)):
            raise GateError("SAMPLES", "resource sample contains a negative value")
        if sample["elapsed_ms"] < previous:
            raise GateError("SAMPLES", "resource sample time regressed")
        previous = sample["elapsed_ms"]
    aggregate = resources.get("aggregate")
    if aggregate != resource_aggregate(samples):
        raise GateError("RESOURCE_AGGREGATE", "resource aggregate does not match samples")
    if resources.get("trend") != resource_trend(samples):
        raise GateError("RESOURCE_TREND", "resource trend did not pass")
    if resources.get("sampler_errors"):
        raise GateError("RESOURCE_QUERY", "resource sampler reported an error")
    if _contains_skipped(report):
        raise GateError("SKIPPED_AS_PASS", "SKIPPED/NOT_RUN cannot be recorded as PASS")
    non_claims = report.get("non_claims")
    if not isinstance(non_claims, list) or "not full GATE-NET-06 completion" not in non_claims:
        raise GateError("NON_CLAIMS", "global non-claim is missing")
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--environment-only", action="store_true")
    modes.add_argument("--run", action="store_true")
    modes.add_argument("--validate-report", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, default=Path("build/gates/m0-011-windows-long"))
    parser.add_argument("--duration-seconds", type=int, default=REQUIRED_DURATION_SECONDS)
    parser.add_argument("--sample-interval-seconds", type=float, default=DEFAULT_SAMPLE_INTERVAL_SECONDS)
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument("--repository-revision", default=os.environ.get("GITHUB_SHA", "unknown"))
    parser.add_argument("--expected-revision")
    args = parser.parse_args(argv)
    output = args.output.resolve()
    revision = str(args.repository_revision)
    if args.environment_only:
        report = environment_report(revision)
        atomic_json(output, report)
        print(f"M0-011 Windows environment: {report['status']}")
        return EXIT_CODES[report["status"]]
    if args.run:
        try:
            report = execute_profile(
                Path(__file__).resolve().parents[2],
                args.artifact_dir.resolve(),
                revision,
                args.duration_seconds,
                args.sample_interval_seconds,
                args.timeout_seconds,
            )
        except GateError as error:
            report = {
                "schema_version": SCHEMA_VERSION,
                "task_id": TASK_ID,
                "report_kind": REPORT_KIND,
                "platform": PLATFORM_ID,
                "status": "FAIL",
                "global_gate_status": "INCOMPLETE",
                "classification": "WINDOWS_SUPPLEMENTAL_4H",
                "repository_revision": revision,
                "error_code": error.code,
                "non_claims": ["not full GATE-NET-06 completion"],
            }
        atomic_json(output, report)
        print(f"M0-011 Windows 4-hour profile: {report['status']}")
        return EXIT_CODES.get(report["status"], 1)
    try:
        raw = json.loads(args.validate_report.resolve().read_text(encoding="utf-8"))
        expected_revision = args.expected_revision
        if expected_revision is None and revision != "unknown":
            expected_revision = revision
        validate_result(raw, expected_revision)
        validation = {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "report_kind": REPORT_KIND,
            "status": "PASS",
            "expected_revision": expected_revision or raw["repository_revision"],
            "report_sha256": evidence_digest.text_evidence_sha256(args.validate_report.resolve()),
            "failures": [],
        }
        atomic_json(output, validation)
        print("M0-011 Windows 4-hour report validation: PASS")
        return 0
    except (OSError, json.JSONDecodeError, GateError) as error:
        if isinstance(error, GateError):
            code = error.code
        elif isinstance(error, json.JSONDecodeError):
            code = "REPORT_JSON"
        else:
            code = "REPORT_IO"
        validation = {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "report_kind": REPORT_KIND,
            "status": "FAIL",
            "failures": [code],
        }
        atomic_json(output, validation)
        print(f"M0-011 Windows 4-hour report validation: FAIL: {code}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
