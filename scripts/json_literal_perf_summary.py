#!/usr/bin/env python3
"""Summarize raw JSON literal benchmark reports with paired run statistics."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


UNIT_TO_NS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}
COMPARISONS = (
    ("jsonMacroStatic", "generatedCodec"),
    ("jsonMacroStatic", "manualDirectWriter"),
    ("jsonMacroDynamicKey", "jsonMacroStatic"),
    ("jsonValueMacroBuildOnly", "manualConcreteAstBuildOnly"),
    ("jsonValueMacroBuildOnly", "manualFluentAstBuildOnly"),
    ("jsonValueMacroAndStringify", "manualConcreteAstAndStringify"),
    ("jsonMacroStatic", "jsonValueMacroAndStringify"),
)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def load_runs(root: Path) -> dict[str, dict[str, list[float]]]:
    runs: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for path in sorted((root / "raw").rglob("bench-*.csv")):
        relative = path.relative_to(root / "raw")
        run_id = relative.parts[0]
        with path.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                batch_size = int(row["BatchSize"])
                if batch_size <= 0 or row.get("Measurement") != "Duration":
                    continue
                scale = UNIT_TO_NS.get(row["Unit"])
                if scale is None:
                    raise ValueError(f"unsupported duration unit {row['Unit']!r} in {path}")
                runs[run_id][row["Case"]].append(float(row["Duration"]) * scale / batch_size)
    if not runs:
        raise ValueError(f"no csv-raw benchmark rows found below {root / 'raw'}")
    return {run_id: dict(cases) for run_id, cases in runs.items()}


def summarize_case(run_samples: dict[str, list[float]]) -> dict[str, object]:
    run_medians = [statistics.median(values) for _, values in sorted(run_samples.items())]
    raw_samples = [value for _, values in sorted(run_samples.items()) for value in values]
    median = statistics.median(run_medians)
    mean = statistics.fmean(run_medians)
    mad = statistics.median([abs(value - median) for value in run_medians])
    return {
        "runs": len(run_medians),
        "raw_samples": len(raw_samples),
        "median_ns": median,
        "p95_ns": percentile(run_medians, 0.95),
        "cv_percent": 0.0 if mean == 0.0 else statistics.pstdev(run_medians) / mean * 100.0,
        "mad_ns": mad,
        "mad_percent": 0.0 if median == 0.0 else mad / median * 100.0,
        "raw_p95_ns": percentile(raw_samples, 0.95),
        "run_medians_ns": run_medians,
        "raw_samples_ns": raw_samples,
    }


def analyze(root: Path, min_runs: int) -> dict[str, object]:
    runs = load_runs(root)
    case_names = sorted({case for cases in runs.values() for case in cases})
    case_runs = {
        case: {run_id: cases[case] for run_id, cases in runs.items() if case in cases}
        for case in case_names
    }
    incomplete = {case: len(values) for case, values in case_runs.items() if len(values) < min_runs}
    if incomplete:
        raise ValueError(f"cases have fewer than {min_runs} runs: {incomplete}")
    summaries = {case: summarize_case(values) for case, values in case_runs.items()}
    comparisons = []
    for left, right in COMPARISONS:
        if left not in case_runs or right not in case_runs:
            raise ValueError(f"missing comparison case: {left} or {right}")
        common_runs = sorted(set(case_runs[left]) & set(case_runs[right]))
        paired_ratios = []
        paired_deltas = []
        for run_id in common_runs:
            left_value = statistics.median(case_runs[left][run_id])
            right_value = statistics.median(case_runs[right][run_id])
            paired_ratios.append(left_value / right_value)
            paired_deltas.append((left_value - right_value) / right_value * 100.0)
        comparisons.append({
            "left": left,
            "right": right,
            "pairs": len(common_runs),
            "left_slower_pairs": sum(delta > 0.0 for delta in paired_deltas),
            "paired_ratio_median": statistics.median(paired_ratios),
            "paired_delta_median_percent": statistics.median(paired_deltas),
            "paired_delta_p95_percent": percentile(paired_deltas, 0.95),
            "paired_delta_mad_points": statistics.median([
                abs(delta - statistics.median(paired_deltas)) for delta in paired_deltas
            ]),
            "paired_deltas_percent": paired_deltas,
        })
    return {"cases": summaries, "comparisons": comparisons}


def render_markdown(result: dict[str, object]) -> str:
    cases = result["cases"]
    comparisons = result["comparisons"]
    assert isinstance(cases, dict) and isinstance(comparisons, list)
    lines = [
        "| Case | Runs | Median | p95 | CV | MAD | Raw samples |",
        "|:--|--:|--:|--:|--:|--:|--:|",
    ]
    for case, summary in cases.items():
        assert isinstance(summary, dict)
        lines.append(
            f"| {case} | {summary['runs']} | {float(summary['median_ns']):.3f} ns | "
            f"{float(summary['p95_ns']):.3f} ns | {float(summary['cv_percent']):.2f}% | "
            f"{float(summary['mad_percent']):.2f}% | {summary['raw_samples']} |"
        )
    lines.extend([
        "",
        "Positive deltas mean the left-hand path is slower than the right-hand path.",
        "",
        "| Left | Right | Left slower | Paired ratio | Paired delta | Delta p95 | Delta MAD |",
        "|:--|:--|--:|--:|--:|--:|--:|",
    ])
    for comparison in comparisons:
        assert isinstance(comparison, dict)
        lines.append(
            f"| {comparison['left']} | {comparison['right']} | "
            f"{comparison['left_slower_pairs']}/{comparison['pairs']} | "
            f"{float(comparison['paired_ratio_median']):.3f}x | "
            f"{float(comparison['paired_delta_median_percent']):+.2f}% | "
            f"{float(comparison['paired_delta_p95_percent']):+.2f}% | "
            f"{float(comparison['paired_delta_mad_points']):.2f} pp |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    result = analyze(args.root, args.min_runs)
    markdown = render_markdown(result)
    print(markdown, end="")
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.markdown is not None:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
