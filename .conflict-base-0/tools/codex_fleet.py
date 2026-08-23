#!/usr/bin/env python3
"""Create isolated Wirestack worktrees and launch dependency-ready Codex sessions."""
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

from codex_fleet_core import (
    FleetError, atomic_write_json, branch_for, completed_ids, issue_for, load_state,
    parse_backlog, ready_tasks, render_prompt, task_sort_key,
)

def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, check=False, text=True, errors="replace",
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise FleetError(f"command failed ({result.returncode}): {shlex.join(args)}\n{detail}")
    return result

def root_of(path: Path) -> Path:
    return Path(run(["git", "-C", str(path.resolve()), "rev-parse", "--show-toplevel"]).stdout.strip())

def local_branch(root: Path, branch: str) -> bool:
    return run(["git", "-C", str(root), "show-ref", "--verify", "--quiet",
                f"refs/heads/{branch}"], check=False).returncode == 0

def remote_branch(root: Path, branch: str) -> bool:
    return run(["git", "-C", str(root), "ls-remote", "--exit-code", "--heads",
                "origin", branch], check=False).returncode == 0

def worktree_map(root: Path) -> dict[str, Path]:
    lines = run(["git", "-C", str(root), "worktree", "list", "--porcelain"]).stdout.splitlines()
    result, current = {}, None
    for line in lines:
        if line.startswith("worktree "):
            current = Path(line[9:]).resolve()
        elif line.startswith("branch refs/heads/") and current:
            result[line[18:]] = current
    return result

def ensure_worktree(root: Path, parent: Path, task_id: str, branch: str,
                    base: str) -> Path:
    existing = worktree_map(root)
    if branch in existing:
        return existing[branch]
    destination = (parent / task_id).resolve()
    if destination.exists() and any(destination.iterdir()):
        raise FleetError(f"non-empty unregistered worktree: {destination}")
    parent.mkdir(parents=True, exist_ok=True)
    run(["git", "-C", str(root), "fetch", "origin", base])
    if local_branch(root, branch):
        command = ["git", "-C", str(root), "worktree", "add", str(destination), branch]
    elif remote_branch(root, branch):
        command = ["git", "-C", str(root), "worktree", "add", "--track", "-b",
                   branch, str(destination), f"origin/{branch}"]
    else:
        command = ["git", "-C", str(root), "worktree", "add", "-b", branch,
                   str(destination), f"origin/{base}"]
    run(command)
    return destination

def prepare(root: Path, tasks, state, requested: list[str], maximum: int,
            parent: Path):
    ready = ready_tasks(tasks, state)
    ready_ids = {task.task_id for task in ready}
    selected_ids = requested or [task.task_id for task in ready[:maximum]]
    selected = []
    runtime = root / "build" / "codex-fleet"
    for task_id in selected_ids:
        if task_id not in ready_ids:
            raise FleetError(f"task is not READY: {task_id}")
        task = tasks[task_id]
        branch = branch_for(task_id, state)
        worktree = ensure_worktree(root, parent, task_id, branch,
                                   str(state.get("base_branch", "main")))
        prompt = runtime / "prompts" / f"{task_id}.md"
        log = runtime / "logs" / f"{task_id}.log"
        last = runtime / "last-messages" / f"{task_id}.md"
        prompt.parent.mkdir(parents=True, exist_ok=True)
        log.parent.mkdir(parents=True, exist_ok=True)
        last.parent.mkdir(parents=True, exist_ok=True)
        prompt.write_text(render_prompt(task, branch, issue_for(task_id, state)), encoding="utf-8")
        selected.append((task_id, branch, worktree, prompt, log, last))
        print(f"prepared {task_id}: {worktree} [{branch}]")
    return selected, runtime

