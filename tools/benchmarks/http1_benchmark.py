#!/usr/bin/env python3
"""Run the pinned Linux HTTP/1 benchmark and emit machine-readable evidence."""
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
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

MIB = 1024 * 1024
WIRESTACK_RE = re.compile(
    r"^\s*HTTP1_BENCH scenario=(\S+) iterations=(\d+) durationNs=(\d+) "
    r"bytes=(\d+) checksum=(\d+)\s*$", re.MULTILINE
)
STDX_RE = re.compile(
    r"^\s*STDX_HTTP1_BENCH scenario=(\S+) iterations=(\d+) durationNs=(\d+) "
    r"bytes=(\d+) checksum=(\d+)\s*$", re.MULTILINE
)
STREAM_CASES = (
    ("stream_16mib", "Http1Stream16MiBBenchmarkTest"),
    ("stream_64mib", "Http1Stream64MiBBenchmarkTest"),
)
STDX_SOURCE = r'''import std.sync.*
import std.time.*
import stdx.net.http.*

main(): Int64 {
    let warmup: Int64 = 200
    let iterations: Int64 = 2000
    let server = ServerBuilder().addr("127.0.0.1").port(0).build()
    server.distributor.register("/small", { context =>
        context.responseBuilder.status(200).header("content-length", "0")
    })
    let bound = AtomicBool(false)
    server.afterBind({ => bound.store(true) })
    let serving = spawn { server.serve() }
    while (!bound.load()) { sleep(Duration.millisecond) }
    let client = ClientBuilder().noProxy().poolSize(1).build()
    var checksum: Int64 = 0
    try {
        let url = "http://127.0.0.1:${server.port}/small"
        for (_ in 0..warmup) {
            let response = client.get(url)
            response.close()
        }
        let started = MonoTime.now()
        for (_ in 0..iterations) {
            let response = client.get(url)
            checksum += Int64(response.status)
            response.close()
        }
        let duration = (MonoTime.now() - started).toNanoseconds()
        println(
            "STDX_HTTP1_BENCH scenario=keep_alive_small iterations=${iterations} " +
            "durationNs=${duration} bytes=0 checksum=${checksum}"
        )
    } finally {
        client.close()
        server.close()
        serving.get(3 * Duration.second)
    }
    if (checksum == iterations * 200) { 0 } else { 1 }
}
'''


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
    def __init__(self, interval_seconds: float = 0.005) -> None:
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


