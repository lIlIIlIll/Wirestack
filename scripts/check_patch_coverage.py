#!/usr/bin/env python3
"""Enforce line and branch coverage for added core Cangjie source lines."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path


def changed_lines(diff: str) -> dict[str, set[int]]:
    changed: dict[str, set[int]] = {}
    current: str | None = None
    new_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            name = raw[4:].split("\t", 1)[0]
            current = None if name == "/dev/null" else name.removeprefix("b/")
            continue
        hunk = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
        if hunk:
            new_line = int(hunk.group(1))
            continue
        if current is None or raw.startswith("diff --git"):
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            changed.setdefault(current, set()).add(new_line)
            new_line += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        elif raw.startswith(" "):
            new_line += 1
    return changed


def read_lcov(path: Path) -> tuple[dict[str, dict[int, int]], dict[str, list[tuple[int, int]]]]:
    lines: dict[str, dict[int, int]] = {}
    branches: dict[str, list[tuple[int, int]]] = {}
    source = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.startswith("SF:"):
            source = raw[3:]
        elif raw.startswith("DA:") and source:
            number, count = raw[3:].split(",", 1)
            lines.setdefault(source, {})[int(number)] = int(count)
        elif raw.startswith("BRDA:") and source:
            number, _, _, taken = raw[5:].split(",", 3)
            count = 0 if taken == "-" else int(taken)
            branches.setdefault(source, []).append((int(number), count))
    return lines, branches


def percent(hit: int, total: int) -> float:
    return 100.0 * hit / total if total else 100.0


parser = argparse.ArgumentParser()
parser.add_argument("--diff", type=Path, required=True)
parser.add_argument("--lcov", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True)
args = parser.parse_args()
changed = changed_lines(args.diff.read_text(encoding="utf-8"))
lines, branches = read_lcov(args.lcov)

line_counts = [
    count
    for source, source_lines in lines.items()
    for number, count in source_lines.items()
    if number in changed.get(source, set())
]
branch_counts = [
    count
    for source, source_branches in branches.items()
    for number, count in source_branches
    if number in changed.get(source, set())
]
line_hit = sum(count > 0 for count in line_counts)
branch_hit = sum(count > 0 for count in branch_counts)
line_percent = percent(line_hit, len(line_counts))
branch_percent = percent(branch_hit, len(branch_counts))
baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
line_minimum = float(baseline["patch_line_percent"])
branch_minimum = float(baseline["patch_branch_percent"])
print(
    f"patch core line coverage: {line_hit}/{len(line_counts)} = {line_percent:.1f}% "
    f"(minimum {line_minimum:.1f}%)"
)
print(
    f"patch core branch coverage: {branch_hit}/{len(branch_counts)} = {branch_percent:.1f}% "
    f"(minimum {branch_minimum:.1f}%)"
)
if line_percent + 1e-9 < line_minimum:
    raise SystemExit("core line coverage fell below the patch minimum")
if branch_percent + 1e-9 < branch_minimum:
    raise SystemExit("core branch coverage fell below the patch minimum")
