#!/usr/bin/env python3
"""Run the json4cj repository's Jackson T9 harness and retain evidence."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import platform
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from run_t9_throughput import B_CASES, CASES


RESULT = re.compile(r"^(t9_\S+)\s+([0-9.]+) us\s+", re.MULTILINE)


def capture(command: list[str], cwd: Path) -> str:
    return subprocess.run(
        command, cwd=cwd, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--jars-dir", type=Path, required=True)
    parser.add_argument("--label", default="jackson-server")
    parser.add_argument("--version", required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument(
        "--include-bytes", action="store_true",
        help="also run the BytesBench three-library track (t9_b_*)",
    )
    args = parser.parse_args()

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    build = output / "raw" / "run-01"
    logs = output / "logs"
    build.mkdir(parents=True)
    logs.mkdir(parents=True)

    source = args.source.resolve()
    shutil.copy2(source, build / "JacksonBench.java")
    jars = [
        args.jars_dir.resolve() / "jackson-core.jar",
        args.jars_dir.resolve() / "jackson-databind.jar",
        args.jars_dir.resolve() / "jackson-annotations.jar",
    ]
    missing = [str(path) for path in jars if not path.is_file()]
    if missing:
        raise RuntimeError(f"missing Jackson jars: {missing}")
    classpath = ":".join(str(path) for path in jars)
    compile_log = capture(
        ["javac", "-cp", classpath, "JacksonBench.java"], build
    )
    (logs / "javac.log").write_text(compile_log + "\n", encoding="utf-8")
    expected_cases = list(CASES) + (list(B_CASES) if args.include_bytes else [])
    command = [
        "taskset", "-c", str(args.cpu), "java", "-cp", f"{build}:{classpath}",
        "JacksonBench", *expected_cases,
    ]
    raw_log = capture(command, build)
    (logs / "run-01.log").write_text(raw_log + "\n", encoding="utf-8")
    values = {name: float(value) for name, value in RESULT.findall(raw_log)}
    if list(values) != expected_cases:
        raise RuntimeError(
            f"Jackson case contract differs: expected {expected_cases!r}, got {list(values)!r}"
        )

    metadata = {
        "schema_version": 1,
        "label": args.label,
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "suite": "T9ThroughputBench" if not args.include_bytes else "T9ThroughputBench+BytesBench",
        "cases": expected_cases,
        "runs": 1,
        "cpu": args.cpu,
        "java": capture(["java", "-version"], build),
        "javac": capture(["javac", "-version"], build),
        "jackson_version": args.version,
        "source_sha256": sha256(source),
        "jar_sha256": {path.name: sha256(path) for path in jars},
        "process_model": "one JVM; selected cases execute sequentially",
        "warmup": "1 second per case",
        "measurement": "5 seconds in 200 batches per case",
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
        for position, case in enumerate(expected_cases, 1):
            writer.writerow({
                "round": 1, "position": position, "case": case,
                "median_ns": f"{values[case] * 1000.0:.6f}",
                "sample_count": 200, "within_run_cv_pct": "",
                "elapsed_seconds": "", "report": "raw/run-01", "log": "logs/run-01.log",
            })

    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=(
            "case", "runs", "median_us", "min_us", "max_us",
            "across_run_cv_pct", "max_within_run_cv_pct",
        ))
        writer.writeheader()
        for case in expected_cases:
            value = values[case]
            writer.writerow({
                "case": case, "runs": 1, "median_us": f"{value:.6f}",
                "min_us": f"{value:.6f}", "max_us": f"{value:.6f}",
                "across_run_cv_pct": "0.000", "max_within_run_cv_pct": "",
            })
    (output / "COMPLETE").write_text(
        datetime.now(timezone.utc).isoformat() + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
