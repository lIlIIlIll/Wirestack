#!/usr/bin/env python3
"""Native Windows capability probe and strict M0-014 report validator."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Mapping, Sequence

GATE_DIR = Path(__file__).resolve().parent
if str(GATE_DIR) not in sys.path:
    sys.path.insert(0, str(GATE_DIR))

from net05_large_buffer_profile import (
    StreamServer,
    parse_probe_output,
    percentile,
    run_process,
)
from net05_large_buffer_profile_sources import RECEIVE_SOURCE


SCHEMA_VERSION = 1
EXIT = {"READY": 0, "PASS": 0, "FAIL": 1, "INVALID": 2, "BLOCKED": 3}
REQUIRED_PAYLOADS = (1024, 16 * 1024, 64 * 1024, 1024 * 1024, 100 * 1024 * 1024)
CAPTURE_LIMIT = 8192
XPERF_TOTAL_RE = re.compile(
    r"^\s*([0-9][0-9,]*)\s*,(?:[^\r\n]*,){6}\s*TOTAL\s*$",
    re.IGNORECASE | re.MULTILINE,
)


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
        for name in (
            "cjc", "cjpm", "wpr", "xperf", "wpaexporter", "tracerpt",
            "clang", "dumpbin", "llvm-objdump", "llvm-nm", "objdump", "nm",
        )
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


class WindowsMemorySampler:
    """Sample process memory through the documented PSAPI structure."""

    def __init__(self, interval_seconds: float = 0.005) -> None:
        self.interval_seconds = interval_seconds
        self.working_set_bytes: list[int] = []
        self.private_bytes: list[int] = []
        self.peak_working_set_bytes: list[int] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._handle: int | None = None

    def start(self, pid: int) -> None:
        if os.name != "nt":
            raise GateError("NON_NATIVE_WINDOWS", "Win32 memory sampler requires Windows")

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

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        psapi.GetProcessMemoryInfo.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong,
        ]
        psapi.GetProcessMemoryInfo.restype = ctypes.c_int
        handle = kernel32.OpenProcess(0x1000 | 0x0010, 0, pid)
        if not handle:
            raise GateError("WIN32_OPEN_PROCESS", f"OpenProcess failed: {ctypes.get_last_error()}")
        self._handle = int(handle)
        self._stop.clear()

        def sample_once() -> None:
            counters = Counters()
            counters.cb = ctypes.sizeof(counters)
            if psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                self.working_set_bytes.append(int(counters.WorkingSetSize))
                self.private_bytes.append(int(counters.PrivateUsage))
                self.peak_working_set_bytes.append(int(counters.PeakWorkingSetSize))

        def sample() -> None:
            while not self._stop.is_set():
                sample_once()
                self._stop.wait(self.interval_seconds)
            sample_once()

        sample_once()
        self._thread = threading.Thread(target=sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(2)
            if self._thread.is_alive():
                raise GateError("MONITOR_LEAK", "Win32 memory sampler thread leaked")
        if self._handle is not None:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CloseHandle(ctypes.c_void_p(self._handle))
            self._handle = None

    @property
    def peak_private(self) -> int | None:
        return max(self.private_bytes) if self.private_bytes else None

    @property
    def peak_working_set(self) -> int | None:
        values = self.peak_working_set_bytes or self.working_set_bytes
        return max(values) if values else None


def counting_receiver_source() -> str:
    import_marker = "import std.convert.*\n"
    result_marker = (
        'println("RESULT bytes=${total} readCalls=${reads} invalid=${invalid} '
        'eof=${eof} durationNs=${durationNs} closeCode=${closeCode} bufferSize=${bufferSize}")'
    )
    if RECEIVE_SOURCE.count(import_marker) != 1 or RECEIVE_SOURCE.count(result_marker) != 1:
        raise GateError("SOURCE_TEMPLATE", "receiver source markers changed")
    foreign = (
        "\nforeign {\n"
        "    func WIRESTACK_M0014_CopyBytes(): UInt64\n"
        "    func WIRESTACK_M0014_CopyCalls(): UInt64\n"
        "}\n"
    )
    result = (
        "let copiedBytes = unsafe { WIRESTACK_M0014_CopyBytes() }\n"
        "    let copyCalls = unsafe { WIRESTACK_M0014_CopyCalls() }\n"
        "    println(\"RESULT bytes=${total} readCalls=${reads} invalid=${invalid} "
        "eof=${eof} durationNs=${durationNs} closeCode=${closeCode} "
        "bufferSize=${bufferSize} copiedBytes=${copiedBytes} copyCalls=${copyCalls}\")"
    )
    return RECEIVE_SOURCE.replace(import_marker, import_marker + foreign).replace(
        result_marker, result
    )


def compile_receiver(root: Path, artifact_dir: Path,
                     timeout: float) -> tuple[Path, dict[str, Any]]:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    source = artifact_dir / "wirestack_m0_014_receive.cj"
    shim_source = root / "tools/gates/native/m0_014_copy_counter.c"
    shim_object = artifact_dir / "m0_014_copy_counter.o"
    binary = artifact_dir / "wirestack_m0_014_receive.exe"
    receiver_source = counting_receiver_source()
    source.write_text(receiver_source, encoding="utf-8")
    shim_compile = run_process(
        ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-c", str(shim_source), "-o", str(shim_object)],
        artifact_dir, timeout,
    )
    if (shim_compile["timed_out"] or shim_compile["exit_code"] != 0
            or not shim_object.is_file()):
        detail = (shim_compile["stdout"] + "\n" + shim_compile["stderr"]).strip()[:CAPTURE_LIMIT]
        raise GateError("SHIM_COMPILE", f"copy-counter shim compilation failed: {detail}")
    command = [
        "cjc", "-O2", str(source), "-o", str(binary),
        "--link-option", str(shim_object),
        "--link-option", "--wrap=CJ_SOCKET_BufferRCopy",
    ]
    process = run_process(command, artifact_dir, timeout)
    if process["timed_out"] or process["exit_code"] != 0 or not binary.is_file():
        detail = (process["stdout"] + "\n" + process["stderr"]).strip()[:CAPTURE_LIMIT]
        raise GateError("COMPILE", f"native Windows Cangjie receiver compilation failed: {detail}")
    return binary, {
        "source_sha256": hashlib.sha256(receiver_source.encode()).hexdigest(),
        "shim_source_sha256": sha256(shim_source),
        "shim_object_sha256": sha256(shim_object),
        "binary_sha256": sha256(binary),
        "shim_compile": shim_compile,
        "process": process,
    }


def transfer_sample(binary: Path, payload: int, timeout: float) -> dict[str, Any]:
    sampler = WindowsMemorySampler()
    with StreamServer(payload, 64 * 1024, timeout) as server:
        command = [
            str(binary), "127.0.0.1", str(server.port), str(payload), str(64 * 1024), "verbose",
        ]
        process = run_process(command, binary.parent, timeout, sampler)
    reads, fields = parse_probe_output(process["stdout"])
    duration_ns = int(fields["durationNs"])
    exact = (
        int(fields["bytes"]) == payload == server.bytes_sent == sum(reads)
        and int(fields["readCalls"]) == len(reads)
    )
    valid = (
        exact and process["exit_code"] == 0 and not process["timed_out"]
        and int(fields["invalid"]) == 0 and fields["eof"] == "false"
        and int(fields["closeCode"]) == 0 and reads
        and all(0 < value <= 64 * 1024 for value in reads)
        and sampler.peak_private is not None
    )
    return {
        "decision": "PASS" if valid else "FAIL",
        "payload_bytes": payload,
        "bytes_read": int(fields["bytes"]),
        "read_sizes": reads,
        "fixed_4k_cap": payload > 4096 and max(reads, default=0) <= 4096,
        "duration_ms": round(duration_ns / 1_000_000.0, 3),
        "throughput_mib_per_second": round(
            (payload / (1024 * 1024)) / (duration_ns / 1_000_000_000), 3
        ) if duration_ns > 0 else None,
        "peak_private_bytes": sampler.peak_private,
        "peak_working_set_bytes": sampler.peak_working_set,
        "copied_bytes": int(fields["copiedBytes"]),
        "copy_calls": int(fields["copyCalls"]),
        "memory_samples": {
            "private_bytes": sampler.private_bytes,
            "working_set_bytes": sampler.working_set_bytes,
        },
        "server_bytes_sent": server.bytes_sent,
        "process": process,
    }


def run_xperf(command: Sequence[str], cwd: Path, timeout: float) -> dict[str, Any]:
    return run_process(["xperf", *command], cwd, timeout)


def run_wpr(command: Sequence[str], cwd: Path, timeout: float) -> dict[str, Any]:
    return run_process(["wpr", *command], cwd, timeout)


def parse_xperf_allocation_count(text: str) -> int | None:
    matches = XPERF_TOTAL_RE.findall(text)
    if len(matches) != 1:
        return None
    return int(matches[0].replace(",", ""))


def instrumented_transfer(binary: Path, payload: int, artifact_dir: Path,
                          timeout: float) -> dict[str, Any]:
    directory = artifact_dir / f"instrumented-{payload}"
    directory.mkdir(parents=True, exist_ok=True)
    etl = directory / "heap.etl"
    heap_report = directory / "heap.txt"
    commands: list[dict[str, Any]] = []
    run_wpr(["-cancel"], directory, 30)
    configure = run_wpr(["-HeapTracingConfig", binary.name, "enable"], directory, 60)
    commands.append(configure)
    if configure["exit_code"] != 0:
        detail = (configure["stdout"] + "\n" + configure["stderr"]).strip()[:CAPTURE_LIMIT]
        raise GateError("ETW_CONFIG", f"WPR heap tracing config failed: {detail}")
    start = run_wpr(["-start", "Heap", "-filemode"], directory, 60)
    commands.append(start)
    if start["exit_code"] != 0:
        run_wpr(["-HeapTracingConfig", binary.name, "disable"], directory, 30)
        detail = (start["stdout"] + "\n" + start["stderr"]).strip()[:CAPTURE_LIMIT]
        raise GateError("ETW_START", f"WPR heap session failed: {detail}")
    sample: dict[str, Any] | None = None
    try:
        sample = transfer_sample(binary, payload, timeout)
    finally:
        stop = run_wpr(["-stop", str(etl)], directory, 120)
        commands.append(stop)
        disable = run_wpr(["-HeapTracingConfig", binary.name, "disable"], directory, 60)
        commands.append(disable)
    if stop["exit_code"] != 0 or not etl.is_file():
        raise GateError("ETW_STOP", "xperf did not produce heap trace")
    analyze = run_xperf([
        "-i", str(etl), "-o", str(heap_report), "-a", "heap", "-totals",
    ], directory, 180)
    commands.append(analyze)
    text = heap_report.read_text(encoding="utf-8", errors="replace") if heap_report.is_file() else ""
    allocation_count = parse_xperf_allocation_count(text)
    return {
        "sample": sample,
        "allocation_count": allocation_count,
        "allocation_status": "MEASURED_BY_ETW_HEAP" if allocation_count else "ETW_UNPARSED",
        "etl_sha256": sha256(etl),
        "heap_report": text[:1024 * 1024],
        "heap_report_sha256": sha256(heap_report) if heap_report.is_file() else None,
        "commands": commands,
    }


def aggregate_case(payload: int, samples: Sequence[Mapping[str, Any]],
                   instrumented: Mapping[str, Any]) -> dict[str, Any]:
    latency = [float(sample["duration_ms"]) for sample in samples]
    throughput = [float(sample["throughput_mib_per_second"]) for sample in samples]
    representative = instrumented["sample"]
    copy_measured = (
        representative["copied_bytes"] == payload
        and representative["copy_calls"] == len(representative["read_sizes"])
    )
    return {
        "payload_bytes": payload,
        "decision": "PASS" if all(sample["decision"] == "PASS" for sample in samples) else "FAIL",
        "bytes_read": representative["bytes_read"],
        "read_sizes": representative["read_sizes"],
        "fixed_4k_cap": representative["fixed_4k_cap"],
        "allocation_count": instrumented["allocation_count"],
        "allocation_status": instrumented["allocation_status"],
        "peak_private_bytes": max(int(sample["peak_private_bytes"]) for sample in samples),
        "peak_working_set_bytes": max(int(sample["peak_working_set_bytes"]) for sample in samples),
        "copied_bytes_per_operation": representative["copied_bytes"],
        "copy_calls_per_operation": representative["copy_calls"],
        "copied_bytes_status": "MEASURED_BY_LINK_WRAP" if copy_measured else "COPY_COUNTER_INVALID",
        "latency_ms": {key: percentile(latency, value) for key, value in (("p50", 50), ("p95", 95), ("p99", 99))},
        "throughput_mib_per_second": {key: percentile(throughput, value) for key, value in (("p50", 50), ("p95", 95), ("p99", 99))},
        "samples": list(samples),
        "instrumentation": dict(instrumented),
    }


def execute_profile(root: Path, artifact_dir: Path, revision: str, repetitions: int,
                    timeout: float, quick: bool) -> dict[str, Any]:
    if platform.system() != "Windows" or os.name != "nt":
        raise GateError("NON_NATIVE_WINDOWS", platform.platform())
    if platform.machine().upper() not in {"AMD64", "X86_64"}:
        raise GateError("ARCHITECTURE", platform.machine())
    for tool in ("cjc", "cjpm", "clang", "wpr", "xperf"):
        if shutil.which(tool) is None:
            raise GateError("TOOL_UNAVAILABLE", tool)
    binary, compile_report = compile_receiver(root, artifact_dir / "receiver", timeout)
    payloads = (1024 * 1024,) if quick else REQUIRED_PAYLOADS
    cases = []
    for payload in payloads:
        samples = [transfer_sample(binary, payload, timeout) for _ in range(repetitions)]
        instrumented = instrumented_transfer(binary, payload, artifact_dir, timeout)
        cases.append(aggregate_case(payload, samples, instrumented))
    allocations_measured = all(case["allocation_status"] == "MEASURED_BY_ETW_HEAP" for case in cases)
    copies_measured = all(case["copied_bytes_status"] == "MEASURED_BY_LINK_WRAP" for case in cases)
    blockers = []
    if not allocations_measured:
        blockers.append({"code": "ETW_HEAP_UNPARSED", "detail": "allocation count was not parsed"})
    if not copies_measured:
        blockers.append({"code": "COPY_COUNTER_INVALID", "detail": "link-wrap copy count did not match reads"})
    cases_pass = all(case["decision"] == "PASS" for case in cases)
    complete = not quick and len(cases) == len(REQUIRED_PAYLOADS)
    status = "PASS" if complete and cases_pass and not blockers else "BLOCKED"
    environment = environment_report(revision)
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-014",
        "report_kind": "windows-copy-profile-preflight" if quick else "windows-copy-profile",
        "status": status,
        "platform": "windows-x86_64",
        "native_execution": True,
        "repository_revision": revision,
        "generated_at_utc": utc_now(),
        "runner": environment["runner"],
        "toolchain": environment["toolchain"],
        "configuration": {"repetitions": repetitions, "quick": quick, "receive_buffer_bytes": 65536},
        "compile": compile_report,
        "metric_availability": {
            "application_visible_read_sizes": "MEASURED",
            "allocation_count": "MEASURED_BY_ETW_HEAP" if allocations_measured else "ETW_UNPARSED",
            "peak_private_bytes": "MEASURED_BY_WIN32",
            "copied_bytes_per_operation": "MEASURED_BY_LINK_WRAP" if copies_measured else "COPY_COUNTER_INVALID",
        },
        "cases": cases,
        "cleanup": {"decision": "PASS", "bounded_process_timeout_seconds": timeout},
        "blockers": blockers,
        "non_claims": ["quick preflight is not M0-014 completion"] if quick else [],
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
    _expect(metrics.get("copied_bytes_per_operation") == "MEASURED_BY_LINK_WRAP", "COPY_BYTES", "copy bytes not measured")
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
        _expect(case.get("copied_bytes_status") == "MEASURED_BY_LINK_WRAP", "COPY_BYTES", f"payload {payload} copy counter unavailable")
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
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--artifact-dir", type=Path, default=Path("build/gates/m0-014/artifacts"))
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--validate-report", type=Path)
    parser.add_argument("--expected-revision")
    args = parser.parse_args(argv)
    selected = sum((args.environment_only, args.run, args.validate_report is not None))
    if selected != 1:
        parser.error("select exactly one of --environment-only, --run or --validate-report")
    if args.repetitions <= 0 or args.timeout_seconds <= 0:
        parser.error("repetitions and timeout must be positive")
    if args.environment_only:
        report = environment_report(args.repository_revision)
        atomic_json(args.output.resolve(), report)
        print(f"M0-014 environment: {report['status']}")
        for blocker in report["blockers"]:
            print(f"- {blocker['code']}: {blocker['detail']}")
        return EXIT[report["status"]]
    if args.run:
        try:
            report = execute_profile(
                Path(__file__).resolve().parents[2], args.artifact_dir.resolve(), args.repository_revision,
                args.repetitions, args.timeout_seconds, args.quick,
            )
            atomic_json(args.output.resolve(), report)
            print(f"M0-014 Windows profile: {report['status']}")
            for blocker in report["blockers"]:
                print(f"- {blocker['code']}: {blocker['detail']}")
            return EXIT[report["status"]]
        except GateError as error:
            report = {
                "schema_version": 1, "task_id": "M0-014", "status": "FAIL",
                "code": error.code, "detail": error.detail,
            }
            atomic_json(args.output.resolve(), report)
            print(f"M0-014 Windows profile: FAIL: {error.code}: {error.detail}", file=sys.stderr)
            return 1
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
