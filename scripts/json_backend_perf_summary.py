#!/usr/bin/env python3
"""Summarize paired yjson DOM backend raw reports."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


UNIT_TO_NS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}
CASE_GROUPS = {
    "parse": (
        (("pureAstParseLifecycle", "pure_ast"), ("pureCompactParseLifecycle", "pure_compact"),
         ("customNativeParseLifecycle", "custom_native"), ("yyjsonDirectParseLifecycle", "yyjson_direct")),
        "yyjsonDirectParseLifecycle",
    ),
    "lookup": (
        (("pureAstRootLookup", "pure_ast"), ("pureCompactRootLookup", "pure_compact"),
         ("customNativeRootLookup", "custom_native"), ("yyjsonDirectRootLookup", "yyjson_direct")),
        "yyjsonDirectRootLookup",
    ),
    "traversal": (
        (("pureCompactTraversal", "pure_compact"), ("customNativeTraversal", "custom_native"),
         ("yyjsonDirectTraversal", "yyjson_direct")),
        "yyjsonDirectTraversal",
    ),
    "custom_native_materialize": (
        (("customNativeFineViewMaterialize", "fine_view"),
         ("customNativeBulkMaterialize", "bulk")),
        "customNativeFineViewMaterialize",
    ),
    "yyjson_materialize": (
        (("yyjsonFineViewMaterialize", "fine_view"), ("yyjsonBulkMaterialize", "bulk")),
        "yyjsonFineViewMaterialize",
    ),
    "serialize": (
        (("pureAstSerialize", "pure_ast"), ("pureCompactSerialize", "pure_compact"),
         ("customNativeSerialize", "custom_native"), ("yyjsonDirectSerialize", "yyjson_direct")),
        "yyjsonDirectSerialize",
    ),
    "roundtrip": (
        (("pureAstRoundTrip", "pure_ast"), ("pureCompactRoundTrip", "pure_compact"),
         ("customNativeRoundTrip", "custom_native"), ("yyjsonDirectRoundTrip", "yyjson_direct")),
        "yyjsonDirectRoundTrip",
    ),
}
CASE_INFO = {
    case: (operation, backend, reference)
    for operation, (entries, reference) in CASE_GROUPS.items()
    for case, backend in entries
}


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
        run_id = path.relative_to(root / "raw").parts[0]
        with path.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                if int(row["BatchSize"]) <= 0 or row.get("Measurement") != "Duration":
                    continue
                scale = UNIT_TO_NS.get(row["Unit"])
                if scale is None:
                    raise ValueError(f"unsupported duration unit {row['Unit']!r} in {path}")
                case = row["Case"].split(".")[-1]
                runs[run_id][case].append(float(row["Duration"]) * scale / int(row["BatchSize"]))
    if not runs:
        raise ValueError(f"no csv-raw benchmark rows found below {root / 'raw'}")
    return {run_id: dict(cases) for run_id, cases in runs.items()}


def analyze(root: Path, min_runs: int) -> list[dict[str, object]]:
    runs = load_runs(root)
    present_cases = {case for values in runs.values() for case in values}
    case_runs = {
        case: {run_id: values[case] for run_id, values in runs.items() if case in values}
        for case in CASE_INFO if case in present_cases
    }
    incomplete = {case: len(values) for case, values in case_runs.items() if len(values) < min_runs}
    if incomplete:
        raise ValueError(f"cases have fewer than {min_runs} runs: {incomplete}")
    rows: list[dict[str, object]] = []
    for case, (operation, backend, reference_case) in CASE_INFO.items():
        if case not in case_runs:
            continue
        run_medians = {
            run_id: statistics.median(samples) for run_id, samples in case_runs[case].items()
        }
        values = list(run_medians.values())
        mean = statistics.fmean(values)
        if reference_case not in case_runs:
            raise ValueError(f"operation {operation!r} has no reference case")
        reference_runs = {
            run_id: statistics.median(samples)
            for run_id, samples in case_runs[reference_case].items()
        }
        common = sorted(set(run_medians) & set(reference_runs))
        ratios = [run_medians[run_id] / reference_runs[run_id] for run_id in common]
        rows.append({
            "operation": operation,
            "backend": backend,
            "case": case,
            "reference_case": reference_case,
            "runs": len(values),
            "median_ns": statistics.median(values),
            "p95_ns": percentile(values, 0.95),
            "cv_percent": 0.0 if mean == 0.0 else statistics.pstdev(values) / mean * 100.0,
            "latency_ratio_to_reference": statistics.median(ratios),
            "slower_than_reference_pairs": sum(ratio > 1.0 for ratio in ratios),
            "pairs": len(ratios),
            "run_medians_ns": values,
        })
    return rows


def render_markdown(rows: list[dict[str, object]]) -> str:
    lines = [
        "`latency ratio` is case median / its reference-case median; below 1 is faster.",
        "",
        "| Operation | Backend | Runs | Median | p95 | CV | Latency ratio | Slower pairs |",
        "|:--|:--|--:|--:|--:|--:|--:|--:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['operation']} | {row['backend']} | {row['runs']} | "
            f"{float(row['median_ns']) / 1_000.0:.3f} us | "
            f"{float(row['p95_ns']) / 1_000.0:.3f} us | "
            f"{float(row['cv_percent']):.2f}% | "
            f"{float(row['latency_ratio_to_reference']):.3f}x | "
            f"{row['slower_than_reference_pairs']}/{row['pairs']} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    rows = analyze(args.root, args.min_runs)
    markdown = render_markdown(rows)
    print(markdown, end="")
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.markdown is not None:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
