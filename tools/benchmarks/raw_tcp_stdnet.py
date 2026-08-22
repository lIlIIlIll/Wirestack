#!/usr/bin/env python3
"""Measure the supplied SDK's existing std.net raw TCP loopback behavior.

This is a pre-Wirestack baseline. It compiles a Cangjie client for each case,
runs it against a bounded echo server, verifies bytes and payload contents, and
emits schema-versioned JSON. It is not a GATE-NET-05 pass by itself.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
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

SCHEMA_VERSION = 1
PATTERN_BYTE = 1
MARKER = "WIRESTACK_RAW_TCP_OK"
MIB = 1024 * 1024
DEFAULT_CASES = (
    ("connect-only", 1, 0),
    ("1KiB", 1024, 1),
    ("16KiB", 16 * 1024, 1),
    ("64KiB", 64 * 1024, 1),
    ("1MiB", 64 * 1024, 16),
    ("100MiB", 64 * 1024, 1600),
)


class BaselineError(RuntimeError):
    pass


@dataclass(frozen=True)
class BenchmarkCase:
    name: str
    chunk_size: int
    iterations: int

    @property
    def payload_bytes(self) -> int:
        return self.chunk_size * self.iterations


@dataclass
class ServerObservation:
    bytes_received: int = 0
    bytes_echoed: int = 0
    accepted_ns: int | None = None
    first_byte_ns: int | None = None
    completed_ns: int | None = None
    error: str | None = None


@dataclass(frozen=True)
class ProcessResult:
    exit_code: int | None
    timed_out: bool
    duration_ms: float
    stdout: str
    stderr: str


class EchoServer:
    def __init__(self, port: int, expected_bytes: int, timeout_seconds: float) -> None:
        self.port = port
        self.expected_bytes = expected_bytes
        self.timeout_seconds = timeout_seconds
        self.ready = threading.Event()
        self.observation = ServerObservation()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()
        if not self.ready.wait(timeout=min(self.timeout_seconds, 10.0)):
            raise BaselineError("echo server did not become ready")

    def join(self) -> ServerObservation:
        self._thread.join(timeout=self.timeout_seconds + 2.0)
        if self._thread.is_alive():
            raise BaselineError("echo server did not terminate within its bound")
        if self.observation.error:
            raise BaselineError(self.observation.error)
        return self.observation

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                server.settimeout(self.timeout_seconds)
                server.bind(("127.0.0.1", self.port))
                server.listen(1)
                self.ready.set()
                connection, _ = server.accept()
                self.observation.accepted_ns = time.monotonic_ns()
                with connection:
                    connection.settimeout(self.timeout_seconds)
                    remaining = self.expected_bytes
                    while remaining > 0:
                        data = connection.recv(min(64 * 1024, remaining))
                        if not data:
                            raise BaselineError(
                                f"peer EOF after {self.observation.bytes_received} of {self.expected_bytes} bytes"
                            )
                        now = time.monotonic_ns()
                        if self.observation.first_byte_ns is None:
                            self.observation.first_byte_ns = now
                        if any(item != PATTERN_BYTE for item in data):
                            raise BaselineError("payload verification failed")
                        self.observation.bytes_received += len(data)
                        remaining -= len(data)
                        connection.sendall(data)
                        self.observation.bytes_echoed += len(data)
                    self.observation.completed_ns = time.monotonic_ns()
        except Exception as error:
            self.observation.error = f"{type(error).__name__}: {error}"
            self.ready.set()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def reserve_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def render_source(template: str, *, port: int, chunk_size: int, iterations: int) -> str:
    rendered = template
    for placeholder, value in {
        "{{PORT}}": str(port),
        "{{CHUNK_SIZE}}": str(chunk_size),
        "{{ITERATIONS}}": str(iterations),
    }.items():
        rendered = rendered.replace(placeholder, value)
    if any(item in rendered for item in ("{{PORT}}", "{{CHUNK_SIZE}}", "{{ITERATIONS}}")):
        raise BaselineError("unexpanded probe placeholder")
    if MARKER not in rendered:
        raise BaselineError(f"probe template must emit {MARKER}")
    return rendered


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
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


def run_process(command: list[str], cwd: Path, timeout_seconds: float) -> ProcessResult:
    started = time.monotonic()
    kwargs: dict[str, Any] = {
        "args": command,
        "cwd": cwd,
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "text": True,
        "errors": "replace",
        "shell": False,
    }
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True
    process = subprocess.Popen(**kwargs)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
        stdout, stderr = process.communicate()
    return ProcessResult(
        process.returncode,
        timed_out,
        round((time.monotonic() - started) * 1000.0, 3),
        stdout[-1024 * 1024:],
        stderr[-1024 * 1024:],
    )


def command_text(command: list[str]) -> str | None:
    if shutil.which(command[0]) is None:
        return None
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.strip()
    return value[:4096] if value else None


def repository_revision(root: Path) -> str:
    if os.environ.get("GITHUB_SHA"):
        return os.environ["GITHUB_SHA"]
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
            text=True,
        )
        if completed.returncode == 0 and completed.stdout.strip():
            return completed.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def environment_metadata(root: Path) -> dict[str, Any]:
    return {
        "repository_revision": repository_revision(root),
        "started_at_utc": utc_now(),
        "platform": sys.platform,
        "os": platform.platform(),
        "architecture": platform.machine(),
        "processor": platform.processor(),
        "python": sys.version.splitlines()[0],
        "cjc": command_text(["cjc", "--version"]),
        "cjpm": command_text(["cjpm", "--version"]),
        "cangjie_home": os.environ.get("CANGJIE_HOME"),
        "cpu_count": os.cpu_count(),
    }


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    if percent < 0 or percent > 100:
        raise ValueError("percent must be in [0, 100]")
    ordered = sorted(values)
    rank = max(1, math.ceil(percent / 100.0 * len(ordered)))
    return round(ordered[rank - 1], 3)


def ns_delta_ms(start: int | None, end: int | None) -> float | None:
    if start is None or end is None:
        return None
    return round((end - start) / 1_000_000.0, 3)


def throughput_mib_per_second(bytes_count: int, duration_ms: float | None) -> float | None:
    if duration_ms is None or duration_ms <= 0:
        return None
    return round((bytes_count / MIB) / (duration_ms / 1000.0), 3)


def compile_probe(source: Path, binary: Path, cwd: Path, timeout_seconds: float) -> ProcessResult:
    result = run_process(["cjc", str(source), "-o", str(binary)], cwd, timeout_seconds)
    if result.timed_out:
        raise BaselineError(f"probe compilation timed out: {source}")
    if result.exit_code != 0:
        raise BaselineError(
            f"probe compilation failed ({result.exit_code})\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    if not binary.is_file():
        raise BaselineError(f"compiler reported success but binary is missing: {binary}")
    return result


def run_sample(binary: Path, port: int, expected_bytes: int, cwd: Path, timeout_seconds: float) -> dict[str, Any]:
    server = EchoServer(port, expected_bytes, timeout_seconds)
    server.start()
    process = run_process([str(binary)], cwd, timeout_seconds)
    try:
        observation = server.join()
    except BaselineError:
        if process.timed_out or process.exit_code != 0:
            observation = server.observation
        else:
            raise
    if process.timed_out:
        raise BaselineError("Cangjie probe timed out")
    if process.exit_code != 0:
        raise BaselineError(
            f"Cangjie probe exited with {process.exit_code}\nstdout:\n{process.stdout}\nstderr:\n{process.stderr}"
        )
    if MARKER not in process.stdout:
        raise BaselineError(f"Cangjie probe did not emit {MARKER}")
    if observation.error:
        raise BaselineError(observation.error)
    if observation.bytes_received != expected_bytes or observation.bytes_echoed != expected_bytes:
        raise BaselineError(
            f"byte mismatch: expected={expected_bytes}, received={observation.bytes_received}, echoed={observation.bytes_echoed}"
        )
    server_transfer_ms = ns_delta_ms(observation.first_byte_ns, observation.completed_ns)
    return {
        "client_process_ms": process.duration_ms,
        "server_accept_to_first_byte_ms": ns_delta_ms(observation.accepted_ns, observation.first_byte_ns),
        "server_first_to_last_byte_ms": server_transfer_ms,
        "server_accept_to_last_byte_ms": ns_delta_ms(observation.accepted_ns, observation.completed_ns),
        "bytes_sent": expected_bytes,
        "bytes_echoed": observation.bytes_echoed,
        "application_roundtrip_bytes": expected_bytes * 2,
        "client_roundtrip_mib_per_second": throughput_mib_per_second(expected_bytes * 2, process.duration_ms),
        "server_transfer_mib_per_second": throughput_mib_per_second(expected_bytes * 2, server_transfer_ms),
        "stdout": process.stdout,
        "stderr": process.stderr,
    }


def aggregate(case: BenchmarkCase, samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    client = [float(sample["client_process_ms"]) for sample in samples]
    transfer = [float(sample["server_first_to_last_byte_ms"]) for sample in samples if sample["server_first_to_last_byte_ms"] is not None]
    throughput = [float(sample["client_roundtrip_mib_per_second"]) for sample in samples if sample["client_roundtrip_mib_per_second"] is not None]
    return {
        "name": case.name,
        "chunk_size": case.chunk_size,
        "iterations": case.iterations,
        "payload_bytes": case.payload_bytes,
        "sample_count": len(samples),
        "client_process_ms": {"p50": percentile(client, 50), "p95": percentile(client, 95), "p99": percentile(client, 99)},
        "server_first_to_last_byte_ms": {"p50": percentile(transfer, 50), "p95": percentile(transfer, 95), "p99": percentile(transfer, 99)},
        "client_roundtrip_mib_per_second": {"p50": percentile(throughput, 50), "p95": percentile(throughput, 95), "p99": percentile(throughput, 99)},
        "samples": list(samples),
    }


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def execute(repo_root: Path, template_path: Path, artifact_dir: Path, cases: Sequence[BenchmarkCase], warmup: int, repetitions: int, timeout_seconds: float) -> dict[str, Any]:
    if shutil.which("cjc") is None:
        raise BaselineError("cjc is not available; load the supplied SDK environment")
    template_bytes = template_path.read_bytes()
    template = template_bytes.decode("utf-8")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "benchmark_id": "STD-NET-RAW-TCP-BASELINE",
        "status": "IN_PROGRESS",
        "scope": "loopback IPv4, existing std.net TcpSocket, one client process per sample",
        "non_claims": [
            "not a GATE-NET-05 pass",
            "not a StdNetTransport measurement",
            "not cross-platform evidence",
            "does not measure allocations or copied bytes",
        ],
        "template_sha256": hashlib.sha256(template_bytes).hexdigest(),
        "environment": environment_metadata(repo_root),
        "configuration": {"warmup": warmup, "repetitions": repetitions, "timeout_seconds": timeout_seconds, "pattern_byte": PATTERN_BYTE},
        "cases": [],
    }
    for case in cases:
        case_dir = artifact_dir / case.name
        case_dir.mkdir(parents=True, exist_ok=True)
        port = reserve_loopback_port()
        source = case_dir / "stdnet_probe.cj"
        binary = case_dir / ("stdnet_probe.exe" if os.name == "nt" else "stdnet_probe")
        source.write_text(render_source(template, port=port, chunk_size=case.chunk_size, iterations=case.iterations), encoding="utf-8")
        compile_result = compile_probe(source, binary, repo_root, timeout_seconds)
        warmup_samples = [run_sample(binary, port, case.payload_bytes, repo_root, timeout_seconds) for _ in range(warmup)]
        measured_samples = [run_sample(binary, port, case.payload_bytes, repo_root, timeout_seconds) for _ in range(repetitions)]
        result = aggregate(case, measured_samples)
        result["compile_ms"] = compile_result.duration_ms
        result["warmup_samples"] = warmup_samples
        report["cases"].append(result)
    report["status"] = "PASS"
    report["duration_ms"] = round((time.monotonic() - started) * 1000.0, 3)
    report["finished_at_utc"] = utc_now()
    return report


def render_summary(report: Mapping[str, Any]) -> str:
    lines = [f"{report['benchmark_id']}: {report['status']}"]
    for case in report.get("cases", []):
        lines.append(
            f"- {case['name']}: bytes={case['payload_bytes']} "
            f"p50={case['client_process_ms']['p50']} ms "
            f"roundtrip={case['client_roundtrip_mib_per_second']['p50']} MiB/s"
        )
    return "\n".join(lines)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--repo-root", type=Path, default=root)
    parser.add_argument("--template", type=Path, default=root / "benchmarks" / "raw_tcp" / "stdnet_probe.cj.in")
    parser.add_argument("--artifact-dir", type=Path, default=root / "build" / "benchmarks" / "raw-tcp")
    parser.add_argument("--output", type=Path, default=root / "build" / "benchmarks" / "raw-tcp.json")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--quick", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.warmup < 0 or args.repetitions <= 0 or args.timeout_seconds <= 0:
        print("warmup must be >= 0, repetitions and timeout must be > 0", file=sys.stderr)
        return 2
    cases = [BenchmarkCase(*item) for item in DEFAULT_CASES]
    if args.quick:
        cases = cases[:3]
    try:
        report = execute(args.repo_root.resolve(), args.template.resolve(), args.artifact_dir.resolve(), cases, args.warmup, args.repetitions, args.timeout_seconds)
        atomic_write_json(args.output.resolve(), report)
    except (BaselineError, OSError, ValueError) as error:
        report = {
            "schema_version": SCHEMA_VERSION,
            "benchmark_id": "STD-NET-RAW-TCP-BASELINE",
            "status": "ERROR",
            "error": f"{type(error).__name__}: {error}",
            "finished_at_utc": utc_now(),
        }
        try:
            atomic_write_json(args.output.resolve(), report)
        except OSError:
            pass
        print(render_summary(report), file=sys.stderr)
        print(report["error"], file=sys.stderr)
        return 1
    print(render_summary(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
