#!/usr/bin/env python3
"""Summarize complete yjson/stdx.json/cjfast_json benchmark reports."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


UNIT_TO_NS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}
LIBRARIES = ("yjson", "stdx_json", "cjfast_json")
PEERS = ("stdx_json", "cjfast_json")


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


def compare(
    yjson_runs: dict[int, list[float]],
    peer_runs: dict[int, list[float]],
    common_rounds: list[int],
) -> dict[str, object]:
    ratios: list[float] = []
    deltas: list[float] = []
    for round_id in common_rounds:
        yjson_value = statistics.median(yjson_runs[round_id])
        peer_value = statistics.median(peer_runs[round_id])
        ratios.append(yjson_value / peer_value)
        deltas.append((yjson_value - peer_value) / peer_value * 100.0)
    delta_median = statistics.median(deltas)
    return {
        "yjson_over_peer_ratio_median": statistics.median(ratios),
        "yjson_over_peer_ratio_p95": percentile(ratios, 0.95),
        "paired_delta_median_percent": delta_median,
        "paired_delta_p95_percent": percentile(deltas, 0.95),
        "paired_delta_mad_points": statistics.median(
            abs(delta - delta_median) for delta in deltas
        ),
        "yjson_faster_pairs": sum(delta < 0.0 for delta in deltas),
        "paired_deltas_percent": deltas,
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
        library_runs = {
            library: samples.get((workload, library), {})
            for library in LIBRARIES
        }
        common_rounds = sorted(
            set.intersection(*(set(library_runs[library]) for library in LIBRARIES))
        )
        if len(common_rounds) < min_runs:
            raise ValueError(
                f"{workload} has {len(common_rounds)} complete three-library rounds, "
                f"fewer than {min_runs}"
            )
        summaries = {
            library: summarize({
                round_id: library_runs[library][round_id]
                for round_id in common_rounds
            })
            for library in LIBRARIES
        }
        row: dict[str, object] = {
            "workload": workload,
            **metadata[workload],
            "rounds": len(common_rounds),
            **summaries,
        }
        for peer in PEERS:
            row[peer + "_comparison"] = compare(
                library_runs["yjson"], library_runs[peer], common_rounds
            )
        rows.append(row)
    return rows


def stable(row: dict[str, object], cv_limit: float) -> bool:
    return all(
        float(row[library]["run_cv_percent"]) <= cv_limit
        for library in LIBRARIES
    )


def render_markdown(rows: list[dict[str, object]], cv_limit: float) -> str:
    stable_rows = [row for row in rows if stable(row, cv_limit)]
    lines = [
        "# yjson / stdx.json / cjfast_json release benchmark",
        "",
        "Every matched workload is included. CV changes only the stable/noisy label; "
        "it never removes a row.",
        "",
        f"- Complete workloads: {len(rows)}",
        f"- Stable workloads (all libraries CV <= {cv_limit:.2f}%): {len(stable_rows)}",
        f"- Noisy workloads retained: {len(rows) - len(stable_rows)}",
        "",
        "| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | "
        "cjfast median | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |",
        "|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|:--|",
    ]
    for row in rows:
        yjson = row["yjson"]
        stdx = row["stdx_json"]
        cjfast = row["cjfast_json"]
        stdx_comparison = row["stdx_json_comparison"]
        cjfast_comparison = row["cjfast_json_comparison"]
        assert all(isinstance(item, dict) for item in (
            yjson, stdx, cjfast, stdx_comparison, cjfast_comparison
        ))
        lines.append(
            f"| {row['scenario']} | {row['operation']} | {row['payload']} | "
            f"{row['input_kind']} | {row['rounds']} | "
            f"{float(yjson['median_ns']):.3f} ns | "
            f"{float(stdx['median_ns']):.3f} ns | "
            f"{float(cjfast['median_ns']):.3f} ns | "
            f"{float(stdx_comparison['yjson_over_peer_ratio_median']):.3f}x | "
            f"{float(cjfast_comparison['yjson_over_peer_ratio_median']):.3f}x | "
            f"{float(yjson['run_cv_percent']):.2f}% / "
            f"{float(stdx['run_cv_percent']):.2f}% / "
            f"{float(cjfast['run_cv_percent']):.2f}% | "
            f"{stdx_comparison['yjson_faster_pairs']}/{row['rounds']} / "
            f"{cjfast_comparison['yjson_faster_pairs']}/{row['rounds']} | "
            f"{'stable' if stable(row, cv_limit) else 'noisy'} |"
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


def write_csv(rows: list[dict[str, object]], path: Path, cv_limit: float) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow([
            "scenario", "operation", "payload", "input_kind", "rounds",
            "yjson_median_ns", "stdx_json_median_ns", "cjfast_json_median_ns",
            "yjson_over_stdx_ratio", "yjson_over_cjfast_ratio",
            "yjson_faster_pairs_vs_stdx", "yjson_faster_pairs_vs_cjfast",
            "yjson_cv_percent", "stdx_json_cv_percent", "cjfast_json_cv_percent",
            "yjson_p95_ns", "stdx_json_p95_ns", "cjfast_json_p95_ns", "status",
        ])
        for row in rows:
            yjson = row["yjson"]
            stdx = row["stdx_json"]
            cjfast = row["cjfast_json"]
            stdx_comparison = row["stdx_json_comparison"]
            cjfast_comparison = row["cjfast_json_comparison"]
            assert all(isinstance(item, dict) for item in (
                yjson, stdx, cjfast, stdx_comparison, cjfast_comparison
            ))
            writer.writerow([
                row["scenario"], row["operation"], row["payload"], row["input_kind"],
                row["rounds"],
                f"{float(yjson['median_ns']):.3f}",
                f"{float(stdx['median_ns']):.3f}",
                f"{float(cjfast['median_ns']):.3f}",
                f"{float(stdx_comparison['yjson_over_peer_ratio_median']):.6f}",
                f"{float(cjfast_comparison['yjson_over_peer_ratio_median']):.6f}",
                stdx_comparison["yjson_faster_pairs"],
                cjfast_comparison["yjson_faster_pairs"],
                f"{float(yjson['run_cv_percent']):.6f}",
                f"{float(stdx['run_cv_percent']):.6f}",
                f"{float(cjfast['run_cv_percent']):.6f}",
                f"{float(yjson['run_p95_ns']):.3f}",
                f"{float(stdx['run_p95_ns']):.3f}",
                f"{float(cjfast['run_p95_ns']):.3f}",
                "stable" if stable(row, cv_limit) else "noisy",
            ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--cv-limit", type=float, default=5.0)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    if args.min_runs < 1:
        parser.error("--min-runs must be positive")
    if args.cv_limit < 0.0:
        parser.error("--cv-limit must be non-negative")

    rows = analyze(args.root, args.min_runs)
    markdown = render_markdown(rows, args.cv_limit)
    print(markdown, end="")
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(normalize_json_floats(rows), indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        write_csv(rows, args.csv, args.cv_limit)
    if args.markdown is not None:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

