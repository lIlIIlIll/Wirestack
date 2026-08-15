#!/usr/bin/env python3
"""Compare yjson benchmark CSV files produced by json_perf_baseline.py."""

from __future__ import annotations

import argparse
import csv
import statistics
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


Key = Tuple[str, str, str, str]


KEY_ROWS: Sequence[Key] = (
    ("AST", "stringify", "Person", "ast"),
    ("Pretty JSON", "encode", "Person", "string"),
    ("转义/Unicode", "encode", "String", "string"),
    ("转义/Unicode", "encode", "String", "bytes"),
    ("基础对象", "encode", "Person", "string"),
    ("基础对象", "encode", "Person", "bytes"),
    ("大数组", "encode", "ArrayList<ProfileRecord>[64]", "string"),
    ("大 Map", "encode", "HashMap<String, Int64>[64]", "string"),
    ("基础对象", "decode", "Person", "string"),
    ("字段顺序", "decode", "Person", "string"),
    ("未知字段", "decode", "Person", "string"),
    ("大数组", "decode", "ArrayList<ProfileRecord>[64]", "string"),
    ("深层嵌套", "decode", "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>", "string"),
    ("转义/Unicode", "decode", "String", "bytes"),
    ("转义/Unicode", "decode", "String", "string"),
)


def read_csv(path: Path) -> Dict[str, Dict[Key, float]]:
    result: Dict[str, Dict[Key, float]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            key = (row["scenario"], row["operation"], row["payload"], row["input_kind"])
            result.setdefault(row["library"], {})[key] = float(row["median_ns"])
    return result


def pct(current: float, baseline: float) -> float:
    return ((current / baseline) - 1.0) * 100.0


def fmt_ns(value: Optional[float]) -> str:
    if value is None:
        return "-"
    return f"{value:.0f}"


def fmt_pct(value: Optional[float]) -> str:
    if value is None:
        return "-"
    sign = "+" if value >= 0.0 else ""
    return f"{sign}{value:.1f}%"


def median(values: Iterable[float]) -> Optional[float]:
    values = list(values)
    if not values:
        return None
    return statistics.median(values)


def markdown_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(lines)


def write_csv(path: Path, headers: Sequence[str], rows: Sequence[Sequence[str]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(headers)
        writer.writerows(rows)


def collect_delta_rows(
    current: Dict[Key, float],
    baselines: Sequence[Tuple[str, Dict[Key, float]]],
) -> List[List[str]]:
    rows: List[List[str]] = []
    for key in sorted(current):
        row = [key[0], key[1], key[2], key[3], fmt_ns(current[key])]
        for _, baseline in baselines:
            base = baseline.get(key)
            row.extend([fmt_ns(base), fmt_pct(None if base is None else pct(current[key], base))])
        rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--baseline", action="append", nargs=2, metavar=("LABEL", "CSV"), default=[])
    parser.add_argument("--out-md", type=Path)
    parser.add_argument("--out-csv", type=Path)
    parser.add_argument("--top", type=int, default=8)
    args = parser.parse_args()

    current_all = read_csv(args.current)
    current = current_all.get("yjson", {})
    java = current_all.get("java_fastjson2", {})
    stdx = current_all.get("stdx_json", {})
    baselines = [(label, read_csv(Path(path)).get("yjson", {})) for label, path in args.baseline]

    java_keys = [key for key in current if key in java]
    stdx_keys = [key for key in current if key in stdx]
    current_over_java = [current[key] / java[key] for key in java_keys if java[key] != 0.0]
    stdx_over_current = [stdx[key] / current[key] for key in stdx_keys if current[key] != 0.0]

    lines: List[str] = []
    lines.append("# yjson benchmark compare")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- rows: {len(current)}")
    lines.append(f"- java_rows: {len(java_keys)}")
    lines.append(f"- fast_than_java: {sum(1 for key in java_keys if current[key] < java[key])}")
    lines.append(f"- pass_1.25x_java: {sum(1 for key in java_keys if current[key] <= java[key] * 1.25)}")
    lines.append(f"- median_current_over_java: {median(current_over_java) or 0.0:.2f}x")
    lines.append(f"- fast_than_stdx: {sum(1 for key in stdx_keys if current[key] < stdx[key])}")
    lines.append(f"- median_stdx_over_current: {median(stdx_over_current) or 0.0:.2f}x")

    for label, baseline in baselines:
        common = [key for key in current if key in baseline]
        deltas = [pct(current[key], baseline[key]) for key in common if baseline[key] != 0.0]
        lines.append(f"- improved_vs_{label}: {sum(1 for value in deltas if value < 0.0)}")
        lines.append(f"- regressed_vs_{label}: {sum(1 for value in deltas if value > 0.0)}")
        lines.append(f"- median_delta_vs_{label}: {median(deltas) or 0.0:.1f}%")

    lines.append("")
    lines.append("## Key Rows")
    lines.append("")
    key_headers = ["scenario", "operation", "payload", "input", "current_ns", "java_ns", "current/java"]
    key_headers.extend([f"{label}_ns" for label, _ in baselines])
    key_headers.extend([f"delta_vs_{label}" for label, _ in baselines])
    key_rows: List[List[str]] = []
    for key in KEY_ROWS:
        if key not in current:
            continue
        java_value = java.get(key)
        row = [
            key[0],
            key[1],
            key[2],
            key[3],
            fmt_ns(current[key]),
            fmt_ns(java_value),
            "-" if java_value is None else f"{current[key] / java_value:.2f}x",
        ]
        row.extend(fmt_ns(baseline.get(key)) for _, baseline in baselines)
        row.extend(fmt_pct(None if key not in baseline else pct(current[key], baseline[key])) for _, baseline in baselines)
        key_rows.append(row)
    lines.append(markdown_table(key_headers, key_rows))

    for label, baseline in baselines:
        deltas = [
            (pct(current[key], baseline[key]), key)
            for key in current
            if key in baseline and baseline[key] != 0.0
        ]
        lines.append("")
        lines.append(f"## Top Delta Vs {label}")
        lines.append("")
        top_rows = []
        for value, key in sorted(deltas)[: args.top]:
            top_rows.append([key[0], key[1], key[2], key[3], fmt_ns(current[key]), fmt_ns(baseline[key]), fmt_pct(value)])
        for value, key in sorted(deltas, reverse=True)[: args.top]:
            top_rows.append([key[0], key[1], key[2], key[3], fmt_ns(current[key]), fmt_ns(baseline[key]), fmt_pct(value)])
        lines.append(markdown_table(["scenario", "operation", "payload", "input", "current_ns", f"{label}_ns", "delta"], top_rows))

    content = "\n".join(lines) + "\n"
    if args.out_md:
        args.out_md.write_text(content, encoding="utf-8")
    else:
        print(content, end="")

    if args.out_csv:
        headers = ["scenario", "operation", "payload", "input", "current_ns"]
        for label, _ in baselines:
            headers.extend([f"{label}_ns", f"delta_vs_{label}"])
        write_csv(args.out_csv, headers, collect_delta_rows(current, baselines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
