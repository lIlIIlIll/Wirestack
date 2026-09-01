#!/usr/bin/env python3
"""Execute Wirestack gate manifests with bounded, reproducible evidence.

The runner intentionally uses only the Python standard library. Gate scenarios
run without a shell, have explicit time limits, capture output to files, and
terminate their process group on timeout. A skipped or blocked required
scenario never makes a run pass.
"""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA_VERSION = 1
DEFAULT_TIMEOUT_SECONDS = 60.0
DEFAULT_REPORT_CAPTURE_BYTES = 1024 * 1024
MAX_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_REPORT_CAPTURE_BYTES = 16 * 1024 * 1024
STATUS_PRIORITY = {
    "PASS": 0,
    "SKIPPED": 1,
    "BLOCKED": 2,
    "FAIL": 3,
    "ERROR": 4,
}
EXIT_CODES = {
    "PASS": 0,
    "FAIL": 1,
    "ERROR": 2,
    "BLOCKED": 3,
    "SKIPPED": 4,
}
TOP_LEVEL_KEYS = {"schema_version", "gate_id", "description", "scenarios"}
SCENARIO_KEYS = {
    "id", "description", "enabled", "platforms", "required_tools",
    "environment", "timeout_seconds", "steps",
}
STEP_KEYS = {"id", "description", "command", "cwd", "environment", "timeout_seconds"}
PLACEHOLDERS = {"repo_root", "artifact_dir", "work_dir"}


class ManifestError(ValueError):
    """The gate manifest is invalid and must fail closed."""


@dataclass(frozen=True)
class CommandResult:
    status: str
    exit_code: int | None
    timed_out: bool
    started_at_utc: str
    finished_at_utc: str
    duration_ms: float
    command: list[str]
    cwd: str
    stdout_path: str
    stderr_path: str
    stdout_excerpt: str
    stderr_excerpt: str
    stdout_truncated: bool
    stderr_truncated: bool
    error: str | None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _require_type(value: Any, expected: type | tuple[type, ...], field: str) -> None:
    if not isinstance(value, expected):
        names = ", ".join(t.__name__ for t in expected) if isinstance(expected, tuple) else expected.__name__
        raise ManifestError(f"{field} must be {names}")


def _reject_unknown(mapping: Mapping[str, Any], allowed: set[str], field: str) -> None:
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        raise ManifestError(f"{field} contains unknown field(s): {', '.join(unknown)}")


