#!/usr/bin/env python3
"""Close the Linux GATE-NET-06 production cleanup gaps without rerunning soak."""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import statistics
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from net06_leak_soak import atomic_json, resource_aggregate, resource_trend

SOAK_SECONDS = 86_400
FORMAL_ITERATIONS = 100_000
HEAP_LIMIT_BYTES = 8 * 1024 * 1024
HEAP_RE = re.compile(r"^\s*NET06_HEAP scenario=(\S+) index=(\d+) usedHeapBytes=(\d+)\s*$", re.M)
CANCEL_RE = re.compile(
    r"^\s*NET06_CANCELLATION requested=(\d+) completed=(\d+) joinedTasks=(\d+) "
    r"activeReads=(\d+) backgroundTasks=(\d+)\s*$", re.M)
TLS_RE = re.compile(
    r"^\s*NET06_TLS_TRANSPORT requested=(\d+) completed=(\d+) engineClosed=(\d+) "
    r"transportAborted=(\d+) terminalDisposals=(\d+) backgroundTasks=(\d+)\s*$", re.M)


class GateError(RuntimeError):
    pass


def one_match(pattern: re.Pattern[str], text: str, label: str) -> tuple[int, ...]:
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise GateError(f"expected one {label} marker, found {len(matches)}")
    return tuple(int(value) for value in matches[0])


