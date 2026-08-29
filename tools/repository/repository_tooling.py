#!/usr/bin/env python3
"""Fail-closed repository diagnostics, task contracts and evidence checks."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

SCHEMA_VERSION = 1
EVIDENCE_SCHEMA_VERSION = 1
# A 24-hour command needs time for build, startup, report flush, and bounded
# teardown. Keep the contract finite while allowing one full day plus overhead.
MAX_TIMEOUT_SECONDS = 172_800
CAPTURE_BYTES = 16_384
EXIT_CODES = {"PASS": 0, "READY": 0, "FAIL": 1, "INVALID": 2,
              "BLOCKED": 3, "SKIPPED": 4, "STALE": 5, "DEGRADED": 6}
TASK_KEYS = {"schema_version", "task_id", "dependencies", "allowed_paths",
             "platforms", "acceptance_commands", "required_evidence",
             "timeout_seconds", "long_running_gate", "source_paths"}
COMMAND_KEYS = {"id", "argv", "timeout_seconds", "long_running", "gate"}
EVIDENCE_KEYS = {"schema_version", "source_task", "platform", "toolchain",
                 "acceptance_status", "generated_at_utc", "revision",
                 "reports", "source_sha256"}
REPORT_KEYS = {"path", "sha256", "source_task", "acceptance_status"}
TASK_ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-\d{3}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ContractError(ValueError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: Mapping[str, Any], before_replace: Callable[[], None] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def safe_path(root: Path, value: Any, field: str, *, must_exist: bool = False,
              file_only: bool = False) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ContractError("PATH_INVALID", f"{field} must be a non-empty repository-relative path")
    candidate = root / value
    try:
        candidate.resolve(strict=False).relative_to(root.resolve())
    except ValueError as error:
        raise ContractError("PATH_ESCAPE", f"{field} escapes repository: {value}") from error
    if must_exist and not candidate.exists():
        raise ContractError("PATH_MISSING", f"{field} does not exist: {value}")
    if file_only and candidate.exists() and not candidate.is_file():
        raise ContractError("PATH_NOT_FILE", f"{field} is not a file: {value}")
    return candidate


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError("TYPE", f"{field} must be an object")
    return value


def _string_list(value: Any, field: str, *, allow_empty: bool = True) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value):
        raise ContractError("TYPE", f"{field} must be a list{'' if allow_empty else ' with entries'}")
    if any(not isinstance(item, str) or not item for item in value):
        raise ContractError("TYPE", f"{field} entries must be non-empty strings")
    return value


def _reject_unknown(value: Mapping[str, Any], allowed: set[str], field: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ContractError("UNKNOWN_FIELD", f"{field} has unknown fields: {', '.join(unknown)}")


def validate_task(raw: Any, root: Path) -> dict[str, Any]:
    task = _object(raw, "task")
    _reject_unknown(task, TASK_KEYS, "task")
    if task.get("schema_version") != SCHEMA_VERSION:
        raise ContractError("UNKNOWN_SCHEMA", f"unsupported task schema: {task.get('schema_version')!r}")
    task_id = task.get("task_id")
    if not isinstance(task_id, str) or TASK_ID_RE.fullmatch(task_id) is None:
        raise ContractError("TASK_ID", "task_id is invalid")
    dependencies = _string_list(task.get("dependencies"), "dependencies")
    if any(TASK_ID_RE.fullmatch(item) is None for item in dependencies):
        raise ContractError("DEPENDENCY_ID", "dependency ID is invalid")
    if task_id in dependencies or len(set(dependencies)) != len(dependencies):
        raise ContractError("DEPENDENCY_INVALID", "dependencies must be unique and exclude the task")
    allowed_paths = _string_list(task.get("allowed_paths"), "allowed_paths", allow_empty=False)
    for index, value in enumerate(allowed_paths):
        safe_path(root, value, f"allowed_paths[{index}]")
    platforms = _string_list(task.get("platforms"), "platforms", allow_empty=False)
    required = _string_list(task.get("required_evidence"), "required_evidence", allow_empty=False)
    for index, value in enumerate(required):
        safe_path(root, value, f"required_evidence[{index}]")
    sources = _string_list(task.get("source_paths"), "source_paths", allow_empty=False)
    for index, value in enumerate(sources):
        safe_path(root, value, f"source_paths[{index}]", must_exist=True, file_only=True)
    timeout = task.get("timeout_seconds")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= MAX_TIMEOUT_SECONDS:
        raise ContractError("TIMEOUT", "timeout_seconds is outside the supported range")
    if not isinstance(task.get("long_running_gate"), bool):
        raise ContractError("TYPE", "long_running_gate must be boolean")
    commands = task.get("acceptance_commands")
    if not isinstance(commands, list) or not commands:
        raise ContractError("TYPE", "acceptance_commands must contain entries")
    command_ids: set[str] = set()
    has_long = False
    for index, raw_command in enumerate(commands):
        field = f"acceptance_commands[{index}]"
        command = _object(raw_command, field)
        _reject_unknown(command, COMMAND_KEYS, field)
        command_id = command.get("id")
        if not isinstance(command_id, str) or not command_id or command_id in command_ids:
            raise ContractError("COMMAND_ID", f"{field}.id is empty or duplicated")
        command_ids.add(command_id)
        _string_list(command.get("argv"), f"{field}.argv", allow_empty=False)
        command_timeout = command.get("timeout_seconds")
        if (isinstance(command_timeout, bool) or not isinstance(command_timeout, (int, float))
                or not 0 < command_timeout <= timeout):
            raise ContractError("TIMEOUT", f"{field}.timeout_seconds is invalid")
        long_running = command.get("long_running")
        if not isinstance(long_running, bool):
            raise ContractError("TYPE", f"{field}.long_running must be boolean")
        gate = command.get("gate")
        if gate not in {"fast", "task", "full", "long"}:
            raise ContractError("GATE", f"{field}.gate is invalid")
        if long_running and gate != "long":
            raise ContractError("LONG_GATE_LEAK", f"{command_id} is long-running but assigned to {gate}")
        if gate == "long" and not long_running:
            raise ContractError("LONG_GATE_MISMATCH", f"{command_id} is assigned to long without long_running")
        has_long = has_long or long_running
    if has_long != task["long_running_gate"]:
        raise ContractError("LONG_GATE_MISMATCH", "long_running_gate does not match acceptance commands")
    return task


def load_task(path: Path, root: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError("JSON", f"cannot read task manifest {path.name}") from error
    task = validate_task(raw, root)
    if path.stem != task["task_id"]:
        raise ContractError("TASK_FILENAME", f"{path.name} does not match task_id")
    return task


def planning_ids(path: Path) -> set[str]:
    return set(re.findall(r"^\|\s*([A-Z][A-Z0-9]*-\d{3})\s*\|", path.read_text(encoding="utf-8"), re.MULTILINE))


def status_map(path: Path) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in re.finditer(
        r"^\|\s*([A-Z][A-Z0-9]*-\d{3})\s*\|\s*([A-Z_]+)\s*\|", path.read_text(encoding="utf-8"), re.MULTILINE)}


def load_tasks(root: Path) -> dict[str, dict[str, Any]]:
    directory = root / "tools/tasks"
    tasks: dict[str, dict[str, Any]] = {}
    for path in sorted(directory.glob("*.json")):
        if path.name.startswith("schema-"):
            continue
        task = load_task(path, root)
        if task["task_id"] in tasks:
            raise ContractError("TASK_DUPLICATE", f"duplicate task {task['task_id']}")
        tasks[task["task_id"]] = task
    return tasks


def validate_repository_tasks(root: Path, requested: str | None = None) -> dict[str, dict[str, Any]]:
    tasks = load_tasks(root)
    if requested is not None and requested not in tasks:
        raise ContractError("TASK_MISSING", f"task manifest is missing: {requested}")
    backlog = planning_ids(root / "docs/planning/implementation-backlog.md")
    statuses = status_map(root / "docs/planning/status.md")
    for task_id, task in tasks.items():
        if task_id not in backlog or task_id not in statuses:
            raise ContractError("PLANNING_MISMATCH", f"{task_id} is absent from backlog or status")
        for dependency in task["dependencies"]:
            if dependency not in backlog or dependency not in statuses:
                raise ContractError("DEPENDENCY_MISSING", f"{task_id} dependency is absent: {dependency}")
            if statuses[dependency] != "COMPLETE":
                raise ContractError("DEPENDENCY_INCOMPLETE", f"{task_id} dependency is not COMPLETE: {dependency}")
    visiting: list[str] = []
    visited: set[str] = set()

    def visit(task_id: str) -> None:
        if task_id in visiting:
            start = visiting.index(task_id)
            raise ContractError("DEPENDENCY_CYCLE", " -> ".join(visiting[start:] + [task_id]))
        if task_id in visited or task_id not in tasks:
            return
        visiting.append(task_id)
        for dependency in tasks[task_id]["dependencies"]:
            visit(dependency)
        visiting.pop()
        visited.add(task_id)

    for task_id in sorted(tasks):
        visit(task_id)
    return tasks


def tool_version(argv: Sequence[str], root: Path) -> str | None:
    try:
        result = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (result.stdout + result.stderr).strip()
    return text[:1024] if result.returncode == 0 and text else None


def platform_identity() -> dict[str, str]:
    libc_name, libc_version = platform.libc_ver()
    return {"system": platform.system(), "machine": platform.machine(),
            "libc": libc_name or "unknown", "libc_version": libc_version or "unknown"}


def toolchain_identity(root: Path) -> dict[str, str | None]:
    return {"cjc": tool_version(["cjc", "--version"], root),
            "cjpm": tool_version(["cjpm", "--version"], root)}


def doctor(root: Path, which: Callable[[str], str | None] = shutil.which,
           run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def add(check_id: str, required: bool, passed: bool, detail: str) -> None:
        checks.append({"id": check_id, "required": required,
                       "status": "PASS" if passed else ("BLOCKED" if required else "DEGRADED"),
                       "detail": detail[:1024]})

    identity = platform_identity()
    add("platform-linux", True, identity["system"] == "Linux", json.dumps(identity, sort_keys=True))
    add("platform-x86_64", True, identity["machine"] == "x86_64", identity["machine"])
    add("platform-glibc", True, identity["libc"] == "glibc", f"{identity['libc']} {identity['libc_version']}")
    for name in ("python3", "cjc", "cjpm", "git"):
        found = which(name)
        add(f"tool-{name}", True, found is not None, found or "not found")
    for name in ("but", "rp-rg"):
        found = which(name)
        add(f"tool-{name}", False, found is not None, found or "not found")
    versions = toolchain_identity(root)
    add("cjc-version", True, versions["cjc"] is not None, versions["cjc"] or "unavailable")
    add("cjpm-version", True, versions["cjpm"] is not None, versions["cjpm"] or "unavailable")
    add("repository-prd", True, (root / "docs/product/prd.md").is_file(), "docs/product/prd.md")
    add("repository-check", True, os.access(root / "scripts/check", os.X_OK), "scripts/check")
    try:
        report_staging = root / "build"
        report_staging.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix="wirestack-doctor-", dir=report_staging, delete=True):
            pass
        writable = True
    except OSError:
        writable = False
    add("workspace-report-write", True, writable, "build directory atomic-report staging")
    clean: bool | None = None
    dirty_count = 0
    if which("but") is not None:
        try:
            state = run(["but", "status", "--json"], cwd=root, capture_output=True,
                        text=True, timeout=10, check=False)
            if state.returncode == 0:
                payload = json.loads(state.stdout)
                changes = payload.get("uncommittedChanges")
                if isinstance(changes, list):
                    clean = not changes
                    dirty_count = len(changes)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            clean = None
    if clean is None and which("but") is None:
        try:
            state = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root,
                        capture_output=True, text=True, timeout=10, check=False)
            if state.returncode == 0:
                clean = not state.stdout.strip()
                dirty_count = len(state.stdout.splitlines())
        except (OSError, subprocess.TimeoutExpired):
            clean = None
    detail = "clean" if clean else (f"uncommitted entries: {dirty_count}" if clean is False else "GitButler workspace status unavailable")
    add("workspace-clean", False, clean is True, detail)
    status = "READY"
    if any(check["status"] == "BLOCKED" for check in checks):
        status = "BLOCKED"
    elif any(check["status"] == "DEGRADED" for check in checks):
        status = "DEGRADED"
    return {"schema_version": 1, "kind": "repo-doctor", "status": status,
            "platform": identity, "toolchain": versions, "checks": checks}


def run_command(root: Path, command: Mapping[str, Any], artifact_dir: Path) -> dict[str, Any]:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    command_id = command["id"]
    stdout_path = artifact_dir / f"{command_id}.stdout.log"
    stderr_path = artifact_dir / f"{command_id}.stderr.log"
    started = utc_now()
    start = time.monotonic()
    status = "FAIL"
    exit_code: int | None = None
    timed_out = False
    error_code: str | None = None
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        try:
            result = subprocess.run(command["argv"], cwd=root, stdout=stdout, stderr=stderr,
                                    timeout=float(command["timeout_seconds"]), check=False,
                                    start_new_session=(os.name != "nt"))
            exit_code = result.returncode
            status = "PASS" if result.returncode == 0 else "FAIL"
        except subprocess.TimeoutExpired:
            timed_out = True
            error_code = "TIMEOUT"
        except OSError:
            error_code = "EXEC"
    def excerpt(path: Path) -> tuple[str, bool]:
        data = path.read_bytes()[:CAPTURE_BYTES + 1]
        return data[:CAPTURE_BYTES].decode("utf-8", errors="replace"), len(data) > CAPTURE_BYTES or path.stat().st_size > CAPTURE_BYTES
    stdout_excerpt, stdout_truncated = excerpt(stdout_path)
    stderr_excerpt, stderr_truncated = excerpt(stderr_path)
    return {"id": command_id, "argv": command["argv"], "status": status,
            "exit_code": exit_code, "timed_out": timed_out, "error_code": error_code,
            "started_at_utc": started, "finished_at_utc": utc_now(),
            "duration_ms": round((time.monotonic() - start) * 1000, 3),
            "stdout_path": str(stdout_path.relative_to(root)), "stderr_path": str(stderr_path.relative_to(root)),
            "stdout_excerpt": stdout_excerpt, "stderr_excerpt": stderr_excerpt,
            "stdout_truncated": stdout_truncated, "stderr_truncated": stderr_truncated}


def check(root: Path, mode: str, task_id: str | None = None) -> dict[str, Any]:
    try:
        tasks = validate_repository_tasks(root, task_id)
    except ContractError as error:
        return {"schema_version": 1, "kind": "repository-check", "mode": mode,
                "task_id": task_id, "status": "INVALID",
                "issues": [{"code": error.code, "detail": error.detail}], "commands": []}
    if mode == "full":
        selected = [{"id": "scripts-check", "argv": ["scripts/check"],
                     "timeout_seconds": 3600, "long_running": False, "gate": "full"}]
    elif mode == "fast":
        selected = [command for task in tasks.values() for command in task["acceptance_commands"] if command["gate"] == "fast"]
    else:
        assert task_id is not None
        gate = "long" if mode == "long" else "task"
        selected = [command for command in tasks[task_id]["acceptance_commands"] if command["gate"] == gate]
    if not selected:
        return {"schema_version": 1, "kind": "repository-check", "mode": mode,
                "task_id": task_id, "status": "SKIPPED", "issues": [], "commands": []}
    artifact_dir = root / "build/repository-tooling" / (task_id or mode)
    results = [run_command(root, command, artifact_dir) for command in selected]
    status = "PASS" if all(result["status"] == "PASS" for result in results) else "FAIL"
    return {"schema_version": 1, "kind": "repository-check", "mode": mode,
            "task_id": task_id, "status": status, "issues": [], "commands": results}


def validate_evidence(raw: Any, root: Path, task: Mapping[str, Any]) -> dict[str, Any]:
    evidence = _object(raw, "evidence")
    _reject_unknown(evidence, EVIDENCE_KEYS, "evidence")
    if evidence.get("schema_version") != EVIDENCE_SCHEMA_VERSION:
        raise ContractError("UNKNOWN_SCHEMA", "unsupported evidence schema")
    if evidence.get("source_task") != task["task_id"]:
        raise ContractError("SOURCE_TASK", "evidence source_task does not match")
    if evidence.get("platform") != platform_identity():
        raise ContractError("PLATFORM_DRIFT", "evidence platform does not match current platform")
    if evidence.get("toolchain") != toolchain_identity(root):
        raise ContractError("TOOLCHAIN_DRIFT", "evidence toolchain does not match current toolchain")
    if evidence.get("acceptance_status") != "PASS":
        raise ContractError("ACCEPTANCE_NOT_PASS", "evidence acceptance_status is not PASS")
    source_hashes = evidence.get("source_sha256")
    if not isinstance(source_hashes, dict) or set(source_hashes) != set(task["source_paths"]):
        raise ContractError("SOURCE_INVENTORY", "source digest inventory does not match manifest")
    stale: list[str] = []
    for relative, expected in source_hashes.items():
        path = safe_path(root, relative, "source_sha256", must_exist=True, file_only=True)
        if not isinstance(expected, str) or SHA256_RE.fullmatch(expected) is None:
            raise ContractError("DIGEST_INVALID", f"invalid source digest: {relative}")
        if sha256_path(path) != expected:
            stale.append(relative)
    reports = evidence.get("reports")
    if not isinstance(reports, list) or not reports:
        raise ContractError("REPORTS", "reports must contain entries")
    report_paths: set[str] = set()
    for index, raw_report in enumerate(reports):
        report = _object(raw_report, f"reports[{index}]")
        _reject_unknown(report, REPORT_KEYS, f"reports[{index}]")
        relative = report.get("path")
        path = safe_path(root, relative, f"reports[{index}].path", must_exist=True, file_only=True)
        if relative in report_paths:
            raise ContractError("REPORT_DUPLICATE", f"duplicate report: {relative}")
        report_paths.add(relative)
        expected = report.get("sha256")
        if not isinstance(expected, str) or SHA256_RE.fullmatch(expected) is None:
            raise ContractError("DIGEST_INVALID", f"invalid report digest: {relative}")
        if sha256_path(path) != expected:
            stale.append(relative)
        if report.get("source_task") != task["task_id"] or report.get("acceptance_status") != "PASS":
            raise ContractError("REPORT_NOT_PASS", f"report does not provide PASS for {task['task_id']}: {relative}")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ContractError("REPORT_JSON", f"report is not valid JSON: {relative}") from error
        if payload.get("status") != "PASS":
            raise ContractError("REPORT_NOT_PASS", f"report status is not PASS: {relative}")
    required = set(task["required_evidence"])
    evidence_path = f"docs/evidence/{task['task_id']}/evidence.json"
    if required - ({evidence_path} | report_paths):
        raise ContractError("REQUIRED_EVIDENCE", "required evidence is absent from the index")
    return {"stale_paths": sorted(set(stale)), "report_count": len(reports),
            "source_count": len(source_hashes)}


def verify_one(root: Path, task: Mapping[str, Any]) -> dict[str, Any]:
    relative = f"docs/evidence/{task['task_id']}/evidence.json"
    try:
        path = safe_path(root, relative, "evidence", must_exist=True, file_only=True)
        raw = json.loads(path.read_text(encoding="utf-8"))
        result = validate_evidence(raw, root, task)
    except ContractError as error:
        return {"task_id": task["task_id"], "status": "FAIL", "issues": [{"code": error.code, "detail": error.detail}]}
    except json.JSONDecodeError:
        return {"task_id": task["task_id"], "status": "FAIL", "issues": [{"code": "JSON", "detail": "evidence JSON is invalid"}]}
    if result["stale_paths"]:
        return {"task_id": task["task_id"], "status": "STALE", "issues": [
            {"code": "DIGEST_STALE", "detail": value} for value in result["stale_paths"]]}
    return {"task_id": task["task_id"], "status": "PASS", "issues": [], **result}


def verify(root: Path, task_id: str | None) -> dict[str, Any]:
    try:
        tasks = validate_repository_tasks(root, task_id)
    except ContractError as error:
        return {"schema_version": 1, "kind": "evidence-freshness", "status": "FAIL",
                "tasks": [], "issues": [{"code": error.code, "detail": error.detail}]}
    selected = [tasks[task_id]] if task_id else [tasks[key] for key in sorted(tasks)]
    results = [verify_one(root, task) for task in selected]
    statuses = {result["status"] for result in results}
    status = "FAIL" if "FAIL" in statuses else ("STALE" if "STALE" in statuses else "PASS")
    return {"schema_version": 1, "kind": "evidence-freshness", "status": status,
            "tasks": results, "issues": []}


def seal_evidence(root: Path, task_id: str, report_paths: Sequence[str], output: Path) -> dict[str, Any]:
    tasks = validate_repository_tasks(root, task_id)
    task = tasks[task_id]
    reports = []
    for relative in report_paths:
        path = safe_path(root, relative, "report", must_exist=True, file_only=True)
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("status") != "PASS":
            raise ContractError("REPORT_NOT_PASS", f"cannot seal non-PASS report: {relative}")
        reports.append({"path": relative, "sha256": sha256_path(path),
                        "source_task": task_id, "acceptance_status": "PASS"})
    payload = {"schema_version": EVIDENCE_SCHEMA_VERSION, "source_task": task_id,
               "platform": platform_identity(), "toolchain": toolchain_identity(root),
               "acceptance_status": "PASS", "generated_at_utc": utc_now(),
               "revision": tool_version(["git", "rev-parse", "HEAD"], root),
               "reports": reports,
               "source_sha256": {relative: sha256_path(root / relative) for relative in task["source_paths"]}}
    atomic_json(output, payload)
    return payload


def validate_plan(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {"schema_version": 1, "kind": "test-plan-validation", "status": "FAIL",
                "issues": [{"code": "PLAN_MISSING", "detail": str(path)}]}
    path_ids = set(re.findall(r"^\|\s*(P\d{3})\s*\|", text, re.MULTILINE))
    scenario_ids = set(re.findall(r"^\|\s*(S\d{3})\s*\|", text, re.MULTILINE))
    test_ids = set(re.findall(r"^\|\s*(T\d{3})\s*\|", text, re.MULTILINE))
    issues = []
    for label, values in (("PATH", path_ids), ("SCENARIO", scenario_ids), ("TEST", test_ids)):
        if not values:
            issues.append({"code": f"{label}_MISSING", "detail": f"no {label.lower()} IDs"})
    scenario_section = text[text.find("## Semantics"):text.find("## Test-plan matrix")]
    test_section = text[text.find("## Test-plan matrix"):]
    missing_paths = sorted(value for value in path_ids if value not in scenario_section)
    missing_scenarios = sorted(value for value in scenario_ids if value not in test_section)
    if missing_paths:
        issues.append({"code": "PATH_UNCOVERED", "detail": ",".join(missing_paths)})
    if missing_scenarios:
        issues.append({"code": "SCENARIO_UNCOVERED", "detail": ",".join(missing_scenarios)})
    return {"schema_version": 1, "kind": "test-plan-validation",
            "status": "PASS" if not issues else "FAIL", "issues": issues,
            "counts": {"paths": len(path_ids), "scenarios": len(scenario_ids), "tests": len(test_ids)}}


def emit(report: Mapping[str, Any], json_mode: bool, output: Path | None) -> int:
    if output is not None:
        atomic_json(output, report)
    if json_mode:
        print(json.dumps(report, sort_keys=True))
    else:
        print(f"{report.get('kind', 'repository-tooling')}: {report['status']}")
        for issue in report.get("issues", [])[:20]:
            print(f"- {issue['code']}: {issue['detail'][:512]}")
        for item in report.get("tasks", [])[:20]:
            print(f"- {item['task_id']}: {item['status']}")
        for item in report.get("checks", [])[:30]:
            print(f"- {item['id']}: {item['status']} ({item['detail'][:256]})")
        for item in report.get("commands", [])[:20]:
            print(f"- {item['id']}: {item['status']} ({item['duration_ms']} ms)")
    return EXIT_CODES.get(str(report["status"]), 2)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    sub = result.add_subparsers(dest="command", required=True)
    for name in ("doctor", "validate-tasks"):
        child = sub.add_parser(name)
        child.add_argument("--json", action="store_true")
        child.add_argument("--output", type=Path)
    plan = sub.add_parser("validate-plan")
    plan.add_argument("path", type=Path)
    plan.add_argument("--json", action="store_true")
    plan.add_argument("--output", type=Path)
    check_parser = sub.add_parser("check")
    check_parser.add_argument("mode", choices=("fast", "task", "full", "long"))
    check_parser.add_argument("task_id", nargs="?")
    check_parser.add_argument("--json", action="store_true")
    check_parser.add_argument("--output", type=Path)
    evidence = sub.add_parser("verify-evidence")
    choice = evidence.add_mutually_exclusive_group(required=True)
    choice.add_argument("--all", action="store_true")
    choice.add_argument("--task")
    evidence.add_argument("--json", action="store_true")
    evidence.add_argument("--output", type=Path)
    seal = sub.add_parser("seal-evidence")
    seal.add_argument("task_id")
    seal.add_argument("--report", action="append", required=True)
    seal.add_argument("--output", type=Path, required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = args.root.resolve()
    if args.command == "doctor":
        return emit(doctor(root), args.json, args.output)
    if args.command == "validate-tasks":
        try:
            tasks = validate_repository_tasks(root)
            report = {"schema_version": 1, "kind": "task-contract-validation", "status": "PASS",
                      "task_ids": sorted(tasks), "issues": []}
        except ContractError as error:
            report = {"schema_version": 1, "kind": "task-contract-validation", "status": "INVALID",
                      "task_ids": [], "issues": [{"code": error.code, "detail": error.detail}]}
        return emit(report, args.json, args.output)
    if args.command == "validate-plan":
        path = args.path if args.path.is_absolute() else root / args.path
        return emit(validate_plan(path), args.json, args.output)
    if args.command == "check":
        if args.mode in {"task", "long"} and not args.task_id:
            return emit({"kind": "repository-check", "status": "INVALID", "issues": [
                {"code": "TASK_REQUIRED", "detail": f"{args.mode} mode requires TASK-ID"}], "commands": []}, args.json, args.output)
        return emit(check(root, args.mode, args.task_id), args.json, args.output)
    if args.command == "verify-evidence":
        return emit(verify(root, None if args.all else args.task), args.json, args.output)
    try:
        seal_evidence(root, args.task_id, args.report, args.output)
    except (ContractError, json.JSONDecodeError) as error:
        print(f"seal-evidence: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"seal-evidence: PASS: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
