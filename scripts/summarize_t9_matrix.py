#!/usr/bin/env python3
"""Validate and summarize the T9 matrix: yjson/json4cj/cjjson on msgc+daily, plus Jackson.

Jackson and the three msgc cells are mandatory; daily cells are optional and
render as ABSENT when their build failed upstream (the orchestrator records
the failure and continues).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

from run_t9_throughput import B_CASES, CASES
from summarize_t9_three_way import geomean, load

LIBS = ("yjson", "json4cj", "cjjson")
GROUPS = ("serialize", "deserialize", "roundtrip")


def group(case: str) -> str:
    if "RoundTrip" in case:
        return "roundtrip"
    if "Deserialize" in case:
        return "deserialize"
    return "serialize"


def fmt(value: float | None, digits: int = 2) -> str:
    return "ABSENT" if value is None else f"{value:.{digits}f}"


def ratio(num: float | None, den: float | None) -> float | None:
    if num is None or den is None or den == 0:
        return None
    return num / den


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jackson", type=Path, required=True)
    parser.add_argument("--yjson-msgc", type=Path, required=True)
    parser.add_argument("--json4cj-msgc", type=Path, required=True)
    parser.add_argument("--cjjson-msgc", type=Path, required=True)
    parser.add_argument("--yjson-daily", type=Path)
    parser.add_argument("--cjjson-daily", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--yjson-msgc-bytes", type=Path)
    parser.add_argument("--yjson-daily-bytes", type=Path)
    parser.add_argument("--json4cj-msgc-bytes", type=Path)
    parser.add_argument("--json4cj-daily-bytes", type=Path)
    parser.add_argument("--jackson-jmh", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    cells: dict[str, tuple[dict[str, float], dict[str, object]] | None] = {
        "jackson": None, "yjson-msgc": None, "json4cj-msgc": None, "cjjson-msgc": None,
        "yjson-daily": None, "cjjson-daily": None,
    }
    required = ("jackson", "yjson-msgc", "json4cj-msgc", "cjjson-msgc")
    optional = ("yjson-daily", "cjjson-daily")
    for name in required:
        _, medians, metadata = load(args.__dict__[name.replace("-", "_")].resolve())
        cells[name] = (medians, metadata)
        print(f"loaded {name}: {args.__dict__[name.replace('-', '_')]}")
    for name in optional:
        path = args.__dict__[name.replace("-", "_")]
        if path is None:
            print(f"note: {name} not provided (ABSENT)")
            continue
        if not (path.resolve() / "COMPLETE").is_file():
            print(f"warning: {name} incomplete (ABSENT): {path}")
            continue
        _, medians, metadata = load(path.resolve())
        cells[name] = (medians, metadata)
        print(f"loaded {name}: {path}")

    # Cross-cell consistency.
    known = {name: value[1] for name, value in cells.items() if value is not None}
    for field in ("host", "platform", "cpu"):
        values = {name: metadata.get(field) for name, metadata in known.items()}
        if len({json.dumps(value, sort_keys=True) for value in values.values()}) != 1:
            raise RuntimeError(f"{field} differs between result directories: {values!r}")
    msgc_names = [name for name in ("yjson-msgc", "json4cj-msgc", "cjjson-msgc") if name in known]
    for field in ("cjc", "cjpm", "cj_heap_size", "cangjie_stdx_path"):
        values = {name: known[name].get(field) for name in msgc_names}
        if len({json.dumps(value, sort_keys=True) for value in values.values()}) != 1:
            raise RuntimeError(f"msgc {field} differs between result directories: {values!r}")
    # json4cj tomls carry no top-level -O2: its msgc cell passes --cfg to select
    # "-O2 --gc-mode=marksweep".  yjson/cjjson have top-level -O2, so their daily
    # cells build bare (default collector, no --cfg).
    expected_cfg = {
        "yjson-msgc": True, "json4cj-msgc": True, "cjjson-msgc": True,
        "yjson-daily": False, "cjjson-daily": False,
        "jackson": False,
    }
    for name, metadata in known.items():
        if bool(metadata.get("cfg")) is not expected_cfg[name]:
            raise RuntimeError(f"{name}: cfg={metadata.get('cfg')} but expected {expected_cfg[name]}")

    jackson = cells["jackson"][0]

    # Full comparison CSV, written deterministically in one pass.
    csv_fields = ["case", "jackson_us"]
    for lib in LIBS:
        csv_fields += [
            f"{lib}_msgc_us", f"{lib}_daily_us", f"{lib}_daily_over_msgc", f"{lib}_msgc_vs_jackson",
        ]
    with (args.output / "comparison.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=csv_fields)
        writer.writeheader()
        for case in CASES:
            row: dict[str, object] = {"case": case, "jackson_us": f"{jackson[case]:.3f}"}
            for lib in LIBS:
                msgc = cells[f"{lib}-msgc"][0]
                daily_cell = cells.get(f"{lib}-daily")
                daily_medians = daily_cell[0] if daily_cell else None
                row[f"{lib}_msgc_us"] = f"{msgc[case]:.3f}"
                row[f"{lib}_daily_us"] = "" if daily_medians is None else f"{daily_medians[case]:.3f}"
                row[f"{lib}_daily_over_msgc"] = (
                    "" if daily_medians is None else f"{daily_medians[case] / msgc[case]:.3f}"
                )
                row[f"{lib}_msgc_vs_jackson"] = f"{msgc[case] / jackson[case]:.3f}"
            writer.writerow(row)

    # Markdown matrix.
    lines: list[str] = []
    lines.append("# T9 matrix: Jackson + yjson/json4cj/cjjson x {msgc, daily}")
    lines.append("")
    lines.append("Single run, CPU pinned, cjHeapSize=128MB; values are per-case medians in microseconds.")
    lines.append("")
    header = ["case", "jackson"] + [
        col for lib in LIBS for col in (f"{lib} msgc", f"{lib} daily")
    ]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    for case in CASES:
        row = [case, fmt(jackson[case])]
        for lib in LIBS:
            daily_cell = cells.get(f"{lib}-daily")
            row.append(fmt(cells[f"{lib}-msgc"][0][case]))
            row.append(fmt(daily_cell[0][case]) if daily_cell else "ABSENT")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    lines.append("## Geomeans")
    lines.append("")
    lines.append("| metric | " + " | ".join(LIBS) + " |")
    lines.append("|---|---|---|---|")
    msgc_over_j = {
        lib: geomean([cells[f"{lib}-msgc"][0][case] / jackson[case] for case in CASES])
        for lib in LIBS
    }
    lines.append(
        "| msgc / Jackson | "
        + " | ".join(f"{msgc_over_j[lib]:.3f}" for lib in LIBS)
        + " |"
    )
    daily_over_j: dict[str, float | None] = {}
    daily_over_msgc: dict[str, float | None] = {}
    for lib in LIBS:
        daily_cell = cells.get(f"{lib}-daily")
        if daily_cell:
            daily_over_j[lib] = geomean([daily_cell[0][case] / jackson[case] for case in CASES])
            daily_over_msgc[lib] = geomean(
                [daily_cell[0][case] / cells[f"{lib}-msgc"][0][case] for case in CASES]
            )
        else:
            daily_over_j[lib] = None
            daily_over_msgc[lib] = None
    lines.append(
        "| daily / Jackson | "
        + " | ".join(fmt(daily_over_j[lib], 3) for lib in LIBS)
        + " |"
    )
    lines.append(
        "| daily / msgc | "
        + " | ".join(fmt(daily_over_msgc[lib], 3) for lib in LIBS)
        + " |"
    )
    lines.append("")
    for grp in GROUPS:
        cells_in_group = [case for case in CASES if group(case) == grp]
        values = []
        for lib in LIBS:
            values.append(geomean(
                [cells[f"{lib}-msgc"][0][case] / jackson[case] for case in cells_in_group]
            ))
        lines.append(f"- group `{grp}` (n={len(cells_in_group)}) msgc/Jackson geomean: "
                     + ", ".join(f"{lib}={value:.3f}" for lib, value in zip(LIBS, values)))
    lines.append("")
    # ---- Bytes/stream track (three-library; cjjson not comparable) ----
    b_cells: dict[str, dict[str, float]] = {}
    for name in ("yjson-msgc", "yjson-daily", "json4cj-msgc"):
        path = args.__dict__[name.replace("-", "_") + "_bytes"]
        if path is not None and (path.resolve() / "COMPLETE").is_file():
            _, medians, _meta = load(path.resolve())
            b_cells[name] = medians
    jackson_b = {case: jackson[case] for case in B_CASES if case in jackson}
    lines.append("## Bytes/stream track (t9_b_*; cjjson has no bytes API — not comparable)")
    lines.append("")
    if b_cells or jackson_b:
        counterpart = {
            "t9_b_1_bytesParsePrimitive": "t9_1_2_primitiveDeserialize",
            "t9_b_2_bytesParseLargeDoc": "t9_5_10_largeDocumentDeserialize",
            "t9_b_3_streamLargeDoc": "t9_5_10_largeDocumentDeserialize",
        }
        header = ["case", "jackson", "jackson vs string"]
        for lib in ("yjson", "json4cj"):
            header += [f"{lib} msgc", f"{lib} msgc vs string", f"{lib} daily", f"{lib} daily vs string"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "---|" * len(header))
        for case in B_CASES:
            row = [case]
            jv = jackson_b.get(case)
            str_case = counterpart[case]
            row.append(fmt(jv))
            row.append(fmt(ratio(jv, jackson.get(str_case)), 3))
            for lib in ("yjson", "json4cj"):
                for sdk in ("msgc", "daily"):
                    cell = b_cells.get(f"{lib}-{sdk}")
                    bv = cell.get(case) if cell else None
                    sv = cells.get(f"{lib}-{sdk}")
                    svv = sv[0].get(str_case) if sv else None
                    row.append(fmt(bv))
                    row.append(fmt(ratio(bv, svv), 3))
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")
        lines.append("Reading: `vs string` = bytes/stream case divided by its String-input counterpart "
                     "(b_1 vs t9_1_2, b_2/b_3 vs t9_5_10); <1.0 means the bytes path is faster. "
                     "Jackson's A track already parses bytes natively, so its ratio is ~1 by construction.")
    else:
        lines.append("ABSENT (no BytesBench dirs provided)")
    lines.append("")

    # ---- Memory (max RSS per case from summary.csv) ----
    def rss_map(dir_path: Path) -> dict[str, float]:
        result: dict[str, float] = {}
        with (dir_path / "summary.csv").open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                if row.get("max_rss_mb"):
                    result[row["case"]] = float(row["max_rss_mb"])
        return result

    mem_cells: dict[str, dict[str, float]] = {}
    for name in ("yjson-msgc", "yjson-daily", "json4cj-msgc", "cjjson-msgc", "cjjson-daily"):
        path = args.__dict__[name.replace("-", "_")]
        if name in known and (path.resolve() / "summary.csv").is_file():
            try:
                mem_cells[name] = rss_map(path.resolve())
            except Exception:
                pass
    if mem_cells:
        lines.append("## Max RSS (MB, /usr/bin/time -v per cjpm bench process)")
        lines.append("")
        mem_names = list(mem_cells)
        lines.append("| case | " + " | ".join(mem_names) + " |")
        lines.append("|" + "---|" * (len(mem_names) + 1))
        for case in CASES:
            row = [case]
            for name in mem_names:
                value = mem_cells[name].get(case)
                row.append(fmt(value, 1))
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")

    lines.append("## Jackson: JMH vs hand-timed timer")
    lines.append("")
    if args.jackson_jmh is not None and (args.jackson_jmh.resolve() / "jmh-deviation.md").is_file():
        lines.append("See `jmh-deviation.md` in the jackson-jmh cell for the per-case table;")
        lines.append("summary: JMH geomean / hand-timed geomean over all measured cases.")
        with (args.jackson_jmh.resolve() / "jmh-deviation.md").open(encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("Geomean of JMH/hand ratios"):
                    lines.append(f"- {line.strip()}")
        lines.append("")
    else:
        lines.append("ABSENT (jackson-jmh cell not provided)")
    lines.append("")

    lines.append("## Consistency")

    lines.append("")
    for name, metadata in sorted(known.items()):
        lines.append(
            f"- {name}: host={metadata.get('host')} cfg={metadata.get('cfg')} "
            f"cjc={str(metadata.get('cjc', '')).splitlines()[0] if metadata.get('cjc') else '?'} "
            f"stdx={metadata.get('cangjie_stdx_path')}"
        )
    absent = [name for name, value in cells.items() if value is None]
    if absent:
        lines.append(f"- ABSENT cells: {', '.join(absent)}")
    lines.append("")

    (args.output / "comparison.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.output / 'comparison.md'} and {args.output / 'comparison.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
