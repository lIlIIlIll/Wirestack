#!/usr/bin/env python3
"""Run reproducible Linux HTTP/2 1/10/100-stream benchmarks."""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import json
import os
import platform
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

BENCH_RE = re.compile(
    r"^\s*HTTP2_BENCH scenario=(\S+) concurrency=(\d+) measuredRequests=(\d+) "
    r"durationNs=(\d+) connections=(\d+) maxPendingWrites=(\d+) "
    r"maxPendingWriteBytes=(\d+) pendingWrites=(\d+) pendingFlowPermits=(\d+) "
    r"flowControlStalls=(\d+) checksum=(\d+) latenciesNs=([0-9,]+)\s*$",
    re.MULTILINE,
)
BASELINE_RE = re.compile(
    r"^\s*HTTP2_BASELINE protocol=http1 concurrency=(\d+) requests=(\d+) "
    r"durationNs=(\d+) connections=(\d+) checksum=(\d+)\s*$",
    re.MULTILINE,
)
CASES = (
    ("streams_1", 1, "Http2Streams1BenchmarkTest"),
    ("streams_10", 10, "Http2Streams10BenchmarkTest"),
    ("streams_100", 100, "Http2Streams100BenchmarkTest"),
)
PRODUCTION_SOURCE_DIRECTORIES = (
    "src/internal/http1",
    "src/internal/http2",
    "src/internal/http_model",
    "src/internal/transport",
)


class BenchmarkError(RuntimeError):
    pass


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def read_process_snapshot() -> dict[int, tuple[int, int, int]]:
    snapshot: dict[int, tuple[int, int, int]] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            ppid = 0
            rss_kib = 0
            for line in (entry / "status").read_text(encoding="utf-8").splitlines():
                if line.startswith("PPid:"):
                    ppid = int(line.split()[1])
                elif line.startswith("VmRSS:"):
                    rss_kib = int(line.split()[1])
            fd_count = sum(1 for _ in (entry / "fd").iterdir())
            snapshot[int(entry.name)] = (ppid, rss_kib, fd_count)
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            continue
    return snapshot


def descendant_totals(root_pid: int,
                      snapshot: Mapping[int, tuple[int, int, int]]) -> tuple[int, int]:
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _, _) in snapshot.items():
            if ppid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    rss = sum(snapshot[pid][1] for pid in descendants if pid in snapshot)
    fds = sum(snapshot[pid][2] for pid in descendants if pid in snapshot)
    return rss, fds


