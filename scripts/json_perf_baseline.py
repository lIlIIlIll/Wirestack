#!/usr/bin/env python3
"""Run and merge yjson, stdx.json, cjfast_json, and Java baselines."""

from __future__ import annotations

import argparse
import csv
import dataclasses
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = ROOT / "target" / "perf-baseline"
DEFAULT_CANGJIE_CMD = (
    "bash -lc 'cd packages/benchmarks && ../../scripts/codex_cangjie_env cjpm bench --no-color --filter ComprehensiveJsonCompareBenchmarks'"
)


@dataclasses.dataclass(frozen=True)
class Meta:
    scenario: str
    operation: str
    payload: str
    input_kind: str
    notes: str = ""


@dataclasses.dataclass
class Measurement:
    scenario: str
    operation: str
    payload: str
    library: str
    input_kind: str
    median_ns: float
    notes: str
    source_case: str


CANGJIE_META: Dict[str, Meta] = {}
CJFAST_META: Dict[str, Meta] = {}
JAVA_META: Dict[str, Meta] = {}


def add_cangjie_pair(suffix: str, meta: Meta) -> None:
    CANGJIE_META["yjson" + suffix] = meta
    CANGJIE_META["stdx" + suffix] = meta


def add_case(suffix: str, java_case: Optional[str], meta: Meta) -> None:
    add_cangjie_pair(suffix, meta)
    if java_case is not None:
        JAVA_META[java_case] = meta


def build_metadata() -> None:
    add_case("AstParsePerson", "ast-parse-person", Meta("AST", "parse", "Person", "ast"))
    add_case("AstStringifyPerson", "ast-stringify-person", Meta("AST", "stringify", "Person", "ast"))

    for payload, java_payload, scenario in [
        ("Address", "address", "基础对象"),
        ("Person", "person", "基础对象"),
        ("ProfileBundle", "profile-bundle", "嵌套对象"),
        ("UInt64Envelope", "uint64-envelope", "数值边界"),
        ("TemporalStats", "temporal-stats", "时间/大数"),
    ]:
        add_case(
            "StringEncode" + payload,
            "string-encode-" + java_payload,
            Meta(scenario, "encode", payload, "string"),
        )
        add_case(
            "StringDecode" + payload,
            "string-decode-" + java_payload,
            Meta(scenario, "decode", payload, "string"),
        )
        add_case(
            "BytesEncode" + payload,
            "bytes-encode-" + java_payload,
            Meta(scenario, "encode", payload, "bytes"),
        )
        add_case(
            "BytesDecode" + payload,
            "bytes-decode-" + java_payload,
            Meta(scenario, "decode", payload, "bytes"),
        )

    add_case(
        "StringEncodePrettyPerson",
        "string-encode-pretty-person",
        Meta("Pretty JSON", "encode", "Person", "string", "pretty output"),
    )
    add_case(
        "StreamEncodePerson",
        None,
        Meta("流式 I/O", "encode", "Person", "stream", "Cangjie stream API only"),
    )
    add_case(
        "StreamDecodePerson",
        None,
        Meta("流式 I/O", "decode", "Person", "stream", "Cangjie stream API only"),
    )
    add_case(
        "StringEncodeEscapedUnicodeString",
        "string-encode-escaped-unicode-string",
        Meta("转义/Unicode", "encode", "String", "string", "quotes, slash, newline, tab, unicode escapes"),
    )
    add_case(
        "StringDecodeEscapedUnicodeString",
        "string-decode-escaped-unicode-string",
        Meta("转义/Unicode", "decode", "String", "string", "quotes, slash, newline, tab, unicode escapes"),
    )
    add_case(
        "BytesEncodeEscapedUnicodeString",
        "bytes-encode-escaped-unicode-string",
        Meta("转义/Unicode", "encode", "String", "bytes", "quotes, slash, newline, tab, unicode escapes"),
    )
    add_case(
        "BytesDecodeEscapedUnicodeString",
        "bytes-decode-escaped-unicode-string",
        Meta("转义/Unicode", "decode", "String", "bytes", "quotes, slash, newline, tab, unicode escapes"),
    )
    add_case(
        "StringEncodeLargeProfileArray",
        "string-encode-large-profile-array",
        Meta("大数组", "encode", "ArrayList<ProfileRecord>[64]", "string"),
    )
    add_case(
        "StringDecodeLargeProfileArray",
        "string-decode-large-profile-array",
        Meta("大数组", "decode", "ArrayList<ProfileRecord>[64]", "string"),
    )
    add_case(
        "StringEncodeLargeInt64Map",
        "string-encode-large-int64-map",
        Meta("大 Map", "encode", "HashMap<String, Int64>[64]", "string"),
    )
    add_case(
        "StringDecodeLargeInt64Map",
        "string-decode-large-int64-map",
        Meta("大 Map", "decode", "HashMap<String, Int64>[64]", "string"),
    )
    add_case(
        "StringEncodeDeepNestedProfiles",
        "string-encode-deep-nested-profiles",
        Meta("深层嵌套", "encode", "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>", "string"),
    )
    add_case(
        "StringDecodeDeepNestedProfiles",
        "string-decode-deep-nested-profiles",
        Meta("深层嵌套", "decode", "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>", "string"),
    )
    add_case(
        "StringDecodeUnorderedPerson",
        "string-decode-unordered-person",
        Meta("字段顺序", "decode", "Person", "string", "wire fields are intentionally reordered"),
    )
    add_case(
        "StringDecodeUnknownPerson",
        "string-decode-unknown-person",
        Meta("未知字段", "decode", "Person", "string", "unknown nested values must be skipped"),
    )
    add_case(
        "StringDecodePrettyPerson",
        "string-decode-pretty-person",
        Meta("Pretty JSON", "decode", "Person", "string", "pretty input"),
    )