def _validate_timeout(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ManifestError(f"{field} must be a number")
    number = float(value)
    if number <= 0 or number > MAX_TIMEOUT_SECONDS:
        raise ManifestError(f"{field} must be in (0, {MAX_TIMEOUT_SECONDS}]")
    return number


def validate_manifest(raw: Any) -> dict[str, Any]:
    _require_type(raw, dict, "manifest")
    _reject_unknown(raw, TOP_LEVEL_KEYS, "manifest")
    if raw.get("schema_version") != SCHEMA_VERSION:
        raise ManifestError(
            f"unsupported schema_version {raw.get('schema_version')!r}; expected {SCHEMA_VERSION}"
        )
    gate_id = raw.get("gate_id")
    _require_type(gate_id, str, "gate_id")
    if not gate_id.strip():
        raise ManifestError("gate_id must not be empty")
    if "description" in raw:
        _require_type(raw["description"], str, "description")
    scenarios = raw.get("scenarios")
    _require_type(scenarios, list, "scenarios")
    if not scenarios:
        raise ManifestError("scenarios must not be empty")

    scenario_ids: set[str] = set()
    for scenario_index, scenario in enumerate(scenarios):
        field = f"scenarios[{scenario_index}]"
        _require_type(scenario, dict, field)
        _reject_unknown(scenario, SCENARIO_KEYS, field)
        scenario_id = scenario.get("id")
        _require_type(scenario_id, str, f"{field}.id")
        if not scenario_id.strip():
            raise ManifestError(f"{field}.id must not be empty")
        if scenario_id in scenario_ids:
            raise ManifestError(f"duplicate scenario id: {scenario_id}")
        scenario_ids.add(scenario_id)
        if "description" in scenario:
            _require_type(scenario["description"], str, f"{field}.description")
        if "enabled" in scenario:
            _require_type(scenario["enabled"], bool, f"{field}.enabled")
        if "platforms" in scenario:
            _require_type(scenario["platforms"], list, f"{field}.platforms")
            if not scenario["platforms"]:
                raise ManifestError(f"{field}.platforms must not be empty")
            for index, item in enumerate(scenario["platforms"]):
                _require_type(item, str, f"{field}.platforms[{index}]")
        if "required_tools" in scenario:
            _require_type(scenario["required_tools"], list, f"{field}.required_tools")
            for index, item in enumerate(scenario["required_tools"]):
                _require_type(item, str, f"{field}.required_tools[{index}]")
                if not item:
                    raise ManifestError(f"{field}.required_tools[{index}] must not be empty")
        if "environment" in scenario:
            _validate_environment(scenario["environment"], f"{field}.environment")
        if "timeout_seconds" in scenario:
            _validate_timeout(scenario["timeout_seconds"], f"{field}.timeout_seconds")

        steps = scenario.get("steps")
        _require_type(steps, list, f"{field}.steps")
        if not steps:
            raise ManifestError(f"{field}.steps must not be empty")
        step_ids: set[str] = set()
        for step_index, step in enumerate(steps):
            step_field = f"{field}.steps[{step_index}]"
            _require_type(step, dict, step_field)
            _reject_unknown(step, STEP_KEYS, step_field)
            step_id = step.get("id")
            _require_type(step_id, str, f"{step_field}.id")
            if not step_id.strip():
                raise ManifestError(f"{step_field}.id must not be empty")
            if step_id in step_ids:
                raise ManifestError(f"duplicate step id in {scenario_id}: {step_id}")
            step_ids.add(step_id)
            if "description" in step:
                _require_type(step["description"], str, f"{step_field}.description")
            command = step.get("command")
            _require_type(command, list, f"{step_field}.command")
            if not command:
                raise ManifestError(f"{step_field}.command must not be empty")
            for index, item in enumerate(command):
                _require_type(item, str, f"{step_field}.command[{index}]")
                if not item:
                    raise ManifestError(f"{step_field}.command[{index}] must not be empty")
            if "cwd" in step:
                _require_type(step["cwd"], str, f"{step_field}.cwd")
            if "environment" in step:
                _validate_environment(step["environment"], f"{step_field}.environment")
            if "timeout_seconds" in step:
                _validate_timeout(step["timeout_seconds"], f"{step_field}.timeout_seconds")
    return raw


def _validate_environment(value: Any, field: str) -> None:
    _require_type(value, dict, field)
    for key, item in value.items():
        _require_type(key, str, f"{field} key")
        _require_type(item, str, f"{field}.{key}")


def load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    data = path.read_bytes()
    try:
        raw = json.loads(data)
    except json.JSONDecodeError as error:
        raise ManifestError(f"invalid JSON in {path}: {error}") from error
    return validate_manifest(raw), evidence_digest.text_evidence_bytes_sha256(data)


def platform_name() -> str:
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    if os.name == "nt" or sys.platform.startswith("win"):
        return "windows"
    return sys.platform.lower()


def expand(value: str, values: Mapping[str, str]) -> str:
    try:
        return value.format_map(values)
    except KeyError as error:
        if error.args and error.args[0] not in PLACEHOLDERS:
            raise ManifestError(f"unknown placeholder: {error.args[0]}") from error
        raise


def path_within(root: Path, path: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def read_excerpt(path: Path, limit: int) -> tuple[str, bool]:
    if not path.exists():
        return "", False
    size = path.stat().st_size
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    truncated = len(data) > limit or size > limit
    return data[:limit].decode("utf-8", errors="replace"), truncated


def terminate_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def run_command(
    command: list[str],
    cwd: Path,
    environment: Mapping[str, str],
    timeout_seconds: float,
    stdout_path: Path,
    stderr_path: Path,
    capture_bytes: int,
) -> CommandResult:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    started_at = utc_now()
    started = time.monotonic()
    process: subprocess.Popen[bytes] | None = None
    exit_code: int | None = None
    timed_out = False
    error_message: str | None = None
    try:
        with stdout_path.open("wb") as stdout_stream, stderr_path.open("wb") as stderr_stream:
            kwargs: dict[str, Any] = {
                "args": command,
                "cwd": cwd,
                "env": dict(environment),
                "stdin": subprocess.DEVNULL,
                "stdout": stdout_stream,
                "stderr": stderr_stream,
                "shell": False,
            }
            if os.name == "nt":
                kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            else:
                kwargs["start_new_session"] = True
            process = subprocess.Popen(**kwargs)
            try:
                exit_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_process_tree(process)
                exit_code = process.returncode
    except FileNotFoundError as error:
        error_message = str(error)
    except OSError as error:
        error_message = f"{type(error).__name__}: {error}"
        if process is not None:
            terminate_process_tree(process)
    finished = time.monotonic()
    stdout_excerpt, stdout_truncated = read_excerpt(stdout_path, capture_bytes)
    stderr_excerpt, stderr_truncated = read_excerpt(stderr_path, capture_bytes)
    if error_message is not None:
        status = "ERROR"
    elif timed_out or exit_code != 0:
        status = "FAIL"
    else:
        status = "PASS"
    return CommandResult(
        status=status,
        exit_code=exit_code,
        timed_out=timed_out,
        started_at_utc=started_at,
        finished_at_utc=utc_now(),
        duration_ms=round((finished - started) * 1000.0, 3),
        command=command,
        cwd=str(cwd),
        stdout_path=str(stdout_path),
        stderr_path=str(stderr_path),
        stdout_excerpt=stdout_excerpt,
        stderr_excerpt=stderr_excerpt,
        stdout_truncated=stdout_truncated,
        stderr_truncated=stderr_truncated,
        error=error_message,
    )


def command_version(command: list[str]) -> str | None:
    if shutil.which(command[0]) is None:
        return None
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = completed.stdout.strip()
    return text[:4096] if text else None


def repository_revision(repo_root: Path) -> str:
    override = os.environ.get("GITHUB_SHA")
    if override:
        return override
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
            text=True,
        )
        revision = completed.stdout.strip()
        if completed.returncode == 0 and revision:
            return revision
    except (OSError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def environment_metadata(repo_root: Path) -> dict[str, Any]:
    return {
        "repository_revision": repository_revision(repo_root),
        "platform": platform_name(),
        "os": platform.platform(),
        "architecture": platform.machine(),
        "python": sys.version.splitlines()[0],
        "cjc": command_version(["cjc", "--version"]),
        "cjpm": command_version(["cjpm", "--version"]),
        "cangjie_home": os.environ.get("CANGJIE_HOME"),
    }


def overall_status(statuses: Sequence[str]) -> str:
    if not statuses:
        return "ERROR"
    if all(status == "PASS" for status in statuses):
        return "PASS"
    return max(statuses, key=lambda status: STATUS_PRIORITY[status])


def atomic_write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def execute_manifest(
    manifest: Mapping[str, Any],
    manifest_sha256: str,
    manifest_path: Path,
    repo_root: Path,
    artifact_dir: Path,
    capture_bytes: int,
) -> dict[str, Any]:
    started_at = utc_now()
    started = time.monotonic()
    repo_root = repo_root.resolve()
    artifact_dir = artifact_dir.resolve()
    artifact_dir.mkdir(parents=True, exist_ok=True)
    current_platform = platform_name()
    scenario_results: list[dict[str, Any]] = []

    for scenario in manifest["scenarios"]:
        scenario_id = scenario["id"]
        scenario_artifacts = artifact_dir / scenario_id
        work_dir = scenario_artifacts / "work"
        scenario_artifacts.mkdir(parents=True, exist_ok=True)
        work_dir.mkdir(parents=True, exist_ok=True)
        base_result: dict[str, Any] = {
            "id": scenario_id,
            "description": scenario.get("description", ""),
            "steps": [],
        }
        if scenario.get("enabled", True) is False:
            base_result.update(status="SKIPPED", reason="scenario disabled by manifest")
            scenario_results.append(base_result)
            continue
        allowed_platforms = [item.lower() for item in scenario.get("platforms", [])]
        if allowed_platforms and current_platform not in allowed_platforms:
            base_result.update(
                status="SKIPPED",
                reason=f"platform {current_platform!r} is not in {allowed_platforms!r}",
            )
            scenario_results.append(base_result)
            continue
        missing_tools = [tool for tool in scenario.get("required_tools", []) if shutil.which(tool) is None]
        if missing_tools:
            base_result.update(
                status="BLOCKED",
                reason=f"missing required tool(s): {', '.join(missing_tools)}",
            )
            scenario_results.append(base_result)
            continue

        values = {
            "repo_root": str(repo_root),
            "artifact_dir": str(scenario_artifacts),
            "work_dir": str(work_dir),
        }
        scenario_environment = os.environ.copy()
        scenario_environment.update(
            {key: expand(value, values) for key, value in scenario.get("environment", {}).items()}
        )
        scenario_timeout = _validate_timeout(
            scenario.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS),
            f"scenario {scenario_id}.timeout_seconds",
        )
        step_statuses: list[str] = []
        scenario_started = time.monotonic()
        reason: str | None = None
        for step in scenario["steps"]:
            command = [expand(item, values) for item in step["command"]]
            cwd_text = expand(step.get("cwd", "{repo_root}"), values)
            cwd = Path(cwd_text)
            if not cwd.is_absolute():
                cwd = repo_root / cwd
            cwd = cwd.resolve()
            if not path_within(repo_root, cwd) and not path_within(scenario_artifacts, cwd):
                step_result = {
                    "id": step["id"],
                    "description": step.get("description", ""),
                    "status": "ERROR",
                    "error": f"cwd escapes repository/artifact roots: {cwd}",
                }
                base_result["steps"].append(step_result)
                step_statuses.append("ERROR")
                reason = step_result["error"]
                break
            if not cwd.is_dir():
                step_result = {
                    "id": step["id"],
                    "description": step.get("description", ""),
                    "status": "ERROR",
                    "error": f"cwd does not exist: {cwd}",
                }
                base_result["steps"].append(step_result)
                step_statuses.append("ERROR")
                reason = step_result["error"]
                break
            environment = scenario_environment.copy()
            environment.update(
                {key: expand(value, values) for key, value in step.get("environment", {}).items()}
            )
            timeout = _validate_timeout(
                step.get("timeout_seconds", scenario_timeout),
                f"scenario {scenario_id} step {step['id']}.timeout_seconds",
            )
            result = run_command(
                command=command,
                cwd=cwd,
                environment=environment,
                timeout_seconds=timeout,
                stdout_path=scenario_artifacts / f"{step['id']}.stdout.log",
                stderr_path=scenario_artifacts / f"{step['id']}.stderr.log",
                capture_bytes=capture_bytes,
            )
            step_result = {"id": step["id"], "description": step.get("description", ""), **result.__dict__}
            base_result["steps"].append(step_result)
            step_statuses.append(result.status)
            if result.status != "PASS":
                if result.timed_out:
                    reason = f"step {step['id']} exceeded {timeout} seconds"
                elif result.error:
                    reason = f"step {step['id']} could not start: {result.error}"
                else:
                    reason = f"step {step['id']} exited with {result.exit_code}"
                break
        scenario_status = overall_status(step_statuses)
        base_result.update(
            status=scenario_status,
            reason=reason,
            duration_ms=round((time.monotonic() - scenario_started) * 1000.0, 3),
        )
        scenario_results.append(base_result)

    status = overall_status([scenario["status"] for scenario in scenario_results])
    return {
        "schema_version": SCHEMA_VERSION,
        "gate_id": manifest["gate_id"],
        "description": manifest.get("description", ""),
        "status": status,
        "started_at_utc": started_at,
        "finished_at_utc": utc_now(),
        "duration_ms": round((time.monotonic() - started) * 1000.0, 3),
        "manifest": {
            "path": str(manifest_path.resolve()),
            "sha256": manifest_sha256,
        },
        "environment": environment_metadata(repo_root),
        "scenarios": scenario_results,
    }


def render_summary(report: Mapping[str, Any]) -> str:
    lines = [f"{report['gate_id']}: {report['status']}"]
    for scenario in report["scenarios"]:
        line = f"- {scenario['id']}: {scenario['status']}"
        if scenario.get("reason"):
            line += f" — {scenario['reason']}"
        lines.append(line)
    return "\n".join(lines)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--capture-bytes", type=int, default=DEFAULT_REPORT_CAPTURE_BYTES,
        help=f"maximum stdout/stderr bytes embedded per step (max {MAX_REPORT_CAPTURE_BYTES})",
    )
    parser.add_argument("--print-json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.capture_bytes <= 0 or args.capture_bytes > MAX_REPORT_CAPTURE_BYTES:
        print(f"capture-bytes must be in [1, {MAX_REPORT_CAPTURE_BYTES}]", file=sys.stderr)
        return EXIT_CODES["ERROR"]
    try:
        manifest, digest = load_manifest(args.manifest)
        report = execute_manifest(
            manifest=manifest,
            manifest_sha256=digest,
            manifest_path=args.manifest,
            repo_root=args.repo_root,
            artifact_dir=args.artifact_dir,
            capture_bytes=args.capture_bytes,
        )
        atomic_write_json(args.output, report)
    except (ManifestError, OSError) as error:
        report = {
            "schema_version": SCHEMA_VERSION,
            "gate_id": "unknown",
            "status": "ERROR",
            "error": f"{type(error).__name__}: {error}",
        }
        try:
            atomic_write_json(args.output, report)
        except OSError:
            pass
        print(render_summary({**report, "scenarios": []}), file=sys.stderr)
        return EXIT_CODES["ERROR"]
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) if args.print_json else render_summary(report))
    return EXIT_CODES[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
