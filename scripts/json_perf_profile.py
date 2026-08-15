#!/usr/bin/env python3
"""Build offline profiling reports from json_perf_baseline.py CSV artifacts."""

from __future__ import annotations

import argparse
import csv
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CURRENT = ROOT / "target" / "perf-baseline" / "json_perf_baseline.csv"

Key = Tuple[str, str, str, str]


@dataclass(frozen=True)
class Row:
    key: Key
    library: str
    median_ns: float
    source_case: str
    notes: str


@dataclass(frozen=True)
class ReportRow:
    section: str
    rank: int
    key: Key
    current_ns: Optional[float]
    peer_label: str = ""
    peer_ns: Optional[float] = None
    ratio: Optional[float] = None
    baseline_label: str = ""
    baseline_ns: Optional[float] = None
    delta_pct: Optional[float] = None
    notes: str = ""


def read_csv(path: Path) -> Dict[str, Dict[Key, Row]]:
    rows: Dict[str, Dict[Key, Row]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"scenario", "operation", "payload", "library", "input_kind", "median_ns"}
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise SystemExit(f"{path} is missing required columns: {', '.join(sorted(missing))}")
        for raw in reader:
            key = (
                raw["scenario"],
                raw["operation"],
                raw["payload"],
                raw["input_kind"],
            )
            library = raw["library"]
            rows.setdefault(library, {})[key] = Row(
                key=key,
                library=library,
                median_ns=float(raw["median_ns"]),
                source_case=raw.get("source_case", ""),
                notes=raw.get("notes", ""),
            )
    return rows


def fmt_ns(value: Optional[float]) -> str:
    if value is None:
        return "-"
    return f"{value:,.0f}"


def fmt_ratio(value: Optional[float]) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


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


def pct_delta(current: float, baseline: float) -> float:
    return ((current / baseline) - 1.0) * 100.0


def escape_md(value: str) -> str:
    return value.replace("|", "\\|")


def markdown_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(lines)


def key_cells(key: Key) -> List[str]:
    return [escape_md(key[0]), key[1], escape_md(key[2]), key[3]]


def top_current_rows(current: Dict[Key, Row], top: int) -> List[ReportRow]:
    result: List[ReportRow] = []
    for rank, row in enumerate(
        sorted(current.values(), key=lambda item: item.median_ns, reverse=True)[:top],
        start=1,
    ):
        result.append(
            ReportRow(
                section="current_hotspots",
                rank=rank,
                key=row.key,
                current_ns=row.median_ns,
                notes=row.notes,
            )
        )
    return result


def java_under_one_rows(
    current: Dict[Key, Row],
    java: Dict[Key, Row],
    top: int,
) -> List[ReportRow]:
    rows: List[ReportRow] = []
    for key, current_row in current.items():
        java_row = java.get(key)
        if java_row is None or java_row.median_ns == 0.0:
            continue
        ratio = current_row.median_ns / java_row.median_ns
        if ratio < 1.0:
            rows.append(
                ReportRow(
                    section="current_over_java_under_1x",
                    rank=0,
                    key=key,
                    current_ns=current_row.median_ns,
                    peer_label="java_fastjson2",
                    peer_ns=java_row.median_ns,
                    ratio=ratio,
                    notes=current_row.notes or java_row.notes,
                )
            )
    rows.sort(key=lambda item: item.ratio if item.ratio is not None else 0.0)
    return [dataclasses_replace_rank(row, rank) for rank, row in enumerate(rows[:top], start=1)]


def stdx_smallest_leads(
    current: Dict[Key, Row],
    stdx: Dict[Key, Row],
    top: int,
) -> List[ReportRow]:
    rows: List[ReportRow] = []
    for key, current_row in current.items():
        stdx_row = stdx.get(key)
        if stdx_row is None or current_row.median_ns == 0.0:
            continue
        ratio = stdx_row.median_ns / current_row.median_ns
        if ratio > 1.0:
            rows.append(
                ReportRow(
                    section="smallest_lead_vs_stdx",
                    rank=0,
                    key=key,
                    current_ns=current_row.median_ns,
                    peer_label="stdx_json",
                    peer_ns=stdx_row.median_ns,
                    ratio=ratio,
                    notes=current_row.notes or stdx_row.notes,
                )
            )
    rows.sort(key=lambda item: item.ratio if item.ratio is not None else 0.0)
    return [dataclasses_replace_rank(row, rank) for rank, row in enumerate(rows[:top], start=1)]


