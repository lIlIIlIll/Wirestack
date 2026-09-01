#!/usr/bin/env python3
"""Measure whether std.net hostname resolution blocks Cangjie carrier threads."""
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
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA_VERSION = 1
TASK_ID = "M0-013"
GATE_ID = "STD-NET-DNS-CARRIER-THREAD"
HEARTBEAT_RE = re.compile(r"^HEARTBEAT index=(\d+) elapsedNs=(\d+)$")
RESOLVE_RE = re.compile(
    r"^RESOLVE index=(\d+) startNs=(\d+) endNs=(\d+) code=(\d+)$"
)
RELEASE_RE = re.compile(r"^RELEASE tasks=(\d+) elapsedNs=(\d+)$")
SUMMARY_RE = re.compile(r"^SUMMARY tasks=(\d+) completed=(\d+) heartbeats=(\d+)$")
SHIM_RE = re.compile(
    r"^GAI phase=(enter|exit) seq=(\d+) pid=(\d+) tid=(\d+) "
    r"ns=(\d+) result=(-?\d+) node=(.*)$"
)


class GateError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    if not 0 <= percent <= 100:
        raise ValueError("percent must be within [0, 100]")
    ordered = sorted(values)
    rank = max(1, math.ceil((percent / 100.0) * len(ordered)))
    return round(ordered[rank - 1], 3)


