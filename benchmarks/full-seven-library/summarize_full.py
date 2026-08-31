#!/usr/bin/env python3
"""Summarize one complete seven-library benchmark batch.

Every raw report is bound to the exact case recorded in ``manifest.csv``.
This is deliberately stricter than accepting every sample emitted below a
report directory: a prefix filter can otherwise run several benchmark cases
and silently mix their timings.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import statistics
from collections import defaultdict
from typing import Callable


LIBRARIES = (
    "yjson",
    "stdx_json",
    "cangjieJSON",
    "json4cj",
    "cjfast_json",
    "jackson",
    "fastjson2",
)
JAVA_LIBRARIES = {"jackson", "fastjson2"}
UNITS = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}
MANIFEST_COLUMNS = {
    "round",
    "library",
    "workload_id",
    "scenario",
    "operation",
    "payload",
    "source_case",
    "report_path",
}


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] * (upper - position) + ordered[upper] * (position - lower)


def _finite_non_negative(value: str, label: str) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise ValueError(f"{label} is not numeric: {value!r}") from error
    if not math.isfinite(result) or result < 0.0:
        raise ValueError(f"{label} must be finite and non-negative")
    return result


def _relative_report(root: pathlib.Path, raw: str) -> pathlib.Path:
    relative = pathlib.PurePosixPath(raw)
    if relative.is_absolute() or not relative.parts or any(
        part in ("", ".", "..") for part in relative.parts
    ):
        raise ValueError(f"unsafe manifest report_path: {raw!r}")
    candidate = root.joinpath(*relative.parts)
    resolved_root = root.resolve()
    resolved = candidate.resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as error:
        raise ValueError(f"manifest report_path escapes result root: {raw!r}") from error
    if not resolved.is_dir():
        raise ValueError(f"manifest report_path is not a directory: {raw!r}")
    return resolved


def inspect_cangjie_report(path: pathlib.Path) -> dict[str, object]:
    reports = sorted(path.rglob("bench-*.csv"))
    if not reports:
        raise ValueError(f"no Cangjie CSV report in {path}")

    case_files: dict[str, set[str]] = defaultdict(set)
    values: dict[str, list[float]] = defaultdict(list)
    for report in reports:
        relative = report.relative_to(path).as_posix()
        try:
            stream = report.open(newline="", encoding="utf-8")
        except OSError as error:
            raise ValueError(f"cannot read Cangjie report {report}: {error}") from error
        with stream:
            reader = csv.DictReader(stream)
            required = {"Case", "BatchSize", "Duration", "Unit", "Measurement"}
            if reader.fieldnames is None or not required.issubset(reader.fieldnames):
                raise ValueError(f"Cangjie report columns are incomplete: {report}")
            for line_number, row in enumerate(reader, 2):
                case = (row.get("Case") or "").strip()
                if not case:
                    raise ValueError(f"empty Case in {report}:{line_number}")
                case_files[case].add(relative)
                if row.get("Measurement") != "Duration":
                    continue
                try:
                    batch_size = int(row["BatchSize"])
                except (TypeError, ValueError) as error:
                    raise ValueError(
                        f"invalid BatchSize in {report}:{line_number}: {row.get('BatchSize')!r}"
                    ) from error
                if batch_size <= 0:
                    continue
                unit = row.get("Unit")
                if unit not in UNITS:
                    raise ValueError(f"unsupported Unit in {report}:{line_number}: {unit!r}")
                duration = _finite_non_negative(
                    row.get("Duration") or "", f"Duration in {report}:{line_number}"
                )
                values[case].append(duration * UNITS[unit] / batch_size)

    return {
        "report_files": tuple(report.relative_to(path).as_posix() for report in reports),
        "case_files": {case: tuple(sorted(files)) for case, files in case_files.items()},
        "values": dict(values),
    }


def values_for_expected_case(inventory: dict[str, object], expected_case: str) -> list[float]:
    case_files = inventory["case_files"]
    values = inventory["values"]
    report_files = inventory["report_files"]
    assert isinstance(case_files, dict)
    assert isinstance(values, dict)
    assert isinstance(report_files, tuple)

    actual_cases = set(case_files)
    errors: list[str] = []
    if expected_case not in actual_cases:
        errors.append(f"missing Case {expected_case!r}")
    extra = sorted(actual_cases - {expected_case})
    if extra:
        errors.append(f"extra Case values {extra}")
    expected_files = case_files.get(expected_case, ())
    if len(expected_files) > 1:
        errors.append(f"duplicate Case {expected_case!r} across reports {list(expected_files)}")
    if len(report_files) != 1:
        errors.append(f"expected one Cangjie CSV report, found {len(report_files)}")
    expected_values = values.get(expected_case, [])
    if expected_case in actual_cases and not expected_values:
        errors.append(f"Case {expected_case!r} has no positive-batch Duration samples")
    if errors:
        raise ValueError("; ".join(errors))
    return list(expected_values)


def load_cangjie_case(path: pathlib.Path, expected_case: str) -> list[float]:
    return values_for_expected_case(inspect_cangjie_report(path), expected_case)


def load_jmh_case(path: pathlib.Path, expected_case: str) -> list[float]:
    report = path / "jmh.json"
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid JMH report {report}: {error}") from error
    if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
        raise ValueError(f"expected exactly one JMH Case in {report}")
    actual = payload[0].get("benchmark")
    expected = f"bench.OptimalJsonBench.{expected_case}"
    if actual != expected:
        raise ValueError(f"JMH Case mismatch: expected {expected!r}, got {actual!r}")
    metric = payload[0].get("primaryMetric")
    if not isinstance(metric, dict) or metric.get("scoreUnit") != "ns/op":
        raise ValueError(f"unexpected JMH primary metric in {report}")
    score = _finite_non_negative(str(metric.get("score")), f"JMH score in {report}")
    return [score]


CaseLoader = Callable[[pathlib.Path, dict[str, str]], list[float]]


def _default_case_loader(root: pathlib.Path, row: dict[str, str]) -> list[float]:
    report = _relative_report(root, row["report_path"])
    if row["library"] in JAVA_LIBRARIES:
        return load_jmh_case(report, row["source_case"])
    return load_cangjie_case(report, row["source_case"])


def collect_samples(
    root: pathlib.Path,
    rows: list[dict[str, str]],
    loader: CaseLoader | None = None,
) -> tuple[dict[tuple[str, str], dict[int, list[float]]], dict[str, dict[str, str]]]:
    load = loader or _default_case_loader
    samples: dict[tuple[str, str], dict[int, list[float]]] = defaultdict(dict)
    metadata: dict[str, dict[str, str]] = {}
    seen_cells: set[tuple[int, str, str]] = set()
    seen_reports: dict[str, tuple[int, str, str]] = {}
    errors: list[str] = []

    if not rows:
        raise ValueError("manifest has no benchmark cells")

    for row_number, row in enumerate(rows, 2):
        missing = sorted(MANIFEST_COLUMNS - set(row))
        if missing:
            errors.append(f"manifest row {row_number} omits {missing}")
            continue
        try:
            round_number = int(row["round"])
        except ValueError:
            errors.append(f"manifest row {row_number} has invalid round {row['round']!r}")
            continue
        if round_number <= 0:
            errors.append(f"manifest row {row_number} has non-positive round")
            continue
        if row["library"] not in LIBRARIES:
            errors.append(f"manifest row {row_number} has unknown library {row['library']!r}")
            continue
        if not row["source_case"]:
            errors.append(f"manifest row {row_number} has empty source_case")
            continue

        cell = (round_number, row["workload_id"], row["library"])
        if cell in seen_cells:
            errors.append(f"duplicate manifest cell {cell}")
            continue
        seen_cells.add(cell)
        report_path = row["report_path"]
        previous_cell = seen_reports.get(report_path)
        if previous_cell is not None:
            errors.append(
                f"manifest report_path {report_path!r} is shared by {previous_cell} and {cell}"
            )
            continue
        seen_reports[report_path] = cell
        try:
            values = load(root, row)
        except (OSError, UnicodeError, ValueError) as error:
            errors.append(
                f"round={round_number} workload={row['workload_id']} "
                f"library={row['library']} source_case={row['source_case']!r}: {error}"
            )
            continue
        if not values:
            errors.append(f"manifest row {row_number} produced no samples")
            continue
        samples[(row["workload_id"], row["library"])][round_number] = values
        shape = {key: row[key] for key in ("scenario", "operation", "payload")}
        previous = metadata.get(row["workload_id"])
        if previous is not None and previous != shape:
            errors.append(f"inconsistent workload metadata for {row['workload_id']}")
        else:
            metadata[row["workload_id"]] = shape

    if errors:
        preview = " | ".join(errors[:3])
        if len(errors) > 3:
            preview += f" | ... ({len(errors)} total)"
        raise ValueError(
            f"{len(errors)}/{len(rows)} benchmark cells violate manifest/source-case binding: {preview}"
        )
    return samples, metadata


def summarize(round_values: dict[int, list[float]]) -> dict[str, object]:
    medians = [statistics.median(round_values[round_number]) for round_number in sorted(round_values)]
    median = statistics.median(medians)
    mean = statistics.fmean(medians)
    return {
        "runs": len(medians),
        "median_ns": median,
        "p95_ns": percentile(medians, 0.95),
        "cv_percent": statistics.pstdev(medians) / mean * 100.0 if mean else 0.0,
        "mad_percent": statistics.median(abs(value - median) for value in medians) / median * 100.0
        if median
        else 0.0,
        "run_medians_ns": medians,
    }


def paired(
    yjson_runs: dict[int, list[float]],
    peer_runs: dict[int, list[float]],
    rounds: list[int],
) -> dict[str, object]:
    ratios = [
        statistics.median(yjson_runs[round_number])
        / statistics.median(peer_runs[round_number])
        for round_number in rounds
    ]
    return {
        "median_yjson_over_peer": statistics.median(ratios),
        "p95_yjson_over_peer": percentile(ratios, 0.95),
        "yjson_faster_rounds": sum(value < 1.0 for value in ratios),
        "ratios": ratios,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--min-runs", type=int, default=11)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream))
        samples, metadata = collect_samples(root, rows)
    except (OSError, UnicodeError, csv.Error, ValueError) as error:
        parser.error(str(error))

    result_rows: list[dict[str, object]] = []
    for workload_id, shape in metadata.items():
        library_runs = {library: samples[(workload_id, library)] for library in LIBRARIES}
        common = sorted(set.intersection(*(set(value) for value in library_runs.values())))
        if len(common) < args.min_runs:
            parser.error(f"{workload_id}: only {len(common)} complete rounds")
        libraries = {
            library: summarize(
                {round_number: library_runs[library][round_number] for round_number in common}
            )
            for library in LIBRARIES
        }
        comparisons = {
            library: paired(library_runs["yjson"], library_runs[library], common)
            for library in LIBRARIES
            if library != "yjson"
        }
        result_rows.append(
            {
                "workload_id": workload_id,
                **shape,
                "rounds": len(common),
                "libraries": libraries,
                "paired": comparisons,
                "stable_cv_le_5_percent": max(
                    value["cv_percent"] for value in libraries.values()
                )
                <= 5.0,
            }
        )

    (root / "summary.json").write_text(
        json.dumps(result_rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    headers = ["workload_id", "scenario", "operation", "payload", "rounds"]
    for library in LIBRARIES:
        headers += [f"{library}_median_ns", f"{library}_cv_percent"]
    for library in LIBRARIES:
        if library != "yjson":
            headers += [f"paired_yjson_over_{library}", f"yjson_faster_rounds_vs_{library}"]
    headers += ["stable_cv_le_5_percent"]
    with (root / "summary.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=headers)
        writer.writeheader()
        for row in result_rows:
            output = {
                key: row[key] for key in ("workload_id", "scenario", "operation", "payload", "rounds")
            }
            libraries = row["libraries"]
            comparisons = row["paired"]
            assert isinstance(libraries, dict)
            assert isinstance(comparisons, dict)
            for library in LIBRARIES:
                output[f"{library}_median_ns"] = f"{libraries[library]['median_ns']:.3f}"
                output[f"{library}_cv_percent"] = f"{libraries[library]['cv_percent']:.3f}"
            for library, comparison in comparisons.items():
                output[f"paired_yjson_over_{library}"] = (
                    f"{comparison['median_yjson_over_peer']:.6f}"
                )
                output[f"yjson_faster_rounds_vs_{library}"] = comparison["yjson_faster_rounds"]
            output["stable_cv_le_5_percent"] = row["stable_cv_le_5_percent"]
            writer.writerow(output)

    completed_rounds = min(int(row["rounds"]) for row in result_rows)
    lines = [
        "# Full optimal-public-API JSON benchmark",
        "",
        f"Times are median ns/op across {completed_rounds} independent process rounds. Lower is better.",
        "",
        "| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |",
        "|:--|--:|--:|--:|--:|--:|--:|--:|--:|",
    ]
    for row in result_rows:
        libraries = row["libraries"]
        assert isinstance(libraries, dict)
        values = [libraries[library]["median_ns"] for library in LIBRARIES]
        cvs = [libraries[library]["cv_percent"] for library in LIBRARIES]
        lines.append(
            "| "
            + str(row["workload_id"])
            + " | "
            + " | ".join(f"{value / 1000.0:.3f} us" for value in values)
            + f" | {max(cvs):.2f}% |"
        )
    (root / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
