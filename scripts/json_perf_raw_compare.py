#!/usr/bin/env python3
"""Compare paired Cangjie ``csv-raw`` benchmark reports.

Each input directory may contain any number of report trees.  A report row is
normalized to nanoseconds per operation using ``Duration / BatchSize``; rows
with a zero batch size are framework overhead samples and are ignored.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import DefaultDict, Iterable


UNIT_TO_NS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def load_reports(root: Path) -> dict[str, list[list[float]]]:
    runs: DefaultDict[str, list[list[float]]] = defaultdict(list)
    for path in sorted(root.rglob("bench-*.csv")):
        samples: DefaultDict[str, list[float]] = defaultdict(list)
        with path.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                batch_size = int(row["BatchSize"])
                if batch_size <= 0 or row.get("Measurement") != "Duration":
                    continue
                scale = UNIT_TO_NS.get(row["Unit"])
                if scale is None:
                    raise ValueError(f"unsupported duration unit {row['Unit']!r} in {path}")
                samples[row["Case"]].append(float(row["Duration"]) * scale / batch_size)
        for case, values in samples.items():
            if values:
                runs[case].append(values)
    if not runs:
        raise ValueError(f"no csv-raw benchmark rows found below {root}")
    return dict(runs)


def summarize(runs: list[list[float]]) -> dict[str, object]:
    samples = [value for run in runs for value in run]
    run_medians = [statistics.median(run) for run in runs]
    mean = statistics.fmean(samples)
    deviation = statistics.pstdev(samples)
    return {
        "runs": len(runs),
        "samples": len(samples),
        "median_ns": statistics.median(run_medians),
        "p95_ns": percentile(samples, 0.95),
        "min_ns": min(samples),
        "max_ns": max(samples),
        "mean_ns": mean,
        "cv_percent": 0.0 if mean == 0.0 else deviation / mean * 100.0,
        "run_medians_ns": run_medians,
    }


def compare(baseline_root: Path, candidate_root: Path) -> list[dict[str, object]]:
    baseline = load_reports(baseline_root)
    candidate = load_reports(candidate_root)
    cases = sorted(set(baseline) & set(candidate))
    if not cases:
        raise ValueError("baseline and candidate reports have no cases in common")
    rows: list[dict[str, object]] = []
    for case in cases:
        before = summarize(baseline[case])
        after = summarize(candidate[case])
        baseline_median = float(before["median_ns"])
        candidate_median = float(after["median_ns"])
        before_runs = before["run_medians_ns"]
        after_runs = after["run_medians_ns"]
        assert isinstance(before_runs, list) and isinstance(after_runs, list)
        paired_improvements = [
            (left - right) / left * 100.0
            for left, right in zip(before_runs, after_runs)
        ]
        rows.append({
            "case": case,
            "baseline": before,
            "candidate": after,
            "median_improvement_percent": (baseline_median - candidate_median) / baseline_median * 100.0,
            "paired_improvement_median_percent": statistics.median(paired_improvements),
            "paired_improvements_percent": paired_improvements,
        })
    return rows


def render_markdown(rows: Iterable[dict[str, object]]) -> str:
    lines = [
        "| Case | Runs B/C | Baseline median | Candidate median | Paired improvement | Candidate p95 | Candidate CV |",
        "|:--|--:|--:|--:|--:|--:|--:|",
    ]
    for row in rows:
        before = row["baseline"]
        after = row["candidate"]
        assert isinstance(before, dict) and isinstance(after, dict)
        lines.append(
            "| {case} | {br}/{cr} | {bm:.3f} us | {cm:.3f} us | {delta:+.2f}% | {p95:.3f} us | {cv:.2f}% |".format(
                case=row["case"],
                br=before["runs"],
                cr=after["runs"],
                bm=float(before["median_ns"]) / 1_000.0,
                cm=float(after["median_ns"]) / 1_000.0,
                delta=float(row["paired_improvement_median_percent"]),
                p95=float(after["p95_ns"]) / 1_000.0,
                cv=float(after["cv_percent"]),
            )
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--json", type=Path, help="also write machine-readable results")
    args = parser.parse_args()
    rows = compare(args.baseline, args.candidate)
    print(render_markdown(rows))
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
