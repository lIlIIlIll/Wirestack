#!/usr/bin/env python3
"""Summarize paired baseline/candidate Person hot-path Server samples."""

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
    parser.add_argument("--min-runs", type=int, default=11)
    parser.add_argument("--screen", action="store_true")
    parser.add_argument("--perf-stat", type=Path)
    args = parser.parse_args()

    timings: dict[tuple[int, str, str], float] = {}
    by_side: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_count: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_freed: dict[tuple[str, str], list[float]] = defaultdict(list)
    rss: dict[tuple[str, str], list[float]] = defaultdict(list)
    with args.csv.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            key = (row["side"], row["case"])
            value = float(row["ns_per_op"])
            timings[(int(row["round"]), row["side"], row["case"])] = value
            by_side[key].append(value)
            gc_count[key].append(float(row["gc_count"]))
            gc_freed[key].append(float(row["gc_freed_bytes"]))
            rss[key].append(float(row["rss_kib"]))

    print("| Case | Baseline | Candidate | Paired gain | Positive pairs | CV B/C | RSS delta |")
    print("|:--|--:|--:|--:|--:|--:|--:|")
    passed = True
    person_gains: list[float] = []
    for case in sorted({case for _, case in by_side}):
        round_ids = sorted({round_id for round_id, _, item_case in timings if item_case == case})
        complete = [
            round_id for round_id in round_ids
            if (round_id, "baseline", case) in timings and (round_id, "candidate", case) in timings
        ]
        paired = [
            (timings[(round_id, "baseline", case)] - timings[(round_id, "candidate", case)]) /
            timings[(round_id, "baseline", case)] * 100.0
            for round_id in complete
        ]
        gain = statistics.median(paired)
        positives = sum(value >= 0.0 for value in paired)
        baseline = by_side[("baseline", case)]
        candidate = by_side[("candidate", case)]
        baseline_rss = statistics.median(rss[("baseline", case)])
        candidate_rss = statistics.median(rss[("candidate", case)])
        rss_delta = (candidate_rss - baseline_rss) / baseline_rss * 100.0
        if len(complete) < args.min_runs:
            passed = False
        if case.startswith("person-"):
            person_gains.append(gain)
            if args.screen:
                passed = passed and gain >= 0.0
            else:
                passed = passed and gain >= 10.0
        else:
            passed = passed and gain >= (-1.0 if args.screen else 0.0)
        passed = passed and positives >= args.min_runs // 2 + 1
        if not args.screen:
            passed = passed and max(cv(baseline), cv(candidate)) <= 3.0 and rss_delta <= 2.0
        print(
            f"| {case} | {statistics.median(baseline):.3f} ns | {statistics.median(candidate):.3f} ns | "
            f"{gain:+.2f}% | {positives}/{len(complete)} | {cv(baseline):.2f}/{cv(candidate):.2f}% | {rss_delta:+.2f}% |"
        )

    if args.screen:
        passed = passed and max(person_gains) >= 2.0
    baseline_gc_count = sum(statistics.median(values) for (side, case), values in gc_count.items() if side == "baseline" and case.startswith("person-"))
    candidate_gc_count = sum(statistics.median(values) for (side, case), values in gc_count.items() if side == "candidate" and case.startswith("person-"))
    baseline_gc_freed = sum(statistics.median(values) for (side, case), values in gc_freed.items() if side == "baseline" and case.startswith("person-"))
    candidate_gc_freed = sum(statistics.median(values) for (side, case), values in gc_freed.items() if side == "candidate" and case.startswith("person-"))
    count_drop = 0.0 if baseline_gc_count == 0.0 else (baseline_gc_count - candidate_gc_count) / baseline_gc_count * 100.0
    freed_drop = 0.0 if baseline_gc_freed == 0.0 else (baseline_gc_freed - candidate_gc_freed) / baseline_gc_freed * 100.0
    if not args.screen:
        passed = passed and (count_drop >= 10.0 or freed_drop >= 10.0)

    counter_text = "not evaluated"
    if args.perf_stat is not None:
        counters: dict[tuple[str, str], list[float]] = defaultdict(list)
        with args.perf_stat.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                counters[(row["side"], "cycles")].append(float(row["cycles"]))
                counters[(row["side"], "instructions")].append(float(row["instructions"]))
        cycle_drop = (statistics.median(counters[("baseline", "cycles")]) - statistics.median(counters[("candidate", "cycles")])) / statistics.median(counters[("baseline", "cycles")]) * 100.0
        instruction_drop = (statistics.median(counters[("baseline", "instructions")]) - statistics.median(counters[("candidate", "instructions")])) / statistics.median(counters[("baseline", "instructions")]) * 100.0
        counter_ok = min(len(values) for values in counters.values()) >= 5 and (cycle_drop >= 5.0 or instruction_drop >= 5.0)
        passed = passed and counter_ok
        counter_text = f"cycles {cycle_drop:+.2f}%, instructions {instruction_drop:+.2f}% ({'PASS' if counter_ok else 'FAIL'})"

    print(f"\nPerson GC count drop: {count_drop:+.2f}%")
    print(f"Person GC-freed bytes drop: {freed_drop:+.2f}%")
    print(f"Counter gate: {counter_text}")
    print(f"Overall gate: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
