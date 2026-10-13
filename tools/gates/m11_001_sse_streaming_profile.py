#!/usr/bin/env python3
"""Run the M11-001 Linux H1/H2 SSE steady-state profile in parallel."""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest
from tools import m7_021_linux_release as release

import argparse
import concurrent.futures
import datetime as dt
import os
import platform
import re
import time
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from tools.gates.sse_streaming_profile import (FORMAL_SECONDS, FORMAL_EVENTS, MAX_CANCEL_NS,
    MAX_LEAD_EVENTS, GateError, atomic_json, Sampler, terminate, parse_output, heap_trend, resource_trend)
import shlex

ROOT = Path(__file__).resolve().parents[2]
ENV_RUNNER = os.environ.get("WIRESTACK_CANGJIE_ENV_RUNNER", "")
TARGET_DIR = ""

def sdk_command(command: list[str]) -> list[str]:
    if ENV_RUNNER:
        return shlex.split(ENV_RUNNER) + ["--cwd", str(ROOT)] + command
    if not os.environ.get("CANGJIE_HOME"):
        raise GateError("provide --env-runner or inherited CANGJIE_HOME")
    return command


def normalize(value: Any) -> Any:
    if isinstance(value, str):
        return value.replace(str(ROOT), "<repo>").replace(str(Path.home()), "$HOME")
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    return value


def source_hashes() -> list[dict[str, str]]:
    paths = release.production_sources(ROOT)
    return [{"path": str(path.relative_to(ROOT)), "sha256": evidence_digest.text_evidence_sha256(path)}
            for path in paths]

def binary_hashes() -> list[dict[str, str]]:
    base = Path(TARGET_DIR) / "release/unittest_bin"
    return [{"path": str(path.relative_to(Path(TARGET_DIR))),
             "sha256": evidence_digest.artifact_byte_sha256(path)}
            for path in sorted(base.rglob("*")) if path.is_file() and path.name in {
                "wirestack.sse", "wirestack.sse$test.cjo", "std.testrunner", "std.testrunner.cjo"}]


def test_command(test_class: str, skip_build: bool) -> list[str]:
    command = sdk_command(["cjpm", "test", "src/sse", "--target-dir", TARGET_DIR,
               "-j", "1", "--parallel", "1"])
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
    quick["WIRESTACK_SSE_DURATION_SECONDS"] = "30"
    quick["WIRESTACK_SSE_MIN_EVENTS"] = "1000"
    command = test_command("M11Http*", False)
    result = subprocess.run(command, cwd=ROOT, env=quick, capture_output=True, text=True,
                            errors="replace", timeout=timeout)
    if result.returncode != 0:
        raise GateError(f"SSE preflight failed: {(result.stdout + result.stderr)[-4096:]}")
    for protocol in ("h1", "h2"):
        parse_output(result.stdout + "\n" + result.stderr, protocol)
    return {"command": command, "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


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
    cleanup = re.findall(r"SSE_CLEANUP protocol=" + protocol + r" managedBufferBytes=(\d+)", stdout)
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
              cleanup == ["0"] and
              all(s["managedBufferBytes"] >= s["sessionReservedBytes"] for s in heap_samples[:-1]) and
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
    global ENV_RUNNER, TARGET_DIR
    ENV_RUNNER = args.env_runner
    TARGET_DIR = str(args.target_dir.resolve())
    env = profile_environment(args)
    before_build = source_hashes()
    preparation = None if args.skip_preflight else preflight(env, args.preflight_timeout_seconds)
    at_start = source_hashes()
    binaries_start = binary_hashes()
    if before_build != at_start or not binaries_start:
        raise GateError("source changed during compilation or test binary is missing")
    atomic_json(args.output.with_suffix(".start.json"), normalize({
        "task_id": "M11-001", "production_sources": at_start, "compiled_binaries": binaries_start,
        "preflight": preparation, "started_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()}))
    cases = (("h1", "M11Http1SseStreamingProfileTest"),
             ("h2", "M11Http2SseStreamingProfileTest"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run_profile, protocol, test_class, env,
                               args.timeout_seconds, args.resource_sample_seconds)
                   for protocol, test_class in cases]
        profiles = [future.result() for future in futures]
    at_end = source_hashes()
    binaries_end = binary_hashes()
    formal = args.duration_seconds >= FORMAL_SECONDS and args.minimum_events >= FORMAL_EVENTS
    passed = formal and all(item["decision"] == "PASS" for item in profiles) and at_start == at_end and binaries_start == binaries_end
    source = ROOT / "src/sse/streaming_profile_test.cj"
    return {"schema_version": 1, "task_id": "M11-001", "platform_scope": "linux-x86_64",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "repository_revision": args.repository_revision,
            "decision": "PASS" if passed else "INCOMPLETE",
            "formal_parameters_met": formal,
            "parameters": {"duration_seconds": args.duration_seconds,
                           "minimum_events": args.minimum_events,
                           "parallel_protocols": True,
                           "resource_sample_seconds": args.resource_sample_seconds},
            "environment": {"platform": platform.platform(), "python": sys.version.splitlines()[0],
                            "cjc": command_text(sdk_command(["cjc", "-v"])),
                            "cjpm": command_text(sdk_command(["cjpm", "--version"]))},
            "source": {"path": str(source.relative_to(ROOT)), "sha256": evidence_digest.text_evidence_sha256(source)},
            "production_sources_start": at_start, "production_sources_end": at_end,
            "compiled_binaries_start": binaries_start, "compiled_binaries_end": binaries_end,
            "source_and_binary_unchanged": at_start == at_end and binaries_start == binaries_end,
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
    parser.add_argument("--env-runner", default=ENV_RUNNER)
    parser.add_argument("--target-dir", type=Path, required=True)
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
    parser.add_argument("--output", type=Path, default=ROOT / "build/gates/m11-001-sse-profile.json")
    args = parser.parse_args(argv)
    positive = (args.duration_seconds, args.minimum_events, args.slow_seconds,
                args.slow_delay_ms, args.heap_sample_seconds, args.events_per_read,
                args.preflight_timeout_seconds,
                args.client_read_bytes, args.resource_sample_seconds, args.timeout_seconds)
    if any(value <= 0 for value in positive):
        parser.error("profile durations, counts, intervals, and timeout must be positive")
    try:
        report = execute(args)
        atomic_json(args.output.resolve(), normalize(report))
    except Exception as error:
        print(f"M11-001 SSE profile: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M11-001 SSE profile: {report['decision']} output={args.output}")
    for profile in report["profiles"]:
        print(f"- {profile['protocol']}: {profile['decision']} events={profile['result']['events']} "
              f"elapsedMs={profile['result']['elapsedMs']} cancelNs={profile['result']['cancelLatencyNs']}")
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())