build_metadata()

for case_name, meta in CANGJIE_META.items():
    if case_name.startswith("yjson") and not case_name.startswith("yjsonAst"):
        CJFAST_META["cjfast" + case_name[len("yjson"):]] = meta

TIME_RE = re.compile(r"([0-9][0-9,]*(?:\.[0-9]+)?)\s*(ns|us|µs|μs|ms|s)\b", re.IGNORECASE)
HEADER_HINTS = ("case", "name", "bench", "benchmark", "function", "method")
LIBRARY_LABELS = {
    "yjson": "当前实现",
    "stdx_json": "stdx.json",
    "cjfast_json": "cjfast_json",
    "java_fastjson2": "Java fastjson2",
}
LIBRARY_ORDER = ("yjson", "stdx_json", "cjfast_json", "java_fastjson2")


def unit_to_ns(value: str, unit: str) -> float:
    numeric = float(value.replace(",", ""))
    normalized = unit.lower().replace("µ", "u").replace("μ", "u")
    if normalized == "ns":
        return numeric
    if normalized == "us":
        return numeric * 1_000.0
    if normalized == "ms":
        return numeric * 1_000_000.0
    if normalized == "s":
        return numeric * 1_000_000_000.0
    raise ValueError(f"unsupported unit: {unit}")


def split_table_cells(line: str) -> List[str]:
    if "|" not in line:
        return []
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def normalize_cangjie_case(raw: str) -> str:
    value = raw.strip().strip("`")
    value = value.split("(")[0]
    value = value.split()[-1] if value.split() else value
    value = value.split(".")[-1]
    return value


def detect_case(text: str, metadata: Dict[str, Meta]) -> Optional[str]:
    direct = normalize_cangjie_case(text)
    if direct in metadata:
        return direct
    for name in metadata:
        if re.search(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])", text):
            return name
    return None


def extract_time_from_cells(cells: Sequence[str], header: Sequence[str]) -> Optional[float]:
    preferred_indexes: List[int] = []
    for index, name in enumerate(header):
        lower = name.lower()
        if "median" in lower or "p50" in lower or lower == "med":
            preferred_indexes.append(index)
    preferred_indexes.extend(range(len(cells)))
    seen = set()
    for index in preferred_indexes:
        if index in seen or index >= len(cells):
            continue
        seen.add(index)
        match = TIME_RE.search(cells[index])
        if match:
            return unit_to_ns(match.group(1), match.group(2))
    return None


