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
BENCH_METHOD_RE = re.compile(r"@Bench\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


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

    metadata = {
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "cpu": args.cpu,
        "heap": args.heap,
        "runs": args.runs,
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
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    manifest_path = output / "manifest.csv"
    with manifest_path.open("w", newline="", encoding="utf-8") as manifest:
        writer = csv.DictWriter(manifest, fieldnames=(
            "round", "workload_position", "library_position", "library", "workload",
            "scenario", "operation", "payload", "input_kind", "source_case",
            "elapsed_seconds", "load1_before", "load1_after", "report_path", "log_path",
        ))
        writer.writeheader()
        built_packages = {"yjson": False, "cjfast_json": False}
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
                    log_path = (
                        log_dir /
                        f"run-{round_id:02d}-workload-{workload_position:02d}-{library}.log"
                    )
                    if library in {"yjson", "stdx_json"}:
                        cwd = YJSON_BENCH_DIR
                        filter_name = f"ComprehensiveJsonCompareBenchmarks.{source_case}*"
                        build_key = "yjson"
                    else:
                        cwd = cjfast_work_dir
                        filter_name = f"CjFastJsonComprehensiveBenchmarks.{source_case}*"
                        build_key = "cjfast_json"
                    command = ["taskset", "-c", str(args.cpu), "cjpm", "bench"]
                    if built_packages[build_key]:
                        command.append("--skip-build")
                    command.extend([
                        "--no-color", "--filter", filter_name, "--report-path", str(report_path),
                        "--report-format", "csv-raw", "--random-seed", str(round_id),
                    ])
                    load_before = os.getloadavg()[0]
                    started = time.monotonic()
                    completed = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
                    elapsed = time.monotonic() - started
                    load_after = os.getloadavg()[0]
                    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
                    if completed.returncode != 0:
                        print(
                            f"benchmark failed: round={round_id} workload={workload['workload']} "
                            f"library={library}; see {log_path}", file=sys.stderr,
                        )
                        return completed.returncode
                    built_packages[build_key] = True
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
                        "load1_before": f"{load_before:.3f}",
                        "load1_after": f"{load_after:.3f}",
                        "report_path": report_path.relative_to(output),
                        "log_path": log_path.relative_to(output),
                    })
                    manifest.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
