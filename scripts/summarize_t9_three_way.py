#!/usr/bin/env python3
"""Validate and summarize the three T9 throughput result directories."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

from run_t9_throughput import CASES


def load(root: Path) -> tuple[list[str], dict[str, float], dict[str, object]]:
    if not (root / "COMPLETE").is_file():
        raise RuntimeError(f"incomplete result directory: {root}")
    with (root / "metadata.json").open(encoding="utf-8") as stream:
        metadata = json.load(stream)
    if metadata.get("suite") != "T9ThroughputBench":
        raise RuntimeError(f"unexpected benchmark suite in {root}: {metadata.get('suite')!r}")
    if metadata.get("cases") != list(CASES):
        raise RuntimeError(f"metadata case contract differs in {root}")
    if metadata.get("runs") != 1:
        raise RuntimeError(f"comparison requires metadata runs=1: {root}")
    with (root / "summary.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 22:
        raise RuntimeError(f"expected 22 cases in {root}, got {len(rows)}")
    if any(int(row["runs"]) != 1 for row in rows):
        raise RuntimeError(f"comparison requires exactly one run per case: {root}")
    order = [row["case"] for row in rows]
    if order != list(CASES):
        raise RuntimeError(f"summary case contract differs in {root}")
    with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        manifest = list(csv.DictReader(stream))
    if len(manifest) != len(CASES) or [row["case"] for row in manifest] != list(CASES):
        raise RuntimeError(f"raw manifest case contract differs in {root}")
    for row in manifest:
        report = root / row["report"]
        log = root / row["log"]
        if not report.is_dir() or not log.is_file():
            raise RuntimeError(f"raw evidence is missing for {row['case']} in {root}")
    return order, {row["case"]: float(row["median_us"]) for row in rows}, metadata


def require_same(label: str, values: list[object]) -> None:
    if any(value is None or value == "" for value in values):
        raise RuntimeError(f"{label} identity is missing: {values!r}")
    if any(value != values[0] for value in values[1:]):
        raise RuntimeError(f"{label} differs between result directories: {values!r}")


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json4cj-server", type=Path, required=True)
    parser.add_argument("--yjson-server", type=Path, required=True)
    parser.add_argument("--yjson-server-daily", type=Path, required=True)
    parser.add_argument("--jackson-server", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    order, json4cj, json4cj_meta = load(args.json4cj_server)
    yjson_server_order, yjson_server, yjson_server_meta = load(args.yjson_server)
    yjson_daily_order, yjson_daily, yjson_daily_meta = load(args.yjson_server_daily)
    jackson = None
    if args.jackson_server is not None:
        jackson_order, jackson, jackson_meta = load(args.jackson_server)
        if order != jackson_order:
            raise RuntimeError("Jackson case order or case set differs")
        require_same("Jackson host", [json4cj_meta.get("host"), jackson_meta.get("host")])
        require_same("Jackson CPU", [json4cj_meta.get("cpu"), jackson_meta.get("cpu")])
    if order != yjson_server_order or order != yjson_daily_order:
        raise RuntimeError("case order or case set differs between result directories")
    all_meta = [json4cj_meta, yjson_server_meta, yjson_daily_meta]
    require_same("host", [meta.get("host") for meta in all_meta])
    require_same("platform", [meta.get("platform") for meta in all_meta])
    require_same("CPU", [meta.get("cpu") for meta in all_meta])
    msgc_meta = [json4cj_meta, yjson_server_meta]
    require_same("MSGC compiler", [meta.get("cjc") for meta in msgc_meta])
    require_same("MSGC cjpm", [meta.get("cjpm") for meta in msgc_meta])
    require_same("MSGC heap", [meta.get("cj_heap_size") for meta in msgc_meta])
    require_same("MSGC stdx path", [meta.get("cangjie_stdx_path") for meta in msgc_meta])
    if json4cj_meta.get("cfg") is not True or yjson_server_meta.get("cfg") is not True:
        raise RuntimeError("json4cj and yjson MSGC results must use --cfg")
    if yjson_server_meta.get("skip_script") is not True:
        raise RuntimeError("yjson MSGC result must use --skip-script")

    args.output.mkdir(parents=True, exist_ok=True)
    csv_path = args.output / "comparison.csv"
    server_ratios: list[float] = []
    host_sdk_ratios: list[float] = []
    jackson_ratios: list[float] = []
    json4cj_jackson_ratios: list[float] = []
    ratio_groups: dict[str, list[float]] = {
        "serialize": [], "deserialize": [], "roundtrip": []
    }
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        columns = [
            "case",
            "json4cj_server_us",
            "yjson_server_us",
            "yjson_server_daily_us",
            "yjson_vs_json4cj_same_server_x",
            "yjson_daily_vs_json4cj_same_server_x",
            "yjson_daily_vs_msgc_same_server_x",
        ]
        if jackson is not None:
            columns.extend((
                "jackson_server_us", "yjson_vs_jackson_same_server_x",
                "json4cj_vs_jackson_same_server_x",
            ))
        writer.writerow(columns)
        for case in order:
            server_ratio = yjson_server[case] / json4cj[case]
            host_sdk_ratio = yjson_daily[case] / yjson_server[case]
            server_ratios.append(server_ratio)
            host_sdk_ratios.append(host_sdk_ratio)
            group = "roundtrip" if "RoundTrip" in case else (
                "deserialize" if "Deserialize" in case else "serialize"
            )
            ratio_groups[group].append(server_ratio)
            row = [
                case,
                f"{json4cj[case]:.6f}",
                f"{yjson_server[case]:.6f}",
                f"{yjson_daily[case]:.6f}",
                f"{server_ratio:.3f}",
                f"{yjson_daily[case] / json4cj[case]:.3f}",
                f"{host_sdk_ratio:.3f}",
            ]
            if jackson is not None:
                jackson_ratio = yjson_server[case] / jackson[case]
                json4cj_jackson_ratio = json4cj[case] / jackson[case]
                jackson_ratios.append(jackson_ratio)
                json4cj_jackson_ratios.append(json4cj_jackson_ratio)
                row.extend((
                    f"{jackson[case]:.6f}", f"{jackson_ratio:.3f}",
                    f"{json4cj_jackson_ratio:.3f}",
                ))
            writer.writerow(row)

    markdown = [
        "> One-run snapshot (`--runs 1`); this is not release performance qualification.",
        "",
        ("| Workload | json4cj us/op | yjson msgc us/op | yjson daily us/op | "
         "msgc/json4cj | daily/json4cj | daily/msgc |" +
         (" Jackson us/op | msgc/Jackson | json4cj/Jackson |" if jackson is not None else "")),
        ("|---|---:|---:|---:|---:|---:|---:|" +
         ("---:|---:|---:|" if jackson is not None else "")),
    ]
    for case in order:
        ratio = yjson_server[case] / json4cj[case]
        line = (
            f"| {case} | {json4cj[case]:.3f} | {yjson_server[case]:.3f} | "
            f"{yjson_daily[case]:.3f} | {ratio:.2f}x | "
            f"{yjson_daily[case] / json4cj[case]:.2f}x | "
            f"{yjson_daily[case] / yjson_server[case]:.2f}x |"
        )
        if jackson is not None:
            line += (
                f" {jackson[case]:.3f} | {yjson_server[case] / jackson[case]:.2f}x | "
                f"{json4cj[case] / jackson[case]:.2f}x |"
            )
        markdown.append(line)
    markdown.extend([
        "",
        f"Same-Server yjson/json4cj geometric mean: {geomean(server_ratios):.3f}x.",
        f"Same-Server daily yjson/json4cj geometric mean: {geomean(server_ratios) * geomean(host_sdk_ratios):.3f}x.",
        f"Serialize geometric mean: {geomean(ratio_groups['serialize']):.3f}x.",
        f"Deserialize geometric mean: {geomean(ratio_groups['deserialize']):.3f}x.",
        f"Round-trip ratio: {geomean(ratio_groups['roundtrip']):.3f}x.",
        "",
        f"Same-Server daily/msgc yjson geometric mean: {geomean(host_sdk_ratios):.3f}x.",
    ])
    if jackson_ratios:
        markdown.extend((
            f"Same-Server yjson MSGC/Jackson geometric mean: {geomean(jackson_ratios):.3f}x.",
            f"Same-Server json4cj/Jackson geometric mean: {geomean(json4cj_jackson_ratios):.3f}x.",
        ))
    (args.output / "comparison.md").write_text("\n".join(markdown) + "\n", encoding="utf-8")
    print(f"wrote {csv_path}")
    print(f"same-server geomean yjson/json4cj: {geomean(server_ratios):.3f}x")
    print(f"same-server yjson daily/msgc geomean: {geomean(host_sdk_ratios):.3f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
