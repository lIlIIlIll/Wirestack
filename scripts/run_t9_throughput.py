#!/usr/bin/env python3
"""Run the comparable T9.1-T9.4 benchmark cases and retain raw evidence."""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


CASES = (
    "t9_1_1_primitiveSerialize",
    "t9_1_2_primitiveDeserialize",
    "t9_1_3_primitiveRoundTrip",
    "t9_2_1_shortStringSerialize",
    "t9_2_2_longStringSerialize",
    "t9_2_3_escapeStringSerialize",
    "t9_2_4_unicodeStringSerialize",
    "t9_3_1_smallArraySerialize",
    "t9_3_2_largeArraySerialize",
    "t9_3_3_largeArrayDeserialize",
    "t9_3_4_smallMapSerialize",
    "t9_3_5_largeMapSerialize",
    "t9_3_6_largeMapDeserialize",
    "t9_3_7_nestedCollectionSerialize",
    "t9_3_8_nestedCollectionDeserialize",
    "t9_3_9_largeFloat64ArraySerialize",
    "t9_4_1_deepNestedSerialize",
    "t9_4_2_deepNestedDeserialize",
    "t9_4_3_wideSerialize",
    "t9_4_4_wideDeserialize",
    "t9_4_5_ultraWideSerialize",
    "t9_4_6_ultraWideDeserialize",
)


def capture(command: list[str], cwd: Path) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout.strip()


def ordered_cases(round_no: int) -> list[str]:
    offset = (round_no - 1) % len(CASES)
    result = list(CASES[offset:] + CASES[:offset])
    return result if round_no % 2 else list(reversed(result))


def read_one_result(report: Path, expected_case: str) -> dict[str, float | int]:
    files = list((report / "benchmarks").glob("bench-*.csv"))
    if len(files) != 1:
        raise RuntimeError(f"expected one raw CSV under {report}, found {len(files)}")
    with files[0].open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    actual_cases = {row.get("Case") for row in rows}
    if actual_cases != {expected_case}:
        raise RuntimeError(
            f"expected only case {expected_case!r} in {files[0]}, found {actual_cases}"
        )
    values = []
    for row in rows:
        if row.get("Measurement") != "Duration":
            continue
        batch_size = int(row["BatchSize"])
        if batch_size <= 0:
            continue
        unit = row.get("Unit")
        scale = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}.get(unit)
        if scale is None:
            raise RuntimeError(f"unsupported unit {unit!r} in {files[0]}")
        values.append(float(row["Duration"]) * scale / batch_size)
    if not values:
        raise RuntimeError(f"case {expected_case!r} has no duration samples in {files[0]}")
    mean = statistics.mean(values)
    return {
        "median_ns": statistics.median(values),
        "sample_count": len(values),
        "within_run_cv_pct": statistics.pstdev(values) / mean * 100.0 if mean else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--suite", default="T9ThroughputBench")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--cfg", action="store_true")
    parser.add_argument("--skip-script", action="store_true")
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    if args.runs <= 0:
        parser.error("--runs must be positive")

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    raw = output / "raw"
    logs = output / "logs"
    raw.mkdir(parents=True)
    logs.mkdir(parents=True)
    cwd = args.cwd.resolve()

    metadata = {
        "schema_version": 1,
        "label": args.label,
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "cwd": str(cwd),
        "suite": args.suite,
        "cases": list(CASES),
        "runs": args.runs,
        "cpu": args.cpu,
        "cfg": args.cfg,
        "skip_script": args.skip_script,
        "cj_heap_size": os.environ.get("cjHeapSize"),
        "cangjie_stdx_path": os.environ.get("CANGJIE_STDX_PATH"),
        "cjc": capture(["cjc", "-v"], cwd),
        "cjpm": capture(["cjpm", "--version"], cwd),
        "schedule": "case order rotates each round and reverses on even rounds",
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    samples: dict[str, list[dict[str, float | int]]] = {case: [] for case in CASES}
    manifest_fields = (
        "round",
        "position",
        "case",
        "median_ns",
        "sample_count",
        "within_run_cv_pct",
        "elapsed_seconds",
        "report",
        "log",
    )
    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        manifest = csv.DictWriter(stream, fieldnames=manifest_fields)
        manifest.writeheader()
        for round_no in range(1, args.runs + 1):
            for position, case in enumerate(ordered_cases(round_no), 1):
                report = raw / f"run-{round_no:02d}" / case
                report.parent.mkdir(parents=True, exist_ok=True)
                log = logs / f"run-{round_no:02d}-{case}.log"
                command = []
                if args.cpu is not None:
                    command.extend(("taskset", "-c", str(args.cpu)))
                command.extend((
                    "cjpm",
                    "bench",
                    "--skip-build",
                    "--no-color",
                    "--filter",
                    f"{args.suite}.{case}",
                    "--report-path",
                    str(report),
                    "--report-format",
                    "csv-raw",
                    "--random-seed",
                    str(round_no),
                ))
                if args.cfg:
                    command.append("--cfg")
                if args.skip_script:
                    command.append("--skip-script")
                started = time.monotonic()
                result = subprocess.run(
                    command,
                    cwd=cwd,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                elapsed = time.monotonic() - started
                log.write_text(result.stdout, encoding="utf-8")
                if result.returncode != 0:
                    raise RuntimeError(
                        f"benchmark failed: round={round_no} case={case} log={log}"
                    )
                row = read_one_result(report, case)
                samples[case].append(row)
                manifest.writerow({
                    "round": round_no,
                    "position": position,
                    "case": case,
                    "median_ns": f"{row['median_ns']:.6f}",
                    "sample_count": row["sample_count"],
                    "within_run_cv_pct": f"{row['within_run_cv_pct']:.6f}",
                    "elapsed_seconds": f"{elapsed:.6f}",
                    "report": report.relative_to(output),
                    "log": log.relative_to(output),
                })
                stream.flush()
                print(
                    f"PASS {args.label} {round_no}/{args.runs} {position}/{len(CASES)} "
                    f"{case} median_ns={row['median_ns']:.3f}",
                    flush=True,
                )

    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as stream:
        fields = (
            "case",
            "runs",
            "median_us",
            "min_us",
            "max_us",
            "across_run_cv_pct",
            "max_within_run_cv_pct",
        )
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for case in CASES:
            medians = [float(row["median_ns"]) / 1000.0 for row in samples[case]]
            within_run_cvs = [float(row["within_run_cv_pct"]) for row in samples[case]]
            mean = statistics.mean(medians)
            writer.writerow({
                "case": case,
                "runs": len(medians),
                "median_us": f"{statistics.median(medians):.6f}",
                "min_us": f"{min(medians):.6f}",
                "max_us": f"{max(medians):.6f}",
                "across_run_cv_pct": f"{statistics.pstdev(medians) / mean * 100.0 if mean else 0.0:.3f}",
                "max_within_run_cv_pct": f"{max(within_run_cvs):.3f}",
            })
    (output / "COMPLETE").write_text(
        datetime.now(timezone.utc).isoformat() + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
