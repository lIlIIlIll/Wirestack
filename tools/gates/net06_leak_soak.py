#!/usr/bin/env python3
"""Run bounded Linux x86_64 portions of GATE-NET-06.

The bounded run is evidence only. It cannot complete the gate's full iteration
counts, TLS cleanup workload, 24-hour soak, or six-platform matrix.
"""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import math
import os
import platform
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from net06_leak_soak_sources import STRESS_SOURCE

SCHEMA_VERSION = 1
RESULT_RE = re.compile(r"^RESULT\s+(.+)$", re.M)
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class Scenario:
    mode: str
    iterations: int


DEFAULT_SCENARIOS = (
    Scenario("connect-close", 2000),
    Scenario("echo-close", 1000),
    Scenario("peer-reset", 1000),
    Scenario("close-during-read", 500),
)

FULL_LINUX_SCENARIOS = (
    Scenario("connect-close", 100_000),
    Scenario("peer-reset", 100_000),
    Scenario("close-during-read", 100_000),
)

SOAK_MINIMUM_SECONDS = 24 * 60 * 60
RSS_GROWTH_LIMIT_KIB = 8192.0
FD_GROWTH_LIMIT = 1.0


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
        process.kill(); process.wait(timeout=2); return
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


class ResourceSampler:
    def __init__(self, interval_seconds: float = 0.01) -> None:
        self.interval_seconds = interval_seconds
        self.samples: list[dict[str, int]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        self.samples = []
        self._stop.clear()
        started = time.monotonic_ns()

        def run() -> None:
            status = Path(f"/proc/{pid}/status")
            fd_dir = Path(f"/proc/{pid}/fd")
            while not self._stop.is_set():
                rss: int | None = None
                fds: int | None = None
                try:
                    for line in status.read_text(encoding="utf-8").splitlines():
                        if line.startswith("VmRSS:"):
                            rss = int(line.split()[1]); break
                    fds = len(list(fd_dir.iterdir()))
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    pass
                if rss is not None and fds is not None:
                    self.samples.append({
                        "elapsed_ms": int((time.monotonic_ns() - started) / 1_000_000),
                        "rss_kib": rss, "fd_count": fds,
                    })
                self._stop.wait(self.interval_seconds)

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(2)
            if self._thread.is_alive():
                raise GateError("resource sampler leaked")


def run_process(command: Sequence[str], cwd: Path, timeout: float,
                sampler: ResourceSampler | None = None) -> dict[str, Any]:
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
    if sampler is not None:
        sampler.start(process.pid)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
        stdout, stderr = process.communicate()
    finally:
        if sampler is not None:
            sampler.stop()
    return {
        "command": list(command), "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000.0, 3),
        "stdout": stdout[-1024 * 1024:], "stderr": stderr[-1024 * 1024:],
    }


class StressServer:
    def __init__(self, mode: str, iterations: int, timeout: float) -> None:
        self.mode = mode
        self.iterations = iterations
        self.timeout = timeout
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(128)
        self.listener.settimeout(0.2)
        self.port = int(self.listener.getsockname()[1])
        self.accepted = 0
        self.bytes_received = 0
        self.bytes_echoed = 0
        self.reset_count = 0
        self.error: str | None = None
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _handle(self, connection: socket.socket) -> None:
        connection.settimeout(self.timeout)
        mode = self.mode
        if mode == "mixed-soak":
            modes = ("connect-close", "echo-close", "peer-reset", "close-during-read")
            mode = modes[(self.accepted - 1) % len(modes)]
        if mode == "connect-close":
            return
        if mode == "echo-close":
            data = bytearray()
            while len(data) < 64:
                chunk = connection.recv(64 - len(data))
                if not chunk:
                    raise GateError(f"echo peer EOF after {len(data)} bytes")
                data.extend(chunk)
            if any(value != 41 for value in data):
                raise GateError("echo payload mismatch")
            self.bytes_received += len(data)
            connection.sendall(data)
            self.bytes_echoed += len(data)
            return
        if mode == "peer-reset":
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                  struct.pack("ii", 1, 0))
            self.reset_count += 1
            return
        if mode == "close-during-read":
            while True:
                try:
                    data = connection.recv(64)
                except ConnectionResetError:
                    return
                if not data:
                    return
        raise GateError(f"unknown server mode: {self.mode}")

    def _run(self) -> None:
        self.ready.set()
        try:
            while not self.stop.is_set() and self.accepted < self.iterations:
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self.stop.is_set(): return
                    raise
                self.accepted += 1
                with connection:
                    self._handle(connection)
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
        finally:
            try:
                self.listener.close()
            except OSError:
                pass

    def __enter__(self) -> "StressServer":
        self.thread.start()
        if not self.ready.wait(2):
            raise GateError("stress server did not become ready")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop.set()
        try:
            self.listener.close()
        except OSError:
            pass
        self.thread.join(self.timeout + 2)
        if self.thread.is_alive():
            raise GateError("stress server leaked")
        if self.error and exc is None:
            raise GateError(self.error)


