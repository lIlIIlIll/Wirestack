#!/usr/bin/env python3
"""Run the versioned yjson Stream benchmark protocol as paired process rounds."""

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


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BENCH_DIR = ROOT / "packages" / "benchmarks"
CASES = {
    "decode-person-chunk-64": ("decode", "person", "chunk-64", "decodePersonChunk64"),
    "decode-person-chunk-4k": ("decode", "person", "chunk-4k", "decodePersonChunk4k"),
    "decode-person-chunk-random": ("decode", "person", "chunk-random", "decodePersonChunkRandom"),
    "decode-records-64k-chunk-64": ("decode", "records-64k", "chunk-64", "decodeRecords64kChunk64"),
    "decode-records-64k-chunk-4k": ("decode", "records-64k", "chunk-4k", "decodeRecords64kChunk4k"),
    "decode-records-64k-chunk-random": ("decode", "records-64k", "chunk-random", "decodeRecords64kChunkRandom"),
    "decode-records-1m-chunk-64": ("decode", "records-1m", "chunk-64", "decodeRecords1mChunk64"),
    "decode-records-1m-chunk-4k": ("decode", "records-1m", "chunk-4k", "decodeRecords1mChunk4k"),
    "decode-records-1m-chunk-random": ("decode", "records-1m", "chunk-random", "decodeRecords1mChunkRandom"),
    "encode-person-memory": ("encode", "person", "memory", "encodePersonMemory"),
    "encode-person-counting": ("encode", "person", "counting", "encodePersonCounting"),
    "encode-records-64k-memory": ("encode", "records-64k", "memory", "encodeRecords64kMemory"),
    "encode-records-64k-counting": ("encode", "records-64k", "counting", "encodeRecords64kCounting"),
    "encode-records-1m-memory": ("encode", "records-1m", "memory", "encodeRecords1mMemory"),
    "encode-records-1m-counting": ("encode", "records-1m", "counting", "encodeRecords1mCounting"),
}
LIFECYCLES = ("unpooled-one-shot", "pooled-steady-state")


