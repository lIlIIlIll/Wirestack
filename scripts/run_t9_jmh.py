#!/usr/bin/env python3
"""Run the JMH-version Jackson baseline and convert results to the T9 contract.

Downloads nothing itself: --jars-dir holds the Jackson jars, --jmh-jars-dir
holds jmh-core/jmh-generator-annprocess/jopt-simple/commons-math3.  Compiles
JacksonBenchJMH.java (JMH annotation processor runs via the classpath), runs
org.openjdk.jmh.Main over the t9_* benchmarks, parses the JSON report, and
writes metadata/manifest/summary/COMPLETE plus a quantified deviation note
against the hand-timed JacksonBench results (--legacy-dir).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import platform
import shutil
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from run_t9_throughput import CASES, LEGACY_CASES, B_CASES


def capture(command: list[str], cwd: Path) -> str:
    return subprocess.run(
        command, cwd=cwd, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--jars-dir", type=Path, required=True)
    parser.add_argument("--jmh-jars-dir", type=Path, required=True)
    parser.add_argument("--legacy-dir", type=Path, required=True,
                        help="hand-timed JacksonBench results dir for the deviation note")
    parser.add_argument("--label", default="jackson-jmh")
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--reuse-report", action="store_true",
                        help="parse the existing jmh.json instead of running JMH")
    args = parser.parse_args()

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    build = output / "raw" / "run-01"
    logs = output / "logs"
    build.mkdir(parents=True)
    logs.mkdir(parents=True)

    source = args.source.resolve()
    shutil.copy2(source, build / "JacksonBenchJMH.java")

    jackson_jars = sorted((args.jars_dir.resolve()).glob("*.jar"))
    jmh_names = ("jmh-core", "jmh-generator-annprocess", "jopt-simple", "commons-math3")
    jmh_jars = []
    for name in jmh_names:
        matches = sorted((args.jmh_jars_dir.resolve()).glob(f"{name}*.jar"))
        if not matches:
            raise RuntimeError(f"missing JMH jar for {name} in {args.jmh_jars_dir}")
        jmh_jars.append(matches[0])
    classpath = ":".join(str(p) for p in [*jackson_jars, *jmh_jars])

    expected_cases = list(CASES) + list(B_CASES)
    report_path = output / "jmh.json"
    if not getattr(args, "reuse_report", False) or not report_path.is_file():
        compile_log = capture(
            ["javac", "-cp", classpath, "-d", ".", "JacksonBenchJMH.java"], build
        )
        (logs / "javac.log").write_text(compile_log + "\n", encoding="utf-8")
        command = [
            "taskset", "-c", str(args.cpu), "java", "-cp", f"{build}:{classpath}",
            "org.openjdk.jmh.Main", "t9_",
            "-f", "1", "-wi", "2", "-w", "1s", "-i", "5", "-r", "1s",
            "-rf", "json", "-rff", str(report_path),
        ]
        raw_log = capture(command, build)
        (logs / "run-01.log").write_text(raw_log + "\n", encoding="utf-8")

    report = json.loads(report_path.read_text(encoding="utf-8"))
    values: dict[str, float] = {}
    for entry in report:
        name = entry["benchmark"].rsplit(".", 1)[-1]
        score = float(entry["primaryMetric"]["score"])
        unit = entry["primaryMetric"]["scoreUnit"]
        if unit != "us/op":
            raise RuntimeError(f"unexpected scoreUnit {unit!r} for {name}")
        values[name] = score
    # JMH reports benchmarks in name-sorted order; compare as sets, write in contract order.
    # Extras (e.g. t9_b_2/b_3 when the Cangjie cells exclude them) are kept in the
    # summary — they are legitimate Jackson-only measurements.
    missing = sorted(set(expected_cases) - set(values))
    if missing:
        raise RuntimeError(f"JMH case contract differs; missing={missing}")
    all_cases = expected_cases + sorted(set(values) - set(expected_cases))

    metadata = {
        "schema_version": 1,
        "label": args.label,
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "suite": "T9ThroughputBench+BytesBench",
        "cases": all_cases,
        "runs": 1,
        "cpu": args.cpu,
        "java": capture(["java", "-version"], build),
        "javac": capture(["javac", "-version"], build),
        "jackson_version": "2.17.2",
        "harness": "JMH 1.37 (AverageTime, us/op, 1 fork, 2x1s warmup, 5x1s measurement)",
        "source_sha256": hashlib_of(source),
        "process_model": "one JVM fork per benchmark (JMH default)",
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=(
            "round", "position", "case", "median_ns", "sample_count",
            "within_run_cv_pct", "elapsed_seconds", "report", "log",
        ))
        writer.writeheader()
        for position, case in enumerate(all_cases, 1):
            writer.writerow({
                "round": 1, "position": position, "case": case,
                "median_ns": f"{values[case] * 1000.0:.6f}",
                "sample_count": 5, "within_run_cv_pct": "",
                "elapsed_seconds": "", "report": "raw/run-01", "log": "logs/run-01.log",
            })

    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=(
            "case", "runs", "median_us", "min_us", "max_us",
            "across_run_cv_pct", "max_within_run_cv_pct",
        ))
        writer.writeheader()
        for case in all_cases:
            value = values[case]
            writer.writerow({
                "case": case, "runs": 1, "median_us": f"{value:.6f}",
                "min_us": f"{value:.6f}", "max_us": f"{value:.6f}",
                "across_run_cv_pct": "0.000", "max_within_run_cv_pct": "",
            })
    (output / "COMPLETE").write_text(
        datetime.now(timezone.utc).isoformat() + "\n", encoding="utf-8"
    )

    # ---- quantified deviation note vs the hand-timed baseline ----
    legacy_summary = args.legacy_dir.resolve() / "summary.csv"
    legacy = {}
    with legacy_summary.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            legacy[row["case"]] = float(row["median_us"])
    lines = [
        "# Jackson JMH vs hand-timed deviation",
        "",
        "JMH (1 fork, 2x1s warmup, 5x1s measurement, AverageTime us/op) vs the",
        "hand-written loop timer (1s warmup, 5s in 200 batches, median of batch",
        "medians). Same fixtures, same Jackson 2.17.2, same CPU pin.",
        "",
        "| case | hand-timed us | JMH us | JMH/hand |",
        "|---|---|---|---|",
    ]
    ratios = []
    for case in all_cases:
        hand = legacy.get(case)
        jmh_us = values[case]
        ratio = (jmh_us / hand) if hand else None
        if ratio is not None:
            ratios.append(ratio)
        lines.append(f"| {case} | {hand:.3f} | {jmh_us:.3f} | {ratio:.3f} |" if hand
                     else f"| {case} | ABSENT | {jmh_us:.3f} | ABSENT |")
    geomean = math.exp(sum(math.log(r) for r in ratios) / len(ratios)) if ratios else float("nan")
    lines += [
        "",
        f"Geomean of JMH/hand ratios: **{geomean:.3f}** "
        "(>1.0 means the hand-timed numbers were faster-looking, i.e. optimistic).",
        "",
    ]
    (output / "jmh-deviation.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {output} (deviation geomean {geomean:.3f})")
    return 0


def hashlib_of(path: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
