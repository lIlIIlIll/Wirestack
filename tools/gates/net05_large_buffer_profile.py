#!/usr/bin/env python3
"""Compare raw std.net and StdNetTransport receive paths on Linux x86_64."""
from __future__ import annotations

from tools import evidence_digest

import argparse
import datetime as dt
import json
import math
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from net05_large_buffer_profile_sources import RECEIVE_SOURCE

SCHEMA_VERSION = 2
PATTERN = 37
KIB = 1024
MIB = 1024 * 1024
READ_RE = re.compile(r"^READ size=(\d+)$", re.M)
RESULT_RE = re.compile(r"^RESULT\s+(.+)$", re.M)
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class Case:
    name: str
    payload_bytes: int


CASES = (
    Case("1KiB", 1 * KIB),
    Case("16KiB", 16 * KIB),
    Case("64KiB", 64 * KIB),
    Case("1MiB", 1 * MIB),
    Case("100MiB", 100 * MIB),
)
THROUGHPUT_RATIO_MINIMUM = 0.95
P95_LATENCY_RATIO_MAXIMUM = 1.10
ADAPTER_TEST_FILTER = "Net05StdNetTransportBenchmarkTest.receive"
RAW_TEST_FILTER = "Net05RawStdNetBenchmarkTest.receive"
HEAPTRACK_ALLOCATIONS_RE = re.compile(
    r"^\s*allocations:\s+([0-9][0-9,]*)\s*$", re.MULTILINE
)
STRACE_RECVFROM_RE = re.compile(
    r"(?:recvfrom\(|<\.\.\. recvfrom resumed>).*?=\s+(-?\d+)(?:\s+.*)?$"
)


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(1, math.ceil(percent / 100.0 * len(ordered))) - 1
    return round(ordered[index], 3)


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.kill()
        process.wait(timeout=2)
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def run_process(command: Sequence[str], cwd: Path, timeout: float,
                rss_sampler: "RssSampler | None" = None,
                environment: Mapping[str, str] | None = None) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "args": list(command), "cwd": cwd, "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
        "text": True, "errors": "replace", "shell": False,
    }
    if environment is not None:
        kwargs["env"] = dict(environment)
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True
    started = time.monotonic()
    process = subprocess.Popen(**kwargs)
    if rss_sampler is not None:
        rss_sampler.start(process.pid)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
        stdout, stderr = process.communicate()
    finally:
        if rss_sampler is not None:
            rss_sampler.stop()
    return {
        "command": list(command), "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000.0, 3),
        "stdout": stdout[-4 * 1024 * 1024:],
        "stderr": stderr[-1024 * 1024:],
    }