def parse_cangjie_output(text: str) -> List[Measurement]:
    rows: List[Measurement] = []
    header: List[str] = []
    seen_cases = set()
    for line in text.splitlines():
        cells = split_table_cells(line)
        if cells and any(any(hint in cell.lower() for hint in HEADER_HINTS) for cell in cells):
            header = cells
            continue

        case_name: Optional[str] = None
        if cells:
            case_name = detect_case(cells[0], CANGJIE_META)
        if case_name is None:
            case_name = detect_case(line, CANGJIE_META)
        if case_name is None:
            continue

        median_ns = extract_time_from_cells(cells, header) if cells else None
        if median_ns is None:
            match = TIME_RE.search(line)
            if match:
                median_ns = unit_to_ns(match.group(1), match.group(2))
        if median_ns is None or case_name in seen_cases:
            continue

        seen_cases.add(case_name)
        meta = CANGJIE_META[case_name]
        library = "stdx_json" if case_name.startswith("stdx") else "yjson"
        rows.append(Measurement(
            meta.scenario,
            meta.operation,
            meta.payload,
            library,
            meta.input_kind,
            median_ns,
            meta.notes,
            case_name,
        ))
    return rows


def parse_cjfast_output(text: str) -> List[Measurement]:
    rows: List[Measurement] = []
    header: List[str] = []
    seen_cases = set()
    for line in text.splitlines():
        cells = split_table_cells(line)
        if cells and any(any(hint in cell.lower() for hint in HEADER_HINTS) for cell in cells):
            header = cells
            continue
        case_name = detect_case(cells[0], CJFAST_META) if cells else None
        if case_name is None:
            case_name = detect_case(line, CJFAST_META)
        if case_name is None:
            continue
        median_ns = extract_time_from_cells(cells, header) if cells else None
        if median_ns is None:
            match = TIME_RE.search(line)
            if match:
                median_ns = unit_to_ns(match.group(1), match.group(2))
        if median_ns is None or case_name in seen_cases:
            continue
        seen_cases.add(case_name)
        meta = CJFAST_META[case_name]
        rows.append(Measurement(
            meta.scenario, meta.operation, meta.payload, "cjfast_json",
            meta.input_kind, median_ns, meta.notes, case_name,
        ))
    return rows


def parse_java_csv(text: str) -> List[Measurement]:
    lines = [line for line in text.splitlines() if line.strip()]
    start = next((i for i, line in enumerate(lines) if line.strip() == "case,medianNs"), None)
    if start is None:
        return []
    reader = csv.DictReader(lines[start:])
    rows: List[Measurement] = []
    for row in reader:
        case_name = (row.get("case") or "").strip()
        if case_name not in JAVA_META:
            continue
        meta = JAVA_META[case_name]
        rows.append(Measurement(
            meta.scenario,
            meta.operation,
            meta.payload,
            "java_fastjson2",
            meta.input_kind,
            float(row["medianNs"]),
            meta.notes,
            case_name,
        ))
    return rows


def run_cangjie_bench(cmd: str, out_dir: Path) -> str:
    print(f"[json-baseline] running Cangjie benchmark: {cmd}", file=sys.stderr)
    args = shlex.split(cmd)
    if not args:
        raise SystemExit("Cangjie benchmark command is empty")
    result = subprocess.run(
        args,
        cwd=str(ROOT),
        text=True,
        capture_output=True,
    )
    combined = result.stdout
    if result.stderr:
        combined += "\n" + result.stderr
    (out_dir / "cangjie_bench.log").write_text(combined, encoding="utf-8")
    if result.returncode != 0:
        raise SystemExit(f"Cangjie benchmark failed; see {out_dir / 'cangjie_bench.log'}")
    return combined