def baseline_delta_rows(
    current: Dict[Key, Row],
    baselines: Sequence[Tuple[str, Dict[Key, Row]]],
    top: int,
) -> List[ReportRow]:
    result: List[ReportRow] = []
    for label, baseline in baselines:
        deltas: List[ReportRow] = []
        for key, current_row in current.items():
            baseline_row = baseline.get(key)
            if baseline_row is None or baseline_row.median_ns == 0.0:
                continue
            delta = pct_delta(current_row.median_ns, baseline_row.median_ns)
            deltas.append(
                ReportRow(
                    section="baseline_delta",
                    rank=0,
                    key=key,
                    current_ns=current_row.median_ns,
                    baseline_label=label,
                    baseline_ns=baseline_row.median_ns,
                    delta_pct=delta,
                    notes=current_row.notes or baseline_row.notes,
                )
            )

        regressions = sorted(
            [row for row in deltas if row.delta_pct is not None and row.delta_pct > 0.0],
            key=lambda item: item.delta_pct or 0.0,
            reverse=True,
        )[:top]
        improvements = sorted(
            [row for row in deltas if row.delta_pct is not None and row.delta_pct < 0.0],
            key=lambda item: item.delta_pct or 0.0,
        )[:top]
        for rank, row in enumerate(regressions, start=1):
            result.append(replace_section_rank(row, "largest_regressions_vs_baseline", rank))
        for rank, row in enumerate(improvements, start=1):
            result.append(replace_section_rank(row, "largest_improvements_vs_baseline", rank))
    return result


def dataclasses_replace_rank(row: ReportRow, rank: int) -> ReportRow:
    return ReportRow(
        section=row.section,
        rank=rank,
        key=row.key,
        current_ns=row.current_ns,
        peer_label=row.peer_label,
        peer_ns=row.peer_ns,
        ratio=row.ratio,
        baseline_label=row.baseline_label,
        baseline_ns=row.baseline_ns,
        delta_pct=row.delta_pct,
        notes=row.notes,
    )


def replace_section_rank(row: ReportRow, section: str, rank: int) -> ReportRow:
    return ReportRow(
        section=section,
        rank=rank,
        key=row.key,
        current_ns=row.current_ns,
        peer_label=row.peer_label,
        peer_ns=row.peer_ns,
        ratio=row.ratio,
        baseline_label=row.baseline_label,
        baseline_ns=row.baseline_ns,
        delta_pct=row.delta_pct,
        notes=row.notes,
    )


def build_report_rows(
    current: Dict[Key, Row],
    stdx: Dict[Key, Row],
    java: Dict[Key, Row],
    baselines: Sequence[Tuple[str, Dict[Key, Row]]],
    top: int,
) -> List[ReportRow]:
    rows: List[ReportRow] = []
    rows.extend(java_under_one_rows(current, java, top))
    rows.extend(stdx_smallest_leads(current, stdx, top))
    rows.extend(top_current_rows(current, top))
    rows.extend(baseline_delta_rows(current, baselines, top))
    return rows


def write_profile_csv(path: Path, rows: Sequence[ReportRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "section",
                "rank",
                "scenario",
                "operation",
                "payload",
                "input_kind",
                "current_ns",
                "peer_label",
                "peer_ns",
                "ratio",
                "baseline_label",
                "baseline_ns",
                "delta_pct",
                "notes",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.section,
                    row.rank,
                    row.key[0],
                    row.key[1],
                    row.key[2],
                    row.key[3],
                    "" if row.current_ns is None else f"{row.current_ns:.3f}",
                    row.peer_label,
                    "" if row.peer_ns is None else f"{row.peer_ns:.3f}",
                    "" if row.ratio is None else f"{row.ratio:.6f}",
                    row.baseline_label,
                    "" if row.baseline_ns is None else f"{row.baseline_ns:.3f}",
                    "" if row.delta_pct is None else f"{row.delta_pct:.6f}",
                    row.notes,
                ]
            )


def section_rows(rows: Sequence[ReportRow], section: str) -> List[ReportRow]:
    return [row for row in rows if row.section == section]


def comparison_ratios(current: Dict[Key, Row], peer: Dict[Key, Row]) -> List[float]:
    ratios: List[float] = []
    for key, current_row in current.items():
        peer_row = peer.get(key)
        if peer_row is not None and peer_row.median_ns != 0.0:
            ratios.append(current_row.median_ns / peer_row.median_ns)
    return ratios


def baseline_summary(
    current: Dict[Key, Row],
    baselines: Sequence[Tuple[str, Dict[Key, Row]]],
) -> List[List[str]]:
    rows: List[List[str]] = []
    for label, baseline in baselines:
        deltas = [
            pct_delta(current[key].median_ns, baseline[key].median_ns)
            for key in current
            if key in baseline and baseline[key].median_ns != 0.0
        ]
        rows.append(
            [
                label,
                str(len(deltas)),
                str(sum(1 for value in deltas if value > 0.0)),
                str(sum(1 for value in deltas if value < 0.0)),
                fmt_pct(median(deltas)),
            ]
        )
    return rows


