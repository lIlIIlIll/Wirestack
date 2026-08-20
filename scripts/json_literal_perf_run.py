#!/usr/bin/env python3
"""Run JSON literal benchmarks as balanced, CPU-pinned independent processes."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BENCH_DIR = ROOT / "packages" / "benchmarks"
CASES = (
    "jsonMacroStatic",
    "jsonMacroDynamicKey",
    "generatedCodec",
    "manualDirectWriter",
    "jsonValueMacroBuildOnly",
    "manualConcreteAstBuildOnly",
    "manualFluentAstBuildOnly",
    "jsonValueMacroAndStringify",
    "manualConcreteAstAndStringify",
)


def run_text(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    completed = subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return (completed.stdout + completed.stderr).strip()


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or "target" in path.parts or ".git" in path.parts:
            continue
        if path.suffix not in {".cj", ".py", ".toml"}:
            continue
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def balanced_order(round_id: int) -> tuple[str, ...]:
    offset = (round_id - 1) % len(CASES)
    rotated = CASES[offset:] + CASES[:offset]
    return rotated if round_id % 2 == 1 else tuple(reversed(rotated))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bench-dir", type=Path, default=DEFAULT_BENCH_DIR)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--cjpm", default="cjpm")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--source-label", default="workspace")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"output directory is not empty: {args.output}")

    bench_dir = args.bench_dir.resolve()
    output = args.output.resolve()
    raw_dir = output / "raw"
    log_dir = output / "logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
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
        "cases": list(CASES),
        "schedule": "balanced rotation; even rounds reversed",
        "source_label": args.source_label,
        "source_sha256": source_digest(ROOT),
        "cjc_version": run_text(["cjc", "-v"], bench_dir, env),
        "cjpm_version": run_text([args.cjpm, "--version"], bench_dir, env),
        "lscpu": run_text(["lscpu"], bench_dir, env),
        "affinity_probe": run_text(
            ["taskset", "-c", str(args.cpu), "sh", "-c", "grep Cpus_allowed_list /proc/self/status"],
            bench_dir,
            env,
        ),
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    if not args.skip_build:
        build = subprocess.run(
            [args.cjpm, "bench", "--no-run", "--no-color"],
            cwd=bench_dir,
            env=env,
            capture_output=True,
            text=True,
        )
        (log_dir / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        if build.returncode != 0:
            print(f"benchmark build failed; see {log_dir / 'build.log'}", file=sys.stderr)
            return build.returncode

    manifest_path = output / "manifest.csv"
    with manifest_path.open("w", newline="", encoding="utf-8") as manifest:
        writer = csv.DictWriter(
            manifest,
            fieldnames=("round", "position", "case", "elapsed_seconds", "report_path", "log_path"),
        )
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            for position, case in enumerate(balanced_order(round_id), start=1):
                report_path = raw_dir / f"run-{round_id:02d}" / f"case-{position:02d}-{case}"
                log_path = log_dir / f"run-{round_id:02d}-case-{position:02d}-{case}.log"
                command = [
                    "taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build", "--no-color",
                    "--filter", f"JsonLiteralPerformance.{case}*",
                    "--report-path", str(report_path), "--report-format", "csv-raw",
                    "--random-seed", str(round_id),
                ]
                started = time.monotonic()
                completed = subprocess.run(
                    command, cwd=bench_dir, env=env, capture_output=True, text=True
                )
                elapsed = time.monotonic() - started
                log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
                if completed.returncode != 0:
                    print(f"benchmark failed: round={round_id} case={case}; see {log_path}", file=sys.stderr)
                    return completed.returncode
                if not list(report_path.rglob("bench-*.csv")):
                    print(f"benchmark produced no raw CSV: round={round_id} case={case}; see {log_path}", file=sys.stderr)
                    return 2
                writer.writerow({
                    "round": round_id,
                    "position": position,
                    "case": case,
                    "elapsed_seconds": f"{elapsed:.6f}",
                    "report_path": report_path.relative_to(output),
                    "log_path": log_path.relative_to(output),
                })
                manifest.flush()
                print(f"completed round {round_id}/{args.runs}, case {position}/{len(CASES)}: {case}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