def run_command(command: Sequence[str], cwd: Path, timeout: float,
                env: Mapping[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            list(command), cwd=cwd, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            errors="replace", shell=False, timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired as error:
        raise BenchmarkError(f"command timed out: {' '.join(command)}") from error
    if result.returncode != 0:
        raise BenchmarkError(
            f"command failed with exit {result.returncode}: {' '.join(command)}\n"
            f"{result.stderr[-4000:]}"
        )
    return result


def run_measurement(command: Sequence[str], cwd: Path, scenario: str,
                    pattern: re.Pattern[str], timeout: float,
                    env: Mapping[str, str] | None = None) -> dict[str, Any]:
    process = subprocess.Popen(
        list(command), cwd=cwd, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", shell=False, start_new_session=True, env=env,
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
    matches = pattern.findall(stdout)
    if process.returncode != 0 or timed_out:
        raise BenchmarkError(
            f"{scenario} failed: exit={process.returncode} timeout={timed_out}\n"
            f"{stderr[-4000:]}"
        )
    if len(matches) != 1 or matches[0][0] != scenario:
        raise BenchmarkError(f"{scenario} expected one matching benchmark record")
    _, iterations, duration_ns, byte_count, checksum = matches[0]
    duration = int(duration_ns)
    count = int(iterations)
    bytes_value = int(byte_count)
    if duration <= 0 or count <= 0:
        raise BenchmarkError(f"{scenario} reported invalid duration or iteration count")
    return {
        "scenario": scenario,
        "iterations": count,
        "duration_ns": duration,
        "bytes": bytes_value,
        "checksum": int(checksum),
        "requests_per_second": count * 1_000_000_000 / duration,
        "throughput_mib_per_second": (
            (bytes_value / MIB) * 1_000_000_000 / duration if bytes_value else None
        ),
        "peak_rss_kib": sampler.peak_rss_kib,
        "peak_fd_count": sampler.peak_fd_count,
        "resource_samples": sampler.sample_count,
        "wall_duration_ms": (time.monotonic() - started) * 1000,
        "command": list(command),
    }


def summarize_rounds(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    if not samples:
        raise BenchmarkError("benchmark round list must not be empty")
    iterations = {int(sample["iterations"]) for sample in samples}
    checksums = {int(sample["checksum"]) for sample in samples}
    if len(iterations) != 1 or len(checksums) != 1:
        raise BenchmarkError("benchmark rounds disagree on iterations or checksum")
    durations = [int(sample["duration_ns"]) for sample in samples]
    median_duration = int(statistics.median(durations))
    count = next(iter(iterations))
    return {
        "scenario": "keep_alive_small",
        "iterations": count,
        "checksum": next(iter(checksums)),
        "duration_ns": median_duration,
        "requests_per_second": round(count * 1_000_000_000 / median_duration, 3),
        "duration_ns_min": min(durations),
        "duration_ns_max": max(durations),
        "round_count": len(samples),
        "rounds": list(samples),
        "peak_rss_kib": max(int(sample["peak_rss_kib"]) for sample in samples),
        "peak_fd_count": max(int(sample["peak_fd_count"]) for sample in samples),
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
            "stdx_requests_per_second": round(stdx_baseline_rps, 3),
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


def load_and_verify_stdx(reference_path: Path, archive: Path,
                         extracted_root: Path) -> tuple[dict[str, Any], Path]:
    reference = json.loads(reference_path.read_text(encoding="utf-8"))
    if not evidence_digest.schema_artifact_sha256_equal(
            evidence_digest.artifact_byte_sha256(archive), reference["archive_sha256"]):
        raise BenchmarkError("stdx archive digest does not match the pinned reference")
    dynamic_dir = extracted_root / reference["dynamic_directory"]
    for filename, expected in reference["module_sha256"].items():
        path = dynamic_dir / filename
        if not path.is_file() or not evidence_digest.schema_artifact_sha256_equal(
                evidence_digest.artifact_byte_sha256(path), expected):
            raise BenchmarkError(f"stdx module digest mismatch: {filename}")
    return reference, dynamic_dir


def compile_stdx_driver(repo: Path, dynamic_dir: Path, output: Path,
                        command_prefix: Sequence[str], timeout: float) -> list[str]:
    source = output.with_suffix(".cj")
    source.write_text(STDX_SOURCE, encoding="utf-8")
    command = [
        *command_prefix, "cjc", "-O2", str(source),
        "-L", str(dynamic_dir), "--import-path", str(dynamic_dir),
        "-lstdx.net.http", "-o", str(output),
    ]
    run_command(command, repo, timeout)
    return command


def enable_o2_manifest(manifest_path: Path) -> None:
    manifest = manifest_path.read_text(encoding="utf-8")
    pattern = re.compile(r'^(\s*compile-option\s*=\s*)"[^"]*"', re.MULTILINE)
    if len(pattern.findall(manifest)) != 1:
        raise BenchmarkError("expected one package compile-option in benchmark snapshot")
    manifest_path.write_text(
        pattern.sub(r'\1"-O2"', manifest, count=1), encoding="utf-8"
    )


def prepare_wirestack(repo: Path, benchmark_repo: Path,
                      command_prefix: Sequence[str], timeout: float) -> list[list[str]]:
    shutil.copytree(
        repo, benchmark_repo,
        ignore=shutil.ignore_patterns(
            ".git", ".cjpm", ".codex", "target", "__pycache__", "*.pyc"
        ),
    )
    native_dir = repo / "target/native"
    if not native_dir.is_dir():
        raise BenchmarkError("Wirestack native provider artifacts are missing")
    snapshot_target = benchmark_repo / "target"
    snapshot_target.mkdir()
    (snapshot_target / "native").symlink_to(native_dir, target_is_directory=True)
    enable_o2_manifest(benchmark_repo / "cjpm.toml")
    commands: list[list[str]] = []
    for package in ("src/internal/http1", "src/http"):
        command = [*command_prefix, "cjpm", "test", package, "-j", "1", "--no-run"]
        run_command(command, benchmark_repo, timeout)
        commands.append(command)
    return commands


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--stdx-archive", type=Path, required=True)
    parser.add_argument("--stdx-root", type=Path, required=True)
    parser.add_argument(
        "--stdx-reference", type=Path,
        default=Path("docs/references/stdx-http1-baseline-linux.json"),
    )
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--build-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--command-prefix", nargs="+",
        default=["/home/elliot/.codex/scripts/codex_cangjie_env"],
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.rounds < 3 or args.rounds % 2 == 0:
        raise BenchmarkError("round count must be an odd integer of at least three")
    repo = args.repo.resolve()
    reference_path = args.stdx_reference
    if not reference_path.is_absolute():
        reference_path = repo / reference_path
    reference, dynamic_dir = load_and_verify_stdx(
        reference_path, args.stdx_archive.resolve(), args.stdx_root.resolve()
    )
    with tempfile.TemporaryDirectory(prefix="wirestack-http1-build-") as build_temporary, \
            tempfile.TemporaryDirectory(prefix="wirestack-http1-stdx-") as temporary:
        benchmark_repo = Path(build_temporary) / "repository"
        build_commands = prepare_wirestack(
            repo, benchmark_repo, args.command_prefix, args.build_timeout_seconds
        )
        wirestack_binary = (
            benchmark_repo / "target/release/unittest_bin/wirestack.http"
        )
        stream_binary = (
            benchmark_repo / "target/release/unittest_bin/wirestack.internal.http1"
        )
        if not wirestack_binary.is_file() or not stream_binary.is_file():
            raise BenchmarkError("cjpm did not produce the expected unittest binaries")

        stdx_binary = Path(temporary) / "stdx_http1_benchmark"
        stdx_compile = compile_stdx_driver(
            repo, dynamic_dir, stdx_binary, args.command_prefix,
            args.build_timeout_seconds,
        )
        stdx_env = dict(os.environ)
        prior_library_path = stdx_env.get("LD_LIBRARY_PATH", "")
        stdx_env["LD_LIBRARY_PATH"] = (
            str(dynamic_dir) if not prior_library_path
            else f"{dynamic_dir}:{prior_library_path}"
        )
        wirestack_rounds: list[dict[str, Any]] = []
        stdx_rounds: list[dict[str, Any]] = []
        wirestack_command = [
            str(wirestack_binary), "--filter=Http1PublicKeepAliveBenchmarkTest",
            "--show-all-output", "--no-progress", "--no-color",
        ]
        for index in range(args.rounds):
            order = ("wirestack", "stdx") if index % 2 == 0 else ("stdx", "wirestack")
            for leg in order:
                if leg == "wirestack":
                    wirestack_rounds.append(run_measurement(
                        wirestack_command, benchmark_repo, "keep_alive_small", WIRESTACK_RE,
                        args.timeout_seconds,
                    ))
                else:
                    stdx_rounds.append(run_measurement(
                        [str(stdx_binary)], repo, "keep_alive_small", STDX_RE,
                        args.timeout_seconds, env=stdx_env,
                    ))

        wirestack_small = summarize_rounds(wirestack_rounds)
        stdx_small = summarize_rounds(stdx_rounds)
        cases: dict[str, dict[str, Any]] = {"keep_alive_small": wirestack_small}
        for scenario, test_class in STREAM_CASES:
            command = [
                str(stream_binary), f"--filter={test_class}",
                "--show-all-output", "--no-progress", "--no-color",
            ]
            cases[scenario] = run_measurement(
                command, benchmark_repo, scenario, WIRESTACK_RE, args.timeout_seconds
            )

    decisions = classify(cases, float(stdx_small["requests_per_second"]))
    decisions["stdx_comparison"]["stdx_rounds"] = stdx_small
    result = {
        "schema_version": 2,
        "task_id": "M5-030",
        "platform": {
            "system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "python": platform.python_version(),
        },
        "configuration": {
            "rounds": args.rounds,
            "optimization": "-O2",
            "ordering": "alternating; Wirestack first on odd-numbered rounds",
            "required_ratio": 0.9,
        },
        "stdx_reference": {
            **reference,
            "reference_sha256": evidence_digest.text_evidence_sha256(reference_path),
            "archive_path": str(args.stdx_archive.resolve()),
            "extracted_root": str(args.stdx_root.resolve()),
            "compile_command": stdx_compile,
            "driver_source_sha256": evidence_digest.text_evidence_bytes_sha256(STDX_SOURCE.encode()),
        },
        "source": {
            "benchmark_runner_sha256": evidence_digest.text_evidence_sha256(Path(__file__)),
            "public_harness_sha256": evidence_digest.text_evidence_sha256(repo / "src/http/benchmark_harness_test.cj"),
            "stream_harness_sha256": evidence_digest.text_evidence_sha256(repo / "src/internal/http1/benchmark_harness_test.cj"),
            "build_commands": build_commands,
            "build_working_directory": str(benchmark_repo),
        },
        "cases": cases,
        **decisions,
    }
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0 if result["decision"] == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"HTTP1_BENCH_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
