#!/usr/bin/env python3
"""Summarize paired yjson/cjfast_json csv-raw benchmark reports."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


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


def load_report(path: Path) -> list[float]:
    values: list[float] = []
    for report in sorted(path.rglob("bench-*.csv")):
        with report.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                batch_size = int(row["BatchSize"])
                if batch_size <= 0 or row.get("Measurement") != "Duration":
                    continue
                scale = UNIT_TO_NS.get(row["Unit"])
                if scale is None:
                    raise ValueError(f"unsupported duration unit {row['Unit']!r} in {report}")
                values.append(float(row["Duration"]) * scale / batch_size)
    if not values:
        raise ValueError(f"no duration samples found below {path}")
    return values


def summarize(run_samples: dict[int, list[float]]) -> dict[str, object]:
    run_medians = [statistics.median(run_samples[key]) for key in sorted(run_samples)]
    raw_samples = [value for key in sorted(run_samples) for value in run_samples[key]]
    median = statistics.median(run_medians)
    mean = statistics.fmean(run_medians)
    mad = statistics.median(abs(value - median) for value in run_medians)
    return {
        "runs": len(run_medians),
        "raw_samples": len(raw_samples),
        "median_ns": median,
        "run_p95_ns": percentile(run_medians, 0.95),
        "run_cv_percent": 0.0 if mean == 0.0 else statistics.pstdev(run_medians) / mean * 100.0,
        "run_mad_ns": mad,
        "run_mad_percent": 0.0 if median == 0.0 else mad / median * 100.0,
        "raw_p95_ns": percentile(raw_samples, 0.95),
        "run_medians_ns": run_medians,
    }


def analyze(root: Path, min_runs: int) -> list[dict[str, object]]:
    samples: dict[tuple[str, str], dict[int, list[float]]] = defaultdict(dict)
    metadata: dict[str, dict[str, str]] = {}
    with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            workload = row["workload"]
            library = row["library"]
            round_id = int(row["round"])
            samples[(workload, library)][round_id] = load_report(root / row["report_path"])
            metadata[workload] = {
                "scenario": row["scenario"],
                "operation": row["operation"],
                "payload": row["payload"],
                "input_kind": row["input_kind"],
            }

    workloads = sorted({workload for workload, _ in samples})
    rows: list[dict[str, object]] = []
    for workload in workloads:
        yjson_runs = samples.get((workload, "yjson"), {})
        cjfast_runs = samples.get((workload, "cjfast_json"), {})
        common_rounds = sorted(set(yjson_runs) & set(cjfast_runs))
        if len(common_rounds) < min_runs:
            raise ValueError(
                f"{workload} has {len(common_rounds)} complete pairs, fewer than {min_runs}"
            )
        yjson_summary = summarize({key: yjson_runs[key] for key in common_rounds})
        cjfast_summary = summarize({key: cjfast_runs[key] for key in common_rounds})
        paired_ratios = []
        paired_deltas = []
        for round_id in common_rounds:
            yjson_value = statistics.median(yjson_runs[round_id])
            cjfast_value = statistics.median(cjfast_runs[round_id])
            paired_ratios.append(cjfast_value / yjson_value)
            paired_deltas.append((cjfast_value - yjson_value) / yjson_value * 100.0)
        delta_median = statistics.median(paired_deltas)
        rows.append({
            "workload": workload,
            **metadata[workload],
            "pairs": len(common_rounds),
            "yjson": yjson_summary,
            "cjfast_json": cjfast_summary,
            "cjfast_over_yjson_ratio_median": statistics.median(paired_ratios),
            "cjfast_over_yjson_ratio_p95": percentile(paired_ratios, 0.95),
            "paired_delta_median_percent": delta_median,
            "paired_delta_p95_percent": percentile(paired_deltas, 0.95),
            "paired_delta_mad_points": statistics.median(
                abs(delta - delta_median) for delta in paired_deltas
            ),
            "yjson_faster_pairs": sum(delta > 0.0 for delta in paired_deltas),
            "paired_deltas_percent": paired_deltas,
        })
    return rows


def render_markdown(rows: list[dict[str, object]]) -> str:
    stable = [
        row for row in rows
        if float(row["yjson"]["run_cv_percent"]) <= 3.0
        and float(row["cjfast_json"]["run_cv_percent"]) <= 3.0
    ]
    yjson_wins = sum(float(row["paired_delta_median_percent"]) > 0.0 for row in stable)
    lines = [
        "# yjson vs cjfast_json formal benchmark",
        "",
        "Positive paired deltas mean cjfast_json is slower and yjson is faster.",
        "Only workloads with process-median CV <= 3% on both sides are counted as stable.",
        "",
        f"- Matched workloads: {len(rows)}",
        f"- Stable workloads: {len(stable)}",
        f"- yjson faster among stable workloads: {yjson_wins}/{len(stable)}",
        "",
        "| Scenario | Operation | Payload | Input | Runs | yjson median | cjfast median | cjfast/yjson | Paired delta | yjson faster pairs | CV Y/C | p95 Y/C | Delta MAD | Status |",
        "|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|",
    ]
    for row in rows:
        yjson = row["yjson"]
        cjfast = row["cjfast_json"]
        assert isinstance(yjson, dict) and isinstance(cjfast, dict)
        stable_row = (
            float(yjson["run_cv_percent"]) <= 3.0
            and float(cjfast["run_cv_percent"]) <= 3.0
        )
        lines.append(
            f"| {row['scenario']} | {row['operation']} | {row['payload']} | {row['input_kind']} | "
            f"{row['pairs']} | {float(yjson['median_ns']):.3f} ns | "
            f"{float(cjfast['median_ns']):.3f} ns | "
            f"{float(row['cjfast_over_yjson_ratio_median']):.3f}x | "
            f"{float(row['paired_delta_median_percent']):+.2f}% | "
            f"{row['yjson_faster_pairs']}/{row['pairs']} | "
            f"{float(yjson['run_cv_percent']):.2f}% / {float(cjfast['run_cv_percent']):.2f}% | "
            f"{float(yjson['run_p95_ns']):.3f} / {float(cjfast['run_p95_ns']):.3f} ns | "
            f"{float(row['paired_delta_mad_points']):.2f} pp | "
            f"{'stable' if stable_row else 'noisy'} |"
        )
    return "\n".join(lines) + "\n"


def normalize_json_floats(value: object) -> object:
    if isinstance(value, float):
        return round(value, 12)
    if isinstance(value, list):
        return [normalize_json_floats(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_json_floats(item) for key, item in value.items()}
    return value


def write_csv(rows: list[dict[str, object]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow([
            "scenario", "operation", "payload", "input_kind", "pairs",
            "yjson_median_ns", "cjfast_json_median_ns", "cjfast_over_yjson_ratio_median",
            "paired_delta_median_percent", "paired_delta_p95_percent", "paired_delta_mad_points",
            "yjson_faster_pairs", "yjson_cv_percent", "cjfast_json_cv_percent",
            "yjson_p95_ns", "cjfast_json_p95_ns", "status",
        ])
        for row in rows:
            yjson = row["yjson"]
            cjfast = row["cjfast_json"]
            assert isinstance(yjson, dict) and isinstance(cjfast, dict)
            stable = (
                float(yjson["run_cv_percent"]) <= 3.0
                and float(cjfast["run_cv_percent"]) <= 3.0
            )
            writer.writerow([
                row["scenario"], row["operation"], row["payload"], row["input_kind"], row["pairs"],
                f"{float(yjson['median_ns']):.3f}", f"{float(cjfast['median_ns']):.3f}",
                f"{float(row['cjfast_over_yjson_ratio_median']):.6f}",
                f"{float(row['paired_delta_median_percent']):.6f}",
                f"{float(row['paired_delta_p95_percent']):.6f}",
                f"{float(row['paired_delta_mad_points']):.6f}", row["yjson_faster_pairs"],
                f"{float(yjson['run_cv_percent']):.6f}",
                f"{float(cjfast['run_cv_percent']):.6f}",
                f"{float(yjson['run_p95_ns']):.3f}", f"{float(cjfast['run_p95_ns']):.3f}",
                "stable" if stable else "noisy",
            ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    rows = analyze(args.root, args.min_runs)
    markdown = render_markdown(rows)
    print(markdown, end="")
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(normalize_json_floats(rows), indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        write_csv(rows, args.csv)
    if args.markdown is not None:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
