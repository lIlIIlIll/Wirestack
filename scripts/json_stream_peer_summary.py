#!/usr/bin/env python3
"""Summarize paired yjson and stdx.json Stream protocol runs."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

from json_stream_protocol_summary import percentile, report_median


def summarize(root: Path, min_runs: int) -> list[dict[str, object]]:
    cells: dict[tuple[str, str], dict[int, float]] = defaultdict(dict)
    metadata: dict[str, tuple[str, str, str]] = {}
    with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            case = row["case"]
            cells[(case, row["implementation"])][int(row["round"])] = report_median(
                root / row["report_path"], row["method"])
            metadata[case] = (row["operation"], row["payload"], row["profile"])

    rows = []
    for case in sorted(metadata):
        yjson = cells[(case, "yjson")]
        stdx = cells[(case, "stdx")]
        common = sorted(set(yjson) & set(stdx))
        if len(common) < min_runs:
            raise ValueError(f"{case} has only {len(common)} paired runs")
        left = [yjson[index] for index in common]
        right = [stdx[index] for index in common]
        left_mean, right_mean = statistics.fmean(left), statistics.fmean(right)
        operation, payload, profile = metadata[case]
        rows.append({
            "case": case, "operation": operation, "payload": payload, "profile": profile,
            "runs": len(common),
            "yjson_median_ns": statistics.median(left),
            "yjson_p95_ns": percentile(left, 0.95),
            "yjson_cv_percent": statistics.pstdev(left) / left_mean * 100.0,
            "stdx_median_ns": statistics.median(right),
            "stdx_p95_ns": percentile(right, 0.95),
            "stdx_cv_percent": statistics.pstdev(right) / right_mean * 100.0,
            "yjson_over_stdx_ratio": statistics.median(left) / statistics.median(right),
            "yjson_faster_pairs": sum(before < after for before, after in zip(left, right)),
            "yjson_run_medians_ns": left,
            "stdx_run_medians_ns": right,
        })
    return rows


def markdown(rows: list[dict[str, object]]) -> str:
    lines = [
        "| Case | yjson | stdx.json | yjson/stdx | yjson wins | CV yjson/stdx | Stability |",
        "|:--|--:|--:|--:|--:|--:|:--|",
    ]
    for row in rows:
        stable = max(float(row["yjson_cv_percent"]), float(row["stdx_cv_percent"])) <= 5.0
        lines.append(
            f"| {row['case']} | {float(row['yjson_median_ns']) / 1_000:.3f} us | "
            f"{float(row['stdx_median_ns']) / 1_000:.3f} us | "
            f"{float(row['yjson_over_stdx_ratio']):.3f}x | "
            f"{row['yjson_faster_pairs']}/{row['runs']} | "
            f"{float(row['yjson_cv_percent']):.2f}% / {float(row['stdx_cv_percent']):.2f}% | "
            f"{'stable' if stable else 'noisy'} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--enforce-stability", action="store_true")
    args = parser.parse_args()
    rows = summarize(args.root, args.min_runs)
    rendered = markdown(rows)
    print(rendered, end="")
    result = {"protocol_version": 1, "comparison": "yjson-vs-stdx-stream", "rows": rows}
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(rendered, encoding="utf-8")
    noisy = [row for row in rows
             if max(float(row["yjson_cv_percent"]), float(row["stdx_cv_percent"])) > 5.0]
    return 1 if args.enforce_stability and noisy else 0


if __name__ == "__main__":
    raise SystemExit(main())
