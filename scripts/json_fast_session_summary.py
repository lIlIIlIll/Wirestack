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
    parser.add_argument("--perf-stat", type=Path)
    parser.add_argument("--min-runs", type=int, default=11)
    args = parser.parse_args()
    values: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_counts: dict[tuple[str, str], list[float]] = defaultdict(list)
    gc_freed: dict[tuple[str, str], list[float]] = defaultdict(list)
    rss_values: dict[tuple[str, str], list[float]] = defaultdict(list)
    rounds: dict[tuple[int, str, str], float] = {}
    with args.csv.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            key = (row["side"], row["case"])
            value = float(row["ns_per_op"])
            values[key].append(value)
            gc_counts[key].append(float(row["gc_count"]))
            gc_freed[key].append(float(row["gc_freed_bytes"]))
            rss_values[key].append(float(row["rss_kib"]))
            rounds[(int(row["round"]), row["side"], row["case"])] = value

    print("| Case | Baseline | Candidate decoder | Session | Paired session gain | Paired decoder delta | Nonnegative pairs | CV B/C/S | RSS delta |")
    print("|:--|--:|--:|--:|--:|--:|--:|--:|--:|")
    gains: list[float] = []
    passed = True
    for case in sorted({case for _, case in values}):
        baseline = values[("baseline", case)]
        decoder = values[("candidate_decoder", case)]
        session = values[("candidate_session", case)]
        round_ids = sorted({round_id for round_id, _, item_case in rounds if item_case == case})
        complete_rounds = [
            round_id for round_id in round_ids
            if all((round_id, side, case) in rounds for side in ("baseline", "candidate_decoder", "candidate_session"))
        ]
        if len(complete_rounds) < args.min_runs:
            passed = False
        bmed = statistics.median(baseline)
        dmed = statistics.median(decoder)
        smed = statistics.median(session)
        paired_gains = [
            (rounds[(round_id, "baseline", case)] - rounds[(round_id, "candidate_session", case)]) /
            rounds[(round_id, "baseline", case)] * 100.0
            for round_id in complete_rounds
        ]
        paired_decoder_deltas = [
            (rounds[(round_id, "candidate_decoder", case)] - rounds[(round_id, "baseline", case)]) /
            rounds[(round_id, "baseline", case)] * 100.0
            for round_id in complete_rounds
        ]
        gain = statistics.median(paired_gains)
        decoder_delta = statistics.median(paired_decoder_deltas)
        nonnegative_pairs = sum(item >= 0.0 for item in paired_gains)
        baseline_rss = statistics.median(rss_values[("baseline", case)])
        session_rss = statistics.median(rss_values[("candidate_session", case)])
        rss_delta = (session_rss - baseline_rss) / baseline_rss * 100.0
        gains.append(gain)
        flat_case = case.startswith("profile-") or case.startswith("address-")
        case_ok = gain >= (50.0 if flat_case else 0.0)
        case_ok = case_ok and nonnegative_pairs >= args.min_runs // 2 + 1
        case_ok = case_ok and decoder_delta <= 2.0
        case_ok = case_ok and max(cv(baseline), cv(decoder), cv(session)) <= 3.0
        case_ok = case_ok and rss_delta <= 2.0
        passed = passed and case_ok
        print(
            f"| {case} | {bmed:.3f} ns | {dmed:.3f} ns | {smed:.3f} ns | "
            f"{gain:+.2f}% | {decoder_delta:+.2f}% | "
            f"{nonnegative_pairs}/{len(complete_rounds)} | "
            f"{cv(baseline):.2f}/{cv(decoder):.2f}/{cv(session):.2f}% | {rss_delta:+.2f}% |"
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
    counter_summary = "not evaluated"
    if args.perf_stat is not None:
        counters: dict[tuple[str, str], list[float]] = defaultdict(list)
        with args.perf_stat.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                counters[(row["side"], "cycles")].append(float(row["cycles"]))
                counters[(row["side"], "instructions")].append(float(row["instructions"]))
        baseline_cycles = counters[("baseline", "cycles")]
        session_cycles = counters[("candidate_session", "cycles")]
        baseline_instructions = counters[("baseline", "instructions")]
        session_instructions = counters[("candidate_session", "instructions")]
        counter_passed = min(
            len(baseline_cycles), len(session_cycles), len(baseline_instructions), len(session_instructions)
        ) >= 5
        cycle_drop = (statistics.median(baseline_cycles) - statistics.median(session_cycles)) / statistics.median(baseline_cycles) * 100.0
        instruction_drop = (
            statistics.median(baseline_instructions) - statistics.median(session_instructions)
        ) / statistics.median(baseline_instructions) * 100.0
        counter_passed = counter_passed and (cycle_drop >= 5.0 or instruction_drop >= 5.0)
        passed = passed and counter_passed
        counter_summary = f"cycles {cycle_drop:+.2f}%, instructions {instruction_drop:+.2f}% ({'PASS' if counter_passed else 'FAIL'})"
    print(f"\nOverall median session gain: {overall:+.2f}%")
    print(f"Aggregate GC count drop: {gc_count_drop:+.2f}%")
    print(f"Aggregate GC-freed bytes drop: {gc_freed_drop:+.2f}%")
    print(f"GC gate: {'PASS' if gc_passed else 'FAIL'}")
    print(f"Counter gate: {counter_summary}")
    print(f"Latency gate: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
