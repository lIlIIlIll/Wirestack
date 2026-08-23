#!/usr/bin/env python3
"""Profile current std.net large-buffer reads on Linux x86_64.

This is pre-Wirestack evidence. It does not measure future StdNetTransport and
cannot complete the global GATE-NET-05 without native Windows copy evidence.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
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

SCHEMA_VERSION = 1
PATTERN = 37
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


CASES = (Case("1MiB", 1 * MIB), Case("100MiB", 100 * MIB))


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
                rss_sampler: "RssSampler | None" = None) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "args": list(command), "cwd": cwd, "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
        "text": True, "errors": "replace", "shell": False,
    }
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
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        self._stop.clear()
        self.samples_kib = []

        def sample() -> None:
            status = Path(f"/proc/{pid}/status")
            while not self._stop.is_set():
                try:
                    for line in status.read_text(encoding="utf-8").splitlines():
                        if line.startswith("VmRSS:"):
                            self.samples_kib.append(int(line.split()[1]))
                            break
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
                self._stop.wait(self.interval_seconds)

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
                    server: StreamServer, rss: RssSampler) -> dict[str, Any]:
    bytes_read = int(fields["bytes"])
    read_calls = int(fields["readCalls"])
    invalid = int(fields["invalid"])
    duration_ns = int(fields["durationNs"])
    eof = fields["eof"] == "true"
    close_code = int(fields["closeCode"])
    exact = (bytes_read == case.payload_bytes == server.bytes_sent == sum(read_sizes))
    process_ok = process["exit_code"] == 0 and not process["timed_out"]
    valid = (process_ok and exact and invalid == 0 and not eof and close_code == 0 and
             read_calls == len(read_sizes) and read_calls > 0 and
             all(0 < size <= requested_buffer for size in read_sizes))
    transfer_ms = round(duration_ns / 1_000_000.0, 3)
    throughput = None
    if duration_ns > 0:
        throughput = round((case.payload_bytes / MIB) / (duration_ns / 1_000_000_000.0), 3)
    return {
        "decision": "PASS" if valid else "FAIL",
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
        "fixed_4k_cap": fixed_4k_cap(read_sizes, requested_buffer),
        "transfer_ms": transfer_ms,
        "throughput_mib_per_second": throughput,
        "peak_rss_kib": rss.peak_kib,
        "rss_samples_kib": rss.samples_kib,
        "server_send_sizes": server.send_sizes,
        "process": dict(process),
    }


def aggregate(case: Case, samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    throughput = [float(item["throughput_mib_per_second"]) for item in samples
                  if item["throughput_mib_per_second"] is not None]
    transfer = [float(item["transfer_ms"]) for item in samples]
    rss = [float(item["peak_rss_kib"]) for item in samples if item["peak_rss_kib"] is not None]
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
                         "p99": percentile(rss, 99), "max": round(max(rss), 3)},
        "read_size_bytes": {"p50": percentile(read_sizes, 50),
                            "p95": percentile(read_sizes, 95),
                            "p99": percentile(read_sizes, 99),
                            "min": min(read_sizes), "max": max(read_sizes)},
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
    directory = artifacts / "probe"
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "net05_receive.cj"
    binary = directory / "net05_receive"
    source.write_text(RECEIVE_SOURCE, encoding="utf-8")
    result = run_process(["cjc", str(source), "-o", str(binary)], directory, timeout)
    if result["timed_out"] or result["exit_code"] != 0 or not binary.is_file():
        raise GateError(f"probe compilation failed: {result}")
    return binary, {"source_sha256": hashlib.sha256(RECEIVE_SOURCE.encode()).hexdigest(),
                    "process": result}


def run_sample(binary: Path, case: Case, buffer_size: int, artifacts: Path,
               timeout: float) -> dict[str, Any]:
    rss = RssSampler()
    with StreamServer(case.payload_bytes, 64 * 1024, timeout) as server:
        process = run_process([str(binary), str(server.port), str(case.payload_bytes),
                               str(buffer_size)], artifacts / "probe", timeout, rss)
    read_sizes, fields = parse_probe_output(process["stdout"])
    return classify_sample(case, buffer_size, process, read_sizes, fields, server, rss)


def execute(artifacts: Path, warmup: int, repetitions: int, timeout: float,
            revision: str, buffer_size: int = 64 * 1024) -> dict[str, Any]:
    if shutil.which("cjc") is None:
        raise GateError("cjc unavailable; source the supplied SDK environment")
    artifacts.mkdir(parents=True, exist_ok=True)
    binary, compile_info = compile_probe(artifacts, timeout)
    results = []
    for case in CASES:
        warmups = [run_sample(binary, case, buffer_size, artifacts, timeout)
                   for _ in range(warmup)]
        samples = [run_sample(binary, case, buffer_size, artifacts, timeout)
                   for _ in range(repetitions)]
        decision = "PASS" if all(item["decision"] == "PASS" for item in samples) else "FAIL"
        results.append({"name": case.name, "decision": decision,
                        "payload_bytes": case.payload_bytes,
                        "sample_count": len(samples),
                        "aggregate": aggregate(case, samples),
                        "warmup_samples": warmups, "samples": samples})
    linux_status = "PASS" if all(case["decision"] == "PASS" for case in results) else "FAIL"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-010", "task_status": "COMPLETE",
        "gate_id": "GATE-NET-05", "linux_profile_status": linux_status,
        "global_gate_status": "INCOMPLETE",
        "configuration": {"warmup": warmup, "repetitions": repetitions,
                          "timeout_seconds": timeout, "receive_buffer_bytes": buffer_size,
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
            "allocation_count": "UNAVAILABLE",
            "copied_bytes_per_operation": "UNAVAILABLE",
            "windows_native_copy_profile": "BLOCKED",
            "future_stdnet_transport_comparison": "NOT_YET_APPLICABLE",
        },
        "non_claims": ["not a global GATE-NET-05 pass",
                       "not a StdNetTransport measurement",
                       "not native Windows evidence",
                       "no allocation or copied-byte claim"],
        "compile": compile_info, "cases": results,
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
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args(argv)
    if args.quick:
        args.warmup = 0; args.repetitions = 1
        global CASES
        CASES = (Case("1MiB", 1 * MIB),)
    try:
        report = execute(args.artifact_dir.resolve(), args.warmup, args.repetitions,
                         args.timeout_seconds, args.repository_revision)
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-05 profile: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M0-010 task={report['task_status']} Linux={report['linux_profile_status']} global=INCOMPLETE")
    for case in report["cases"]:
        aggregate_value = case["aggregate"]
        print(f"- {case['name']}: {case['decision']} samples={case['sample_count']} "
              f"read-max={aggregate_value['read_size_bytes']['max']} "
              f"fixed4k={aggregate_value['fixed_4k_cap']} "
              f"throughput-p50={aggregate_value['throughput_mib_per_second']['p50']} MiB/s "
              f"rss-max={aggregate_value['peak_rss_kib']['max']} KiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
