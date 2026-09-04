#!/usr/bin/env python3
"""Run the Pure/Native single-engine acceleration gate in independent processes."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BENCH_DIR = ROOT / "packages" / "native_accel_benchmarks"
CASES = (
    "writeNumericArray",
    "writeNumericBytes",
    "readNumericArray",
    "readNumericDocument",
    "writeEscapedStrings",
    "writeEscapedBytes",
    "writePlainStrings",
)
ADVERTISED = frozenset(("writeNumericBytes", "readNumericDocument"))
CHECKSUM_RE = re.compile(r"^CHECKSUM\s+(\S+)\s+([0-9a-f]{16})$", re.MULTILINE)
RSS_RE = re.compile(r"Maximum resident set size \(kbytes\):\s*(\d+)")


def find_time_binary() -> str:
    path = shutil.which("time", path="/usr/bin:/bin")
    if path:
        return path
    raise SystemExit(
        "GNU time (/usr/bin/time) is required for RSS capture; install the 'time' package"
    )


def run_text(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return (result.stdout + result.stderr).strip()


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for current, dirs, files in os.walk(root):
        dirs[:] = [name for name in dirs if name not in {"target", ".git", "build-script-cache"}]
        for filename in sorted(files):
            path = Path(current) / filename
            if path.suffix not in {".cj", ".c", ".h", ".py", ".toml"}:
                continue
            digest.update(path.relative_to(root).as_posix().encode("utf-8"))
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def raw_median(report: Path) -> float:
    samples: list[float] = []
    with report.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if row.get("Measurement") != "Duration":
                continue
            batch_size = float(row["BatchSize"])
            if batch_size <= 0:
                continue
            samples.append(float(row["Duration"]) / batch_size)
    if not samples:
        raise ValueError(f"no duration samples in {report}")
    return statistics.median(samples)


def cv(values: list[float]) -> float:
    if len(values) < 2 or statistics.mean(values) == 0:
        return 0.0
    return statistics.stdev(values) / statistics.mean(values) * 100.0


def parse_checksums(log: str) -> dict[str, str]:
    """Parse `CHECKSUM <case> <16-hex>` lines from a benchmark stdout log."""
    found: dict[str, str] = {}
    for match in CHECKSUM_RE.finditer(log):
        case, digest = match.group(1), match.group(2)
        previous = found.get(case)
        if previous is not None and previous != digest:
            raise ValueError(
                f"conflicting CHECKSUM lines for {case}: {previous} vs {digest}"
            )
        found[case] = digest
    return found


def parse_max_rss(log: str) -> int | None:
    match = RSS_RE.search(log)
    return int(match.group(1)) if match else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bench-dir", type=Path, default=DEFAULT_BENCH_DIR)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--cjpm", default="cjpm")
    parser.add_argument("--skip-build", action="store_true")
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
    time_binary = find_time_binary()
    tested_source_digest = source_digest(ROOT)
    build_stamp = bench_dir / "target" / "yjson-native-accel-source-sha256"
    if args.skip_build:
        stamped = build_stamp.read_text(encoding="utf-8").strip() if build_stamp.exists() else ""
        if stamped != tested_source_digest:
            print("--skip-build requires a benchmark binary built from the current source", file=sys.stderr)
            return 2
    metadata = {
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(), "platform": platform.platform(),
        "cpu": args.cpu, "heap": args.heap, "runs": args.runs,
        "cases": list(CASES),
        "schedule": "case rotation; Pure/Native order alternates by round",
        "time_binary": time_binary,
        "formal_qualification": args.runs == 11,
        "source_sha256": tested_source_digest,
        "build_reused": args.skip_build,
        "cjc_version": run_text(["cjc", "-v"], bench_dir, env),
        "cjpm_version": run_text([args.cjpm, "--version"], bench_dir, env),
        "affinity_probe": run_text(["taskset", "-c", str(args.cpu), "sh", "-c",
            "grep Cpus_allowed_list /proc/self/status"], bench_dir, env),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    if not args.skip_build:
        build_env = env.copy(); build_env["YJSON_ACCEL_MODE"] = "pure"
        build = subprocess.run([args.cjpm, "bench", "--no-run", "--no-color"],
            cwd=bench_dir, env=build_env, capture_output=True, text=True)
        (log_dir / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        if build.returncode != 0:
            print(f"benchmark build failed; see {log_dir / 'build.log'}", file=sys.stderr)
            return build.returncode
        build_stamp.parent.mkdir(parents=True, exist_ok=True)
        build_stamp.write_text(tested_source_digest + "\n", encoding="utf-8")

    values: dict[tuple[str, str], list[float]] = {(case, mode): [] for case in CASES for mode in ("pure", "native")}
    rss_kb: dict[tuple[str, str], list[int]] = {(case, mode): [] for case in CASES for mode in ("pure", "native")}
    checksums: dict[tuple[str, str], dict[str, str]] = {}
    manifest_path = output / "manifest.csv"
    with manifest_path.open("w", newline="", encoding="utf-8") as manifest:
        writer = csv.writer(manifest)
        writer.writerow(("round", "case", "mode", "median_ns", "max_rss_kb",
            "report_sha256", "checksum", "report_path", "log_path"))
        for round_id in range(1, args.runs + 1):
            offset = (round_id - 1) % len(CASES)
            cases = CASES[offset:] + CASES[:offset]
            if round_id % 2 == 0:
                cases = tuple(reversed(cases))
            modes = ("pure", "native") if round_id % 2 == 1 else ("native", "pure")
            for case in cases:
                for mode in modes:
                    report_path = raw_dir / f"run-{round_id:02d}" / f"{case}-{mode}"
                    log_path = log_dir / f"run-{round_id:02d}-{case}-{mode}.log"
                    rss_file = report_path / "time-rss.txt"
                    run_env = env.copy(); run_env["YJSON_ACCEL_MODE"] = mode
                    command = ["taskset", "-c", str(args.cpu), args.cjpm, "bench", "--skip-build",
                        "--no-color", "--filter", f"NativeAccelerationBenchmarks.{case}*",
                        "--report-path", str(report_path), "--report-format", "csv-raw",
                        "--random-seed", str(round_id)]
                    completed = subprocess.run([time_binary, "-v", "-o", str(rss_file), *command],
                        cwd=bench_dir, env=run_env, capture_output=True, text=True)
                    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
                    if completed.returncode != 0:
                        print(f"benchmark failed: round={round_id} case={case} mode={mode}; see {log_path}", file=sys.stderr)
                        return completed.returncode
                    reports = list(report_path.rglob("bench-*.csv"))
                    if len(reports) != 1:
                        print(f"expected one benchmark report below {report_path}", file=sys.stderr)
                        return 2
                    median = raw_median(reports[0])
                    values[(case, mode)].append(median)
                    run_rss = parse_max_rss(rss_file.read_text(encoding="utf-8", errors="replace"))
                    if run_rss is not None:
                        rss_kb[(case, mode)].append(run_rss)
                    run_checksums = parse_checksums(completed.stdout + completed.stderr)
                    missing = set(CASES) - set(run_checksums)
                    if missing:
                        print(
                            f"benchmark emitted no CHECKSUM line for: {', '.join(sorted(missing))}; "
                            f"see {log_path}",
                            file=sys.stderr,
                        )
                        return 2
                    checksums[(case, mode)] = run_checksums
                    writer.writerow((round_id, case, mode, f"{median:.6f}",
                        run_rss if run_rss is not None else "", file_digest(reports[0]),
                        run_checksums[case], report_path.relative_to(output),
                        log_path.relative_to(output)))
                    manifest.flush()
                    print(f"completed round {round_id}/{args.runs}: {case} {mode}", flush=True)

    rows = []
    failed = False
    for case in CASES:
        pure = values[(case, "pure")]; native = values[(case, "native")]
        pure_median = statistics.median(pure); native_median = statistics.median(native)
        ratio = native_median / pure_median
        wins = sum(1 for p, n in zip(pure, native) if n < p)
        pure_cv = cv(pure); native_cv = cv(native)
        stable = pure_cv <= 5.0 and native_cv <= 5.0
        pure_rss = rss_kb[(case, "pure")]; native_rss = rss_kb[(case, "native")]
        rss_ok = len(pure_rss) == args.runs and len(native_rss) == args.runs
        pure_checksum = checksums[(case, "pure")][case]
        native_checksum = checksums[(case, "native")][case]
        checksum_ok = pure_checksum == native_checksum
        if case in ADVERTISED:
            passed = stable and rss_ok and checksum_ok and ratio <= 0.95 and wins >= math.ceil(args.runs / 2)
        else:
            passed = stable and rss_ok and checksum_ok and ratio <= 1.05
        failed = failed or not passed
        rows.append((case, pure_median, native_median, ratio, wins, pure_cv, native_cv,
                     stable, rss_ok, checksum_ok, pure_checksum, passed))
    qualification = args.runs == 11 and not failed
    lines = ["# yjson Native acceleration gate", "",
        f"Qualification: {'formal 11-round gate' if qualification else 'NOT qualified'}. "
        f"Formal gate requires exactly 11 rounds, stable CV <= 5% on both sides, "
        f"RSS captured for every run, and matching pure/native content checksums.", "",
        "| Case | Pure median ns | Native median ns | N/P | Native wins | CV P/N | Stable | RSS | Checksum | Gate |",
        "|---|---:|---:|---:|---:|---:|---|---|---|---|"]
    for case, pure_median, native_median, ratio, wins, pure_cv, native_cv, stable, rss_ok, checksum_ok, checksum, passed in rows:
        lines.append(f"| {case} | {pure_median:.2f} | {native_median:.2f} | {ratio:.3f} | {wins}/{args.runs} | {pure_cv:.2f}%/{native_cv:.2f}% | {'yes' if stable else 'no'} | {'yes' if rss_ok else 'no'} | {checksum} | {'pass' if passed else 'fail'} |")
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 1 if failed or not qualification else 0


if __name__ == "__main__":
    raise SystemExit(main())