def launch(selected, runtime: Path, args) -> None:
    if shutil.which("codex") is None:
        raise FleetError("`codex` is not available in PATH")
    if args.backend == "tmux" and shutil.which("tmux") is None:
        raise FleetError("`tmux` is unavailable; use --backend process")
    runtime_file = runtime / "runtime.json"
    data = json.loads(runtime_file.read_text()) if runtime_file.exists() else {
        "schema_version": 1, "sessions": {}}
    sessions = dict(data.get("sessions", {}))
    for task_id, branch, worktree, prompt, log, last in selected:
        command = ["codex", "exec", "--approve-for-me", "--cd", str(worktree),
                   "--output-last-message", str(last)]
        if args.model:
            command += ["--model", args.model]
        if args.network:
            command += ["-c", "sandbox_workspace_write.network_access=true"]
        if os.environ.get("CODEX_FLEET_EXTRA_ARGS"):
            command += shlex.split(os.environ["CODEX_FLEET_EXTRA_ARGS"])
        command += ["-"]
        prefix = ""
        if os.environ.get("WIRESTACK_SDK_ENV"):
            prefix = f"source {shlex.quote(os.environ['WIRESTACK_SDK_ENV'])} && "
        shell = (f"{prefix}{shlex.join(command)} < {shlex.quote(str(prompt))} "
                 f"> {shlex.quote(str(log))} 2>&1")
        if args.backend == "tmux":
            session = f"wirestack-{task_id.lower()}"
            if run(["tmux", "has-session", "-t", session], check=False).returncode == 0:
                raise FleetError(f"tmux session already exists: {session}")
            run(["tmux", "new-session", "-d", "-s", session, "bash", "-lc", shell])
            metadata = {"backend": "tmux", "session": session}
        else:
            stream = log.open("ab", buffering=0)
            process = subprocess.Popen(["bash", "-lc", shell], cwd=worktree,
                                       stdin=subprocess.DEVNULL, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            stream.close()
            metadata = {"backend": "process", "pid": process.pid}
        sessions[task_id] = {**metadata, "branch": branch, "worktree": str(worktree),
                             "log": str(log), "started_unix": int(time.time())}
        print(f"launched {task_id}: {metadata}")
    data["sessions"] = sessions
    atomic_write_json(runtime_file, data)

def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=Path.cwd())
    sub = result.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--max-parallel", type=int)
    for name in ("prepare", "launch"):
        command = sub.add_parser(name)
        command.add_argument("tasks", nargs="*")
        command.add_argument("--max-parallel", type=int)
        command.add_argument("--worktree-root", default=os.environ.get(
            "WIRESTACK_WORKTREE_ROOT", "../Wirestack.worktrees"))
        if name == "launch":
            command.add_argument("--backend", choices=("tmux", "process"), default="tmux")
            command.add_argument("--model", default=os.environ.get("CODEX_FLEET_MODEL"))
            command.add_argument("--network", action=argparse.BooleanOptionalAction, default=True)
    complete = sub.add_parser("mark-complete")
    complete.add_argument("tasks", nargs="+")
    return result

def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        root = root_of(args.repo)
        tasks = parse_backlog(root / "docs/planning/implementation-backlog.md")
        state_path = root / "docs/planning/fleet-state.json"
        state = load_state(state_path)
        maximum = getattr(args, "max_parallel", None) or int(state.get("max_parallel", 8))
        if args.command == "plan":
            ready = ready_tasks(tasks, state)
            for task in ready[:maximum]:
                print(f"{task.task_id}\t{branch_for(task.task_id, state)}\t"
                      f"deps={task.dependency_expression}\t{task.title}")
            return 0
        if args.command in {"prepare", "launch"}:
            selected, runtime = prepare(root, tasks, state, args.tasks, maximum,
                                        Path(args.worktree_root).expanduser().resolve())
            if args.command == "launch":
                launch(selected, runtime, args)
            return 0
        complete = completed_ids(state)
        complete.update(args.tasks)
        state["completed"] = sorted(complete, key=task_sort_key)
        atomic_write_json(state_path, state)
        print("marked COMPLETE:", ", ".join(args.tasks))
        return 0
    except FleetError as error:
        print(f"codex-fleet: {error}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
