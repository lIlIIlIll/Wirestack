#!/usr/bin/env python3
"""Run the M6-023 Linux H1/H2 SSE steady-state profile in parallel."""
from __future__ import annotations

from tools import evidence_digest

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
ENV_RUNNER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")
FORMAL_SECONDS = 3600
FORMAL_EVENTS = 1_000_000
MAX_CANCEL_NS = 50_000_000
MAX_LEAD_EVENTS = 524_288
MAX_HEAP_GROWTH_BYTES = 32 * 1024 * 1024
MAX_RSS_GROWTH_KIB = 32 * 1024
MAX_RESOURCE_GROWTH = 2
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")
SAMPLE_RE = re.compile(r"^\s*SSE_SAMPLE\s+(.+)$", re.M)
RESULT_RE = re.compile(r"^\s*SSE_RESULT\s+(.+)$", re.M)


class GateError(RuntimeError):
    pass


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def fields(text: str) -> dict[str, str]:
    return dict(FIELD_RE.findall(text))


def parse_output(text: str, protocol: str) -> tuple[list[dict[str, int]], dict[str, str]]:
    samples = []
    for marker in SAMPLE_RE.findall(text):
        item = fields(marker)
        if item.get("protocol") == protocol:
            samples.append({key: int(value) for key, value in item.items() if key != "protocol"})
    results = [fields(marker) for marker in RESULT_RE.findall(text)]
    results = [item for item in results if item.get("protocol") == protocol]
    if len(results) != 1:
        raise GateError(f"expected one {protocol} SSE_RESULT, found {len(results)}")
    return samples, results[0]


def descendants(root_pid: int) -> set[int]:
    parents: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            status = (entry / "status").read_text(encoding="utf-8")
            parent = next(line for line in status.splitlines() if line.startswith("PPid:"))
            parents[int(entry.name)] = int(parent.split()[1])
        except (FileNotFoundError, PermissionError, ProcessLookupError, StopIteration, ValueError):
            continue
    result = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, parent in parents.items():
            if parent in result and pid not in result:
                result.add(pid)
                changed = True
    return result