def run_java_bench(quick: bool, java_args: Sequence[str], out_dir: Path) -> str:
    args = ["benchmarks/java_fastjson2/run.sh"]
    if quick:
        args.append("--quick")
    args.extend(java_args)
    print(f"[json-baseline] running Java fastjson2 benchmark: {' '.join(args)}", file=sys.stderr)
    result = subprocess.run(args, cwd=str(ROOT), text=True, capture_output=True)
    (out_dir / "java_fastjson2.csv").write_text(result.stdout, encoding="utf-8")
    if result.stderr:
        (out_dir / "java_fastjson2.stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise SystemExit(f"Java fastjson2 benchmark failed; see {out_dir / 'java_fastjson2.stderr.log'}")
    return result.stdout


def run_cjfast_bench(cjfast_dir: Optional[str], out_dir: Path) -> str:
    args = ["benchmarks/cjfast_json/run.sh"]
    if cjfast_dir:
        args.append(cjfast_dir)
    print(f"[json-baseline] running cjfast_json benchmark: {' '.join(args)}", file=sys.stderr)
    result = subprocess.run(args, cwd=str(ROOT), text=True, capture_output=True)
    combined = result.stdout
    if result.stderr:
        combined += "\n" + result.stderr
    (out_dir / "cjfast_json_bench.log").write_text(combined, encoding="utf-8")
    if result.returncode != 0:
        raise SystemExit(f"cjfast_json benchmark failed; see {out_dir / 'cjfast_json_bench.log'}")
    return combined


def group_key(row: Measurement) -> Tuple[str, str, str, str]:
    return (row.scenario, row.operation, row.payload, row.input_kind)


def with_ratios(rows: Iterable[Measurement]) -> List[Tuple[Measurement, Optional[float]]]:
    rows = list(rows)
    baseline: Dict[Tuple[str, str, str, str], float] = {}
    for row in rows:
        if row.library == "yjson":
            baseline[group_key(row)] = row.median_ns
    result: List[Tuple[Measurement, Optional[float]]] = []
    for row in rows:
        base = baseline.get(group_key(row))
        ratio = None if base is None or base == 0 else row.median_ns / base
        result.append((row, ratio))
    return result


def write_csv(rows: List[Measurement], path: Path) -> None:
    enriched = with_ratios(rows)
    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.writer(file)
        writer.writerow([
            "scenario",
            "operation",
            "payload",
            "library",
            "input_kind",
            "median_ns",
            "median_us",
            "relative_to_yjson",
            "source_case",
            "notes",
        ])
        for row, ratio in enriched:
            writer.writerow([
                row.scenario,
                row.operation,
                row.payload,
                row.library,
                row.input_kind,
                f"{row.median_ns:.3f}",
                f"{row.median_ns / 1_000.0:.3f}",
                "" if ratio is None else f"{ratio:.3f}",
                row.source_case,
                row.notes,
            ])


def format_ns(value: Optional[float]) -> str:
    if value is None:
        return "-"
    return f"{value:,.0f}"


def format_ratio(value: Optional[float]) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


def markdown_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def write_markdown(rows: List[Measurement], path: Path) -> None:
    by_group: Dict[Tuple[str, str, str, str], Dict[str, Measurement]] = {}
    notes: Dict[Tuple[str, str, str, str], str] = {}
    for row in rows:
        key = group_key(row)
        by_group.setdefault(key, {})[row.library] = row
        if row.notes:
            notes[key] = row.notes

    table_rows: List[List[str]] = []
    for key in sorted(by_group):
        libs = by_group[key]
        current = libs.get("yjson")
        stdx = libs.get("stdx_json")
        cjfast = libs.get("cjfast_json")
        java = libs.get("java_fastjson2")
        base = current.median_ns if current is not None else None
        stdx_ratio = None if base is None or stdx is None else stdx.median_ns / base
        cjfast_ratio = None if base is None or cjfast is None else cjfast.median_ns / base
        java_ratio = None if base is None or java is None else java.median_ns / base
        table_rows.append([
            key[0],
            key[1],
            key[2].replace("|", "\\|"),
            key[3],
            format_ns(current.median_ns if current else None),
            format_ns(stdx.median_ns if stdx else None),
            format_ns(cjfast.median_ns if cjfast else None),
            format_ns(java.median_ns if java else None),
            format_ratio(stdx_ratio),
            format_ratio(cjfast_ratio),
            format_ratio(java_ratio),
            notes.get(key, ""),
        ])

    library_counts = {library: 0 for library in LIBRARY_ORDER}
    for row in rows:
        library_counts[row.library] = library_counts.get(row.library, 0) + 1
    summary_rows = [
        [LIBRARY_LABELS.get(library, library), str(count)]
        for library, count in library_counts.items()
        if count > 0
    ]

    content = [
        "# JSON 性能基线对比",
        "",
            f"- 当前实现：`yjson`",
        f"- 对比库：`stdx.encoding.json` / `cjfast_json` / `Java fastjson2`",
        f"- 指标：每次操作耗时，单位 ns；`x` 值为相对当前实现的倍数，越小越快。",
        "",
        "## 覆盖情况",
        "",
        markdown_table(["库", "样本数"], summary_rows),
        "",
        "## 场景透视表",
        "",
        markdown_table(
            [
                "场景",
                "操作",
                "载荷",
                "输入",
                "当前实现 ns",
                "stdx.json ns",
                "cjfast_json ns",
                "Java fastjson2 ns",
                "stdx/当前",
                "cjfast/当前",
                "fastjson2/当前",
                "备注",
            ],
            table_rows,
        ),
        "",
    ]
    path.write_text("\n".join(content), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help="output directory")
    parser.add_argument("--quick", action="store_true", help="pass --quick to Java benchmark")
    parser.add_argument("--skip-cangjie", action="store_true", help="do not run or parse Cangjie benchmark")
    parser.add_argument("--skip-java", action="store_true", help="do not run or parse Java fastjson2 benchmark")
    parser.add_argument("--skip-cjfast", action="store_true", help="do not run or parse cjfast_json benchmark")
    parser.add_argument("--cangjie-output", help="read an existing Cangjie benchmark log")
    parser.add_argument("--java-csv", help="read an existing Java fastjson2 CSV")
    parser.add_argument("--cjfast-output", help="read an existing cjfast_json benchmark log")
    parser.add_argument("--cjfast-dir", help="local cjfast_json checkout; otherwise clone the pinned revision")
    parser.add_argument(
        "--cangjie-cmd",
        default=os.environ.get("CANGJIE_BENCH_CMD", DEFAULT_CANGJIE_CMD),
        help="argv-style command used to run Cangjie benchmark",
    )
    parser.add_argument("--java-arg", action="append", default=[], help="extra argument passed to benchmarks/java_fastjson2/run.sh")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    measurements: List[Measurement] = []
    if not args.skip_cangjie:
        if args.cangjie_output:
            cangjie_text = Path(args.cangjie_output).read_text(encoding="utf-8")
        else:
            cangjie_text = run_cangjie_bench(args.cangjie_cmd, out_dir)
        cangjie_rows = parse_cangjie_output(cangjie_text)
        if not cangjie_rows:
            print("[json-baseline] warning: no Cangjie benchmark rows parsed", file=sys.stderr)
        measurements.extend(cangjie_rows)

    if not args.skip_java:
        if args.java_csv:
            java_text = Path(args.java_csv).read_text(encoding="utf-8")
        else:
            java_text = run_java_bench(args.quick, args.java_arg, out_dir)
        java_rows = parse_java_csv(java_text)
        if not java_rows:
            print("[json-baseline] warning: no Java benchmark rows parsed", file=sys.stderr)
        measurements.extend(java_rows)

    if not args.skip_cjfast:
        if args.cjfast_output:
            cjfast_text = Path(args.cjfast_output).read_text(encoding="utf-8")
        else:
            cjfast_text = run_cjfast_bench(args.cjfast_dir, out_dir)
        cjfast_rows = parse_cjfast_output(cjfast_text)
        if not cjfast_rows:
            print("[json-baseline] warning: no cjfast_json benchmark rows parsed", file=sys.stderr)
        measurements.extend(cjfast_rows)

    measurements.sort(key=lambda row: (
        row.scenario,
        row.operation,
        row.payload,
        row.input_kind,
        LIBRARY_ORDER.index(row.library) if row.library in LIBRARY_ORDER else len(LIBRARY_ORDER),
    ))
    csv_path = out_dir / "json_perf_baseline.csv"
    md_path = out_dir / "json_perf_baseline.md"
    write_csv(measurements, csv_path)
    write_markdown(measurements, md_path)
    print(f"[json-baseline] wrote {csv_path}")
    print(f"[json-baseline] wrote {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
