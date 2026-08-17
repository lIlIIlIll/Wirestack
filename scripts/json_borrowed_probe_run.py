#!/usr/bin/env python3
"""Collect alternating owned/borrowed full-traversal probe samples.

The default two-side mode is a cheap same-binary screen.  ``--three-way``
adds an immutable baseline binary and keeps candidate-owned and candidate-view
measurements separate for the release gate.
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import tempfile
from itertools import permutations
from pathlib import Path


CASES = (
    "profile-string",
    "profile-bytes",
    "address-string",
    "address-bytes",
    "person-string",
    "person-bytes",
)


def parse_probe(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for item in output.strip().split(","):
        key, value = item.split("=", 1)
        values[key] = value
    required = {"ns_per_op", "gc_count", "gc_freed_bytes"}
    if not required.issubset(values):
        raise ValueError(f"incomplete probe output: {output!r}")
    return values


def run_once(binary: Path, mode: str, cpu: int, heap: str) -> tuple[dict[str, str], str]:
    with tempfile.NamedTemporaryFile() as rss_file:
        env = os.environ.copy()
        env["cjHeapSize"] = heap
        command = [
            "/usr/bin/time", "-f", "%M", "-o", rss_file.name,
            "taskset", "-c", str(cpu), str(binary), mode,
        ]
        completed = subprocess.run(command, check=True, capture_output=True, text=True, env=env)
        rss_file.seek(0)
        rss = rss_file.read().decode("utf-8").strip()
    return parse_probe(completed.stdout), rss


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="candidate probe binary")
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline-binary", type=Path)
    parser.add_argument(
        "--candidate-owned-binary", type=Path,
        help="owned-only candidate binary; defaults to the candidate View binary",
    )
    parser.add_argument("--three-way", action="store_true")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    parser.add_argument("--candidate-flavor", default="generated")
    parser.add_argument(
        "--cases", default=",".join(CASES),
        help="comma-separated subset of the six frozen workload names",
    )
    args = parser.parse_args()
    if args.three_way and args.baseline_binary is None:
        parser.error("--three-way requires --baseline-binary")
    selected_cases = tuple(item.strip() for item in args.cases.split(",") if item.strip())
    unknown_cases = set(selected_cases) - set(CASES)
    if not selected_cases or unknown_cases:
        parser.error(f"invalid --cases value; unknown cases: {sorted(unknown_cases)}")

    if args.three_way:
        candidate_owned_binary = args.candidate_owned_binary or args.binary
        side_specs = {
            "baseline": (args.baseline_binary, "owned"),
            "candidate_owned": (candidate_owned_binary, "owned"),
            "candidate_view": (args.binary, args.candidate_flavor),
        }
        orders = tuple(permutations(side_specs))
    else:
        side_specs = {
            "baseline": (args.binary, "owned"),
            "candidate": (args.binary, args.candidate_flavor),
        }
        orders = (("baseline", "candidate"), ("candidate", "baseline"))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=(
            "round", "side", "case", "ns_per_op", "gc_count", "gc_freed_bytes", "rss_kib"
        ))
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            sides = orders[(round_id - 1) % len(orders)]
            for case in selected_cases:
                for side in sides:
                    binary, flavor = side_specs[side]
                    mode = f"{case.split('-', 1)[0]}-{flavor}-full-{case.rsplit('-', 1)[1]}"
                    values, rss = run_once(binary, mode, args.cpu, args.heap)
                    writer.writerow({
                        "round": round_id,
                        "side": side,
                        "case": case,
                        "ns_per_op": values["ns_per_op"],
                        "gc_count": values["gc_count"],
                        "gc_freed_bytes": values["gc_freed_bytes"],
                        "rss_kib": rss,
                    })
                    stream.flush()
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
