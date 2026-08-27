#!/usr/bin/env python3
"""Compare a Stream protocol candidate with a frozen previous-yjson baseline."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load(path: Path) -> dict[str, dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {row["case"]: row for row in payload["rows"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument("--baseline-lifecycle", choices=("unpooled", "pooled"), default="pooled")
    parser.add_argument("--candidate-lifecycle", choices=("unpooled", "pooled"), default="pooled")
    args = parser.parse_args()
    baseline, candidate = load(args.baseline), load(args.candidate)
    if set(baseline) != set(candidate):
        raise SystemExit("baseline and candidate cases differ")
    rows = []
    for case in sorted(candidate):
        before, after = baseline[case], candidate[case]
        baseline_runs = before[f"{args.baseline_lifecycle}_run_medians_ns"]
        candidate_runs = after[f"{args.candidate_lifecycle}_run_medians_ns"]
        paired = [(left - right) / left * 100.0
                  for left, right in zip(baseline_runs, candidate_runs)]
        rows.append({
            "case": case, "operation": after["operation"], "payload": after["payload"],
            "profile": after["profile"],
            "baseline_median_ns": statistics.median(baseline_runs),
            "candidate_median_ns": statistics.median(candidate_runs),
            "paired_improvement_median_percent": statistics.median(paired),
            "candidate_faster_pairs": sum(right < left for left, right in zip(baseline_runs, candidate_runs)),
            "pairs": len(paired),
            "baseline_cv_percent": before[f"{args.baseline_lifecycle}_cv_percent"],
            "candidate_cv_percent": after[f"{args.candidate_lifecycle}_cv_percent"],
        })
    regressions = [row["case"] for row in rows
                   if max(float(row["baseline_cv_percent"]), float(row["candidate_cv_percent"])) <= 5.0
                   and float(row["paired_improvement_median_percent"]) < -5.0]
    canonical_wins = [row["case"] for row in rows
                      if row["operation"] == "decode" and row["profile"] == "chunk-4k"
                      and max(float(row["baseline_cv_percent"]), float(row["candidate_cv_percent"])) <= 5.0
                      and float(row["paired_improvement_median_percent"]) >= 5.0
                      and int(row["candidate_faster_pairs"]) >= 6]
    noisy = [row["case"] for row in rows
             if max(float(row["baseline_cv_percent"]), float(row["candidate_cv_percent"])) > 5.0]
    gates = {
        "no_stable_core_regression_over_5_percent": {"passed": not regressions, "cases": regressions},
        "two_canonical_decode_improvements": {"passed": len(canonical_wins) >= 2, "cases": canonical_wins},
        "both_sides_cv_at_most_5_percent": {"passed": not noisy, "cases": noisy},
    }
    lines = [
        "| Case | Baseline | Candidate | Paired improvement | Candidate wins | CV B/C |",
        "|:--|--:|--:|--:|--:|--:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['case']} | {float(row['baseline_median_ns']) / 1_000:.3f} us | "
            f"{float(row['candidate_median_ns']) / 1_000:.3f} us | "
            f"{float(row['paired_improvement_median_percent']):+.2f}% | "
            f"{row['candidate_faster_pairs']}/{row['pairs']} | "
            f"{float(row['baseline_cv_percent']):.2f}% / "
            f"{float(row['candidate_cv_percent']):.2f}% |"
        )
    lines.extend(["", "Gates:", ""])
    for name, result in gates.items():
        lines.append(f"- {'PASS' if result['passed'] else 'FAIL'} `{name}`")
    rendered = "\n".join(lines) + "\n"
    print(rendered, end="")
    result = {"protocol_version": 1,
              "baseline_lifecycle": args.baseline_lifecycle,
              "candidate_lifecycle": args.candidate_lifecycle,
              "rows": rows, "gates": gates}
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.write_text(rendered, encoding="utf-8")
    return 1 if args.enforce and not all(item["passed"] for item in gates.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
