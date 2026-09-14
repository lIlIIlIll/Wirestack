#!/usr/bin/env python3
"""Run yjson, stdx.json, and cjfast_json as interleaved benchmark processes."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import json_perf_baseline as baseline


ROOT = Path(__file__).resolve().parents[1]
YJSON_BENCH_DIR = ROOT / "packages" / "benchmarks"
YJSON_SOURCE = YJSON_BENCH_DIR / "src" / "bench_json_comprehensive.cj"
CJFAST_ADAPTER = ROOT / "benchmarks" / "cjfast_json" / "cjfast_comprehensive_bench.cj"
YJSON_BINARY = YJSON_BENCH_DIR / "target/release/unittest_bin/yjson_benchmarks"
BENCH_METHOD_RE = re.compile(r"@Bench\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)

RSS_RE = re.compile(
    r"^[ \t]*Maximum resident set size \(kbytes\):[ \t]*(\d+)[ \t]*$",
    re.MULTILINE,
)


def find_time_binary() -> str:
    path = shutil.which("time", path="/usr/bin:/bin")
    if path:
        return path
    raise SystemExit(
        "GNU time (/usr/bin/time) is required for RSS capture; install the 'time' package"
    )


def parse_max_rss(path: Path) -> int:
    matches = RSS_RE.findall(path.read_text(encoding="utf-8", errors="replace"))
    if len(matches) != 1:
        raise ValueError(
            f"expected one GNU time RSS value in {path}, found {len(matches)}"
        )
    value = int(matches[0])
    if value <= 0:
        raise ValueError(f"GNU time RSS value must be positive in {path}")
    return value


def run_text(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    completed = subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return (completed.stdout + completed.stderr).strip()


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    paths: list[Path] = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [item for item in dirs if item not in {"target", ".git", "build-script-cache"}]
        for filename in files:
            path = Path(current) / filename
            if path.suffix in {".cj", ".py", ".sh", ".toml"}:
                paths.append(path)
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def declared_methods(path: Path) -> set[str]:
    return set(BENCH_METHOD_RE.findall(path.read_text(encoding="utf-8")))


def meta_key(meta: baseline.Meta) -> tuple[str, str, str, str]:
    return (meta.scenario, meta.operation, meta.payload, meta.input_kind)


def matched_workloads() -> list[dict[str, str]]:
    baseline.build_metadata()
    yjson_methods = declared_methods(YJSON_SOURCE)
    cjfast_methods = declared_methods(CJFAST_ADAPTER)
    yjson = {
        meta_key(meta): case
        for case, meta in baseline.CANGJIE_META.items()
        if case.startswith("yjson") and case in yjson_methods
    }
    stdx = {
        meta_key(meta): case
        for case, meta in baseline.CANGJIE_META.items()
        if case.startswith("stdx") and case in yjson_methods
    }
    cjfast = {
        meta_key(meta): case
        for case, meta in baseline.CJFAST_META.items()
        if case in cjfast_methods
    }
    workloads = []
    for key in sorted(set(yjson) & set(stdx) & set(cjfast)):
        scenario, operation, payload, input_kind = key
        workloads.append({
            "workload": " | ".join(key),
            "scenario": scenario,
            "operation": operation,
            "payload": payload,
            "input_kind": input_kind,
            "yjson_case": yjson[key],
            "stdx_json_case": stdx[key],
            "cjfast_json_case": cjfast[key],
        })
    if not workloads:
        raise ValueError("no implemented yjson/stdx.json/cjfast_json benchmark workloads overlap")
    return workloads


def balanced_workloads(workloads: list[dict[str, str]], round_id: int) -> list[dict[str, str]]:
    offset = (round_id - 1) % len(workloads)
    rotated = workloads[offset:] + workloads[:offset]
    return rotated if round_id % 2 == 1 else list(reversed(rotated))


def library_order(round_id: int) -> tuple[str, str, str]:
    libraries = ("yjson", "stdx_json", "cjfast_json")
    offset = (round_id - 1) % len(libraries)
    return libraries[offset:] + libraries[:offset]

def cangjie_command(
    cpu: int,
    binary: Path,
    source_case: str,
    report_path: Path,
    round_id: int,
) -> list[str]:
    """Build a timed command for one prebuilt Cangjie benchmark case."""
    return [
        "taskset",
        "-c",
        str(cpu),
        str(binary),
        "--bench",
        "--no-color",
        "--no-progress",
        f"--filter=*.{source_case}",
        f"--report-path={report_path}",
        "--report-format=csv-raw",
        f"--random-seed={round_id}",
    ]


def build_command(cpu: int) -> list[str]:
    """Build a benchmark package without running a measured case."""
    return [
        "taskset",
        "-c",
        str(cpu),
        "cjpm",
        "bench",
        "--no-run",
        "--no-color",
    ]


def build_benchmark_package(
    cwd: Path,
    env: dict[str, str],
    cpu: int,
    log_path: Path,
) -> int:
    completed = subprocess.run(
        build_command(cpu),
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
    )
    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
    return completed.returncode


def binary_path_for(library: str, cjfast_work_dir: Path) -> Path:
    if library in {"yjson", "stdx_json"}:
        return YJSON_BINARY
    return cjfast_work_dir / "target/release/unittest_bin/fastjson.bench"


def runtime_environment(env: dict[str, str]) -> dict[str, str]:
    command_env = env.copy()
    dynamic_stdx = command_env.get("CANGJIE_STDX_PATH")
    if not dynamic_stdx:
        raise ValueError("CANGJIE_STDX_PATH is required for direct benchmark execution")
    current = command_env.get("LD_LIBRARY_PATH", "")
    command_env["LD_LIBRARY_PATH"] = (
        f"{dynamic_stdx}:{current}" if current else dynamic_stdx
    )
    return command_env


def build_cwd_for(library: str, cjfast_work_dir: Path) -> Path:
    if library in {"yjson", "stdx_json"}:
        return YJSON_BENCH_DIR
    return cjfast_work_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--cjfast-work-dir", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--yjson-commit", default="unknown")
    parser.add_argument("--cjfast-commit", default="eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65")
    parser.add_argument("--sdk-label", default="unknown")
    parser.add_argument(
        "--workload-regex",
        help="run only workloads whose descriptive key matches this regular expression",
    )
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"output directory is not empty: {args.output}")

    output = args.output.resolve()
    cjfast_work_dir = args.cjfast_work_dir.resolve()
    raw_dir = output / "raw"
    log_dir = output / "logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    workloads = matched_workloads()
    if args.workload_regex:
        pattern = re.compile(args.workload_regex)
        workloads = [item for item in workloads if pattern.search(item["workload"])]
        if not workloads:
            parser.error(f"no workload matches --workload-regex {args.workload_regex!r}")
    env = os.environ.copy()
    env["cjHeapSize"] = args.heap
    env["LC_ALL"] = "C"
    time_binary = find_time_binary()

    metadata = {
        "time_binary": time_binary,
        "rss_unit": "kbytes",
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "cpu": args.cpu,
        "heap": args.heap,
        "runs": args.runs,
        "timing_build_policy": (
            "both Cangjie benchmark packages are built with cjpm bench --no-run "
            "before GNU time wraps the prebuilt benchmark executables"
        ),
        "schedule": "workload rotation; even rounds reversed; three-library order rotates by round",
        "workload_count": len(workloads),
        "workloads": workloads,
        "yjson_commit": args.yjson_commit,
        "cjfast_json_commit": args.cjfast_commit,
        "stdx_dependency": "0.0.3",
        "sdk_label": args.sdk_label,
        "yjson_source_sha256": source_digest(ROOT),
        "cjfast_source_sha256": source_digest(cjfast_work_dir),
        "cjc_version": run_text(["cjc", "-v"], YJSON_BENCH_DIR, env),
        "cjpm_version": run_text(["cjpm", "--version"], YJSON_BENCH_DIR, env),
        "lscpu": run_text(["lscpu"], YJSON_BENCH_DIR, env),
        "affinity_probe": run_text(
            ["taskset", "-c", str(args.cpu), "sh", "-c", "grep Cpus_allowed_list /proc/self/status"],
            YJSON_BENCH_DIR,
            env,
        ),
        "ld_preload": env.get("LD_PRELOAD", ""),
        "cangjie_stdx_path": env.get("CANGJIE_STDX_PATH", ""),
    }

    for build_key, build_cwd in (
        ("yjson", YJSON_BENCH_DIR),
        ("cjfast_json", cjfast_work_dir),
    ):
        build_log_path = log_dir / f"build-{build_key}.log"
        build_status = build_benchmark_package(
            build_cwd, env, args.cpu, build_log_path
        )
        if build_status != 0:
            print(
                f"benchmark build failed for {build_key}; see {build_log_path}",
                file=sys.stderr,
            )
            return build_status
    binary_paths = {
        library: binary_path_for(library, cjfast_work_dir)
        for library in ("yjson", "stdx_json", "cjfast_json")
    }
    missing_binaries = [
        f"{library}: {path}"
        for library, path in binary_paths.items()
        if not path.is_file() or not os.access(path, os.X_OK)
    ]
    if missing_binaries:
        print(
            "built benchmark executable missing after unmeasured build: "
            + ", ".join(missing_binaries),
            file=sys.stderr,
        )
        return 2
    metadata["cangjie_binaries"] = {
        library: {"path": str(path), "sha256": file_digest(path)}
        for library, path in binary_paths.items()
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


    manifest_path = output / "manifest.csv"
    with manifest_path.open("w", newline="", encoding="utf-8") as manifest:
        writer = csv.DictWriter(manifest, fieldnames=(
            "round", "workload_position", "library_position", "library", "workload",
            "scenario", "operation", "payload", "input_kind", "source_case",
            "elapsed_seconds", "max_rss_kb", "load1_before", "load1_after",
            "report_path", "rss_path", "log_path",
        ))
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            for workload_position, workload in enumerate(
                balanced_workloads(workloads, round_id), start=1
            ):
                for library_position, library in enumerate(library_order(round_id), start=1):
                    source_case = workload[f"{library}_case"]
                    report_path = (
                        raw_dir / f"run-{round_id:02d}" /
                        f"workload-{workload_position:02d}-{library}"
                    )
                    report_path.mkdir(parents=True, exist_ok=True)
                    rss_path = report_path / "time-rss.txt"
                    log_path = (
                        log_dir /
                        f"run-{round_id:02d}-workload-{workload_position:02d}-{library}.log"
                    )
                    cwd = build_cwd_for(library, cjfast_work_dir)
                    if library in {"yjson", "stdx_json", "cjfast_json"}:
                        binary = binary_path_for(library, cjfast_work_dir)
                        command = cangjie_command(
                            args.cpu, binary, source_case, report_path, round_id
                        )
                    else:
                        command = java_command(
                            args.cpu, source_case, report_path / "jmh.json"
                        )
                    before = os.getloadavg()[0]
                    started = time.monotonic()
                    command_env = (
                        runtime_environment(env)
                        if library in {"yjson", "stdx_json", "cjfast_json"}
                        else env.copy()
                    )
                    completed = subprocess.run(
                        [time_binary, "-v", "-o", str(rss_path), *command],
                        cwd=cwd,
                        env=command_env,
                        capture_output=True,
                        text=True,
                    )
                    elapsed = time.monotonic() - started
                    load_after = os.getloadavg()[0]
                    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
                    if completed.returncode != 0:
                        print(
                            f"benchmark failed: round={round_id} workload={workload['workload']} "
                            f"library={library}; see {log_path}", file=sys.stderr,
                        )
                        return completed.returncode
                    try:
                        max_rss_kb = parse_max_rss(rss_path)
                    except (OSError, UnicodeError, ValueError) as error:
                        print(
                            f"benchmark RSS capture failed: round={round_id} "
                            f"workload={workload['workload']} library={library}: {error}",
                            file=sys.stderr,
                        )
                        return 2

                    if not list(report_path.rglob("bench-*.csv")):
                        print(
                            f"benchmark produced no raw CSV: round={round_id} "
                            f"workload={workload['workload']} library={library}; see {log_path}",
                            file=sys.stderr,
                        )
                        return 2
                    writer.writerow({
                        "round": round_id,
                        "workload_position": workload_position,
                        "library_position": library_position,
                        "library": library,
                        "workload": workload["workload"],
                        "scenario": workload["scenario"],
                        "operation": workload["operation"],
                        "payload": workload["payload"],
                        "input_kind": workload["input_kind"],
                        "source_case": source_case,
                        "elapsed_seconds": f"{elapsed:.6f}",
                        "max_rss_kb": max_rss_kb,
                        "load1_before": f"{load_before:.3f}",
                        "load1_after": f"{load_after:.3f}",
                        "report_path": report_path.relative_to(output),
                        "rss_path": rss_path.relative_to(output),
                        "log_path": log_path.relative_to(output),
                    })
                    manifest.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