def stats(values: Sequence[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "p50": percentile(values, 50),
        "p95": percentile(values, 95),
        "p99": percentile(values, 99),
        "max": round(max(values), 3) if values else None,
    }


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
    text = completed.stdout.strip()
    return text[:4096] if text else None


def repository_revision(root: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
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


def run_captured(
    command: list[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
    output_limit: int = 4 * 1024 * 1024,
) -> dict[str, Any]:
    started_ns = time.monotonic_ns()
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=dict(env),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        bufsize=1,
        start_new_session=(os.name != "nt"),
    )
    events: list[dict[str, Any]] = []
    byte_count = 0
    overflow = False
    lock = threading.Lock()

    def consume(stream: Any, name: str) -> None:
        nonlocal byte_count, overflow
        assert stream is not None
        for line in iter(stream.readline, ""):
            line = line.rstrip("\n")
            encoded = len(line.encode("utf-8", "replace")) + 1
            with lock:
                if byte_count + encoded <= output_limit:
                    events.append({
                        "stream": name,
                        "host_monotonic_ns": time.monotonic_ns(),
                        "line": line,
                    })
                    byte_count += encoded
                else:
                    overflow = True
        stream.close()

    threads = [
        threading.Thread(target=consume, args=(process.stdout, "stdout"), daemon=True),
        threading.Thread(target=consume, args=(process.stderr, "stderr"), daemon=True),
    ]
    for thread in threads:
        thread.start()
    timed_out = False
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process_group(process)
    for thread in threads:
        thread.join(timeout=2)
    ended_ns = time.monotonic_ns()
    return {
        "command": command,
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "output_overflow": overflow,
        "started_monotonic_ns": started_ns,
        "ended_monotonic_ns": ended_ns,
        "duration_ms": round((ended_ns - started_ns) / 1_000_000.0, 3),
        "events": events,
    }


def compile_artifacts(root: Path, work: Path) -> dict[str, Any]:
    work.mkdir(parents=True, exist_ok=True)
    cjc = shutil.which("cjc")
    gcc = shutil.which("gcc") or shutil.which("cc")
    if not cjc:
        raise GateError("cjc is unavailable; load the supplied SDK environment")
    if not gcc:
        raise GateError("gcc/cc is unavailable")
    probe_source = root / "tools/gates/probes/dns_carrier_probe.cj"
    shim_source = root / "tools/gates/native/gai_delay.c"
    probe = work / "dns-carrier-probe"
    shim = work / "libwirestack-gai-delay.so"
    compile_probe = subprocess.run(
        [cjc, str(probe_source), "-o", str(probe)],
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
        text=True,
        errors="replace",
    )
    if compile_probe.returncode != 0 or not probe.is_file():
        raise GateError(
            "Cangjie probe compilation failed:\n"
            + compile_probe.stdout[-4000:] + compile_probe.stderr[-4000:]
        )
    shim_command = [
        gcc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
        "-o", str(shim), str(shim_source), "-ldl", "-pthread",
    ]
    compile_shim = subprocess.run(
        shim_command,
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=False,
        text=True,
        errors="replace",
    )
    if compile_shim.returncode != 0 or not shim.is_file():
        raise GateError(
            "getaddrinfo shim compilation failed:\n"
            + compile_shim.stdout[-4000:] + compile_shim.stderr[-4000:]
        )
    return {
        "probe": probe,
        "shim": shim,
        "probe_sha256": evidence_digest.artifact_byte_sha256(probe),
        "shim_sha256": evidence_digest.artifact_byte_sha256(shim),
        "probe_compile": {
            "command": [cjc, str(probe_source), "-o", str(probe)],
            "stdout": compile_probe.stdout[-4000:],
            "stderr": compile_probe.stderr[-4000:],
        },
        "shim_compile": {
            "command": shim_command,
            "stdout": compile_shim.stdout[-4000:],
            "stderr": compile_shim.stderr[-4000:],
        },
    }


def parse_probe_events(events: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    heartbeats: list[dict[str, int]] = []
    resolves: list[dict[str, int]] = []
    release: dict[str, int] | None = None
    summary: dict[str, int] | None = None
    for event in events:
        if event["stream"] != "stdout":
            continue
        line = str(event["line"])
        if match := HEARTBEAT_RE.fullmatch(line):
            heartbeats.append({
                "index": int(match.group(1)),
                "elapsed_ns": int(match.group(2)),
                "host_monotonic_ns": int(event["host_monotonic_ns"]),
            })
        elif match := RESOLVE_RE.fullmatch(line):
            resolves.append({
                "index": int(match.group(1)),
                "start_ns": int(match.group(2)),
                "end_ns": int(match.group(3)),
                "code": int(match.group(4)),
                "host_monotonic_ns": int(event["host_monotonic_ns"]),
            })
        elif match := RELEASE_RE.fullmatch(line):
            release = {"tasks": int(match.group(1)), "elapsed_ns": int(match.group(2))}
        elif match := SUMMARY_RE.fullmatch(line):
            summary = {
                "tasks": int(match.group(1)),
                "completed": int(match.group(2)),
                "heartbeats": int(match.group(3)),
            }
    gaps_ms = [
        round((right["elapsed_ns"] - left["elapsed_ns"]) / 1_000_000.0, 3)
        for left, right in zip(heartbeats, heartbeats[1:])
    ]
    return {
        "heartbeats": heartbeats,
        "heartbeat_gaps_ms": gaps_ms,
        "resolves": sorted(resolves, key=lambda item: item["index"]),
        "release": release,
        "summary": summary,
    }


def parse_shim_log(text: str) -> dict[str, Any]:
    events: list[dict[str, Any]] = []
    by_sequence: dict[int, dict[str, dict[str, Any]]] = {}
    for line in text.splitlines():
        match = SHIM_RE.fullmatch(line)
        if not match:
            raise GateError(f"malformed shim log line: {line!r}")
        event = {
            "phase": match.group(1),
            "sequence": int(match.group(2)),
            "pid": int(match.group(3)),
            "tid": int(match.group(4)),
            "monotonic_ns": int(match.group(5)),
            "result": int(match.group(6)),
            "node": match.group(7),
        }
        events.append(event)
        phases = by_sequence.setdefault(event["sequence"], {})
        if event["phase"] in phases:
            raise GateError(
                f"duplicate {event['phase']} for shim sequence {event['sequence']}"
            )
        phases[event["phase"]] = event
    call_durations_ms: list[float] = []
    for sequence, phases in sorted(by_sequence.items()):
        if set(phases) != {"enter", "exit"}:
            raise GateError(f"incomplete shim call sequence {sequence}: {sorted(phases)}")
        duration = phases["exit"]["monotonic_ns"] - phases["enter"]["monotonic_ns"]
        if duration < 0:
            raise GateError(f"negative shim duration for sequence {sequence}")
        call_durations_ms.append(round(duration / 1_000_000.0, 3))
    concurrent = 0
    maximum_concurrent = 0
    for event in sorted(
        events, key=lambda item: (item["monotonic_ns"], item["phase"] != "exit")
    ):
        if event["phase"] == "enter":
            concurrent += 1
            maximum_concurrent = max(maximum_concurrent, concurrent)
        else:
            concurrent -= 1
        if concurrent < 0:
            raise GateError("shim exit observed before matching enter")
    if concurrent != 0:
        raise GateError("shim calls remained active at process exit")
    return {
        "events": events,
        "call_count": len(by_sequence),
        "thread_ids": sorted({event["tid"] for event in events}),
        "unique_thread_count": len({event["tid"] for event in events}),
        "maximum_concurrent_calls": maximum_concurrent,
        "call_duration_ms": stats(call_durations_ms),
    }


def validate_sample(sample: Mapping[str, Any], task_count: int) -> None:
    process = sample["process"]
    probe = sample["probe"]
    shim = sample["shim"]
    if process["timed_out"]:
        raise GateError("probe process timed out")
    if process["exit_code"] != 0:
        raise GateError(f"probe exited with {process['exit_code']}")
    if process["output_overflow"]:
        raise GateError("probe output exceeded the bounded capture limit")
    if probe["release"] is None or probe["summary"] is None:
        raise GateError("probe release/summary marker missing")
    if probe["summary"]["tasks"] != task_count or probe["summary"]["completed"] != task_count:
        raise GateError("not all resolution tasks completed")
    if len(probe["resolves"]) != task_count:
        raise GateError("resolution marker count differs from requested task count")
    if {item["index"] for item in probe["resolves"]} != set(range(task_count)):
        raise GateError("resolution indexes are not complete and unique")
    if any(item["end_ns"] < item["start_ns"] for item in probe["resolves"]):
        raise GateError("resolution task has negative duration")
    if shim["call_count"] != task_count:
        raise GateError(
            f"shim intercepted {shim['call_count']} getaddrinfo calls, expected {task_count}"
        )
    if len(probe["heartbeats"]) < 2:
        raise GateError("insufficient heartbeat samples")


def run_sample(
    root: Path,
    compiled: Mapping[str, Any],
    work: Path,
    *,
    task_count: int,
    delay_ms: int,
    minimum_heartbeats: int,
    heartbeat_interval_ms: int,
    timeout_seconds: float,
    label: str,
) -> dict[str, Any]:
    sample_dir = work / label
    sample_dir.mkdir(parents=True, exist_ok=True)
    shim_log = sample_dir / "getaddrinfo.log"
    environment = dict(os.environ)
    environment.update({
        "LD_PRELOAD": str(compiled["shim"]),
        "WIRESTACK_GAI_DELAY_MS": str(delay_ms),
        "WIRESTACK_GAI_LOG": str(shim_log),
    })
    process = run_captured(
        [
            str(compiled["probe"]), str(task_count), str(minimum_heartbeats),
            str(heartbeat_interval_ms),
        ],
        cwd=root,
        env=environment,
        timeout_seconds=timeout_seconds,
    )
    (sample_dir / "process-events.json").write_text(
        json.dumps(process["events"], ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    for stream_name in ("stdout", "stderr"):
        lines = [
            event["line"] for event in process["events"]
            if event["stream"] == stream_name
        ]
        (sample_dir / f"{stream_name}.log").write_text(
            "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
        )
    if not shim_log.is_file():
        raise GateError("LD_PRELOAD shim did not produce an interception log")
    shim_text = shim_log.read_text(encoding="utf-8")
    probe = parse_probe_events(process["events"])
    shim = parse_shim_log(shim_text)
    sample = {
        "task_count": task_count,
        "delay_ms": delay_ms,
        "process": process,
        "probe": probe,
        "shim": shim,
        "shim_log_sha256": evidence_digest.text_evidence_bytes_sha256(shim_text.encode()),
    }
    try:
        validate_sample(sample, task_count)
    except GateError as error:
        raise GateError(f"{label}: {error}") from error
    return sample


def aggregate_samples(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    gaps = [
        float(value)
        for sample in samples
        for value in sample["probe"]["heartbeat_gaps_ms"]
    ]
    resolution_ms = [
        (item["end_ns"] - item["start_ns"]) / 1_000_000.0
        for sample in samples
        for item in sample["probe"]["resolves"]
    ]
    process_ms = [float(sample["process"]["duration_ms"]) for sample in samples]
    helper_threads = [int(sample["shim"]["unique_thread_count"]) for sample in samples]
    concurrent_calls = [
        int(sample["shim"]["maximum_concurrent_calls"]) for sample in samples
    ]
    return {
        "sample_count": len(samples),
        "heartbeat_gap_ms": stats(gaps),
        "resolution_duration_ms": stats(resolution_ms),
        "process_duration_ms": stats(process_ms),
        "helper_thread_count": stats([float(value) for value in helper_threads]),
        "maximum_concurrent_calls": stats([float(value) for value in concurrent_calls]),
    }


def classify_aggregates(
    aggregates: list[dict[str, Any]], delay_ms: int
) -> dict[str, Any]:
    controls = {
        int(item["task_count"]): item
        for item in aggregates if int(item["delay_ms"]) == 0
    }
    observed: list[dict[str, Any]] = []
    for item in aggregates:
        if int(item["delay_ms"]) != delay_ms:
            continue
        task_count = int(item["task_count"])
        control = controls.get(task_count)
        if control is None:
            raise GateError(f"missing control aggregate for task count {task_count}")
        delayed_p95 = float(item["metrics"]["heartbeat_gap_ms"]["p95"] or 0.0)
        delayed_max = float(item["metrics"]["heartbeat_gap_ms"]["max"] or 0.0)
        control_p95 = float(control["metrics"]["heartbeat_gap_ms"]["p95"] or 0.0)
        threshold = max(delay_ms * 0.75, control_p95 * 5.0)
        starved = delayed_p95 >= threshold
        item["comparison"] = {
            "control_p95_ms": control_p95,
            "starvation_threshold_ms": round(threshold, 3),
            "p95_ratio": round(delayed_p95 / control_p95, 3) if control_p95 else None,
            "starvation_observed": starved,
        }
        if starved:
            observed.append({
                "task_count": task_count,
                "delayed_p95_ms": delayed_p95,
                "delayed_max_ms": delayed_max,
                "control_p95_ms": control_p95,
            })
    return {
        "classification": (
            "CARRIER_THREAD_STARVATION_OBSERVED"
            if observed else "NO_CARRIER_THREAD_STARVATION_OBSERVED"
        ),
        "gate_decision": "FAIL" if observed else "PASS",
        "starvation_points": observed,
        "recommended_requirement": (
            "runtime-native async resolver or a strictly bounded blocking resolver pool"
            if observed else "retain continuous native-platform regression evidence"
        ),
        "conditional_upstream_candidate": "UP-007" if observed else None,
    }


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
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


def render_summary(report: Mapping[str, Any]) -> str:
    decision = report["decision"]
    lines = [
        f"{GATE_ID}: {decision['gate_decision']}",
        f"classification: {decision['classification']}",
        f"recommendation: {decision['recommended_requirement']}",
    ]
    for item in report["aggregates"]:
        metrics = item["metrics"]["heartbeat_gap_ms"]
        comparison = item.get("comparison") or {}
        lines.append(
            f"delay={item['delay_ms']}ms tasks={item['task_count']} "
            f"p95={metrics['p95']}ms max={metrics['max']}ms "
            f"starved={comparison.get('starvation_observed')}"
        )
    return "\n".join(lines)


def parse_int_list(text: str) -> list[int]:
    values = [int(item.strip()) for item in text.split(",") if item.strip()]
    if not values or any(value <= 0 for value in values) or len(set(values)) != len(values):
        raise argparse.ArgumentTypeError(
            "expected unique positive comma-separated integers"
        )
    return values


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--repo-root", type=Path, default=root)
    parser.add_argument(
        "--artifact-dir", type=Path,
        default=root / "build/gates/dns-carrier-thread-artifacts",
    )
    parser.add_argument(
        "--output", type=Path,
        default=root / "build/gates/dns-carrier-thread.json",
    )
    parser.add_argument(
        "--task-counts", type=parse_int_list,
        default=parse_int_list("1,2,4,8,16,32,64"),
    )
    parser.add_argument("--delay-ms", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--minimum-heartbeats", type=int, default=30)
    parser.add_argument("--heartbeat-interval-ms", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--repository-revision")
    parser.add_argument(
        "--sdk-archive", type=Path,
        default=Path("/mnt/data/cangjie_sdk.tar.gz"),
    )
    return parser.parse_args(argv)


def execute(args: argparse.Namespace) -> dict[str, Any]:
    root = args.repo_root.resolve()
    artifact_dir = args.artifact_dir.resolve()
    artifact_dir.mkdir(parents=True, exist_ok=True)
    compiled = compile_artifacts(root, artifact_dir / "compiled")
    started = time.monotonic()
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "gate_id": GATE_ID,
        "status": "IN_PROGRESS",
        "started_at_utc": utc_now(),
        "scope": "native Linux x86_64 supplied-SDK std.net hostname resolution",
        "non_claims": [
            "not a cross-platform result",
            "does not modify std.net/runtime",
            "does not authorize UP-007 without M0-021 RFC",
        ],
        "environment": {
            "repository_revision": repository_revision(root, args.repository_revision),
            "platform": sys.platform,
            "os": platform.platform(),
            "architecture": platform.machine(),
            "processor": platform.processor(),
            "cpu_count": os.cpu_count(),
            "python": sys.version.splitlines()[0],
            "cjc": command_text(["cjc", "--version"]),
            "cjpm": command_text(["cjpm", "--version"]),
            "gcc": command_text(["gcc", "--version"]),
            "sdk_archive_sha256": (
                evidence_digest.artifact_byte_sha256(args.sdk_archive.resolve())
                if args.sdk_archive.is_file() else None
            ),
        },
        "configuration": {
            "task_counts": args.task_counts,
            "delay_ms": args.delay_ms,
            "warmup": args.warmup,
            "repetitions": args.repetitions,
            "minimum_heartbeats": args.minimum_heartbeats,
            "heartbeat_interval_ms": args.heartbeat_interval_ms,
            "timeout_seconds": args.timeout_seconds,
        },
        "compiled": {
            key: value for key, value in compiled.items()
            if key not in {"probe", "shim"}
        },
        "runs": [],
        "aggregates": [],
    }
    for delay_ms in (0, args.delay_ms):
        for task_count in args.task_counts:
            warmups = []
            measured = []
            for index in range(args.warmup + args.repetitions):
                label = f"delay-{delay_ms}-tasks-{task_count}-sample-{index}"
                sample = run_sample(
                    root,
                    compiled,
                    artifact_dir,
                    task_count=task_count,
                    delay_ms=delay_ms,
                    minimum_heartbeats=args.minimum_heartbeats,
                    heartbeat_interval_ms=args.heartbeat_interval_ms,
                    timeout_seconds=args.timeout_seconds,
                    label=label,
                )
                sample["warmup"] = index < args.warmup
                report["runs"].append(sample)
                (warmups if sample["warmup"] else measured).append(sample)
            report["aggregates"].append({
                "delay_ms": delay_ms,
                "task_count": task_count,
                "warmup_count": len(warmups),
                "metrics": aggregate_samples(measured),
            })
    report["decision"] = classify_aggregates(report["aggregates"], args.delay_ms)
    report["status"] = report["decision"]["gate_decision"]
    report["duration_ms"] = round((time.monotonic() - started) * 1000.0, 3)
    report["finished_at_utc"] = utc_now()
    return report


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.delay_ms <= 0 or args.warmup < 0 or args.repetitions <= 0:
        print(
            "delay/repetitions must be positive and warmup non-negative",
            file=sys.stderr,
        )
        return 2
    try:
        report = execute(args)
        atomic_write_json(args.output.resolve(), report)
    except (GateError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        report = {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "gate_id": GATE_ID,
            "status": "ERROR",
            "error": f"{type(error).__name__}: {error}",
            "finished_at_utc": utc_now(),
        }
        try:
            atomic_write_json(args.output.resolve(), report)
        except OSError:
            pass
        print(f"{GATE_ID}: ERROR\n{report['error']}", file=sys.stderr)
        return 2
    print(render_summary(report))
    # A measured gate failure is valid M0 evidence, not a harness process error.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