def run_text(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    done = subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return (done.stdout + done.stderr).strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_variant(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("variant must be LABEL=BENCH_DIR")
    label, raw_path = value.split("=", 1)
    if not label or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", label):
        raise argparse.ArgumentTypeError("variant label must use lowercase letters, digits, and hyphens")
    return label, Path(raw_path)


def process_schedule(round_id: int, variants: list[str]) -> list[tuple[str, str]]:
    ordered_variants = variants if round_id % 2 else list(reversed(variants))
    result: list[tuple[str, str]] = []
    for index, variant in enumerate(ordered_variants):
        lifecycles = LIFECYCLES if (round_id + index) % 2 else tuple(reversed(LIFECYCLES))
        result.extend((variant, lifecycle) for lifecycle in lifecycles)
    return result


def cell_schedule(round_id: int, variants: list[str], cases: list[str]) -> list[tuple[str, str, str]]:
    offset = (round_id - 1) % len(cases)
    ordered_cases = cases[offset:] + cases[:offset]
    if round_id % 2 == 0:
        ordered_cases.reverse()
    result: list[tuple[str, str, str]] = []
    for case_index, case in enumerate(ordered_cases):
        ordered_variants = variants if (round_id + case_index) % 2 else list(reversed(variants))
        for variant_index, variant in enumerate(ordered_variants):
            lifecycles = LIFECYCLES if (round_id + case_index + variant_index) % 2 \
                else tuple(reversed(LIFECYCLES))
            result.extend((variant, lifecycle, case) for lifecycle in lifecycles)
    return result


def exported_payloads(artifact_dir: Path) -> dict[str, dict[str, object]]:
    payloads = {}
    for path in sorted(artifact_dir.glob("*.json")):
        payloads[path.stem] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    if set(payloads) != {"person", "records-64k", "records-1m"}:
        raise ValueError(f"payload export incomplete: {sorted(payloads)}")
    return payloads


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bench-dir", type=Path, default=DEFAULT_BENCH_DIR)
    parser.add_argument("--variant", type=parse_variant, action="append",
                        help="paired LABEL=BENCH_DIR build; repeat for baseline and candidate")
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--cjpm", default="cjpm")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--case-regex")
    parser.add_argument("--commit", default="workspace")
    parser.add_argument("--sdk-label", default="unknown")
    parser.add_argument("--process-mode", choices=("cell", "grouped"), default="cell",
                        help="cell is the formal isolated protocol; grouped is smoke-only")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"output directory is not empty: {args.output}")

    cases = list(CASES)
    if args.case_regex:
        pattern = re.compile(args.case_regex)
        cases = [case for case in cases if pattern.search(case)]
        if not cases:
            parser.error("--case-regex matched no cases")

    output = args.output.resolve()
    variant_items = args.variant or [("workspace", args.bench_dir)]
    variants = {label: path.resolve() for label, path in variant_items}
    if len(variants) != len(variant_items):
        parser.error("variant labels must be unique")
    raw_dir = output / "raw"
    log_dir = output / "logs"
    artifact_dir = output / "payloads"
    raw_dir.mkdir(parents=True)
    log_dir.mkdir(parents=True)
    artifact_dir.mkdir(parents=True)
    env = os.environ.copy()
    env["cjHeapSize"] = args.heap
    env["LC_ALL"] = "C"

    for label, bench_dir in variants.items():
        if not args.skip_build:
            build = subprocess.run([args.cjpm, "bench", "--no-run", "--no-color"], cwd=bench_dir,
                                   env=env, capture_output=True, text=True)
            (log_dir / f"build-{label}.log").write_text(build.stdout + build.stderr, encoding="utf-8")
            if build.returncode:
                print(f"benchmark build failed for {label}; see {log_dir / f'build-{label}.log'}",
                      file=sys.stderr)
                return build.returncode

        export_dir = artifact_dir if label == next(iter(variants)) else output / f"payloads-{label}"
        export_dir.mkdir(parents=True, exist_ok=True)
        export_env = env.copy()
        export_env["YJSON_STREAM_PROTOCOL_ARTIFACT_DIR"] = str(export_dir)
        export = subprocess.run([
            "taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build", "--no-color",
            "--filter", "StreamProtocolBenchmarks.decodePersonChunk64*",
        ], cwd=bench_dir, env=export_env, capture_output=True, text=True)
        (log_dir / f"payload-export-{label}.log").write_text(
            export.stdout + export.stderr, encoding="utf-8")
        if export.returncode:
            print(f"payload export failed for {label}; see {log_dir / f'payload-export-{label}.log'}",
                  file=sys.stderr)
            return export.returncode
        current_payloads = exported_payloads(export_dir)
        if label == next(iter(variants)):
            payloads = current_payloads
        elif current_payloads != payloads:
            print(f"payload identity differs for variant {label}", file=sys.stderr)
            return 2

    metadata = {
        "protocol_version": 1,
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(), "platform": platform.platform(),
        "cpu": args.cpu, "heap": args.heap, "runs": args.runs,
        "process_mode": args.process_mode,
        "schedule": ("one process per case/variant/lifecycle; cases rotate and reverse by round; "
                     "variant and lifecycle order alternate" if args.process_mode == "cell" else
                     "one process per variant/lifecycle/round; variant and lifecycle order alternate; "
                     "benchmark method order uses the round random seed"),
        "commit": args.commit, "sdk_label": args.sdk_label,
        "variants": {label: str(path) for label, path in variants.items()},
        "payloads": payloads,
        "cjc_version": run_text(["cjc", "-v"], next(iter(variants.values())), env),
        "cjpm_version": run_text([args.cjpm, "--version"], next(iter(variants.values())), env),
        "lscpu": run_text(["lscpu"], next(iter(variants.values())), env),
        "affinity_probe": run_text(["taskset", "-c", str(args.cpu), "sh", "-c",
                                    "grep Cpus_allowed_list /proc/self/status"],
                                   next(iter(variants.values())), env),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    fields = ("round", "position", "variant", "case", "method", "operation", "payload", "profile", "lifecycle",
              "elapsed_seconds", "report_path", "log_path")
    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            if args.process_mode == "cell":
                scheduled = cell_schedule(round_id, list(variants), cases)
            else:
                scheduled = [(variant, lifecycle, "")
                             for variant, lifecycle in process_schedule(round_id, list(variants))]
            for position, (variant, lifecycle, scheduled_case) in enumerate(scheduled, start=1):
                bench_dir = variants[variant]
                suffix = f"-{scheduled_case}" if scheduled_case else ""
                report = raw_dir / variant / f"run-{round_id:02d}" / f"{lifecycle}{suffix}"
                log = log_dir / f"run-{round_id:02d}-{position:02d}-{variant}-{lifecycle}{suffix}.log"
                cell_env = env.copy()
                if lifecycle == "unpooled-one-shot":
                    cell_env["YJSON_BENCH_DISABLE_STREAM_REUSE"] = "1"
                filter_value = (f"StreamProtocolBenchmarks.{CASES[scheduled_case][3]}*"
                                if scheduled_case else "StreamProtocolBenchmarks.*")
                started = time.monotonic()
                done = subprocess.run([
                    "taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build", "--no-color",
                    "--filter", filter_value, "--report-path", str(report),
                    "--report-format", "csv-raw", "--random-seed", str(round_id),
                ], cwd=bench_dir, env=cell_env, capture_output=True, text=True)
                elapsed = time.monotonic() - started
                log.write_text(done.stdout + done.stderr, encoding="utf-8")
                if done.returncode or not list(report.rglob("bench-*.csv")):
                    print(f"benchmark failed: round={round_id} variant={variant} lifecycle={lifecycle}; see {log}",
                          file=sys.stderr)
                    return done.returncode or 2
                recorded_cases = [scheduled_case] if scheduled_case else cases
                for case in recorded_cases:
                    operation, payload, profile, method = CASES[case]
                    writer.writerow({"round": round_id, "position": position, "variant": variant,
                                     "case": case, "method": method, "operation": operation,
                                     "payload": payload, "profile": profile, "lifecycle": lifecycle,
                                     "elapsed_seconds": f"{elapsed:.6f}",
                                     "report_path": report.relative_to(output),
                                     "log_path": log.relative_to(output)})
                stream.flush()
                print(f"completed round {round_id}/{args.runs}, process {position}/{len(scheduled)}: "
                      f"{variant} {lifecycle} "
                      f"({scheduled_case if scheduled_case else f'{len(cases)} cases'})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