def write_markdown(
    path: Optional[Path],
    current_path: Path,
    current: Dict[Key, Row],
    stdx: Dict[Key, Row],
    java: Dict[Key, Row],
    baselines: Sequence[Tuple[str, Dict[Key, Row]]],
    rows: Sequence[ReportRow],
) -> str:
    java_ratios = comparison_ratios(current, java)
    stdx_ratios = [
        stdx[key].median_ns / current[key].median_ns
        for key in current
        if key in stdx and current[key].median_ns != 0.0
    ]

    lines: List[str] = [
        "# yjson offline performance profile",
        "",
        f"- current_csv: `{current_path}`",
        f"- yjson_rows: {len(current)}",
        f"- java_rows_matched: {len(java_ratios)}",
        f"- current_over_java_median: {fmt_ratio(median(java_ratios))}",
        f"- current_over_java_under_1x_rows: {sum(1 for value in java_ratios if value < 1.0)}",
        f"- stdx_over_current_median: {fmt_ratio(median(stdx_ratios))}",
        f"- current_faster_than_stdx_rows: {sum(1 for value in stdx_ratios if value > 1.0)}",
    ]
    if baselines:
        lines.extend(["", "## Baseline Summary", ""])
        lines.append(
            markdown_table(
                ["baseline", "matched", "regressed", "improved", "median_delta"],
                baseline_summary(current, baselines),
            )
        )

    add_comparison_section(
        lines,
        "Rows Where current/java < 1.0x",
        section_rows(rows, "current_over_java_under_1x"),
        ["rank", "scenario", "operation", "payload", "input", "current_ns", "java_ns", "current/java", "notes"],
    )
    add_comparison_section(
        lines,
        "Smallest Leads Vs stdx.json",
        section_rows(rows, "smallest_lead_vs_stdx"),
        ["rank", "scenario", "operation", "payload", "input", "current_ns", "stdx_ns", "stdx/current", "notes"],
    )
    add_hotspot_section(lines, section_rows(rows, "current_hotspots"))
    add_baseline_section(lines, "Largest Regressions Vs Baseline", section_rows(rows, "largest_regressions_vs_baseline"))
    add_baseline_section(lines, "Largest Improvements Vs Baseline", section_rows(rows, "largest_improvements_vs_baseline"))

    content = "\n".join(lines) + "\n"
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return content


def add_comparison_section(
    lines: List[str],
    title: str,
    rows: Sequence[ReportRow],
    headers: Sequence[str],
) -> None:
    lines.extend(["", f"## {title}", ""])
    table_rows = [
        [
            str(row.rank),
            *key_cells(row.key),
            fmt_ns(row.current_ns),
            fmt_ns(row.peer_ns),
            fmt_ratio(row.ratio),
            escape_md(row.notes),
        ]
        for row in rows
    ]
    lines.append(markdown_table(headers, table_rows))


def add_hotspot_section(lines: List[str], rows: Sequence[ReportRow]) -> None:
    lines.extend(["", "## Current Hotspots", ""])
    table_rows = [
        [
            str(row.rank),
            *key_cells(row.key),
            fmt_ns(row.current_ns),
            escape_md(row.notes),
        ]
        for row in rows
    ]
    lines.append(
        markdown_table(
            ["rank", "scenario", "operation", "payload", "input", "current_ns", "notes"],
            table_rows,
        )
    )


def add_baseline_section(lines: List[str], title: str, rows: Sequence[ReportRow]) -> None:
    if not rows:
        return
    lines.extend(["", f"## {title}", ""])
    table_rows = [
        [
            row.baseline_label,
            str(row.rank),
            *key_cells(row.key),
            fmt_ns(row.current_ns),
            fmt_ns(row.baseline_ns),
            fmt_pct(row.delta_pct),
            escape_md(row.notes),
        ]
        for row in rows
    ]
    lines.append(
        markdown_table(
            [
                "baseline",
                "rank",
                "scenario",
                "operation",
                "payload",
                "input",
                "current_ns",
                "baseline_ns",
                "delta",
                "notes",
            ],
            table_rows,
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "current",
        nargs="?",
        type=Path,
        default=DEFAULT_CURRENT,
        help="current json_perf_baseline.csv; defaults to target/perf-baseline/json_perf_baseline.csv",
    )
    parser.add_argument("--baseline", action="append", nargs=2, metavar=("LABEL", "CSV"), default=[])
    parser.add_argument("--out-md", type=Path, help="write markdown report")
    parser.add_argument("--out-csv", type=Path, help="write flattened profile rows")
    parser.add_argument("--top", type=int, default=10, help="rows per section")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    current_path = args.current
    all_current = read_csv(current_path)
    current = all_current.get("yjson", {})
    if not current:
        raise SystemExit(f"{current_path} has no yjson rows")
    stdx = all_current.get("stdx_json", {})
    java = all_current.get("java_fastjson2", {})
    baselines = [
        (label, read_csv(Path(path)).get("yjson", {}))
        for label, path in args.baseline
    ]

    report_rows = build_report_rows(current, stdx, java, baselines, max(args.top, 1))
    content = write_markdown(args.out_md, current_path, current, stdx, java, baselines, report_rows)
    if args.out_csv:
        write_profile_csv(args.out_csv, report_rows)
    if not args.out_md:
        print(content, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