class RssSampler:
    def __init__(self, interval_seconds: float = 0.005) -> None:
        self.interval_seconds = interval_seconds
        self.samples_kib: list[int] = []
        self.thread_samples: list[int] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        self._stop.clear()
        self.samples_kib = []
        self.thread_samples = []

        status = Path(f"/proc/{pid}/status")

        def sample_once() -> None:
            try:
                lines = status.read_text(encoding="utf-8").splitlines()
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                return
            for line in lines:
                if line.startswith("VmRSS:"):
                    self.samples_kib.append(int(line.split()[1]))
                elif line.startswith("Threads:"):
                    self.thread_samples.append(int(line.split()[1]))

        def sample() -> None:
            while not self._stop.is_set():
                sample_once()
                self._stop.wait(self.interval_seconds)

        sample_once()
        self._thread = threading.Thread(target=sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(2)
            if self._thread.is_alive():
                raise GateError("RSS sampler thread leaked")

    @property
    def peak_kib(self) -> int | None:
        return max(self.samples_kib) if self.samples_kib else None

    @property
    def peak_threads(self) -> int | None:
        return max(self.thread_samples) if self.thread_samples else None


class StreamServer:
    def __init__(self, total_bytes: int, send_chunk: int, timeout: float) -> None:
        self.total_bytes = total_bytes
        self.send_chunk = send_chunk
        self.timeout = timeout
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(timeout)
        self.port = int(self.listener.getsockname()[1])
        self.ready = threading.Event()
        self.error: str | None = None
        self.bytes_sent = 0
        self.send_sizes: list[int] = []
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        self.ready.set()
        connection: socket.socket | None = None
        try:
            connection, _ = self.listener.accept()
            connection.settimeout(self.timeout)
            payload = bytes([PATTERN]) * self.send_chunk
            remaining = self.total_bytes
            while remaining > 0:
                view = memoryview(payload)[:min(self.send_chunk, remaining)]
                while view:
                    sent = connection.send(view)
                    if sent <= 0:
                        raise GateError("server send made no progress")
                    self.bytes_sent += sent
                    self.send_sizes.append(sent)
                    remaining -= sent
                    view = view[sent:]
            try:
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
        finally:
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass
            try:
                self.listener.close()
            except OSError:
                pass

    def __enter__(self) -> "StreamServer":
        self._thread.start()
        if not self.ready.wait(2):
            raise GateError("stream server did not become ready")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            self.listener.close()
        except OSError:
            pass
        self._thread.join(self.timeout + 2)
        if self._thread.is_alive():
            raise GateError("stream server thread leaked")
        if self.error and exc is None:
            raise GateError(self.error)


def parse_probe_output(stdout: str) -> tuple[list[int], dict[str, str]]:
    sizes = [int(item) for item in READ_RE.findall(stdout)]
    results = RESULT_RE.findall(stdout)
    if len(results) != 1:
        raise GateError(f"expected one RESULT line, found {len(results)}")
    fields = dict(FIELD_RE.findall(results[0]))
    required = {"bytes", "readCalls", "invalid", "eof", "durationNs",
                "closeCode", "bufferSize"}
    missing = required - fields.keys()
    if missing:
        raise GateError(f"missing result fields: {sorted(missing)}")
    return sizes, fields


def fixed_4k_cap(read_sizes: Sequence[int], requested_buffer: int) -> bool:
    return bool(read_sizes) and requested_buffer > 4096 and max(read_sizes) <= 4096


def classify_sample(case: Case, requested_buffer: int, process: Mapping[str, Any],
                    read_sizes: Sequence[int], fields: Mapping[str, str],
                    server: StreamServer, rss: RssSampler,
                    implementation: str = "std.net") -> dict[str, Any]:
    bytes_read = int(fields["bytes"])
    read_calls = int(fields["readCalls"])
    invalid = int(fields["invalid"])
    duration_ns = int(fields["durationNs"])
    eof = fields["eof"] == "true"
    close_code = int(fields["closeCode"])
    exact = (bytes_read == case.payload_bytes == server.bytes_sent == sum(read_sizes))
    process_ok = process["exit_code"] == 0 and not process["timed_out"]
    expected_progress = read_calls > 0 or case.payload_bytes == 0
    copied_read_bytes = int(fields.get("copiedReadBytes", "0"))
    copied_write_bytes = int(fields.get("copiedWriteBytes", "0"))
    copied_bytes_valid = (
        implementation == "std.net" or
        (copied_read_bytes == 0 and copied_write_bytes == 0)
    )
    valid = (process_ok and exact and invalid == 0 and not eof and close_code == 0 and
             read_calls == len(read_sizes) and expected_progress and
             all(0 < size <= requested_buffer for size in read_sizes) and
             copied_bytes_valid)
    transfer_ms = round(duration_ns / 1_000_000.0, 3)
    throughput = None
    if duration_ns > 0:
        throughput = round((case.payload_bytes / MIB) / (duration_ns / 1_000_000_000.0), 3)
    return {
        "decision": "PASS" if valid else "FAIL",
        "implementation": implementation,
        "payload_bytes": case.payload_bytes,
        "bytes_read": bytes_read,
        "server_bytes_sent": server.bytes_sent,
        "exact_bytes": exact,
        "invalid_bytes": invalid,
        "premature_eof": eof,
        "read_calls": read_calls,
        "read_sizes": list(read_sizes),
        "max_read_size": max(read_sizes) if read_sizes else None,
        "min_read_size": min(read_sizes) if read_sizes else None,
        "fixed_4k_cap": (
            case.payload_bytes > 4096 and fixed_4k_cap(read_sizes, requested_buffer)
        ),
        "transfer_ms": transfer_ms,
        "throughput_mib_per_second": throughput,
        "peak_rss_kib": rss.peak_kib,
        "rss_samples_kib": rss.samples_kib,
        "peak_thread_count": rss.peak_threads,
        "thread_count_samples": rss.thread_samples,
        "server_send_sizes": server.send_sizes,
        "adapter_staging_copied_read_bytes": copied_read_bytes,
        "adapter_staging_copied_write_bytes": copied_write_bytes,
        "process": dict(process),
    }


def aggregate(case: Case, samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    throughput = [float(item["throughput_mib_per_second"]) for item in samples
                  if item["throughput_mib_per_second"] is not None]
    transfer = [float(item["transfer_ms"]) for item in samples]
    rss = [float(item["peak_rss_kib"]) for item in samples if item["peak_rss_kib"] is not None]
    threads = [float(item["peak_thread_count"]) for item in samples
               if item["peak_thread_count"] is not None]
    read_sizes = [int(size) for item in samples for size in item["read_sizes"]]
    read_calls = [float(item["read_calls"]) for item in samples]
    return {
        "payload_bytes": case.payload_bytes,
        "sample_count": len(samples),
        "transfer_ms": {"p50": percentile(transfer, 50), "p95": percentile(transfer, 95),
                        "p99": percentile(transfer, 99), "max": round(max(transfer), 3)},
        "throughput_mib_per_second": {
            "p50": percentile(throughput, 50), "p95": percentile(throughput, 95),
            "p99": percentile(throughput, 99), "min": round(min(throughput), 3),
        },
        "peak_rss_kib": {"p50": percentile(rss, 50), "p95": percentile(rss, 95),
                         "p99": percentile(rss, 99),
                         "max": round(max(rss), 3) if rss else None},
        "peak_thread_count": {"p50": percentile(threads, 50),
                              "p95": percentile(threads, 95),
                              "p99": percentile(threads, 99),
                              "max": round(max(threads), 3) if threads else None},
        "read_size_bytes": {"p50": percentile(read_sizes, 50),
                            "p95": percentile(read_sizes, 95),
                            "p99": percentile(read_sizes, 99),
                            "min": min(read_sizes) if read_sizes else None,
                            "max": max(read_sizes) if read_sizes else None},
        "read_calls": {"p50": percentile(read_calls, 50),
                       "p95": percentile(read_calls, 95),
                       "p99": percentile(read_calls, 99)},
        "fixed_4k_cap": all(bool(item["fixed_4k_cap"]) for item in samples),
    }


def command_text(command: Sequence[str]) -> str | None:
    if shutil.which(command[0]) is None:
        return None
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                errors="replace", timeout=10)
    except Exception:
        return None
    return (result.stdout or result.stderr).strip()[:4096] or None


def compile_probe(artifacts: Path, timeout: float) -> tuple[Path, dict[str, Any]]:
    """Build the shared minimal raw probe used by the M0-005 baseline."""
    directory = artifacts / "probe"
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "net05_receive.cj"
    binary = directory / "net05_receive"
    source.write_text(RECEIVE_SOURCE, encoding="utf-8")
    result = run_process(["cjc", "-O2", str(source), "-o", str(binary)], directory, timeout)
    if result["timed_out"] or result["exit_code"] != 0 or not binary.is_file():
        raise GateError(f"probe compilation failed: {result}")
    return binary, {"source_sha256": evidence_digest.text_evidence_bytes_sha256(RECEIVE_SOURCE.encode()),
                    "process": result}


def enable_o2_manifest(manifest_path: Path) -> None:
    manifest = manifest_path.read_text(encoding="utf-8")
    pattern = re.compile(r'^(\s*compile-option\s*=\s*)"[^"]*"', re.MULTILINE)
    if len(pattern.findall(manifest)) != 1:
        raise GateError("expected one package compile-option in benchmark snapshot")
    manifest_path.write_text(
        pattern.sub(r'\1"-O2"', manifest, count=1), encoding="utf-8"
    )


def compile_adapter_probe(root: Path, artifacts: Path,
                          timeout: float) -> tuple[Path, dict[str, Any]]:
    snapshot = artifacts / "adapter-snapshot"
    if snapshot.exists():
        shutil.rmtree(snapshot)
    shutil.copytree(
        root, snapshot,
        ignore=shutil.ignore_patterns(
            ".git", ".cjpm", ".codex", "target", "build", "__pycache__", "*.pyc"
        ),
    )
    native = root / "target/native"
    if not native.is_dir():
        raise GateError("Wirestack native provider artifacts are missing")
    snapshot_target = snapshot / "target"
    snapshot_target.mkdir()
    (snapshot_target / "native").symlink_to(native, target_is_directory=True)
    enable_o2_manifest(snapshot / "cjpm.toml")
    command = [
        "cjpm", "test", "src/internal/transport_stdnet", "-j", "1", "--no-run"
    ]
    result = run_process(command, snapshot, timeout)
    binary = snapshot / "target/release/unittest_bin/wirestack.internal.transport_stdnet"
    if result["timed_out"] or result["exit_code"] != 0 or not binary.is_file():
        raise GateError(f"adapter probe compilation failed: {result}")
    source = snapshot / "src/internal/transport_stdnet/benchmark_harness_test.cj"
    return binary, {
        "source_sha256": evidence_digest.text_evidence_bytes_sha256(source.read_bytes()),
        "manifest_compile_option": "-O2",
        "process": result,
    }


def benchmark_environment(server: StreamServer, case: Case,
                          buffer_size: int) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update({
        "WIRESTACK_NET05_HOST": "127.0.0.1",
        "WIRESTACK_NET05_PORT": str(server.port),
        "WIRESTACK_NET05_EXPECTED": str(case.payload_bytes),
        "WIRESTACK_NET05_BUFFER_SIZE": str(buffer_size),
    })
    return environment


def unittest_probe_command(binary: Path, test_filter: str) -> list[str]:
    return [
        str(binary), f"--filter={test_filter}",
        "--show-all-output", "--no-progress", "--no-color",
    ]


def run_sample(binary: Path, case: Case, buffer_size: int, artifacts: Path,
               timeout: float) -> dict[str, Any]:
    rss = RssSampler()
    with StreamServer(case.payload_bytes, 64 * 1024, timeout) as server:
        process = run_process(
            unittest_probe_command(binary, RAW_TEST_FILTER), binary.parent,
            timeout, rss, environment=benchmark_environment(server, case, buffer_size)
        )
    read_sizes, fields = parse_probe_output(process["stdout"])
    return classify_sample(
        case, buffer_size, process, read_sizes, fields, server, rss,
        implementation="std.net",
    )


def run_adapter_sample(binary: Path, case: Case, buffer_size: int,
                       artifacts: Path, timeout: float) -> dict[str, Any]:
    rss = RssSampler()
    with StreamServer(case.payload_bytes, 64 * 1024, timeout) as server:
        process = run_process(
            unittest_probe_command(binary, ADAPTER_TEST_FILTER), binary.parent,
            timeout, rss, environment=benchmark_environment(server, case, buffer_size)
        )
    read_sizes, fields = parse_probe_output(process["stdout"])
    return classify_sample(
        case, buffer_size, process, read_sizes, fields, server, rss,
        implementation="StdNetTransport",
    )


def parse_heaptrack_allocations(stderr: str) -> int:
    matches = HEAPTRACK_ALLOCATIONS_RE.findall(stderr)
    if len(matches) != 1:
        raise GateError(f"expected one heaptrack allocation count, found {len(matches)}")
    return int(matches[0].replace(",", ""))


def parse_strace_recvfrom_results(trace: str) -> list[int]:
    results = []
    for line in trace.splitlines():
        match = STRACE_RECVFROM_RE.search(line)
        if match is not None:
            results.append(int(match.group(1)))
    return results


def run_instrumented_sample(binary: Path, implementation: str, case: Case,
                            buffer_size: int, artifacts: Path,
                            timeout: float) -> dict[str, Any]:
    label = "std-net" if implementation == "std.net" else "stdnet-transport"
    sample_dir = artifacts / "instrumentation" / case.name / label
    sample_dir.mkdir(parents=True, exist_ok=True)
    trace_path = sample_dir / "recvfrom.trace"
    heaptrack_prefix = sample_dir / "heaptrack-data"
    heaptrack_path = Path(f"{heaptrack_prefix}.zst")
    trace_path.unlink(missing_ok=True)
    heaptrack_path.unlink(missing_ok=True)
    rss = RssSampler()
    with StreamServer(case.payload_bytes, 64 * 1024, timeout) as server:
        test_filter = RAW_TEST_FILTER if implementation == "std.net" else ADAPTER_TEST_FILTER
        probe_command = unittest_probe_command(binary, test_filter)
        command = [
            "strace", "-f", "-qq", "-s", "0", "-e", "trace=recvfrom",
            "-o", str(trace_path), "heaptrack", "--record-only",
            "-o", str(heaptrack_prefix), *probe_command,
        ]
        process = run_process(
            command, binary.parent, timeout, rss,
            environment=benchmark_environment(server, case, buffer_size)
        )
    if not trace_path.is_file():
        raise GateError(f"strace did not produce {implementation} receive evidence")
    if not heaptrack_path.is_file():
        raise GateError(f"heaptrack did not produce {implementation} allocation evidence")
    trace = trace_path.read_text(encoding="utf-8", errors="replace")
    recvfrom_results = parse_strace_recvfrom_results(trace)
    read_sizes = [value for value in recvfrom_results if value > 0]
    _reported_read_sizes, fields = parse_probe_output(process["stdout"])
    sample = classify_sample(
        case, buffer_size, process, read_sizes, fields, server, rss,
        implementation=implementation,
    )
    allocations = parse_heaptrack_allocations(process["stderr"])
    copied_bytes = sum(read_sizes)
    attempts = len(recvfrom_results)
    valid = (
        sample["decision"] == "PASS" and allocations > 0 and
        copied_bytes == case.payload_bytes and
        len(read_sizes) == sample["read_calls"]
    )
    sample["instrumentation"] = {
        "decision": "PASS" if valid else "FAIL",
        "native_allocation_events_per_process_operation": allocations,
        "recvfrom_attempts": attempts,
        "successful_recvfrom_calls": len(read_sizes),
        "syscall_receive_copied_bytes_per_process_operation": copied_bytes,
        "adapter_staging_copied_read_bytes_per_process_operation": (
            sample["adapter_staging_copied_read_bytes"]
        ),
        "strace_trace": trace,
        "strace_trace_sha256": evidence_digest.text_evidence_bytes_sha256(trace.encode()),
        "heaptrack_record_sha256": evidence_digest.artifact_bytes_sha256(heaptrack_path.read_bytes()),
    }
    return sample


def compare_implementations(raw: Mapping[str, Any],
                            adapter: Mapping[str, Any]) -> dict[str, Any]:
    raw_throughput = float(raw["throughput_mib_per_second"]["p50"])
    adapter_throughput = float(adapter["throughput_mib_per_second"]["p50"])
    raw_p95 = float(raw["transfer_ms"]["p95"])
    adapter_p95 = float(adapter["transfer_ms"]["p95"])
    throughput_ratio = adapter_throughput / raw_throughput if raw_throughput > 0 else 0.0
    latency_ratio = adapter_p95 / raw_p95 if raw_p95 > 0 else float("inf")
    throughput_pass = throughput_ratio >= THROUGHPUT_RATIO_MINIMUM
    latency_pass = latency_ratio <= P95_LATENCY_RATIO_MAXIMUM
    return {
        "decision": "PASS" if throughput_pass and latency_pass else "FAIL",
        "throughput_ratio": round(throughput_ratio, 6),
        "throughput_minimum": THROUGHPUT_RATIO_MINIMUM,
        "throughput_decision": "PASS" if throughput_pass else "FAIL",
        "p95_latency_ratio": round(latency_ratio, 6),
        "p95_latency_maximum": P95_LATENCY_RATIO_MAXIMUM,
        "p95_latency_decision": "PASS" if latency_pass else "FAIL",
    }


def execute(root: Path, artifacts: Path, warmup: int, repetitions: int,
            timeout: float, build_timeout: float, revision: str,
            buffer_size: int = 64 * 1024) -> dict[str, Any]:
    if shutil.which("cjc") is None:
        raise GateError("cjc unavailable; source the supplied SDK environment")
    for tool in ("strace", "heaptrack"):
        if shutil.which(tool) is None:
            raise GateError(f"{tool} is required for M0-010 copy/allocation evidence")
    artifacts.mkdir(parents=True, exist_ok=True)
    comparison_binary, comparison_compile = compile_adapter_probe(
        root, artifacts, build_timeout
    )
    results = []
    for case in CASES:
        raw_warmups = []
        adapter_warmups = []
        for _ in range(warmup):
            raw_warmups.append(run_sample(comparison_binary, case, buffer_size, artifacts, timeout))
            adapter_warmups.append(
                run_adapter_sample(comparison_binary, case, buffer_size, artifacts, timeout)
            )
        raw_samples = []
        adapter_samples = []
        paired_order = []
        for index in range(repetitions):
            order = ("std.net", "StdNetTransport") if index % 2 == 0 else (
                "StdNetTransport", "std.net"
            )
            paired_order.append(list(order))
            for implementation in order:
                if implementation == "std.net":
                    raw_samples.append(
                        run_sample(comparison_binary, case, buffer_size, artifacts, timeout)
                    )
                else:
                    adapter_samples.append(
                        run_adapter_sample(
                            comparison_binary, case, buffer_size, artifacts, timeout
                        )
                    )
        raw_aggregate = aggregate(case, raw_samples)
        adapter_aggregate = aggregate(case, adapter_samples)
        comparison = compare_implementations(raw_aggregate, adapter_aggregate)
        raw_instrumented = run_instrumented_sample(
            comparison_binary, "std.net", case, buffer_size, artifacts, timeout
        )
        adapter_instrumented = run_instrumented_sample(
            comparison_binary, "StdNetTransport", case, buffer_size, artifacts, timeout
        )
        samples_pass = all(
            item["decision"] == "PASS" for item in raw_samples + adapter_samples
        )
        instrumentation_pass = (
            raw_instrumented["instrumentation"]["decision"] == "PASS" and
            adapter_instrumented["instrumentation"]["decision"] == "PASS"
        )
        decision = "PASS" if (
            samples_pass and instrumentation_pass and comparison["decision"] == "PASS"
        ) else "FAIL"
        results.append({
            "name": case.name,
            "decision": decision,
            "payload_bytes": case.payload_bytes,
            "sample_count_per_implementation": repetitions,
            "paired_order": paired_order,
            "comparison": comparison,
            "std_net": {
                "aggregate": raw_aggregate,
                "instrumented_sample": raw_instrumented,
                "warmup_samples": raw_warmups,
                "samples": raw_samples,
            },
            "stdnet_transport": {
                "aggregate": adapter_aggregate,
                "instrumented_sample": adapter_instrumented,
                "warmup_samples": adapter_warmups,
                "samples": adapter_samples,
            },
        })
    linux_status = "PASS" if all(case["decision"] == "PASS" for case in results) else "FAIL"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-010", "task_status": "COMPLETE",
        "gate_id": "GATE-NET-05", "linux_profile_status": linux_status,
        "global_gate_status": "INCOMPLETE",
        "configuration": {"warmup": warmup, "repetitions": repetitions,
                          "timeout_seconds": timeout,
                          "build_timeout_seconds": build_timeout,
                          "comparison_process_shape": "same_unittest_binary",
                          "receive_buffer_bytes": buffer_size,
                          "server_send_chunk_bytes": 64 * 1024},
        "environment": {"repository_revision": revision,
                        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "os": platform.platform(), "architecture": platform.machine(),
                        "python": sys.version.splitlines()[0],
                        "cjc": command_text(["cjc", "--version"]),
                        "cjpm": command_text(["cjpm", "--version"]),
                        "cangjie_home": os.environ.get("CANGJIE_HOME")},
        "metric_availability": {
            "application_visible_read_sizes": "MEASURED",
            "throughput": "MEASURED", "peak_rss": "MEASURED",
            "native_process_allocation_events": "MEASURED",
            "syscall_receive_copied_bytes_per_operation": "MEASURED",
            "adapter_staging_copied_bytes_per_operation": "MEASURED",
            "windows_native_copy_profile": "BLOCKED",
            "stdnet_transport_comparison": "MEASURED",
        },
        "non_claims": ["not a global GATE-NET-05 pass",
                       "not native Windows evidence",
                       "not M1-025 leak, soak or cancellation evidence"],
        "compile": {"comparison_binary": comparison_compile},
        "cases": results,
    }


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path,
                        default=root / "build/gates/net05-large-buffer-profile")
    parser.add_argument("--output", type=Path,
                        default=root / "build/gates/net05-large-buffer-profile.json")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--build-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args(argv)
    if args.quick:
        args.warmup = 0; args.repetitions = 1
        global CASES
        CASES = (Case("1MiB", 1 * MIB),)
    if args.warmup < 0 or args.repetitions <= 0:
        parser.error("warmup must be non-negative and repetitions must be positive")
    try:
        report = execute(
            root, args.artifact_dir.resolve(), args.warmup, args.repetitions,
            args.timeout_seconds, args.build_timeout_seconds,
            args.repository_revision,
        )
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-05 profile: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M0-010 task={report['task_status']} Linux={report['linux_profile_status']} global=INCOMPLETE")
    for case in report["cases"]:
        raw = case["std_net"]["aggregate"]
        adapter = case["stdnet_transport"]["aggregate"]
        comparison = case["comparison"]
        print(
            f"- {case['name']}: {case['decision']} "
            f"samples={case['sample_count_per_implementation']} "
            f"raw-throughput-p50={raw['throughput_mib_per_second']['p50']} MiB/s "
            f"adapter-throughput-p50={adapter['throughput_mib_per_second']['p50']} MiB/s "
            f"throughput-ratio={comparison['throughput_ratio']} "
            f"p95-latency-ratio={comparison['p95_latency_ratio']} "
            f"adapter-read-max={adapter['read_size_bytes']['max']}"
        )
    return 0 if report["linux_profile_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
