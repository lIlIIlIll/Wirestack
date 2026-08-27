#!/usr/bin/env python3
"""Measure the per-call layers used by background StdNetTransport I/O."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import statistics
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

from net05_large_buffer_profile import (
    GateError,
    compile_adapter_probe,
    command_text,
    parse_heaptrack_allocations,
    run_process,
)

PROFILE_RE = re.compile(
    r"^M127_PROFILE stage=([^\s]+) iterations=(\d+) "
    r"durationNs=(\d+) checksum=(-?\d+)$",
    re.MULTILINE,
)
PROFILE_CLASS = "M127OperationContextCostProfileTest"
PERF_RE = re.compile(r"^([0-9]+);;([^;]+);", re.MULTILINE)
STAGES = (
    ("controlLoop", "control-loop", 1_000_000),
    ("backgroundContextCheck", "background-context-check", 1_000_000),
    ("deadlineCheck", "deadline-check", 1_000_000),
    ("noneCancellationRegistration", "none-cancellation-registration", 1_000_000),
    ("cancellableRegistration", "cancellable-registration", 100_000),
    ("operationGate", "operation-gate", 1_000_000),
    ("emptyBackgroundRead", "empty-background-read", 100_000),
    ("noneReadTimeoutAssignment", "none-read-timeout-assignment", 100_000),
    ("readyBackgroundRead", "ready-background-read", 65_536),
    ("readyObservedRead", "ready-observed-read", 65_536),
)


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


def profile_command(binary: Path, case_name: str) -> list[str]:
    return [
        str(binary), f"--filter={PROFILE_CLASS}.{case_name}",
        "--show-all-output", "--no-progress", "--no-color",
    ]


def parse_profile(stdout: str, expected_stage: str) -> dict[str, int | float | str]:
    matches = PROFILE_RE.findall(stdout)
    if len(matches) != 1:
        raise GateError(f"expected one M127_PROFILE line, found {len(matches)}")
    stage, iterations_text, duration_text, checksum_text = matches[0]
    if stage != expected_stage:
        raise GateError(f"expected stage {expected_stage}, found {stage}")
    iterations = int(iterations_text)
    duration_ns = int(duration_text)
    return {
        "stage": stage,
        "iterations": iterations,
        "duration_ns": duration_ns,
        "nanoseconds_per_call": round(duration_ns / iterations, 3),
        "checksum": int(checksum_text),
    }


def run_stage(binary: Path, case_name: str, stage: str, iterations: int,
              timeout: float) -> dict[str, Any]:
    environment = dict(os.environ)
    environment["WIRESTACK_M127_ITERATIONS"] = str(iterations)
    process = run_process(
        profile_command(binary, case_name), binary.parent, timeout,
        environment=environment,
    )
    if process["timed_out"] or process["exit_code"] != 0:
        raise GateError(f"stage {stage} failed: {process}")
    result = parse_profile(process["stdout"], stage)
    result["process"] = process
    return result


def aggregate_timing(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    values = [float(item["nanoseconds_per_call"]) for item in samples]
    return {
        "repetitions": len(samples),
        "nanoseconds_per_call": {
            "p50": round(statistics.median(values), 3),
            "min": round(min(values), 3),
            "max": round(max(values), 3),
        },
        "samples": list(samples),
    }


def run_perf_stage(binary: Path, case_name: str, stage: str,
                   iterations: int, timeout: float) -> dict[str, Any]:
    environment = dict(os.environ)
    environment["WIRESTACK_M127_ITERATIONS"] = str(iterations)
    command = [
        "perf", "stat", "-x", ";", "-e", "cycles:u,instructions:u", "--",
        *profile_command(binary, case_name),
    ]
    process = run_process(command, binary.parent, timeout, environment=environment)
    if process["timed_out"] or process["exit_code"] != 0:
        raise GateError(f"perf stage {stage} failed: {process}")
    parsed = parse_profile(process["stdout"], stage)
    counters = {name: int(value) for value, name in PERF_RE.findall(process["stderr"])}
    if "cycles:u" not in counters or "instructions:u" not in counters:
        raise GateError(f"perf stage {stage} omitted required counters")
    cycles = counters["cycles:u"]
    instructions = counters["instructions:u"]
    return {
        "iterations": parsed["iterations"],
        "cycles": cycles,
        "instructions": instructions,
        "cycles_per_call": round(cycles / iterations, 3),
        "instructions_per_call": round(instructions / iterations, 3),
        "ipc": round(instructions / cycles, 6) if cycles > 0 else None,
    }


def run_allocation_stage(binary: Path, case_name: str, stage: str,
                         iterations: int, artifacts: Path,
                         timeout: float) -> dict[str, Any]:
    sample_dir = artifacts / "allocations" / stage
    sample_dir.mkdir(parents=True, exist_ok=True)
    heaptrack_prefix = sample_dir / "heaptrack-data"
    heaptrack_path = Path(f"{heaptrack_prefix}.zst")
    heaptrack_path.unlink(missing_ok=True)
    environment = dict(os.environ)
    environment["WIRESTACK_M127_ITERATIONS"] = str(iterations)
    command = [
        "heaptrack", "--record-only", "-o", str(heaptrack_prefix),
        *profile_command(binary, case_name),
    ]
    process = run_process(command, binary.parent, timeout, environment=environment)
    if process["timed_out"] or process["exit_code"] != 0 or not heaptrack_path.is_file():
        raise GateError(f"allocation stage {stage} failed: {process}")
    parsed = parse_profile(process["stdout"], stage)
    allocations = parse_heaptrack_allocations(process["stderr"])
    return {
        "iterations": parsed["iterations"],
        "native_process_allocation_events": allocations,
        "heaptrack_record": str(heaptrack_path),
    }


def execute(root: Path, artifacts: Path, timeout: float,
            build_timeout: float, revision: str,
            allocation_iterations: int, repetitions: int) -> dict[str, Any]:
    if shutil.which("heaptrack") is None:
        raise GateError("heaptrack is required for M1-027 allocation evidence")
    if shutil.which("perf") is None:
        raise GateError("perf is required for M1-027 cycle and instruction evidence")
    artifacts.mkdir(parents=True, exist_ok=True)
    binary, compile_result = compile_adapter_probe(root, artifacts, build_timeout)
    stages = []
    for case_name, stage, iterations in STAGES:
        timing = aggregate_timing([
            run_stage(binary, case_name, stage, iterations, timeout)
            for _ in range(repetitions)
        ])
        perf = run_perf_stage(binary, case_name, stage, iterations, timeout)
        allocation = run_allocation_stage(
            binary, case_name, stage, allocation_iterations, artifacts, timeout
        )
        stages.append({
            "name": stage, "timing": timing, "perf": perf,
            "allocation": allocation,
        })

    control_allocations = int(
        next(item for item in stages if item["name"] == "control-loop")
        ["allocation"]["native_process_allocation_events"]
    )
    for item in stages:
        allocation = item["allocation"]
        delta = int(allocation["native_process_allocation_events"]) - control_allocations
        allocation["events_above_control"] = delta
        allocation["events_above_control_per_call"] = round(
            delta / int(allocation["iterations"]), 6
        )

    return {
        "schema_version": 1,
        "task_id": "M1-027",
        "profile": "background-operation-context-per-call",
        "environment": {
            "repository_revision": revision,
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "os": platform.platform(),
            "architecture": platform.machine(),
            "python": sys.version.splitlines()[0],
            "cjc": command_text(["cjc", "--version"]),
            "cjpm": command_text(["cjpm", "--version"]),
            "cangjie_home": os.environ.get("CANGJIE_HOME"),
        },
        "configuration": {
            "compile_option": "-O2",
            "allocation_iterations": allocation_iterations,
            "timing_repetitions": repetitions,
        },
        "compile": compile_result,
        "stages": stages,
        "metric_availability": {
            "wall_time": "MEASURED",
            "native_process_allocation_events": "MEASURED",
            "cycles": "MEASURED",
            "instructions": "MEASURED",
            "ipc": "MEASURED",
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path,
                        default=root / "build/gates/m1-027-operation-context-profile")
    parser.add_argument("--output", type=Path,
                        default=root / "build/gates/m1-027-operation-context-profile.json")
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--build-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--allocation-iterations", type=int, default=10000)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    args = parser.parse_args(argv)
    if args.allocation_iterations <= 0 or args.repetitions <= 0:
        parser.error("allocation iterations and repetitions must be positive")
    try:
        report = execute(
            root, args.artifact_dir.resolve(), args.timeout_seconds,
            args.build_timeout_seconds, args.repository_revision,
            args.allocation_iterations, args.repetitions,
        )
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"M1-027 profile: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print("M1-027 background OperationContext profile: PASS")
    for item in report["stages"]:
        timing = item["timing"]
        allocation = item["allocation"]
        print(
            f"- {item['name']}: {timing['nanoseconds_per_call']['p50']} ns/call, "
            f"cycles={item['perf']['cycles_per_call']}/call, "
            f"allocation-delta={allocation['events_above_control_per_call']} events/call"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
