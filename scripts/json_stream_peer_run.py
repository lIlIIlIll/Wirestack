#!/usr/bin/env python3
"""Run paired yjson and stdx.json Stream protocol processes."""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from json_stream_protocol_run import exported_payloads, run_text


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BENCH_DIR = ROOT / "packages" / "benchmarks"
IMPLEMENTATIONS = ("yjson", "stdx")
CASES = {
    "decode-person-chunk-64": ("decode", "person", "chunk-64", "decodePersonChunk64", "decodeStdxPersonChunk64"),
    "decode-person-chunk-4k": ("decode", "person", "chunk-4k", "decodePersonChunk4k", "decodeStdxPersonChunk4k"),
    "decode-person-chunk-random": ("decode", "person", "chunk-random", "decodePersonChunkRandom", "decodeStdxPersonChunkRandom"),
    "decode-records-64k-chunk-64": ("decode", "records-64k", "chunk-64", "decodeRecords64kChunk64", "decodeStdxRecords64kChunk64"),
    "decode-records-64k-chunk-4k": ("decode", "records-64k", "chunk-4k", "decodeRecords64kChunk4k", "decodeStdxRecords64kChunk4k"),
    "decode-records-64k-chunk-random": ("decode", "records-64k", "chunk-random", "decodeRecords64kChunkRandom", "decodeStdxRecords64kChunkRandom"),
    "decode-records-1m-chunk-64": ("decode", "records-1m", "chunk-64", "decodeRecords1mChunk64", "decodeStdxRecords1mChunk64"),
    "decode-records-1m-chunk-4k": ("decode", "records-1m", "chunk-4k", "decodeRecords1mChunk4k", "decodeStdxRecords1mChunk4k"),
    "decode-records-1m-chunk-random": ("decode", "records-1m", "chunk-random", "decodeRecords1mChunkRandom", "decodeStdxRecords1mChunkRandom"),
    "encode-person-memory": ("encode", "person", "memory", "encodePersonMemory", "encodeStdxPersonMemory"),
    "encode-person-counting": ("encode", "person", "counting", "encodePersonCounting", "encodeStdxPersonCounting"),
    "encode-records-64k-memory": ("encode", "records-64k", "memory", "encodeRecords64kMemory", "encodeStdxRecords64kMemory"),
    "encode-records-64k-counting": ("encode", "records-64k", "counting", "encodeRecords64kCounting", "encodeStdxRecords64kCounting"),
    "encode-records-1m-memory": ("encode", "records-1m", "memory", "encodeRecords1mMemory", "encodeStdxRecords1mMemory"),
    "encode-records-1m-counting": ("encode", "records-1m", "counting", "encodeRecords1mCounting", "encodeStdxRecords1mCounting"),
}


