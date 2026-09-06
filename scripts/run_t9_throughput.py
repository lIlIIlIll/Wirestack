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


LEGACY_CASES = (
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

COVERAGE_CASES = (
    "t9_5_1_optionSerialize",
    "t9_5_2_optionDeserialize",
    "t9_5_3_optionRoundTrip",
    "t9_5_4_emptyContainersSerialize",
    "t9_5_5_emptyContainersDeserialize",
    "t9_5_6_int64ExtremesSerialize",
    "t9_5_7_int64ExtremesDeserialize",
    "t9_5_8_unknownFieldDeserialize",
)

CASES = LEGACY_CASES + COVERAGE_CASES

# EXCLUDED cases (historical matrix exclusion; bench code kept):
# - t9_5_9/t9_5_10/t9_5_11/t9_5_12/t9_b_2/t9_b_3 were excluded after a
#   scratch run recorded malformed output for Array<E> with composite E
#   (`{"field":,"field":[...]}`) and a follow-on parser failure. The current
#   clean-HEAD/worktree probes do not reproduce it, so this remains a pinned
#   source/SDK follow-up rather than a confirmed current regression.
# - t9_5_13 (pretty-printed input): json4cj @Codable[fixedSchema] streaming
#   decode throws "Fixed JSON schema field name mismatch" on indented JSON
#   (same-order compact input passes, so whitespace between tokens is the
#   trigger). Re-add after a cross-library fixture decision.
# Bytes/stream track: three-library suite (cjjson has no bytes API).
B_CASES = (
    "t9_b_1_bytesParsePrimitive",
)

CASES_BY_SUITE = {"T9ThroughputBench": CASES, "BytesBench": B_CASES}


def capture(command: list[str], cwd: Path) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout.strip()


def ordered_cases(round_no: int, cases: tuple[str, ...]) -> list[str]:
    offset = (round_no - 1) % len(cases)
    result = list(cases[offset:] + cases[:offset])
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
    parser.add_argument("--suite", default="T9ThroughputBench",
                        help="T9ThroughputBench (A track) or BytesBench (three-library B track)")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--cfg", action="store_true")
    parser.add_argument("--skip-script", action="store_true")
    parser.add_argument("--label", required=True)
    parser.add_argument("--memory", action="store_true",
                        help="wrap each case with /usr/bin/time -v and record max RSS")
    args = parser.parse_args()
    if args.suite not in CASES_BY_SUITE:
        parser.error(f"unknown suite: {args.suite}")
    cases = CASES_BY_SUITE[args.suite]

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
        "cases": list(cases),
        "memory": args.memory,
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

    samples: dict[str, list[dict[str, float | int]]] = {case: [] for case in cases}
    manifest_fields = (
        "round",
        "position",
        "case",
        "median_ns",
        "sample_count",
        "within_run_cv_pct",
        "elapsed_seconds",
        "max_rss_kb",
        "report",
        "log",
    )
    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        manifest = csv.DictWriter(stream, fieldnames=manifest_fields)
        manifest.writeheader()
        for round_no in range(1, args.runs + 1):
            for position, case in enumerate(ordered_cases(round_no, cases), 1):
                report = raw / f"run-{round_no:02d}" / case
                report.parent.mkdir(parents=True, exist_ok=True)
                report.mkdir(parents=True, exist_ok=True)
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
                rss_file = report / "time-rss.txt"
                if args.memory:
                    command = ["/usr/bin/time", "-v", "-o", str(rss_file), *command]
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
                max_rss_kb = ""
                if args.memory:
                    for line in rss_file.read_text(encoding="utf-8", errors="replace").splitlines():
                        if "Maximum resident set size" in line:
                            max_rss_kb = line.rsplit(":", 1)[-1].strip()
                            break
                row = read_one_result(report, case)
                row["max_rss_kb"] = max_rss_kb
                samples[case].append(row)
                manifest.writerow({
                    "round": round_no,
                    "position": position,
                    "case": case,
                    "median_ns": f"{row['median_ns']:.6f}",
                    "sample_count": row["sample_count"],
                    "within_run_cv_pct": f"{row['within_run_cv_pct']:.6f}",
                    "elapsed_seconds": f"{elapsed:.6f}",
                    "max_rss_kb": max_rss_kb,
                    "report": report.relative_to(output),
                    "log": log.relative_to(output),
                })
                stream.flush()
                print(
                    f"PASS {args.label} {round_no}/{args.runs} {position}/{len(cases)} "
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
            "max_rss_mb",
        )
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for case in cases:
            medians = [float(row["median_ns"]) / 1000.0 for row in samples.get(case, [])]
            if not medians:
                raise RuntimeError(
                    f"internal: no samples for case {case!r}; "
                    f"sampled={sorted(k for k in samples if samples[k])}"
                )
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
                "max_rss_mb": (
                    f"{max(float(r['max_rss_kb']) for r in samples[case] if r['max_rss_kb'] != '') / 1024.0:.1f}"
                    if all(r["max_rss_kb"] != "" for r in samples[case]) else ""
                ),
            })
    (output / "COMPLETE").write_text(
        datetime.now(timezone.utc).isoformat() + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
