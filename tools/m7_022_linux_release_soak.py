#!/usr/bin/env python3
"""Run the installed Wirestack Linux artifact under the M7-022 mixed soak."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import m7_021_linux_release as release


TASK_ID = "M7-022"
FORMAL_SECONDS = 86_400
FORMAL_TIMEOUT_SECONDS = 90_000
MAX_CAPTURE_BYTES = 16_384
MAX_CANCEL_NS = 50_000_000
MAX_HEAP_GROWTH_BYTES = 32 * 1024 * 1024
RESOURCE_LIMITS = {
    "rss_kib": 64 * 1024,
    "fd_count": 2,
    "socket_count": 2,
    "timerfd_count": 2,
    "process_count": 0,
    "thread_count": 2,
}
COUNT_METRICS = {
    "fd_count", "socket_count", "timerfd_count", "process_count", "thread_count"
}
SAMPLE_PREFIX = "M7022_SAMPLE "
RESULT_PREFIX = "M7022_RESULT "
SAMPLE_FIELDS = {
    "index", "elapsedMs", "usedHeapBytes", "activeWaiters", "activeBuffers",
    "backgroundTasks", "cycles", "h1Requests", "h2Requests", "sseEvents",
}
RESULT_FIELDS = {
    "durationSeconds", "elapsedMs", "cycles", "activePhases", "idlePhases",
    "connects", "h1Requests", "h2Requests", "h2MultiplexBatches", "sseH1Events",
    "sseH2Events", "requestCancels", "streamResets", "connectionCancels",
    "reconnects", "spawnedTasks", "joinedTasks", "sequenceErrors",
    "maxCancelLatencyNs", "activeWaiters", "activeBuffers", "backgroundTasks",
    "serverTasks",
}
SOURCE = ROOT / "tools/release_soak/main.cj"
FIXTURE = ROOT / "examples/linux/m7_027/fixtures.cj"
QUALIFICATION = ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json"
ARTIFACT = ROOT / "dist/m7-021" / release.ARTIFACT_NAME
ENV_RUNNER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")


class SoakError(RuntimeError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(
    path: Path,
    value: Mapping[str, Any],
    replace: Callable[[str | bytes | os.PathLike[str] | os.PathLike[bytes],
                       str | bytes | os.PathLike[str] | os.PathLike[bytes]], None] = os.replace,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def bounded_tail(path: Path, limit: int = MAX_CAPTURE_BYTES) -> str:
    if not path.is_file():
        return ""
    with path.open("rb") as stream:
        size = path.stat().st_size
        stream.seek(max(0, size - limit))
        return stream.read(limit).decode("utf-8", errors="replace")


def require_platform(
    system: str | None = None,
    machine: str | None = None,
    libc: str | None = None,
) -> dict[str, str]:
    system = system or platform.system()
    machine = machine or platform.machine()
    detected_libc, libc_version = platform.libc_ver()
    libc = libc if libc is not None else detected_libc
    if system != "Linux" or machine.lower() != "x86_64":
        raise SoakError("UNSUPPORTED_PLATFORM", f"requires Linux x86_64, got {system} {machine}")
    if "musl" in libc.lower():
        raise SoakError("UNSUPPORTED_LIBC", "current Linux profile requires glibc")
    return {
        "system": "Linux",
        "machine": "x86_64",
        "libc": "glibc",
        "libc_version": libc_version or "unknown",
    }


def load_qualified_artifact(
    root: Path = ROOT,
    qualification_path: Path = QUALIFICATION,
    artifact_path: Path = ARTIFACT,
) -> tuple[dict[str, Any], str]:
    if not qualification_path.is_file():
        raise SoakError("QUALIFICATION_MISSING", f"missing {qualification_path}")
    try:
        report = json.loads(qualification_path.read_text(encoding="utf-8"))
        release.validate_report(report, root)
    except (json.JSONDecodeError, OSError, release.ReleaseError) as error:
        raise SoakError("QUALIFICATION_INVALID", str(error)) from error
    if not artifact_path.is_file():
        raise SoakError("ARTIFACT_MISSING", f"missing {artifact_path}")
    expected = report["artifact"]["sha256"]
    actual = sha256_path(artifact_path)
    if actual != expected:
        raise SoakError("ARTIFACT_DIGEST", f"artifact digest {actual} != {expected}")
    return report, actual


def validate_consumer_sources(source: str, fixture: str) -> None:
    combined = source + "\n" + fixture
    if "wirestack.internal" in combined:
        raise SoakError("INTERNAL_IMPORT", "release soak consumer imports wirestack.internal")
    if "import wirestack.http.*" not in source:
        raise SoakError("PUBLIC_IMPORT_MISSING", "consumer does not import wirestack.http")
    if source.count("package wirestack_m7_022_soak") != 1:
        raise SoakError("SOURCE_PACKAGE", "soak source package declaration is invalid")


def consumer_manifest(installed: Path) -> str:
    dependency = json.dumps(str(installed.resolve()))
    return f'''[package]
  cjc-version = "1.1.0"
  name = "wirestack_m7_022_soak"
  organization = ""
  description = "M7-022 installed artifact soak consumer"
  version = "1.0.0"
  target-dir = ""
  script-dir = ""
  src-dir = "src"
  output-type = "executable"
  compile-option = "-O2"
  override-compile-option = ""
  link-option = ""
  package-configuration = {{}}

[dependencies]
  wirestack = {{ path = {dependency} }}
'''


def run_build(command: Sequence[str], cwd: Path, timeout: float = 600) -> str:
    try:
        result = subprocess.run(
            list(command), cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise SoakError("BUILD_TIMEOUT", "clean consumer build timed out") from error
    output = result.stdout[-MAX_CAPTURE_BYTES:]
    if result.returncode != 0:
        raise SoakError("BUILD_FAILED", output)
    return output


def descendants(root_pid: int) -> set[int]:
    parents: dict[int, int] = {}
    try:
        entries = list(Path("/proc").iterdir())
    except OSError:
        return set()
    for entry in entries:
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
    sample = {
        "elapsed_ms": elapsed_ms,
        "process_count": 0,
        "rss_kib": 0,
        "fd_count": 0,
        "socket_count": 0,
        "timerfd_count": 0,
        "thread_count": 0,
    }
    for pid in descendants(root_pid):
        try:
            status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines()
            file_descriptors = list(Path(f"/proc/{pid}/fd").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        links: list[str] = []
        for descriptor in file_descriptors:
            try:
                links.append(descriptor.readlink().as_posix())
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        sample["process_count"] += 1
        sample["fd_count"] += len(file_descriptors)
        sample["socket_count"] += sum(link.startswith("socket:[") for link in links)
        sample["timerfd_count"] += sum(link == "anon_inode:[timerfd]" for link in links)
        for line in status:
            if line.startswith("VmRSS:"):
                sample["rss_kib"] += int(line.split()[1])
            elif line.startswith("Threads:"):
                sample["thread_count"] += int(line.split()[1])
    return sample


class ProcessSampler:
    def __init__(self, interval_seconds: float) -> None:
        self.interval_seconds = interval_seconds
        self.samples: list[dict[str, int]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        started = time.monotonic_ns()

        def sample() -> None:
            while not self._stop.is_set():
                value = process_tree_snapshot(
                    pid, (time.monotonic_ns() - started) // 1_000_000
                )
                if value["process_count"] > 0:
                    self.samples.append(value)
                self._stop.wait(self.interval_seconds)

        self._thread = threading.Thread(target=sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(10)
            if self._thread.is_alive():
                raise SoakError("SAMPLER_STUCK", "resource sampler did not terminate")


def terminate_process_group(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired as error:
            raise SoakError("PROCESS_STUCK", "soak process group survived SIGKILL") from error


def parse_fields(text: str, expected: set[str], marker: str) -> dict[str, int]:
    fields: dict[str, int] = {}
    for token in text.split():
        if token.count("=") != 1:
            raise SoakError("MARKER_TOKEN", f"invalid {marker} token: {token!r}")
        key, raw = token.split("=", 1)
        if key in fields:
            raise SoakError("MARKER_DUPLICATE_FIELD", f"duplicate {marker} field: {key}")
        try:
            fields[key] = int(raw)
        except ValueError as error:
            raise SoakError("MARKER_VALUE", f"non-integer {marker} field: {key}") from error
    if set(fields) != expected:
        missing = sorted(expected - set(fields))
        unknown = sorted(set(fields) - expected)
        raise SoakError("MARKER_FIELDS", f"{marker} missing={missing} unknown={unknown}")
    return fields


def parse_output(text: str) -> tuple[list[dict[str, int]], dict[str, int]]:
    if "SKIPPED" in text:
        raise SoakError("SKIPPED_AS_PASS", "soak output contains SKIPPED")
    samples: list[dict[str, int]] = []
    results: list[dict[str, int]] = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(SAMPLE_PREFIX):
            samples.append(parse_fields(line[len(SAMPLE_PREFIX):], SAMPLE_FIELDS, "sample"))
        elif line.startswith(RESULT_PREFIX):
            results.append(parse_fields(line[len(RESULT_PREFIX):], RESULT_FIELDS, "result"))
    if len(results) != 1:
        raise SoakError("RESULT_COUNT", f"expected one result marker, found {len(results)}")
    if not samples:
        raise SoakError("SAMPLE_MISSING", "soak produced no application samples")
    previous_elapsed = -1
    previous_cycles = -1
    for index, sample in enumerate(samples):
        if sample["index"] != index:
            raise SoakError("SAMPLE_ORDER", f"sample index {sample['index']} != {index}")
        if sample["elapsedMs"] <= previous_elapsed or sample["cycles"] < previous_cycles:
            raise SoakError("SAMPLE_ORDER", "sample time or cycle counter regressed")
        previous_elapsed = sample["elapsedMs"]
        previous_cycles = sample["cycles"]
    return samples, results[0]


def median_windows(values: Sequence[int]) -> tuple[float, float, list[int]]:
    warmup = max(1, len(values) // 5)
    steady = list(values[warmup:])
    width = max(1, len(steady) // 5)
    return statistics.median(steady[:width]), statistics.median(steady[-width:]), steady


def metric_trend(values: Sequence[int], limit: int, *, count_metric: bool) -> dict[str, Any]:
    first, last, steady = median_windows(values)
    growth = last - first
    positive_steps = sum(right > left for left, right in zip(steady, steady[1:]))
    monotonic_growth = (
        len(steady) > 1 and steady[-1] > steady[0]
        and all(right >= left for left, right in zip(steady, steady[1:]))
        and positive_steps >= 3
    )
    passed = growth <= limit and not (count_metric and monotonic_growth)
    return {
        "decision": "PASS" if passed else "FAIL",
        "first_median": first,
        "last_median": last,
        "growth": growth,
        "growth_limit": limit,
        "positive_steps": positive_steps,
        "monotonic_growth": monotonic_growth,
    }


def resource_trend(
    samples: Sequence[Mapping[str, int]], *, minimum_samples: int
) -> dict[str, Any]:
    if len(samples) < minimum_samples:
        return {
            "decision": "INCONCLUSIVE",
            "sample_count": len(samples),
            "minimum_samples": minimum_samples,
            "metrics": {},
        }
    metrics = {
        name: metric_trend(
            [int(sample[name]) for sample in samples],
            limit,
            count_metric=name in COUNT_METRICS,
        )
        for name, limit in RESOURCE_LIMITS.items()
    }
    return {
        "decision": "PASS" if all(value["decision"] == "PASS" for value in metrics.values()) else "FAIL",
        "sample_count": len(samples),
        "minimum_samples": minimum_samples,
        "metrics": metrics,
    }


def application_trend(
    samples: Sequence[Mapping[str, int]], *, minimum_samples: int
) -> dict[str, Any]:
    if len(samples) < minimum_samples:
        return {
            "decision": "INCONCLUSIVE",
            "sample_count": len(samples),
            "minimum_samples": minimum_samples,
        }
    heap = metric_trend(
        [int(sample["usedHeapBytes"]) for sample in samples],
        MAX_HEAP_GROWTH_BYTES,
        count_metric=False,
    )
    owners_ok = all(
        sample["activeWaiters"] == 0
        and sample["activeBuffers"] == 0
        and sample["backgroundTasks"] == 2
        for sample in samples
    )
    progress_ok = samples[-1]["cycles"] > samples[0]["cycles"]
    return {
        "decision": "PASS" if heap["decision"] == "PASS" and owners_ok and progress_ok else "FAIL",
        "sample_count": len(samples),
        "minimum_samples": minimum_samples,
        "heavy_gc_heap": heap,
        "bounded_application_owners": owners_ok,
        "workload_progress": progress_ok,
    }


def validate_workload(
    result: Mapping[str, int],
    requested_seconds: int,
    wall_elapsed_ms: int,
) -> dict[str, bool]:
    checks = {
        "requested_duration": result["durationSeconds"] == requested_seconds,
        "child_duration": result["elapsedMs"] >= requested_seconds * 1000,
        "parent_duration": wall_elapsed_ms >= requested_seconds * 1000,
        "cycles": result["cycles"] > 0,
        "active_idle_mix": (
            result["activePhases"] == result["cycles"]
            and result["idlePhases"] == result["cycles"]
        ),
        "connections": result["connects"] > 2,
        "h1_pool": result["h1Requests"] > 0,
        "h2_multiplex": (
            result["h2Requests"] > 0 and result["h2MultiplexBatches"] == result["cycles"]
        ),
        "sse": result["sseH1Events"] > 0 and result["sseH2Events"] > 0,
        "request_cancellation": result["requestCancels"] == result["cycles"],
        "stream_reset": result["streamResets"] == result["cycles"],
        "connection_recovery": (
            result["connectionCancels"] > 0
            and result["connectionCancels"] == result["reconnects"]
        ),
        "task_join": result["spawnedTasks"] == result["joinedTasks"],
        "sequence_integrity": result["sequenceErrors"] == 0,
        "cancellation_latency": result["maxCancelLatencyNs"] <= MAX_CANCEL_NS,
        "terminal_owners": all(
            result[name] == 0
            for name in ("activeWaiters", "activeBuffers", "backgroundTasks", "serverTasks")
        ),
    }
    return checks


def command_text(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(
            list(command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", timeout=10, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip()[:4096] or None


def execute(args: argparse.Namespace) -> dict[str, Any]:
    platform_data = require_platform()
    if args.duration_seconds <= 0 or args.application_sample_seconds <= 0:
        raise SoakError("ARGUMENT", "duration and application sample interval must be positive")
    if args.resource_sample_seconds <= 0 or args.idle_milliseconds <= 0:
        raise SoakError("ARGUMENT", "resource interval and idle duration must be positive")
    if not ENV_RUNNER.is_file():
        raise SoakError("ENV_RUNNER_MISSING", f"missing {ENV_RUNNER}")
    qualification, artifact_digest = load_qualified_artifact(
        ROOT, args.qualification.resolve(), args.artifact.resolve()
    )
    source = SOURCE.read_text(encoding="utf-8")
    fixture = FIXTURE.read_text(encoding="utf-8").replace(
        "package wirestack_m7_027_examples", "package wirestack_m7_022_soak", 1
    )
    validate_consumer_sources(source, fixture)
    raw_log = args.raw_log.resolve()
    raw_log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-022-") as temporary:
        work = Path(temporary)
        try:
            installed = release.extract_archive(args.artifact.resolve(), work / "install")
        except release.ReleaseError as error:
            raise SoakError("ARTIFACT_EXTRACT", str(error)) from error
        consumer = work / "consumer"
        consumer_source = consumer / "src"
        consumer_source.mkdir(parents=True)
        (consumer / "cjpm.toml").write_text(consumer_manifest(installed), encoding="utf-8")
        (consumer_source / "main.cj").write_text(source, encoding="utf-8")
        (consumer_source / "fixtures.cj").write_text(fixture, encoding="utf-8")
        build_output = run_build(
            [str(ENV_RUNNER), "--cwd", str(consumer), "cjpm", "build"], consumer
        )
        binary = consumer / "target/release/bin/main"
        if not binary.is_file():
            raise SoakError("BINARY_MISSING", "clean consumer produced no executable")
        command = [
            str(ENV_RUNNER), "--cwd", str(consumer), str(binary),
            str(args.duration_seconds), str(int(args.application_sample_seconds * 1000)),
            str(args.idle_milliseconds),
        ]
        started = time.monotonic_ns()
        with raw_log.open("w", encoding="utf-8") as output:
            process = subprocess.Popen(
                command, cwd=consumer, stdout=output, stderr=subprocess.STDOUT,
                text=True, errors="replace", start_new_session=True,
            )
            sampler = ProcessSampler(args.resource_sample_seconds)
            sampler.start(process.pid)
            timed_out = False
            try:
                process.wait(timeout=args.duration_seconds + args.teardown_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_process_group(process)
            finally:
                sampler.stop()
        wall_elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
        exit_code = process.returncode
        if timed_out:
            raise SoakError("SOAK_TIMEOUT", f"child exceeded {args.duration_seconds + args.teardown_seconds}s")
        if exit_code != 0:
            raise SoakError("SOAK_EXIT", f"child exited {exit_code}: {bounded_tail(raw_log)}")
    raw_text = raw_log.read_text(encoding="utf-8", errors="replace")
    application_samples, result = parse_output(raw_text)
    formal = args.duration_seconds >= FORMAL_SECONDS
    minimum_samples = 20 if formal else 5
    process_trend = resource_trend(sampler.samples, minimum_samples=minimum_samples)
    app_trend = application_trend(application_samples, minimum_samples=minimum_samples)
    workload = validate_workload(result, args.duration_seconds, wall_elapsed_ms)
    all_semantics = all(workload.values())
    trends_pass = process_trend["decision"] == "PASS" and app_trend["decision"] == "PASS"
    decision = "PASS" if formal and all_semantics and trends_pass else "INCOMPLETE"
    preflight_status = "PASS" if all_semantics and trends_pass else "FAIL"
    return {
        "schema_version": 1,
        "source_task": TASK_ID,
        "status": decision,
        "acceptance_status": decision,
        "decision": decision,
        "preflight_status": preflight_status,
        "formal_parameters_met": formal,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "platform": platform_data,
        "artifact": {
            "path": str(args.artifact.resolve().relative_to(ROOT)),
            "sha256": artifact_digest,
            "qualification_sha256": sha256_path(args.qualification.resolve()),
            "payload_sha256": qualification["artifact"]["payload_sha256"],
            "installed_as_only_wirestack_dependency": True,
        },
        "parameters": {
            "duration_seconds": args.duration_seconds,
            "minimum_formal_seconds": FORMAL_SECONDS,
            "application_sample_seconds": args.application_sample_seconds,
            "resource_sample_seconds": args.resource_sample_seconds,
            "idle_milliseconds": args.idle_milliseconds,
            "teardown_seconds": args.teardown_seconds,
        },
        "process": {
            "command": command,
            "exit_code": exit_code,
            "timed_out": False,
            "wall_elapsed_ms": wall_elapsed_ms,
            "clean_consumer_build": "PASS",
            "build_output_tail": build_output,
        },
        "workload": {
            "checks": workload,
            "result": result,
            "decision": "PASS" if all_semantics else "FAIL",
        },
        "resources": {
            "process_tree": {"trend": process_trend, "samples": sampler.samples},
            "application": {"trend": app_trend, "samples": application_samples},
            "coverage": {
                "rss": "process-tree VmRSS",
                "fd": "process-tree file descriptors",
                "socket": "process-tree socket descriptors",
                "timer": "process-tree timerfd descriptors",
                "waiter": "zero application-owned waiters between cycles and at terminal",
                "buffer": "zero application-owned buffers between cycles and at terminal",
                "gc_root": "heavy-GC used heap steady-state trend",
                "task": "joined spawned tasks plus bounded server tasks and thread trend",
                "thread": "process-tree thread count",
            },
        },
        "raw_log": {
            "path": str(raw_log.relative_to(ROOT)),
            "sha256": sha256_path(raw_log),
            "bytes": raw_log.stat().st_size,
            "tail": bounded_tail(raw_log),
        },
        "source": {
            "consumer": str(SOURCE.relative_to(ROOT)),
            "consumer_sha256": sha256_path(SOURCE),
            "fixture": str(FIXTURE.relative_to(ROOT)),
            "fixture_sha256": sha256_path(FIXTURE),
        },
        "toolchain": {
            "cjc": command_text([str(ENV_RUNNER), "cjc", "-v"]),
            "cjpm": command_text([str(ENV_RUNNER), "cjpm", "--version"]),
        },
        "non_claims": [
            "This result applies only to native Linux x86_64 glibc.",
            "A short preflight is not 24-hour acceptance evidence.",
            "This task does not sign the artifact or close the independent security review.",
        ],
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--duration-seconds", type=int, default=FORMAL_SECONDS)
    result.add_argument("--application-sample-seconds", type=float, default=60.0)
    result.add_argument("--resource-sample-seconds", type=float, default=60.0)
    result.add_argument("--idle-milliseconds", type=int, default=10)
    result.add_argument("--teardown-seconds", type=int, default=300)
    result.add_argument("--artifact", type=Path, default=ARTIFACT)
    result.add_argument("--qualification", type=Path, default=QUALIFICATION)
    result.add_argument("--raw-log", type=Path, default=ROOT / "build/gates/m7-022-soak.log")
    result.add_argument("--output", type=Path, default=ROOT / "build/gates/m7-022-soak.json")
    result.add_argument("--preflight", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    output = args.output.resolve()
    try:
        report = execute(args)
    except (SoakError, OSError, ValueError) as error:
        code = error.code if isinstance(error, SoakError) else type(error).__name__
        failure = {
            "schema_version": 1,
            "source_task": TASK_ID,
            "status": "FAIL",
            "acceptance_status": "FAIL",
            "decision": "FAIL",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "error": {"code": code, "detail": str(error)[:4096]},
        }
        try:
            atomic_json(output, failure)
        except OSError:
            pass
        print(f"M7-022 Linux release soak: FAIL: {code}: {error}")
        return 1
    atomic_json(output, report)
    print(
        f"M7-022 Linux release soak: {report['decision']} "
        f"preflight={report['preflight_status']} output={output}"
    )
    if args.preflight:
        return 0 if report["preflight_status"] == "PASS" else 1
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