def heap_trend(text: str, scenario: str) -> dict[str, Any]:
    samples = [
        {"index": int(index), "used_heap_bytes": int(value)}
        for name, index, value in HEAP_RE.findall(text) if name == scenario
    ]
    if len(samples) < 2:
        return {"decision": "INCONCLUSIVE", "samples": samples, "growth_bytes": None}
    window = max(1, len(samples) // 5)
    first = sorted(item["used_heap_bytes"] for item in samples[:window])
    last = sorted(item["used_heap_bytes"] for item in samples[-window:])
    growth = last[len(last) // 2] - first[len(first) // 2]
    return {
        "decision": "PASS" if growth <= HEAP_LIMIT_BYTES else "FAIL",
        "samples": samples,
        "growth_bytes": growth,
        "growth_limit_bytes": HEAP_LIMIT_BYTES,
    }


def descendants(root_pid: int) -> set[int]:
    parent_by_pid: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            for line in (entry / "status").read_text(encoding="utf-8").splitlines():
                if line.startswith("PPid:"):
                    parent_by_pid[int(entry.name)] = int(line.split()[1])
                    break
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            continue
    result = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, parent in parent_by_pid.items():
            if parent in result and pid not in result:
                result.add(pid)
                changed = True
    return result


def process_tree_snapshot(root_pid: int, elapsed_ms: int) -> dict[str, int]:
    sample = {
        "elapsed_ms": elapsed_ms, "process_count": 0, "rss_kib": 0,
        "fd_count": 0, "socket_count": 0, "timerfd_count": 0,
        "thread_count": 0,
    }
    for pid in descendants(root_pid):
        status = Path(f"/proc/{pid}/status")
        fd_dir = Path(f"/proc/{pid}/fd")
        try:
            lines = status.read_text(encoding="utf-8").splitlines()
            entries = list(fd_dir.iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        links: list[str] = []
        for item in entries:
            try:
                links.append(item.readlink().as_posix())
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        sample["process_count"] += 1
        for line in lines:
            if line.startswith("VmRSS:"):
                sample["rss_kib"] += int(line.split()[1])
            elif line.startswith("Threads:"):
                sample["thread_count"] += int(line.split()[1])
        sample["fd_count"] += len(entries)
        sample["socket_count"] += sum(link.startswith("socket:[") for link in links)
        sample["timerfd_count"] += sum(link == "anon_inode:[timerfd]" for link in links)
    return sample


class ProcessTreeSampler:
    def __init__(self, interval: float) -> None:
        self.interval = interval
        self.samples: list[dict[str, int]] = []
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        started = time.monotonic_ns()
        def sample() -> None:
            while not self.stop_event.is_set():
                item = process_tree_snapshot(
                    pid, int((time.monotonic_ns() - started) / 1_000_000))
                if item["process_count"]:
                    self.samples.append(item)
                self.stop_event.wait(self.interval)
        self.thread = threading.Thread(target=sample, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(2)
            if self.thread.is_alive():
                raise GateError("process tree sampler did not stop")


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run_case(package: str, filter_name: str, iterations: int, timeout: float,
             interval: float) -> tuple[dict[str, Any], list[dict[str, int]]]:
    base_command = [
        "/home/elliot/.codex/scripts/codex_cangjie_env", "--cwd", str(ROOT),
        "cjpm", "test", package, "-j", "1", "--parallel", "1",
        "--filter", filter_name, "--show-all-output", "--no-progress", "--no-color",
    ]
    env = os.environ.copy()
    env["DISABLE_ZOXIDE"] = "1"
    env["WIRESTACK_NET06_ITERATIONS"] = str(iterations)
    prepare_env = env.copy()
    prepare_env["WIRESTACK_NET06_ITERATIONS"] = "1"
    prepared = subprocess.run(
        base_command, cwd=ROOT, env=prepare_env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", timeout=timeout, check=False,
    )
    if prepared.returncode != 0:
        raise GateError(
            f"preparing {filter_name} failed: {(prepared.stderr or prepared.stdout)[-2000:]}")
    command = [*base_command, "--skip-build"]
    started = time.monotonic()
    process = subprocess.Popen(
        command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", start_new_session=True,
    )
    sampler = ProcessTreeSampler(interval)
    sampler.start(process.pid)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate(process)
        stdout, stderr = process.communicate()
    finally:
        sampler.stop()
    return ({
        "command": command, "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000, 3),
        "preparation": {"command": base_command, "exit_code": prepared.returncode},
        "stdout": stdout[-1024 * 1024:], "stderr": stderr[-1024 * 1024:],
    }, sampler.samples)


def resource_summary(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    trend = resource_trend(samples)
    maxima = {
        key: max((int(item[key]) for item in samples), default=None)
        for key in ("process_count", "socket_count", "timerfd_count", "thread_count")
    }
    lifecycle_trend: dict[str, Any]
    if len(samples) < 20:
        lifecycle_trend = {"decision": "INCONCLUSIVE", "reason": "fewer than 20 samples"}
    else:
        warmup = max(1, len(samples) // 5)
        steady = samples[warmup:]
        window = max(1, len(steady) // 5)
        limits = {"process_count": 0, "socket_count": 1,
                  "timerfd_count": 0, "thread_count": 2}
        growth: dict[str, Any] = {}
        passed = True
        for key, limit in limits.items():
            first = statistics.median(float(item[key]) for item in steady[:window])
            last = statistics.median(float(item[key]) for item in steady[-window:])
            delta = last - first
            growth[key] = {"first_median": first, "last_median": last,
                           "growth": delta, "growth_limit": limit}
            passed = passed and delta <= limit
        lifecycle_trend = {"decision": "PASS" if passed else "FAIL", "growth": growth}
    return {"aggregate": resource_aggregate(samples), "trend": trend,
            "lifecycle_trend": lifecycle_trend,
            "maxima": maxima, "samples": list(samples)}


def validate_soak(path: Path) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    soak = report.get("soak") or {}
    valid = (
        report.get("task_id") == "M0-011" and report.get("gate_id") == "GATE-NET-06" and
        report.get("linux_profile_status") == "PASS" and
        soak.get("requested_seconds", 0) >= SOAK_SECONDS and
        soak.get("decision") == "PASS" and
        (soak.get("resources") or {}).get("trend", {}).get("decision") == "PASS"
    )
    if not valid:
        raise GateError("reused soak report is not formal PASS evidence")
    return {"path": str(path), "sha256": evidence_digest.text_evidence_sha256(path), "repository_revision":
            report.get("repository_revision", "4323da2"), "seconds": soak["requested_seconds"],
            "iterations": soak.get("iterations"), "decision": "PASS"}


def validate_provider(path: Path) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    valid = (
        report.get("task_id") == "M0-011" and report.get("gate_id") == "GATE-NET-06" and
        report.get("decision") == "PASS" and
        report.get("requested_cycles", 0) >= FORMAL_ITERATIONS and
        report.get("completed_cycles") == report.get("requested_cycles") and
        (report.get("resources") or {}).get("trend", {}).get("decision") == "PASS" and
        not (report.get("build") or {}).get("system_tls_dependencies") and
        not (report.get("build") or {}).get("runtime_loader_library_strings")
    )
    if not valid:
        raise GateError("reused provider cleanup report is not formal PASS evidence")
    return {"path": str(path), "sha256": evidence_digest.text_evidence_sha256(path), "repository_revision":
            report.get("repository_revision"), "cycles": report["completed_cycles"],
            "decision": "PASS"}


def execute(iterations: int, timeout: float, interval: float,
            soak_path: Path, provider_path: Path, revision: str) -> dict[str, Any]:
    soak = validate_soak(soak_path)
    provider = validate_provider(provider_path)
    cancel_process, cancel_samples = run_case(
        "src/internal/transport_stdnet", "Net06CancellationGateTest",
        iterations, timeout, interval)
    cancel = one_match(CANCEL_RE, cancel_process["stdout"], "cancellation")
    cancel_heap = heap_trend(cancel_process["stdout"], "cancellation")
    cancel_resources = resource_summary(cancel_samples)
    cancel_pass = (
        cancel_process["exit_code"] == 0 and not cancel_process["timed_out"] and
        cancel == (iterations, iterations, iterations * 2, 0, 0) and
        cancel_heap["decision"] == "PASS" and
        cancel_resources["trend"]["decision"] == "PASS" and
        cancel_resources["lifecycle_trend"]["decision"] == "PASS"
    )
    tls_process, tls_samples = run_case(
        "src/internal/tls_engine", "Net06TlsTransportCleanupGateTest",
        iterations, timeout, interval)
    tls = one_match(TLS_RE, tls_process["stdout"], "TLS transport cleanup")
    tls_heap = heap_trend(tls_process["stdout"], "tls-transport-cleanup")
    tls_resources = resource_summary(tls_samples)
    tls_pass = (
        tls_process["exit_code"] == 0 and not tls_process["timed_out"] and
        tls == (iterations, iterations, iterations, iterations, iterations, 0) and
        tls_heap["decision"] == "PASS" and
        tls_resources["trend"]["decision"] == "PASS" and
        tls_resources["lifecycle_trend"]["decision"] == "PASS"
    )
    passed = iterations >= FORMAL_ITERATIONS and cancel_pass and tls_pass
    return {
        "schema_version": 1, "task_id": "M0-011", "gate_id": "GATE-NET-06",
        "platform_scope": "linux-x86_64", "repository_revision": revision,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "decision": "PASS" if passed else "INCOMPLETE",
        "reused_24_hour_soak": soak, "reused_aws_lc_cleanup": provider,
        "production_cancellation": {
            "decision": "PASS" if cancel_pass else "FAIL", "iterations": iterations,
            "marker": {"requested": cancel[0], "completed": cancel[1],
                       "joined_tasks": cancel[2], "active_reads": cancel[3],
                       "background_tasks": cancel[4]},
            "heap": cancel_heap, "resources": cancel_resources, "process": cancel_process,
        },
        "production_tls_transport_cleanup": {
            "decision": "PASS" if tls_pass else "FAIL", "iterations": iterations,
            "marker": {"requested": tls[0], "completed": tls[1],
                       "engine_closed": tls[2], "transport_aborted": tls[3],
                       "terminal_disposals": tls[4], "background_tasks": tls[5]},
            "heap": tls_heap, "resources": tls_resources, "process": tls_process,
        },
        "resource_coverage": {
            "socket_handles": "process-tree fd classification plus zero active reads",
            "timers": "process-tree timerfd classification and plateau trend",
            "waiters": "joined task counts plus zero active reads",
            "native_buffers": "AWS-LC RSS plateau plus exact TLS engine disposal",
            "gc_roots": "heavy-GC used-heap plateau",
            "background_tasks": "joined task and process-tree thread plateau",
        },
        "non_claims": ["not six-platform GATE-NET-06 completion"],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    evidence = ROOT / "docs/evidence/M0-011/linux_x86_64"
    parser.add_argument("--iterations", type=int, default=FORMAL_ITERATIONS)
    parser.add_argument("--timeout-seconds", type=float, default=7200)
    parser.add_argument("--sample-interval-seconds", type=float, default=0.1)
    parser.add_argument("--soak-report", type=Path, default=evidence / "linux-profile.json")
    parser.add_argument("--provider-cleanup-report", type=Path,
                        default=evidence / "tls-failure-cleanup.json")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "build/gates/net06-production-cleanup.json")
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "working-tree"))
    args = parser.parse_args(argv)
    if args.iterations <= 0 or args.sample_interval_seconds <= 0:
        parser.error("iterations and sample interval must be positive")
    try:
        report = execute(args.iterations, args.timeout_seconds,
                         args.sample_interval_seconds, args.soak_report.resolve(),
                         args.provider_cleanup_report.resolve(), args.repository_revision)
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-06 production cleanup: ERROR: {type(error).__name__}: {error}",
              file=sys.stderr)
        return 1
    print(f"M0-011 Linux production cleanup: {report['decision']} iterations={args.iterations} "
          f"reused-soak-seconds={report['reused_24_hour_soak']['seconds']}")
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
