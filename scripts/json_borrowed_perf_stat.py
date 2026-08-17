#!/usr/bin/env python3
"""Collect paired perf-stat counters for candidate owned and borrowed modes."""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
from pathlib import Path


CASES = (
    "profile-string", "profile-bytes", "address-string",
    "address-bytes", "person-string", "person-bytes",
)


def run_once(binary: Path, mode: str, cpu: int, heap: str) -> tuple[str, str]:
    env = os.environ.copy()
    env["cjHeapSize"] = heap
    env["LC_ALL"] = "C"
    command = [
        "perf", "stat", "-x,", "-e", "cycles,instructions", "--",
        "taskset", "-c", str(cpu), str(binary), mode,
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True, env=env)
    values: dict[str, str] = {}
    for line in completed.stderr.splitlines():
        columns = line.split(",")
        if len(columns) >= 3 and columns[2] in {"cycles", "instructions"}:
            values[columns[2]] = columns[0]
    if values.keys() != {"cycles", "instructions"}:
        raise ValueError(f"incomplete perf output: {completed.stderr!r}")
    return values["cycles"], values["instructions"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--heap", default="128MB")
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=("round", "side", "case", "cycles", "instructions")
        )
        writer.writeheader()
        for round_id in range(1, args.runs + 1):
            sides = (
                ("candidate_owned", "owned"), ("candidate_view", "generated")
            ) if round_id % 2 == 1 else (
                ("candidate_view", "generated"), ("candidate_owned", "owned")
            )
            for case in CASES:
                stem, input_kind = case.split("-", 1)
                for side, flavor in sides:
                    cycles, instructions = run_once(
                        args.binary, f"{stem}-{flavor}-full-{input_kind}", args.cpu, args.heap
                    )
                    writer.writerow({
                        "round": round_id, "side": side, "case": case,
                        "cycles": cycles, "instructions": instructions,
                    })
                    stream.flush()
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