def parse_result(stdout: str) -> dict[str, str]:
    matches = RESULT_RE.findall(stdout)
    if len(matches) != 1:
        raise GateError(f"expected one RESULT line, found {len(matches)}")
    fields = dict(FIELD_RE.findall(matches[0]))
    required = {"mode", "iterations", "connected", "completed", "socketErrors",
                "otherErrors", "eof", "bytesWritten", "bytesRead",
                "closeErrors", "durationNs", "unknownMode"}
    missing = required - fields.keys()
    if missing:
        raise GateError(f"missing fields: {sorted(missing)}")
    return fields


def median(values: Sequence[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def resource_trend(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    """Detect sustained end-to-end growth after excluding process warmup."""
    if len(samples) < 20:
        return {"decision": "INCONCLUSIVE", "reason": "fewer than 20 samples"}
    warmup = max(1, len(samples) // 5)
    steady = samples[warmup:]
    window = max(1, len(steady) // 5)
    first = steady[:window]
    last = steady[-window:]
    first_rss = median([float(item["rss_kib"]) for item in first])
    last_rss = median([float(item["rss_kib"]) for item in last])
    first_fd = median([float(item["fd_count"]) for item in first])
    last_fd = median([float(item["fd_count"]) for item in last])
    rss_growth = last_rss - first_rss
    fd_growth = last_fd - first_fd
    decision = "PASS" if (
        rss_growth <= RSS_GROWTH_LIMIT_KIB and fd_growth <= FD_GROWTH_LIMIT
    ) else "FAIL"
    return {
        "decision": decision,
        "warmup_samples_excluded": warmup,
        "comparison_window_samples": window,
        "first_rss_median_kib": first_rss,
        "last_rss_median_kib": last_rss,
        "rss_growth_kib": rss_growth,
        "rss_growth_limit_kib": RSS_GROWTH_LIMIT_KIB,
        "first_fd_median": first_fd,
        "last_fd_median": last_fd,
        "fd_growth": fd_growth,
        "fd_growth_limit": FD_GROWTH_LIMIT,
    }


def resource_aggregate(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    if not samples:
        return {"sample_count": 0, "rss_kib": None, "fd_count": None}
    rss = [float(item["rss_kib"]) for item in samples]
    fds = [float(item["fd_count"]) for item in samples]
    return {
        "sample_count": len(samples),
        "rss_kib": {"first": rss[0], "last": rss[-1], "min": min(rss),
                    "max": max(rss), "p50": percentile(rss, 50),
                    "p95": percentile(rss, 95), "p99": percentile(rss, 99)},
        "fd_count": {"first": fds[0], "last": fds[-1], "min": min(fds),
                     "max": max(fds), "p50": percentile(fds, 50),
                     "p95": percentile(fds, 95), "p99": percentile(fds, 99)},
    }


def classify(scenario: Scenario, fields: Mapping[str, str], process: Mapping[str, Any],
             server: StressServer, sampler: ResourceSampler) -> dict[str, Any]:
    iterations = int(fields["iterations"])
    connected = int(fields["connected"])
    completed = int(fields["completed"])
    socket_errors = int(fields["socketErrors"])
    other_errors = int(fields["otherErrors"])
    eof = int(fields["eof"])
    bytes_written = int(fields["bytesWritten"])
    bytes_read = int(fields["bytesRead"])
    close_errors = int(fields["closeErrors"])
    mode_ok = fields["mode"] == scenario.mode and fields["unknownMode"] == "false"
    base_ok = (process["exit_code"] == 0 and not process["timed_out"] and mode_ok and
               iterations == scenario.iterations and
               completed == iterations and server.accepted == iterations and
               other_errors == 0 and close_errors == 0)
    if scenario.mode == "echo-close":
        base_ok = (base_ok and bytes_written == iterations * 64 and
                   bytes_read == iterations * 64 and
                   server.bytes_received == iterations * 64 and
                   server.bytes_echoed == iterations * 64)
    elif scenario.mode == "peer-reset":
        base_ok = (base_ok and connected <= iterations and
                   server.reset_count == iterations and socket_errors == iterations)
    elif scenario.mode == "close-during-read":
        base_ok = (base_ok and connected == iterations and
                   socket_errors + eof == iterations)
    else:
        base_ok = base_ok and connected == iterations
    return {
        "mode": scenario.mode, "decision": "PASS" if base_ok else "FAIL",
        "iterations": iterations, "connected": connected, "completed": completed,
        "socket_errors": socket_errors, "other_errors": other_errors, "eof": eof,
        "bytes_written": bytes_written, "bytes_read": bytes_read,
        "close_errors": close_errors,
        "server": {"accepted": server.accepted,
                   "bytes_received": server.bytes_received,
                   "bytes_echoed": server.bytes_echoed,
                   "reset_count": server.reset_count},
        "resources": {"aggregate": resource_aggregate(sampler.samples),
                      "trend": resource_trend(sampler.samples),
                      "samples": sampler.samples},
        "process": dict(process),
    }


def command_text(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                errors="replace", timeout=10)
    except Exception:
        return None
    return (result.stdout or result.stderr).strip()[:4096] or None


def compile_probe(artifacts: Path, timeout: float) -> tuple[Path, dict[str, Any]]:
    directory = artifacts / "probe"
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "net06_stress.cj"
    binary = directory / "net06_stress"
    source.write_text(STRESS_SOURCE, encoding="utf-8")
    process = run_process(["cjc", str(source), "-o", str(binary)], directory, timeout)
    if process["timed_out"] or process["exit_code"] != 0 or not binary.is_file():
        raise GateError(f"probe compile failed: {process}")
    return binary, {"source_sha256": evidence_digest.text_evidence_bytes_sha256(STRESS_SOURCE.encode()),
                    "process": process}


def execute(artifacts: Path, scenarios: Sequence[Scenario], timeout: float,
            revision: str, sample_interval: float = 0.01,
            soak_seconds: int = 0) -> dict[str, Any]:
    artifacts.mkdir(parents=True, exist_ok=True)
    binary, compile_info = compile_probe(artifacts, timeout)
    results = []
    for scenario in scenarios:
        sampler = ResourceSampler(sample_interval)
        with StressServer(scenario.mode, scenario.iterations, timeout) as server:
            process = run_process([str(binary), scenario.mode, str(server.port),
                                   str(scenario.iterations)], artifacts / "probe",
                                  timeout, sampler)
        results.append(classify(scenario, parse_result(process["stdout"]),
                                process, server, sampler))
    soak = None
    if soak_seconds > 0:
        sampler = ResourceSampler(sample_interval)
        with StressServer("mixed-soak", sys.maxsize, timeout) as server:
            process = run_process([str(binary), "mixed-soak", str(server.port),
                                   str(soak_seconds)], artifacts / "probe",
                                  soak_seconds + timeout, sampler)
        fields = parse_result(process["stdout"])
        iterations = int(fields["iterations"])
        trend = resource_trend(sampler.samples)
        passed = (
            process["exit_code"] == 0 and not process["timed_out"] and
            fields["mode"] == "mixed-soak" and iterations > 0 and
            int(fields["completed"]) == iterations and
            int(fields["otherErrors"]) == 0 and
            int(fields["closeErrors"]) == 0 and server.accepted == iterations and
            trend["decision"] == "PASS"
        )
        soak = {
            "decision": "PASS" if passed else "FAIL",
            "requested_seconds": soak_seconds,
            "iterations": iterations,
            "connected": int(fields["connected"]),
            "completed": int(fields["completed"]),
            "socket_errors": int(fields["socketErrors"]),
            "eof": int(fields["eof"]),
            "server_accepted": server.accepted,
            "resources": {"aggregate": resource_aggregate(sampler.samples),
                          "trend": trend, "samples": sampler.samples},
            "process": dict(process),
        }
    bounded_status = "PASS" if all(item["decision"] == "PASS" for item in results) else "FAIL"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-011", "task_status": "INCOMPLETE",
        "gate_id": "GATE-NET-06", "bounded_linux_status": bounded_status,
        "global_gate_status": "INCOMPLETE",
        "environment": {"repository_revision": revision,
                        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "os": platform.platform(), "architecture": platform.machine(),
                        "python": sys.version.splitlines()[0],
                        "cjc": command_text(["cjc", "--version"]),
                        "cjpm": command_text(["cjpm", "--version"]),
                        "cangjie_home": os.environ.get("CANGJIE_HOME")},
        "compile": compile_info, "scenarios": results, "soak": soak,
        "deferred": [
            {"id": "100000-transport-cleanups", "status": "NOT_RUN"},
            {"id": "100000-tls-handshake-failure-cleanups", "status": "NOT_YET_APPLICABLE"},
            {"id": "24-hour-idle-active-soak", "status":
             "PASS" if soak is not None and soak["decision"] == "PASS" and
             soak_seconds >= SOAK_MINIMUM_SECONDS else "NOT_RUN"},
            {"id": "windows-native", "status": "BLOCKED"},
            {"id": "macos-native", "status": "BLOCKED"},
            {"id": "android-native", "status": "BLOCKED"},
            {"id": "ios-native", "status": "BLOCKED"},
            {"id": "harmony-native", "status": "BLOCKED"},
        ],
        "non_claims": ["not full GATE-NET-06 completion",
                       "not a 24-hour soak", "not TLS cleanup evidence",
                       "not six-platform evidence"],
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


def parse_scenarios(text: str) -> tuple[Scenario, ...]:
    result = []
    for item in text.split(","):
        mode, raw = item.split(":", 1)
        iterations = int(raw)
        if iterations <= 0:
            raise argparse.ArgumentTypeError("iterations must be positive")
        result.append(Scenario(mode, iterations))
    return tuple(result)


def load_tls_cleanup_report(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    value = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "schema_version": 1,
        "task_id": "M0-011",
        "scenario": "tls-handshake-failure-cleanup",
        "requested_cycles": 100_000,
        "completed_cycles": 100_000,
        "decision": "PASS",
    }
    for key, expected in required.items():
        if value.get(key) != expected:
            raise GateError(
                f"TLS cleanup report {key}={value.get(key)!r}, expected {expected!r}")
    trend = value.get("resources", {}).get("trend", {})
    if trend.get("decision") != "PASS":
        raise GateError("TLS cleanup report lacks PASS resource trend")
    build = value.get("build", {})
    if build.get("system_tls_dependencies") or build.get("runtime_loader_library_strings"):
        raise GateError("TLS cleanup report contains a forbidden system TLS dependency")
    return value


def transport_cleanup_pass(results: Sequence[Mapping[str, Any]]) -> bool:
    by_mode = {item["mode"]: item for item in results}
    return all(
        mode in by_mode and by_mode[mode]["decision"] == "PASS" and
        by_mode[mode]["iterations"] >= 100_000
        for mode in ("connect-close", "peer-reset", "close-during-read")
    )


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path,
                        default=root / "build/gates/net06-leak-soak")
    parser.add_argument("--output", type=Path,
                        default=root / "build/gates/net06-leak-soak.json")
    parser.add_argument("--scenarios", type=parse_scenarios,
                        default=DEFAULT_SCENARIOS)
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--full-linux", action="store_true")
    parser.add_argument("--soak-seconds", type=int, default=0)
    parser.add_argument("--sample-interval-seconds", type=float, default=0.01)
    parser.add_argument("--tls-cleanup-report", type=Path)
    args = parser.parse_args(argv)
    scenarios = args.scenarios
    if args.quick:
        scenarios = tuple(Scenario(item.mode, min(item.iterations, 5)) for item in DEFAULT_SCENARIOS)
    elif args.full_linux:
        scenarios = FULL_LINUX_SCENARIOS
    if args.soak_seconds < 0:
        parser.error("--soak-seconds must be non-negative")
    if args.sample_interval_seconds <= 0:
        parser.error("--sample-interval-seconds must be positive")
    try:
        tls_cleanup = load_tls_cleanup_report(
            args.tls_cleanup_report.resolve() if args.tls_cleanup_report else None)
        report = execute(args.artifact_dir.resolve(), scenarios,
                         args.timeout_seconds, args.repository_revision,
                         args.sample_interval_seconds, args.soak_seconds)
        report["tls_handshake_failure_cleanup"] = tls_cleanup
        transport_pass = transport_cleanup_pass(report["scenarios"])
        soak_pass = (
            report["soak"] is not None and report["soak"]["decision"] == "PASS" and
            report["soak"]["requested_seconds"] >= SOAK_MINIMUM_SECONDS
        )
        tls_pass = tls_cleanup is not None
        report["linux_profile_status"] = (
            "PASS" if transport_pass and soak_pass and tls_pass else "INCOMPLETE")
        non_claims = ["not full GATE-NET-06 completion", "not six-platform evidence"]
        if not transport_pass:
            non_claims.append("not 100000-cleanup transport evidence")
        if not soak_pass:
            non_claims.append("not a 24-hour soak")
        if not tls_pass:
            non_claims.append("not TLS cleanup evidence")
        report["non_claims"] = non_claims
        for item in report["deferred"]:
            if item["id"] == "100000-transport-cleanups":
                item["status"] = "PASS" if transport_pass else "NOT_RUN"
            elif item["id"] == "100000-tls-handshake-failure-cleanups":
                item["status"] = "PASS" if tls_pass else "NOT_RUN"
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-06: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M0-011 Linux={report['linux_profile_status']} "
          f"bounded-Linux={report['bounded_linux_status']} global=INCOMPLETE")
    for item in report["scenarios"]:
        resources = item["resources"]["aggregate"]
        print(f"- {item['mode']}: {item['decision']} iterations={item['iterations']} "
              f"rss-max={resources['rss_kib']['max'] if resources['rss_kib'] else None} KiB "
              f"fd-max={resources['fd_count']['max'] if resources['fd_count'] else None}")
    if report["soak"] is not None:
        soak = report["soak"]
        print(f"- mixed-soak: {soak['decision']} seconds={soak['requested_seconds']} "
              f"iterations={soak['iterations']} trend={soak['resources']['trend']['decision']}")
    passed = (report["linux_profile_status"] == "PASS" if args.full_linux else
              report["bounded_linux_status"] == "PASS")
    if not args.full_linux and report["soak"] is not None:
        passed = passed and report["soak"]["decision"] == "PASS"
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
