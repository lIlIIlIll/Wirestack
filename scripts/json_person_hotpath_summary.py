#!/usr/bin/env python3
"""Summarize paired Borrowed View Server samples and enforce release gates."""

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
    parser.add_argument("--screen-person-best", type=float, default=2.0)
    parser.add_argument("--screen-guard-floor", type=float, default=-1.0)
    parser.add_argument("--screen-gc-drop", type=float, default=0.0)
    parser.add_argument("--profile-address-min-gain", type=float, default=50.0)
    parser.add_argument("--person-min-gain", type=float, default=10.0)
    parser.add_argument("--ordinary-max-regression", type=float, default=2.0)
    parser.add_argument("--gc-min-drop", type=float, default=20.0)
    parser.add_argument("--rss-max-increase", type=float, default=2.0)
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

    sides = {side for side, _ in by_side}
    view_side = "candidate_view" if "candidate_view" in sides else "candidate"
    owned_side = "candidate_owned" if "candidate_owned" in sides else None
    print("| Case | Baseline | View | Paired gain | Positive pairs | CV B/V | Session RSS delta | Owned gain/CV |")
    print("|:--|--:|--:|--:|--:|--:|--:|--:|")
    passed = True
    person_gains: list[float] = []
    for case in sorted({case for _, case in by_side}):
        round_ids = sorted({round_id for round_id, _, item_case in timings if item_case == case})
        complete = [
            round_id for round_id in round_ids
            if (round_id, "baseline", case) in timings and (round_id, view_side, case) in timings
        ]
        paired = [
            (timings[(round_id, "baseline", case)] - timings[(round_id, view_side, case)]) /
            timings[(round_id, "baseline", case)] * 100.0
            for round_id in complete
        ]
        gain = statistics.median(paired)
        positives = sum(value >= 0.0 for value in paired)
        baseline = by_side[("baseline", case)]
        candidate = by_side[(view_side, case)]
        rss_reference_side = owned_side if owned_side is not None else "baseline"
        rss_reference = statistics.median(rss[(rss_reference_side, case)])
        candidate_rss = statistics.median(rss[(view_side, case)])
        rss_delta = (candidate_rss - rss_reference) / rss_reference * 100.0
        if len(complete) < args.min_runs:
            passed = False
        if case.startswith("person-"):
            person_gains.append(gain)
            if args.screen:
                passed = passed and gain >= 0.0
            else:
                passed = passed and gain >= args.person_min_gain
        else:
            passed = passed and gain >= (
                args.screen_guard_floor if args.screen else args.profile_address_min_gain
            )
        passed = passed and positives >= args.min_runs // 2 + 1
        if not args.screen:
            passed = passed and max(cv(baseline), cv(candidate)) <= 3.0
            passed = passed and rss_delta <= args.rss_max_increase
        owned_text = "n/a"
        if owned_side is not None:
            owned = by_side[(owned_side, case)]
            owned_complete = [
                round_id for round_id in round_ids
                if (round_id, "baseline", case) in timings and (round_id, owned_side, case) in timings
            ]
            owned_gains = [
                (timings[(round_id, "baseline", case)] - timings[(round_id, owned_side, case)]) /
                timings[(round_id, "baseline", case)] * 100.0
                for round_id in owned_complete
            ]
            owned_gain = statistics.median(owned_gains)
            owned_cv = cv(owned)
            owned_text = f"{owned_gain:+.2f}%/{owned_cv:.2f}%"
            if not args.screen:
                passed = passed and len(owned_complete) >= args.min_runs
                passed = passed and owned_gain >= -args.ordinary_max_regression
                passed = passed and owned_cv <= 3.0
        print(
            f"| {case} | {statistics.median(baseline):.3f} ns | {statistics.median(candidate):.3f} ns | "
            f"{gain:+.2f}% | {positives}/{len(complete)} | {cv(baseline):.2f}/{cv(candidate):.2f}% | "
            f"{rss_delta:+.2f}% | {owned_text} |"
        )

    if args.screen:
        passed = passed and max(person_gains) >= args.screen_person_best
    gc_reference_side = owned_side if owned_side is not None else "baseline"
    baseline_gc_count = sum(statistics.median(values) for (side, _), values in gc_count.items() if side == gc_reference_side)
    candidate_gc_count = sum(statistics.median(values) for (side, _), values in gc_count.items() if side == view_side)
    baseline_gc_freed = sum(statistics.median(values) for (side, _), values in gc_freed.items() if side == gc_reference_side)
    candidate_gc_freed = sum(statistics.median(values) for (side, _), values in gc_freed.items() if side == view_side)
    count_drop = 0.0 if baseline_gc_count == 0.0 else (baseline_gc_count - candidate_gc_count) / baseline_gc_count * 100.0
    freed_drop = 0.0 if baseline_gc_freed == 0.0 else (baseline_gc_freed - candidate_gc_freed) / baseline_gc_freed * 100.0
    if not args.screen:
        passed = passed and (count_drop >= args.gc_min_drop or freed_drop >= args.gc_min_drop)
    else:
        passed = passed and (count_drop >= args.screen_gc_drop or freed_drop >= args.screen_gc_drop)

    counter_text = "not evaluated"
    if args.perf_stat is not None:
        counters: dict[tuple[int, str, str, str], float] = {}
        with args.perf_stat.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                for metric in ("cycles", "instructions"):
                    counters[(int(row["round"]), row["side"], row["case"], metric)] = float(row[metric])
        counter_reference = "candidate_owned" if any(key[1] == "candidate_owned" for key in counters) else "baseline"
        counter_candidate = "candidate_view" if any(key[1] == "candidate_view" for key in counters) else "candidate"
        drops: dict[str, list[float]] = {"cycles": [], "instructions": []}
        counter_cases = sorted({key[2] for key in counters})
        counter_complete = True
        for case in counter_cases:
            for metric in drops:
                round_ids = sorted({key[0] for key in counters if key[2] == case and key[3] == metric})
                complete = [
                    round_id for round_id in round_ids
                    if (round_id, counter_reference, case, metric) in counters and
                    (round_id, counter_candidate, case, metric) in counters
                ]
                counter_complete = counter_complete and len(complete) >= 5
                paired_drops = [
                    (counters[(round_id, counter_reference, case, metric)] -
                     counters[(round_id, counter_candidate, case, metric)]) /
                    counters[(round_id, counter_reference, case, metric)] * 100.0
                    for round_id in complete
                ]
                drops[metric].append(statistics.median(paired_drops))
        cycle_drop = statistics.median(drops["cycles"])
        instruction_drop = statistics.median(drops["instructions"])
        counter_ok = counter_complete and (cycle_drop >= 5.0 or instruction_drop >= 5.0)
        passed = passed and counter_ok
        counter_text = f"cycles {cycle_drop:+.2f}%, instructions {instruction_drop:+.2f}% ({'PASS' if counter_ok else 'FAIL'})"

    print(f"\nAggregate GC count drop: {count_drop:+.2f}%")
    print(f"Aggregate GC-freed bytes drop: {freed_drop:+.2f}%")
    print(f"Counter gate: {counter_text}")
    print(f"Overall gate: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
