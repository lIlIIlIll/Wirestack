#!/usr/bin/env python3
"""Summarize alternating Server samples for fast decoder sessions."""

from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path


def cv(values: list[float]) -> float:
    mean = statistics.fmean(values)
    return 0.0 if mean == 0.0 else statistics.pstdev(values) / mean * 100.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    args = parser.parse_args()
    values: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_counts: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_freed: dict[tuple[str, str], list[float]] = defaultdict(list)
    with args.csv.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            values[(row["side"], row["case"])].append(float(row["ns_per_op"]))
            gc_counts[(row["side"], row["case"])].append(float(row["gc_count"]))
            gc_freed[(row["side"], row["case"])].append(float(row["gc_freed_bytes"]))

    print("| Case | Baseline | Candidate decoder | Session | Session gain | Decoder delta | CV B/C/S |")
    print("|:--|--:|--:|--:|--:|--:|--:|")
    gains: list[float] = []
    passed = True
    for case in sorted({case for _, case in values}):
        baseline = values[("baseline", case)]
        decoder = values[("candidate_decoder", case)]
        session = values[("candidate_session", case)]
        if min(len(baseline), len(decoder), len(session)) < 11:
            passed = False
        bmed = statistics.median(baseline)
        dmed = statistics.median(decoder)
        smed = statistics.median(session)
        gain = (bmed - smed) / bmed * 100.0
        decoder_delta = (dmed - bmed) / bmed * 100.0
        gains.append(gain)
        case_ok = gain >= (8.0 if case.startswith("profile-") else 0.0)
        case_ok = case_ok and decoder_delta <= 2.0 and max(cv(baseline), cv(decoder), cv(session)) <= 3.0
        passed = passed and case_ok
        print(
            f"| {case} | {bmed:.3f} ns | {dmed:.3f} ns | {smed:.3f} ns | "
            f"{gain:+.2f}% | {decoder_delta:+.2f}% | "
            f"{cv(baseline):.2f}/{cv(decoder):.2f}/{cv(session):.2f}% |"
        )
    overall = statistics.median(gains)
    passed = passed and overall >= 10.0
    baseline_gc_count = sum(statistics.median(items) for (side, _), items in gc_counts.items() if side == "baseline")
    session_gc_count = sum(statistics.median(items) for (side, _), items in gc_counts.items() if side == "candidate_session")
    baseline_gc_freed = sum(statistics.median(items) for (side, _), items in gc_freed.items() if side == "baseline")
    session_gc_freed = sum(statistics.median(items) for (side, _), items in gc_freed.items() if side == "candidate_session")
    gc_count_drop = 0.0 if baseline_gc_count == 0.0 else (baseline_gc_count - session_gc_count) / baseline_gc_count * 100.0
    gc_freed_drop = 0.0 if baseline_gc_freed == 0.0 else (baseline_gc_freed - session_gc_freed) / baseline_gc_freed * 100.0
    gc_passed = gc_count_drop >= 20.0 or gc_freed_drop >= 20.0
    passed = passed and gc_passed
    print(f"\nOverall median session gain: {overall:+.2f}%")
    print(f"Aggregate GC count drop: {gc_count_drop:+.2f}%")
    print(f"Aggregate GC-freed bytes drop: {gc_freed_drop:+.2f}%")
    print(f"GC gate: {'PASS' if gc_passed else 'FAIL'}")
    print(f"Latency gate: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