class ResourceSampler:
    def __init__(self, interval_seconds: float = 0.01) -> None:
        self.interval_seconds = interval_seconds
        self.peak_rss_kib = 0
        self.peak_fd_count = 0
        self.sample_count = 0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, root_pid: int) -> None:
        def sample() -> None:
            while not self._stop.is_set():
                try:
                    rss, fds = descendant_totals(root_pid, read_process_snapshot())
                    self.peak_rss_kib = max(self.peak_rss_kib, rss)
                    self.peak_fd_count = max(self.peak_fd_count, fds)
                    self.sample_count += 1
                except (FileNotFoundError, PermissionError):
                    pass
                self._stop.wait(self.interval_seconds)
        self._thread = threading.Thread(target=sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(2)
            if self._thread.is_alive():
                raise BenchmarkError("resource sampler thread leaked")


def nearest_rank(values: Sequence[int], percentile: float) -> int:
    if not values or percentile <= 0 or percentile > 1:
        raise BenchmarkError("percentile input is invalid")
    ordered = sorted(values)
    rank = max(1, (len(ordered) * int(percentile * 100) + 99) // 100)
    return ordered[min(rank, len(ordered)) - 1]


def test_command(command_prefix: Sequence[str], test_class: str) -> list[str]:
    return [
        *command_prefix, "cjpm", "test", "src/internal/http1", "-j", "1",
        "--parallel", "1", "--filter", test_class,
        "--show-all-output", "--no-progress", "--no-color",
    ]


def run_process(repo: Path, command: Sequence[str], timeout: float) -> tuple[str, ResourceSampler, float]:
    process = subprocess.Popen(
        list(command), cwd=repo, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", shell=False, start_new_session=True,
    )
    sampler = ResourceSampler()
    sampler.start(process.pid)
    started = time.monotonic()
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
        stdout, stderr = process.communicate()
    finally:
        sampler.stop()
    wall_ms = round((time.monotonic() - started) * 1000, 3)
    if process.returncode != 0 or timed_out:
        raise BenchmarkError(
            f"benchmark process failed: exit={process.returncode} timeout={timed_out}\n"
            f"stdout tail:\n{stdout[-4000:]}\nstderr tail:\n{stderr[-4000:]}"
        )
    return stdout, sampler, wall_ms


def run_case(repo: Path, scenario: str, concurrency: int, test_class: str,
             timeout: float, command_prefix: Sequence[str], pass_name: str) -> dict[str, Any]:
    command = test_command(command_prefix, test_class)
    stdout, sampler, wall_ms = run_process(repo, command, timeout)
    matches = BENCH_RE.findall(stdout)
    if len(matches) != 1 or matches[0][0] != scenario:
        raise BenchmarkError(f"{scenario} expected one matching HTTP2_BENCH record")
    (name, raw_concurrency, measured, duration, connections, max_writes,
     max_bytes, pending_writes, pending_permits, stalls, checksum, raw_latencies) = matches[0]
    latencies = [int(value) for value in raw_latencies.split(",")]
    if int(raw_concurrency) != concurrency or len(latencies) != int(measured):
        raise BenchmarkError(f"{scenario} record has inconsistent concurrency or latency count")
    return {
        "pass": pass_name, "scenario": name, "concurrency": concurrency,
        "measured_requests": int(measured), "duration_ns": int(duration),
        "connections": int(connections), "maximum_pending_writes": int(max_writes),
        "maximum_pending_write_bytes": int(max_bytes), "pending_writes": int(pending_writes),
        "pending_flow_permits": int(pending_permits), "flow_control_stalls": int(stalls),
        "checksum": int(checksum), "latencies_ns": latencies,
        "peak_rss_kib": sampler.peak_rss_kib, "peak_fd_count": sampler.peak_fd_count,
        "resource_samples": sampler.sample_count, "wall_duration_ms": wall_ms,
        "command": command,
    }


def run_baseline(repo: Path, timeout: float, command_prefix: Sequence[str]) -> dict[str, Any]:
    command = test_command(command_prefix, "Http1HundredConnectionBaselineTest")
    stdout, sampler, wall_ms = run_process(repo, command, timeout)
    matches = BASELINE_RE.findall(stdout)
    if len(matches) != 1:
        raise BenchmarkError("HTTP/1 baseline expected one matching HTTP2_BASELINE record")
    concurrency, requests, duration, connections, checksum = (int(value) for value in matches[0])
    return {
        "protocol": "http1", "concurrency": concurrency, "requests": requests,
        "duration_ns": duration, "connections": connections, "checksum": checksum,
        "peak_rss_kib": sampler.peak_rss_kib, "peak_fd_count": sampler.peak_fd_count,
        "resource_samples": sampler.sample_count, "wall_duration_ms": wall_ms,
        "command": command,
    }


def aggregate(passes: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    latencies = [value for item in passes for value in item["latencies_ns"]]
    requests = sum(int(item["measured_requests"]) for item in passes)
    duration = sum(int(item["duration_ns"]) for item in passes)
    return {
        "concurrency": int(passes[0]["concurrency"]),
        "measured_requests": requests,
        "duration_ns": duration,
        "requests_per_second": round(requests * 1_000_000_000 / duration, 3),
        "p50_latency_ns": nearest_rank(latencies, 0.50),
        "p95_latency_ns": nearest_rank(latencies, 0.95),
        "p99_latency_ns": nearest_rank(latencies, 0.99),
        "connections": max(int(item["connections"]) for item in passes),
        "peak_rss_kib": max(int(item["peak_rss_kib"]) for item in passes),
        "peak_fd_count": max(int(item["peak_fd_count"]) for item in passes),
        "maximum_pending_writes": max(int(item["maximum_pending_writes"]) for item in passes),
        "maximum_pending_write_bytes": max(int(item["maximum_pending_write_bytes"]) for item in passes),
        "maximum_observed_pending_writes": max(int(item["pending_writes"]) for item in passes),
        "maximum_observed_pending_flow_permits": max(int(item["pending_flow_permits"]) for item in passes),
        "flow_control_stalls": sum(int(item["flow_control_stalls"]) for item in passes),
        "raw_passes": list(passes),
    }


def classify(cases: Mapping[str, Mapping[str, Any]], baseline: Mapping[str, Any]) -> dict[str, Any]:
    reasons: list[str] = []
    for name, case in cases.items():
        if int(case["connections"]) != 1:
            reasons.append(f"{name} did not use exactly one HTTP/2 connection")
        if int(case["maximum_pending_writes"]) > 256:
            reasons.append(f"{name} exceeded the configured write-count bound")
        if int(case["maximum_pending_write_bytes"]) > 1_048_576:
            reasons.append(f"{name} exceeded the configured write-byte bound")
        if int(case["maximum_observed_pending_flow_permits"]) != 0:
            reasons.append(f"{name} retained flow permits after request completion")
        if int(case["requests_per_second"]) <= 0 or int(case["p99_latency_ns"]) <= 0:
            reasons.append(f"{name} produced invalid throughput or latency")
    h2_connections = int(cases["streams_100"]["connections"])
    h1_connections = int(baseline["connections"])
    ratio = h2_connections / h1_connections if h1_connections > 0 else 1.0
    reduction = {
        "decision": "PASS" if ratio <= 0.25 else "FAIL",
        "http2_connections": h2_connections,
        "http1_connections": h1_connections,
        "ratio": round(ratio, 4),
        "required_maximum_ratio": 0.25,
        "reduction_percent": round((1.0 - ratio) * 100, 2),
    }
    if reduction["decision"] != "PASS":
        reasons.append("100-stream HTTP/2 connection reduction was not significant")
    return {"decision": "PASS" if not reasons else "FAIL", "reasons": reasons,
            "connection_reduction": reduction}


def production_source_sha256(repo: Path) -> str:
    paths: list[Path] = []
    for directory in PRODUCTION_SOURCE_DIRECTORIES:
        paths.extend(
            path for path in (repo / directory).glob("*.cj")
            if not path.name.endswith("_test.cj")
        )
    if not paths:
        raise BenchmarkError("HTTP/2 production source inventory is empty")
    return evidence_digest.text_evidence_inventory_sha256(repo, paths)


def tool_version(command: Sequence[str], repo: Path) -> str:
    completed = subprocess.run(command, cwd=repo, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace", timeout=10, check=False)
    return completed.stdout.strip()[:4096]


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--command-prefix", nargs="+",
                        default=["/home/elliot/.codex/scripts/codex_cangjie_env"])
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo = args.repo.resolve()
    collected: dict[str, list[dict[str, Any]]] = {name: [] for name, _, _ in CASES}
    for name, concurrency, test_class in CASES:
        collected[name].append(run_case(repo, name, concurrency, test_class,
                                        args.timeout_seconds, args.command_prefix, "forward"))
    baseline = run_baseline(repo, args.timeout_seconds, args.command_prefix)
    for name, concurrency, test_class in reversed(CASES):
        collected[name].append(run_case(repo, name, concurrency, test_class,
                                        args.timeout_seconds, args.command_prefix, "reverse"))
    cases = {name: aggregate(passes) for name, passes in collected.items()}
    decision = classify(cases, baseline)
    result = {
        "schema_version": 1,
        "platform": {"system": platform.system(), "release": platform.release(),
                     "machine": platform.machine(), "python": platform.python_version()},
        "toolchain": {"cjc": tool_version(["cjc", "-v"], repo),
                      "cjpm": tool_version(["cjpm", "-v"], repo)},
        "source": {
            "benchmark_runner_sha256": evidence_digest.text_evidence_sha256(Path(__file__)),
            "harness_sha256": evidence_digest.text_evidence_sha256(repo / "src/internal/http1/http2_benchmark_harness_test.cj"),
            "production_source_sha256": production_source_sha256(repo),
        },
        "method": {"warmup_rounds_per_pass": 2, "measured_rounds_per_pass": 20,
                   "pass_order": [[1, 10, 100], [100, 10, 1]],
                   "percentile": "nearest-rank"},
        "cases": cases, "http1_100_concurrent_baseline": baseline, **decision,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"decision": result["decision"], "output": str(args.output)}))
    return 0 if result["decision"] == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"HTTP2_BENCH_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