def schedule(round_id: int, cases: list[str]) -> list[tuple[str, str]]:
    offset = (round_id - 1) % len(cases)
    ordered_cases = cases[offset:] + cases[:offset]
    if round_id % 2 == 0:
        ordered_cases.reverse()
    result: list[tuple[str, str]] = []
    for case_index, case in enumerate(ordered_cases):
        implementations = IMPLEMENTATIONS if (round_id + case_index) % 2 else tuple(reversed(IMPLEMENTATIONS))
        result.extend((implementation, case) for implementation in implementations)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bench-dir", type=Path, default=DEFAULT_BENCH_DIR)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--cjpm", default="cjpm")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--case-regex")
    parser.add_argument("--commit", default="workspace")
    parser.add_argument("--sdk-label", default="unknown")
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
    bench_dir = args.bench_dir.resolve()
    raw_dir = output / "raw"
    log_dir = output / "logs"
    payload_dir = output / "payloads"
    raw_dir.mkdir(parents=True)
    log_dir.mkdir(parents=True)
    payload_dir.mkdir(parents=True)
    env = os.environ.copy()
    env["cjHeapSize"] = args.heap
    env["LC_ALL"] = "C"

    if not args.skip_build:
        build = subprocess.run([args.cjpm, "bench", "--no-run", "--no-color"], cwd=bench_dir,
                               env=env, capture_output=True, text=True)
        (log_dir / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        if build.returncode:
            print(f"benchmark build failed; see {log_dir / 'build.log'}", file=sys.stderr)
            return build.returncode

    export_env = env.copy()
    export_env["YJSON_STREAM_PROTOCOL_ARTIFACT_DIR"] = str(payload_dir)
    export = subprocess.run([
        "taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build", "--no-color",
        "--filter", "StreamProtocolBenchmarks.decodePersonChunk64*",
    ], cwd=bench_dir, env=export_env, capture_output=True, text=True)
    (log_dir / "payload-export.log").write_text(export.stdout + export.stderr, encoding="utf-8")
    if export.returncode:
        print(f"payload export failed; see {log_dir / 'payload-export.log'}", file=sys.stderr)
        return export.returncode
    payloads = exported_payloads(payload_dir)

    metadata = {
        "protocol_version": 1,
        "comparison": "yjson-vs-stdx-stream",
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(), "platform": platform.platform(),
        "cpu": args.cpu, "heap": args.heap, "runs": args.runs,
        "schedule": ("one process per case and implementation; cases rotate and reverse by round; "
                     "implementation order alternates"),
        "commit": args.commit, "sdk_label": args.sdk_label,
        "bench_dir": str(bench_dir), "payloads": payloads,
        "eligibility": {
            "yjson": "typed incremental InputStream and OutputStream",
            "stdx.json": "typed incremental JsonReader(InputStream) and JsonWriter(OutputStream)",
            "cjfast_json": "N/A: the current adapter requires ByteBuffer rather than InputStream",
        },
        "cjc_version": run_text(["cjc", "-v"], bench_dir, env),
        "cjpm_version": run_text([args.cjpm, "--version"], bench_dir, env),
        "lscpu": run_text(["lscpu"], bench_dir, env),
        "affinity_probe": run_text(["taskset", "-c", str(args.cpu), "sh", "-c",
                                    "grep Cpus_allowed_list /proc/self/status"], bench_dir, env),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    fields = ("round", "position", "implementation", "case", "method", "operation", "payload",
              "profile", "elapsed_seconds", "report_path", "log_path")
    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            scheduled = schedule(round_id, cases)
            for position, (implementation, case) in enumerate(scheduled, start=1):
                operation, payload, profile, yjson_method, stdx_method = CASES[case]
                method = yjson_method if implementation == "yjson" else stdx_method
                report = raw_dir / implementation / f"run-{round_id:02d}" / case
                log = log_dir / f"run-{round_id:02d}-{position:02d}-{implementation}-{case}.log"
                started = time.monotonic()
                done = subprocess.run([
                    "taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build", "--no-color",
                    "--filter", f"StreamProtocolBenchmarks.{method}*", "--report-path", str(report),
                    "--report-format", "csv-raw", "--random-seed", str(round_id),
                ], cwd=bench_dir, env=env, capture_output=True, text=True)
                elapsed = time.monotonic() - started
                log.write_text(done.stdout + done.stderr, encoding="utf-8")
                if done.returncode or not list(report.rglob("bench-*.csv")):
                    print(f"benchmark failed: round={round_id} implementation={implementation} "
                          f"case={case}; see {log}", file=sys.stderr)
                    return done.returncode or 2
                writer.writerow({"round": round_id, "position": position,
                                 "implementation": implementation, "case": case, "method": method,
                                 "operation": operation, "payload": payload, "profile": profile,
                                 "elapsed_seconds": f"{elapsed:.6f}",
                                 "report_path": report.relative_to(output),
                                 "log_path": log.relative_to(output)})
                stream.flush()
                print(f"completed round {round_id}/{args.runs}, process {position}/{len(scheduled)}: "
                      f"{implementation} {case}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
