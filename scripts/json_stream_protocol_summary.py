#!/usr/bin/env python3
"""Summarize paired yjson Stream protocol runs and enforce lifecycle gates."""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path


UNIT_TO_NS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def report_median(path: Path, method: str) -> float:
    samples: list[float] = []
    reports = list(path.rglob("bench-*.csv"))
    if len(reports) != 1:
        raise ValueError(f"expected one raw report below {path}, found {len(reports)}")
    with reports[0].open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if row.get("Case") != method:
                continue
            batch = int(row["BatchSize"])
            if batch <= 0 or row.get("Measurement") != "Duration":
                continue
            samples.append(float(row["Duration"]) * UNIT_TO_NS[row["Unit"]] / batch)
    if not samples:
        raise ValueError(f"no duration samples in {reports[0]}")
    return statistics.median(samples)


def bootstrap_ci(improvements: list[float], samples: int = 20_000) -> tuple[float, float]:
    rng = random.Random(0x594A534F4E)
    estimates = []
    for _ in range(samples):
        draw = [improvements[rng.randrange(len(improvements))] for _ in improvements]
        estimates.append(statistics.median(draw))
    return percentile(estimates, 0.025), percentile(estimates, 0.975)


def summarize(root: Path, min_runs: int, variant: str | None) -> list[dict[str, object]]:
    cells: dict[tuple[str, str], dict[int, float]] = defaultdict(dict)
    metadata: dict[str, tuple[str, str, str]] = {}
    with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            row_variant = row.get("variant", "workspace")
            if variant is not None and row_variant != variant:
                continue
            case, lifecycle, round_id = row["case"], row["lifecycle"], int(row["round"])
            cells[(case, lifecycle)][round_id] = report_median(root / row["report_path"], row["method"])
            metadata[case] = (row["operation"], row["payload"], row["profile"])

    rows = []
    for case in sorted(metadata):
        unpooled = cells[(case, "unpooled-one-shot")]
        pooled = cells[(case, "pooled-steady-state")]
        common = sorted(set(unpooled) & set(pooled))
        if len(common) < min_runs:
            raise ValueError(f"{case} has only {len(common)} paired runs")
        left = [unpooled[index] for index in common]
        right = [pooled[index] for index in common]
        improvements = [(before - after) / before * 100.0 for before, after in zip(left, right)]
        left_mean, right_mean = statistics.fmean(left), statistics.fmean(right)
        ci_low, ci_high = bootstrap_ci(improvements)
        operation, payload, profile = metadata[case]
        rows.append({
            "case": case, "operation": operation, "payload": payload, "profile": profile,
            "runs": len(common),
            "unpooled_median_ns": statistics.median(left),
            "unpooled_p95_ns": percentile(left, 0.95),
            "unpooled_cv_percent": statistics.pstdev(left) / left_mean * 100.0,
            "unpooled_run_medians_ns": left,
            "pooled_median_ns": statistics.median(right),
            "pooled_p95_ns": percentile(right, 0.95),
            "pooled_cv_percent": statistics.pstdev(right) / right_mean * 100.0,
            "pooled_run_medians_ns": right,
            "paired_improvement_median_percent": statistics.median(improvements),
            "paired_improvement_ci95_percent": [ci_low, ci_high],
            "pooled_faster_pairs": sum(after < before for before, after in zip(left, right)),
        })
    return rows


def gates(rows: list[dict[str, object]]) -> dict[str, object]:
    canonical = [row for row in rows if row["operation"] == "decode" and row["profile"] == "chunk-4k"]
    payload_wins = {str(row["payload"]) for row in canonical
                    if float(row["paired_improvement_median_percent"]) > 0.0}
    noisy = [row["case"] for row in rows
             if max(float(row["unpooled_cv_percent"]), float(row["pooled_cv_percent"])) > 5.0]
    return {
        "pooled_faster_on_at_least_two_payloads": {"passed": len(payload_wins) >= 2,
                                                    "payloads": sorted(payload_wins)},
        "all_rows_cv_at_most_5_percent": {"passed": not noisy, "noisy_cases": noisy},
    }


def markdown(rows: list[dict[str, object]], gate_result: dict[str, object]) -> str:
    lines = [
        "| Case | Lifecycle U/P median | P p95 | CV U/P | Paired improvement (95% CI) | P wins |",
        "|:--|--:|--:|--:|--:|--:|",
    ]
    for row in rows:
        low, high = row["paired_improvement_ci95_percent"]
        lines.append(
            f"| {row['case']} | {float(row['unpooled_median_ns']) / 1_000:.3f} / "
            f"{float(row['pooled_median_ns']) / 1_000:.3f} us | "
            f"{float(row['pooled_p95_ns']) / 1_000:.3f} us | "
            f"{float(row['unpooled_cv_percent']):.2f}% / {float(row['pooled_cv_percent']):.2f}% | "
            f"{float(row['paired_improvement_median_percent']):+.2f}% "
            f"[{float(low):+.2f}%, {float(high):+.2f}%] | "
            f"{row['pooled_faster_pairs']}/{row['runs']} |"
        )
    lines.extend(["", "Gates:", ""])
    for name, result in gate_result.items():
        lines.append(f"- {'PASS' if result['passed'] else 'FAIL'} `{name}`")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--variant")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--enforce", action="store_true")
    args = parser.parse_args()
    rows = summarize(args.root, args.min_runs, args.variant)
    gate_result = gates(rows)
    rendered = markdown(rows, gate_result)
    print(rendered, end="")
    result = {"protocol_version": 1, "variant": args.variant or "workspace",
              "rows": rows, "gates": gate_result}
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(rendered, encoding="utf-8")
    return 1 if args.enforce and not all(item["passed"] for item in gate_result.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
