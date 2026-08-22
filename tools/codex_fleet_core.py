"""Pure dependency and prompt logic for Wirestack's local Codex fleet."""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

SCHEMA_VERSION = 1
TASK_ID_RE = re.compile(r"(?:M\d+-\d{3}|UP-\d{3}|P1-\d{3})")
TASK_RANGE_RE = re.compile(r"(M\d+)-(\d{3})\.\.(?:(M\d+)-)?(\d{3})")
MILESTONE_RANGE_RE = re.compile(r"M(\d+)\.\.M(\d+)")
SHARED_HOTSPOTS = (
    "docs/planning/status.md", "scripts/check", "README.md", "AGENTS.md", "cjpm.toml"
)

class FleetError(RuntimeError):
    pass

@dataclass(frozen=True)
class Task:
    task_id: str
    title: str
    area: str
    complexity: str
    dependency_expression: str
    dependencies: frozenset[str]
    trace: str
    acceptance: str

def task_sort_key(task_id: str) -> tuple[int, int, int]:
    if task_id.startswith("M"):
        milestone, number = task_id[1:].split("-", 1)
        return (0, int(milestone), int(number))
    if task_id.startswith("UP-"):
        return (1, 0, int(task_id.split("-", 1)[1]))
    if task_id.startswith("P1-"):
        return (2, 0, int(task_id.split("-", 1)[1]))
    return (9, 0, 0)

def _rows(text: str) -> list[list[str]]:
    result = []
    for line in text.splitlines():
        if line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) >= 7 and TASK_ID_RE.fullmatch(cells[0]):
                result.append(cells[:7])
    return result

def _expand(token: str, all_ids: set[str]) -> set[str]:
    token = re.sub(r"（.*?）|\(.*?\)", "", token).strip()
    if not token or token == "—" or token.startswith("UP-*"):
        return set()
    if token in all_ids:
        return {token}
    match = TASK_RANGE_RE.fullmatch(token)
    if match:
        left, start, right, end = match.groups()
        right = right or left
        if left != right:
            raise FleetError(f"unsupported cross-milestone range: {token}")
        return {
            f"{left}-{number:03d}" for number in range(int(start), int(end) + 1)
            if f"{left}-{number:03d}" in all_ids
        }
    match = MILESTONE_RANGE_RE.fullmatch(token)
    if match:
        start, end = map(int, match.groups())
        return {
            task_id for task_id in all_ids if task_id.startswith("M")
            and start <= int(task_id[1:task_id.index("-")]) <= end
        }
    raise FleetError(f"unrecognized dependency token: {token}")

def parse_backlog(path: Path) -> dict[str, Task]:
    rows = _rows(path.read_text(encoding="utf-8"))
    all_ids = {row[0] for row in rows}
    if not all_ids:
        raise FleetError(f"no task table found in {path}")
    tasks = {}
    for task_id, title, area, complexity, dep_expr, trace, acceptance in rows:
        dependencies = set()
        for token in dep_expr.split(","):
            dependencies.update(_expand(token, all_ids))
        tasks[task_id] = Task(task_id, title, area, complexity, dep_expr,
                              frozenset(dependencies), trace, acceptance)
    return tasks

def load_state(path: Path) -> dict[str, object]:
    state = json.loads(path.read_text(encoding="utf-8"))
    if state.get("schema_version") != SCHEMA_VERSION:
        raise FleetError(f"unsupported state schema: {state.get('schema_version')!r}")
    return state

def atomic_write_json(path: Path, value: Mapping[str, object]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)

def completed_ids(state: Mapping[str, object]) -> set[str]:
    return {str(item) for item in state.get("completed", [])}

def ready_tasks(tasks: Mapping[str, Task], state: Mapping[str, object]) -> list[Task]:
    complete = completed_ids(state)
    blocked = set(dict(state.get("blocked", {})))
    return sorted(
        [task for task in tasks.values() if task.task_id not in complete
         and task.task_id not in blocked and task.dependencies <= complete],
        key=lambda task: task_sort_key(task.task_id),
    )

def branch_for(task_id: str, state: Mapping[str, object]) -> str:
    return str(dict(state.get("branch_overrides", {})).get(task_id, f"task/{task_id.lower()}"))

def issue_for(task_id: str, state: Mapping[str, object]) -> int | None:
    raw = dict(state.get("issue_numbers", {})).get(task_id)
    return int(raw) if raw is not None else None

def render_prompt(task: Task, branch: str, issue: int | None) -> str:
    issue_line = f"GitHub issue: #{issue}\n" if issue is not None else ""
    deps = ", ".join(sorted(task.dependencies, key=task_sort_key)) or "none"
    hotspots = "\n".join(f"- `{item}`" for item in SHARED_HOTSPOTS)
    return f"""Execute exactly one Wirestack task: {task.task_id} — {task.title}.

{issue_line}Branch: `{branch}`
Area: {task.area}; complexity: {task.complexity}
Dependencies: {deps}
PRD trace: {task.trace}
Acceptance: {task.acceptance}

Read `AGENTS.md`, the PRD, backlog, relevant ADRs, dependency evidence, and Git state first.
Work only on {task.task_id}. Use the repository-recorded Cangjie SDK and report exact versions.
Missing devices/platforms, cross-compile-only results, skipped tests, timeouts, or unavailable metrics are BLOCKED/NOT RUN, never PASS.
Do not use private handles, `CJ_MRT_Sock*`, legacy `stdx.net.tls/http`, exception-message control flow, polling workarounds, or unbounded resources.
Final shared-host timing/performance/soak evidence must run through:
`scripts/with-host-gate-lock linux-native-gate -- <command...>`.
You may commit, push, open/update a PR, and repair CI. Do not merge your own PR.

Do not edit these coordinator-owned hotspots:
{hotspots}
Do not edit another task's evidence directory. Add task-specific tools/tests/workflows.
Store durable evidence under `docs/evidence/{task.task_id}/`, run applicable checks, and open a focused PR that distinguishes task completion from platform/global gate completion.
"""
