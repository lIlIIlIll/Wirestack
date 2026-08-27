#!/usr/bin/env python3
"""Convert core yjson cjcov output to LCOV and enforce the project baseline."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--gcov-root", type=Path, required=True, action="append")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--root", type=Path, required=True)
args = parser.parse_args()
repository_root = args.root.resolve()
source_root = repository_root / "src"


def semantic_branch_lines(source: Path) -> set[int]:
    """Return lines whose branches are explicit in the Cangjie source.

    cjcov's gcov stream also reports compiler-generated edges for checked
    arithmetic, bounds checks, calls, and exception propagation. Those edges
    are useful to the compiler, but they are not source branch coverage and
    many cannot be selected by a test input. Keep only explicit control-flow
    headers and boolean short-circuit expressions.
    """

    result: set[int] = set()
    continuation = False
    control = re.compile(r"(^|\W)(if|while|for|match|case)(\W|$)")
    for number, raw in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
        text = raw.strip()
        starts_control = bool(control.search(text))
        explicit_boolean = "&&" in text or "||" in text
        if starts_control or explicit_boolean or continuation:
            result.add(number)
        if starts_control:
            continuation = "{" not in text and "=>" not in text
        elif continuation and ("{" in text or "=>" in text):
            continuation = False
        elif continuation and not text:
            continuation = False
    return result

records: dict[str, dict[int, int]] = {}
branch_records: dict[str, dict[tuple[int, int], int]] = {}
for gcov_root in args.gcov_root:
    for path in gcov_root.rglob("*.gcov"):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        source = ""
        for line in lines[:10]:
            match = re.match(r"\s*-:\s*0:Source:(.+)$", line)
            if match:
                source = match.group(1)
                break
        if not source:
            continue
        source_path = Path(source)
        resolved = source_root / source_path.name
        if not resolved.exists():
            continue
        if not resolved.name.startswith("lib_") or resolved.suffix != ".cj":
            continue
        relative = str(resolved.relative_to(repository_root))
        target = records.setdefault(relative, {})
        branch_target = branch_records.setdefault(relative, {})
        source_branch_lines = semantic_branch_lines(resolved)
        current_number = 0
        branch_index = 0
        for line in lines:
            match = re.match(r"\s*([^:]+):\s*(\d+):", line)
            if match:
                current_number = int(match.group(2))
                branch_index = 0
            if line.startswith("branch "):
                branch_match = re.match(
                    r"branch\s+\d+\s+(?:taken\s+(\d+)|never executed)$", line
                )
                if branch_match and current_number in source_branch_lines:
                    count = int(branch_match.group(1) or 0)
                    key = (current_number, branch_index)
                    branch_target[key] = max(branch_target.get(key, 0), count)
                    branch_index += 1
                continue
            if not match or match.group(1).strip() == "-":
                continue
            count_text = match.group(1).strip().rstrip("*")
            count = 0 if count_text.startswith("#") else int(count_text)
            number = int(match.group(2))
            target[number] = max(target.get(number, 0), count)

if not records:
    raise SystemExit("no src/lib_*.cj coverage records were found")

args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("w", encoding="utf-8") as handle:
    for source, lines in sorted(records.items()):
        handle.write("TN:core\nSF:" + source + "\n")
        for number, count in sorted(lines.items()):
            handle.write(f"DA:{number},{count}\n")
        branches = branch_records.get(source, {})
        for (number, index), count in sorted(branches.items()):
            taken = str(count) if count > 0 else "-"
            handle.write(f"BRDA:{number},0,{index},{taken}\n")
        handle.write(f"BRF:{len(branches)}\n")
        handle.write(f"BRH:{sum(count > 0 for count in branches.values())}\n")
        handle.write("end_of_record\n")

line_hit = sum(count > 0 for lines in records.values() for count in lines.values())
line_total = sum(len(lines) for lines in records.values())
branch_hit = sum(count > 0 for branches in branch_records.values() for count in branches.values())
branch_total = sum(len(branches) for branches in branch_records.values())
line_percent = 100.0 * line_hit / line_total if line_total else 0.0
branch_percent = 100.0 * branch_hit / branch_total if branch_total else 0.0
baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
line_minimum = float(baseline["project_line_percent"])
branch_minimum = float(baseline["project_branch_percent"])
print(f"core line coverage: {line_hit}/{line_total} = {line_percent:.1f}% (minimum {line_minimum:.1f}%)")
print(
    f"core branch coverage: {branch_hit}/{branch_total} = {branch_percent:.1f}% "
    f"(minimum {branch_minimum:.1f}%)"
)
if line_percent + 1e-9 < line_minimum:
    raise SystemExit("core line coverage fell below the project minimum")
if branch_percent + 1e-9 < branch_minimum:
    raise SystemExit("core branch coverage fell below the project minimum")