def process_tree_snapshot(root_pid: int, elapsed_ms: int) -> dict[str, int]:
    sample = {"elapsed_ms": elapsed_ms, "process_count": 0, "rss_kib": 0,
              "fd_count": 0, "socket_count": 0, "thread_count": 0}
    for pid in descendants(root_pid):
        try:
            status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines()
            entries = list(Path(f"/proc/{pid}/fd").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        links = []
        for entry in entries:
            try:
                links.append(entry.readlink().as_posix())
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        sample["process_count"] += 1
        sample["fd_count"] += len(entries)
        sample["socket_count"] += sum(link.startswith("socket:[") for link in links)
        for line in status:
            if line.startswith("VmRSS:"):
                sample["rss_kib"] += int(line.split()[1])
            elif line.startswith("Threads:"):
                sample["thread_count"] += int(line.split()[1])
    return sample


class Sampler:
    def __init__(self, interval: float) -> None:
        self.interval = interval
        self.samples: list[dict[str, int]] = []
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        started = time.monotonic_ns()

        def run() -> None:
            while not self.stop_event.is_set():
                sample = process_tree_snapshot(pid, (time.monotonic_ns() - started) // 1_000_000)
                if sample["process_count"]:
                    self.samples.append(sample)
                self.stop_event.wait(self.interval)

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(5)
            if self.thread.is_alive():
                raise GateError("resource sampler did not stop")


def median_window(values: Sequence[int]) -> tuple[float, float]:
    warmup = max(1, len(values) // 5)
    steady = values[warmup:]
    width = max(1, len(steady) // 5)
    return statistics.median(steady[:width]), statistics.median(steady[-width:])


def heap_trend(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    values = [item["usedHeapBytes"] for item in samples]
    if len(values) < 5:
        return {"decision": "INCONCLUSIVE", "sample_count": len(values)}
    first, last = median_window(values)
    growth = last - first
    return {"decision": "PASS" if growth <= MAX_HEAP_GROWTH_BYTES else "FAIL",
            "sample_count": len(values), "first_median_bytes": first,
            "last_median_bytes": last, "growth_bytes": growth,
            "growth_limit_bytes": MAX_HEAP_GROWTH_BYTES}


def resource_trend(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    if len(samples) < 20:
        return {"decision": "INCONCLUSIVE", "sample_count": len(samples)}
    result: dict[str, Any] = {"sample_count": len(samples)}
    limits = {"rss_kib": MAX_RSS_GROWTH_KIB, "fd_count": MAX_RESOURCE_GROWTH,
              "socket_count": MAX_RESOURCE_GROWTH, "thread_count": MAX_RESOURCE_GROWTH}
    passed = True
    for name, limit in limits.items():
        first, last = median_window([item[name] for item in samples])
        growth = last - first
        result[name] = {"first_median": first, "last_median": last,
                        "growth": growth, "growth_limit": limit}
        passed = passed and growth <= limit
    result["decision"] = "PASS" if passed else "FAIL"
    return result


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def test_command(test_class: str, skip_build: bool) -> list[str]:
    command = [str(ENV_RUNNER), "--cwd", str(ROOT), "cjpm", "test", "src/http",
               "-j", "1", "--parallel", "1"]
    if skip_build:
        command.append("--skip-build")
    command += ["--filter", test_class, "--show-all-output", "--no-progress", "--no-color"]
    return command


def profile_environment(args: argparse.Namespace) -> dict[str, str]:
    env = os.environ.copy()
    env.update({"DISABLE_ZOXIDE": "1", "WIRESTACK_SSE_DURATION_SECONDS": str(args.duration_seconds),
                "WIRESTACK_SSE_MIN_EVENTS": str(args.minimum_events),
                "WIRESTACK_SSE_SLOW_SECONDS": str(args.slow_seconds),
                "WIRESTACK_SSE_SLOW_DELAY_MS": str(args.slow_delay_ms),
                "WIRESTACK_SSE_SAMPLE_SECONDS": str(args.heap_sample_seconds),
                "WIRESTACK_SSE_FAST_PRODUCER_MS": str(args.fast_producer_ms),
                "WIRESTACK_SSE_STEADY_PRODUCER_MS": str(args.steady_producer_ms),
                "WIRESTACK_SSE_EVENTS_PER_READ": str(args.events_per_read),
                "WIRESTACK_SSE_CLIENT_READ_BYTES": str(args.client_read_bytes)})
    return env


def preflight(env: Mapping[str, str], timeout: float) -> dict[str, Any]:
    quick = dict(env)
    quick["WIRESTACK_SSE_DURATION_SECONDS"] = "1"
    quick["WIRESTACK_SSE_MIN_EVENTS"] = "100"
    # Building one class produces the shared test binary. Avoid compressing the
    # H2 slow-consumer/sibling schedule into this one-second compile smoke.
    command = test_command("Http1SseStreamingProfileTest", False)
    result = subprocess.run(command, cwd=ROOT, env=quick, capture_output=True, text=True,
                            errors="replace", timeout=timeout)
    if result.returncode != 0:
        raise GateError(f"SSE preflight failed: {(result.stdout + result.stderr)[-4096:]}")
    return {"command": command, "exit_code": result.returncode}


def run_profile(protocol: str, test_class: str, env: Mapping[str, str], timeout: float,
                sample_interval: float) -> dict[str, Any]:
    command = test_command(test_class, True)
    started = time.monotonic_ns()
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, errors="replace",
                               start_new_session=True)
    sampler = Sampler(sample_interval)
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
    elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
    heap_samples, marker = parse_output(stdout + "\n" + stderr, protocol)
    heap = heap_trend(heap_samples)
    resources = resource_trend(sampler.samples)
    formal_case = (int(env["WIRESTACK_SSE_DURATION_SECONDS"]) >= FORMAL_SECONDS and
                   int(env["WIRESTACK_SSE_MIN_EVENTS"]) >= FORMAL_EVENTS)
    trends_ok = ((heap["decision"] == "PASS" and resources["decision"] == "PASS")
                 if formal_case else
                 (heap["decision"] != "FAIL" and resources["decision"] != "FAIL"))
    expected_sibling = protocol == "h2"
    passed = (process.returncode == 0 and not timed_out and
              int(marker["requestedSeconds"]) >= int(env["WIRESTACK_SSE_DURATION_SECONDS"]) and
              int(marker["elapsedMs"]) >= int(env["WIRESTACK_SSE_DURATION_SECONDS"]) * 1000 and
              int(marker["events"]) >= int(env["WIRESTACK_SSE_MIN_EVENTS"]) and
              int(marker["sequenceErrors"]) == 0 and
              int(marker["maxLeadEvents"]) <= MAX_LEAD_EVENTS and
              int(marker["slowLeadEvents"]) > 0 and int(marker["slowReadGapNs"]) > 0 and
              int(marker["cancelLatencyNs"]) <= MAX_CANCEL_NS and
              int(marker["bodyLimitBytes"]) == 65536 and
              int(marker["applicationPendingBytes"]) == 0 and
              (marker["siblingBefore"] == "true") == expected_sibling and
              (marker["siblingAfter"] == "true") == expected_sibling and
              trends_ok)
    return {"protocol": protocol, "decision": "PASS" if passed else "FAIL",
            "command": command, "exit_code": process.returncode, "timed_out": timed_out,
            "wall_elapsed_ms": elapsed_ms, "result": marker,
            "heavy_gc_heap": {"trend": heap, "samples": heap_samples},
            "resources": {"trend": resources, "samples": sampler.samples},
            "stdout": stdout[-1_048_576:], "stderr": stderr[-1_048_576:]}


def command_text(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=10)
        return (result.stdout or result.stderr).strip()[:4096] or None
    except Exception:
        return None


def execute(args: argparse.Namespace) -> dict[str, Any]:
    env = profile_environment(args)
    preparation = None if args.skip_preflight else preflight(env, args.preflight_timeout_seconds)
    cases = (("h1", "Http1SseStreamingProfileTest"),
             ("h2", "Http2SseStreamingProfileTest"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run_profile, protocol, test_class, env,
                               args.timeout_seconds, args.resource_sample_seconds)
                   for protocol, test_class in cases]
        profiles = [future.result() for future in futures]
    formal = args.duration_seconds >= FORMAL_SECONDS and args.minimum_events >= FORMAL_EVENTS
    passed = formal and all(item["decision"] == "PASS" for item in profiles)
    source = ROOT / "src/http/sse_profile_test.cj"
    return {"schema_version": 1, "task_id": "M6-023", "platform_scope": "linux-x86_64",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "repository_revision": args.repository_revision,
            "decision": "PASS" if passed else "INCOMPLETE",
            "formal_parameters_met": formal,
            "parameters": {"duration_seconds": args.duration_seconds,
                           "minimum_events": args.minimum_events,
                           "parallel_protocols": True,
                           "resource_sample_seconds": args.resource_sample_seconds},
            "environment": {"platform": platform.platform(), "python": sys.version.splitlines()[0],
                            "cjc": command_text(["cjc", "--version"]),
                            "cjpm": command_text(["cjpm", "--version"])},
            "source": {"path": str(source.relative_to(ROOT)), "sha256": evidence_digest.text_evidence_sha256(source)},
            "preflight": preparation, "profiles": profiles,
            "acceptance": {"one_hour_each": formal, "one_million_events_each": formal,
                           "numbered_sequence": all(int(p["result"]["sequenceErrors"]) == 0 for p in profiles),
                           "bounded_application_and_protocol_flow": all(p["decision"] == "PASS" for p in profiles),
                           "heavy_gc_heap_steady": all(p["heavy_gc_heap"]["trend"]["decision"] == "PASS" for p in profiles),
                           "rss_fd_socket_thread_steady": all(p["resources"]["trend"]["decision"] == "PASS" for p in profiles),
                           "slow_consumer_backpressure": all(int(p["result"]["slowLeadEvents"]) > 0 for p in profiles),
                           "public_cancel_within_50ms": all(int(p["result"]["cancelLatencyNs"]) <= MAX_CANCEL_NS for p in profiles),
                           "h2_sibling_survives": next(p for p in profiles if p["protocol"] == "h2")["result"]["siblingAfter"] == "true"}}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration-seconds", type=int, default=FORMAL_SECONDS)
    parser.add_argument("--minimum-events", type=int, default=FORMAL_EVENTS)
    parser.add_argument("--slow-seconds", type=int, default=60)
    parser.add_argument("--slow-delay-ms", type=int, default=20)
    parser.add_argument("--heap-sample-seconds", type=int, default=300)
    parser.add_argument("--fast-producer-ms", type=int, default=1)
    parser.add_argument("--steady-producer-ms", type=int, default=2)
    parser.add_argument("--events-per-read", type=int, default=256)
    parser.add_argument("--client-read-bytes", type=int, default=256)
    parser.add_argument("--resource-sample-seconds", type=float, default=10.0)
    parser.add_argument("--timeout-seconds", type=float, default=3900.0)
    parser.add_argument("--preflight-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--skip-preflight", action="store_true")
    parser.add_argument("--repository-revision", default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/gates/m6-023-sse-profile.json")
    args = parser.parse_args(argv)
    positive = (args.duration_seconds, args.minimum_events, args.slow_seconds,
                args.slow_delay_ms, args.heap_sample_seconds, args.events_per_read,
                args.client_read_bytes, args.resource_sample_seconds, args.timeout_seconds)
    if any(value <= 0 for value in positive):
        parser.error("profile durations, counts, intervals, and timeout must be positive")
    try:
        report = execute(args)
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"M6-023 SSE profile: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M6-023 SSE profile: {report['decision']} output={args.output}")
    for profile in report["profiles"]:
        print(f"- {profile['protocol']}: {profile['decision']} events={profile['result']['events']} "
              f"elapsedMs={profile['result']['elapsedMs']} cancelNs={profile['result']['cancelLatencyNs']}")
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
