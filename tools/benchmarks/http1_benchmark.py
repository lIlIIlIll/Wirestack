#!/usr/bin/env python3
"""Run reproducible Wirestack HTTP/1 benchmarks and emit JSON evidence."""
from __future__ import annotations

import argparse
import hashlib
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

MIB = 1024 * 1024
BENCH_RE = re.compile(
    r"^\s*HTTP1_BENCH scenario=(\S+) iterations=(\d+) durationNs=(\d+) "
    r"bytes=(\d+) checksum=(\d+)\s*$", re.MULTILINE
)
CASES = (
    ("keep_alive_small", "Http1KeepAliveBenchmarkTest"),
    ("stream_16mib", "Http1Stream16MiBBenchmarkTest"),
    ("stream_64mib", "Http1Stream64MiBBenchmarkTest"),
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


def run_case(repo: Path, scenario: str, test_class: str, timeout: float,
             command_prefix: Sequence[str]) -> dict[str, Any]:
    command = [*command_prefix, "cjpm", "test", "src/internal/http1", "-j", "1",
               "--parallel", "1", "--filter", test_class,
               "--show-all-output", "--no-progress", "--no-color"]
    process = subprocess.Popen(
        command, cwd=repo, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, errors="replace", shell=False,
        start_new_session=True,
    )
    sampler = ResourceSampler()
    sampler.start(process.pid)
    timed_out = False
    started = time.monotonic()
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
        stdout, stderr = process.communicate()
    finally:
        sampler.stop()
    matches = BENCH_RE.findall(stdout)
    if process.returncode != 0 or timed_out:
        raise BenchmarkError(
            f"{scenario} process failed: exit={process.returncode} timeout={timed_out}\n"
            f"{stderr[-4000:]}"
        )
    if len(matches) != 1 or matches[0][0] != scenario:
        raise BenchmarkError(f"{scenario} expected one matching HTTP1_BENCH record")
    _, iterations, duration_ns, byte_count, checksum = matches[0]
    duration = int(duration_ns)
    count = int(iterations)
    bytes_value = int(byte_count)
    return {
        "scenario": scenario,
        "iterations": count,
        "duration_ns": duration,
        "bytes": bytes_value,
        "checksum": int(checksum),
        "requests_per_second": round(count * 1_000_000_000 / duration, 3),
        "throughput_mib_per_second": (
            round((bytes_value / MIB) * 1_000_000_000 / duration, 3)
            if bytes_value else None
        ),
        "peak_rss_kib": sampler.peak_rss_kib,
        "peak_fd_count": sampler.peak_fd_count,
        "resource_samples": sampler.sample_count,
        "wall_duration_ms": round((time.monotonic() - started) * 1000, 3),
        "command": command,
    }


def classify(cases: Mapping[str, Mapping[str, Any]],
             stdx_baseline_rps: float | None) -> dict[str, Any]:
    small = cases["keep_alive_small"]
    stream16 = cases["stream_16mib"]
    stream64 = cases["stream_64mib"]
    rss_growth = int(stream64["peak_rss_kib"]) - int(stream16["peak_rss_kib"])
    rss_ratio = (
        round(int(stream64["peak_rss_kib"]) / int(stream16["peak_rss_kib"]), 3)
        if int(stream16["peak_rss_kib"]) > 0 else None
    )
    bounded_memory = rss_growth <= 16 * 1024 and rss_ratio is not None and rss_ratio <= 1.5
    baseline = {
        "decision": "NOT_RUN",
        "stdx_requests_per_second": None,
        "wirestack_requests_per_second": small["requests_per_second"],
        "ratio": None,
        "required_ratio": 0.9,
    }
    if stdx_baseline_rps is not None:
        ratio = float(small["requests_per_second"]) / stdx_baseline_rps
        baseline.update({
            "decision": "PASS" if ratio >= 0.9 else "FAIL",
            "stdx_requests_per_second": stdx_baseline_rps,
            "ratio": round(ratio, 4),
        })
    memory = {
        "decision": "PASS" if bounded_memory else "FAIL",
        "rss_growth_kib": rss_growth,
        "rss_ratio": rss_ratio,
        "maximum_growth_kib": 16 * 1024,
        "maximum_ratio": 1.5,
    }
    overall = "PASS"
    if memory["decision"] == "FAIL" or baseline["decision"] == "FAIL":
        overall = "FAIL"
    elif baseline["decision"] == "NOT_RUN":
        overall = "PARTIAL"
    return {"decision": overall, "stdx_comparison": baseline, "streaming_memory": memory}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--stdx-baseline-rps", type=float)
    parser.add_argument("--allow-missing-stdx-baseline", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--command-prefix", nargs="+",
        default=["/home/elliot/.codex/scripts/codex_cangjie_env"],
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.stdx_baseline_rps is not None and args.stdx_baseline_rps <= 0:
        raise BenchmarkError("stdx baseline must be positive")
    repo = args.repo.resolve()
    cases = {
        scenario: run_case(repo, scenario, test_class, args.timeout_seconds,
                           args.command_prefix)
        for scenario, test_class in CASES
    }
    result = {
        "schema_version": 1,
        "platform": {
            "system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "python": platform.python_version(),
        },
        "source": {
            "benchmark_runner_sha256": sha256(Path(__file__)),
            "harness_sha256": sha256(repo / "src/internal/http1/benchmark_harness_test.cj"),
        },
        "cases": cases,
        **classify(cases, args.stdx_baseline_rps),
    }
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    if result["decision"] == "FAIL":
        return 1
    if result["decision"] == "PARTIAL" and not args.allow_missing_stdx_baseline:
        return 3
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"HTTP1_BENCH_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
