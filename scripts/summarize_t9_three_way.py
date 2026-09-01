#!/usr/bin/env python3
"""Validate and summarize the three T9 throughput result directories."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path


def load(root: Path) -> tuple[list[str], dict[str, float]]:
    if not (root / "COMPLETE").is_file():
        raise RuntimeError(f"incomplete result directory: {root}")
    with (root / "summary.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 22:
        raise RuntimeError(f"expected 22 cases in {root}, got {len(rows)}")
    if any(int(row["runs"]) != 1 for row in rows):
        raise RuntimeError(f"comparison requires exactly one run per case: {root}")
    order = [row["case"] for row in rows]
    return order, {row["case"]: float(row["median_us"]) for row in rows}


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json4cj-server", type=Path, required=True)
    parser.add_argument("--yjson-server", type=Path, required=True)
    parser.add_argument("--yjson-server-daily", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    order, json4cj = load(args.json4cj_server)
    yjson_server_order, yjson_server = load(args.yjson_server)
    yjson_daily_order, yjson_daily = load(args.yjson_server_daily)
    if order != yjson_server_order or order != yjson_daily_order:
        raise RuntimeError("case order or case set differs between result directories")

    args.output.mkdir(parents=True, exist_ok=True)
    csv_path = args.output / "comparison.csv"
    server_ratios: list[float] = []
    host_sdk_ratios: list[float] = []
    ratio_groups: dict[str, list[float]] = {
        "serialize": [], "deserialize": [], "roundtrip": []
    }
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow([
            "case",
            "json4cj_server_us",
            "yjson_server_us",
            "yjson_server_daily_us",
            "yjson_vs_json4cj_same_server_x",
            "yjson_daily_vs_json4cj_same_server_x",
            "yjson_daily_vs_msgc_same_server_x",
        ])
        for case in order:
            server_ratio = yjson_server[case] / json4cj[case]
            host_sdk_ratio = yjson_daily[case] / yjson_server[case]
            server_ratios.append(server_ratio)
            host_sdk_ratios.append(host_sdk_ratio)
            group = "roundtrip" if "RoundTrip" in case else (
                "deserialize" if "Deserialize" in case else "serialize"
            )
            ratio_groups[group].append(server_ratio)
            writer.writerow([
                case,
                f"{json4cj[case]:.6f}",
                f"{yjson_server[case]:.6f}",
                f"{yjson_daily[case]:.6f}",
                f"{server_ratio:.3f}",
                f"{yjson_daily[case] / json4cj[case]:.3f}",
                f"{host_sdk_ratio:.3f}",
            ])

    markdown = [
        "| Workload | json4cj us/op | yjson msgc us/op | yjson daily us/op | msgc/json4cj | daily/json4cj | daily/msgc |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for case in order:
        ratio = yjson_server[case] / json4cj[case]
        markdown.append(
            f"| {case} | {json4cj[case]:.3f} | {yjson_server[case]:.3f} | "
            f"{yjson_daily[case]:.3f} | {ratio:.2f}x | "
            f"{yjson_daily[case] / json4cj[case]:.2f}x | "
            f"{yjson_daily[case] / yjson_server[case]:.2f}x |"
        )
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
    (args.output / "comparison.md").write_text("\n".join(markdown) + "\n", encoding="utf-8")
    print(f"wrote {csv_path}")
    print(f"same-server geomean yjson/json4cj: {geomean(server_ratios):.3f}x")
    print(f"same-server yjson daily/msgc geomean: {geomean(host_sdk_ratios):.3f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
