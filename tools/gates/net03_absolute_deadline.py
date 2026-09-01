#!/usr/bin/env python3
"""Capture Linux x86_64 GATE-NET-03 absolute-deadline evidence.

The harness compiles small Cangjie programs against the active SDK and drives
blocked read, repeated write, connect, and accept operations.  A single
external deadline owner closes the public std.net object; no mutable socket
read/write timeout is used.  Results are schema-versioned JSON and deliberately
remain Linux-only evidence.
"""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import contextlib
import datetime as dt
import json
import math
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Iterator, Mapping, Sequence

SCHEMA_VERSION = 1
DEFAULT_BUDGETS_MS = (50, 200, 1000)
RESULT_RE = re.compile(r"^RESULT\s+(.+)$", re.M)
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")

from net03_absolute_deadline_sources import EXPECTED_TERMINALS, SOURCES


class GateError(RuntimeError):
    pass


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(1, math.ceil(percent / 100.0 * len(ordered))) - 1
    return round(ordered[index], 3)


def command_text(command: Sequence[str]) -> str | None:
    try:
        completed = subprocess.run(
            list(command),
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.strip()
    return value[:4096] if value else None


def run_process(command: Sequence[str], cwd: Path, timeout_seconds: float) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "args": list(command),
        "cwd": cwd,
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "text": True,
        "errors": "replace",
        "shell": False,
    }
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True
    started = time.monotonic()
    process = subprocess.Popen(**kwargs)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        if os.name == "nt":
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        stdout, stderr = process.communicate()
    return {
        "command": list(command),
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000.0, 3),
        "stdout": stdout[-65536:],
        "stderr": stderr[-65536:],
    }


def parse_result(stdout: str) -> dict[str, str]:
    lines = RESULT_RE.findall(stdout)
    if len(lines) != 1:
        raise GateError(f"expected exactly one RESULT line, found {len(lines)}")
    values = dict(FIELD_RE.findall(lines[0]))
    required = {
        "scenario",
        "budgetMs",
        "budgetStartNs",
        "opStartNs",
        "terminalBeforeClose",
        "closeStartNs",
        "closeDoneNs",
        "terminalNs",
        "terminalCode",
        "closeCode",
    }
    missing = required - values.keys()
    if missing:
        raise GateError(f"missing result fields: {sorted(missing)}")
    return values


def classify(values: Mapping[str, str], process: Mapping[str, Any]) -> dict[str, Any]:
    scenario = values["scenario"]
    budget_ms = int(values["budgetMs"])
    budget_start_ns = int(values["budgetStartNs"])
    start_ns = int(values["opStartNs"])
    close_start_ns = int(values["closeStartNs"])
    close_done_ns = int(values["closeDoneNs"])
    terminal_ns = int(values["terminalNs"])
    terminal_code = int(values["terminalCode"])
    close_code = int(values["closeCode"])
    terminal_before_close = values["terminalBeforeClose"] == "true"
    expected_deadline_ns = budget_start_ns + budget_ms * 1_000_000
    total_ms = round((terminal_ns - budget_start_ns) / 1_000_000.0, 3)
    owner_late_ms = round((close_start_ns - expected_deadline_ns) / 1_000_000.0, 3)
    overshoot_ms = round((terminal_ns - expected_deadline_ns) / 1_000_000.0, 3)
    wake_ms = round((terminal_ns - close_start_ns) / 1_000_000.0, 3)
    tolerance_ms = max(20.0, budget_ms * 0.05)

    blocked = not terminal_before_close
    count_a: int | None = None
    count_b: int | None = None
    checkpoint_span_ms: float | None = None
    if scenario == "partial-write":
        count_a = int(values.get("countA", "-1"))
        count_b = int(values.get("countB", "-1"))
        checkpoint_ns = int(values.get("checkpointNs", "-1"))
        checkpoint_fired = values.get("checkpointFired", "false") == "true"
        checkpoint_span_ms = round((close_start_ns - checkpoint_ns) / 1_000_000.0, 3)
        blocked = (
            blocked
            and checkpoint_fired
            and count_a == count_b
            and count_a >= 0
            and checkpoint_span_ms >= 15.0
        )

    start_delay_ms = round((start_ns - budget_start_ns) / 1_000_000.0, 3)
    timing_order = (
        0 <= budget_start_ns <= start_ns <= close_start_ns <= close_done_ns
        and terminal_ns >= close_start_ns
        and start_delay_ms <= 5.0
    )
    no_early_expiry = owner_late_ms >= -2.0
    within_tolerance = overshoot_ms <= tolerance_ms
    expected_terminal = terminal_code in EXPECTED_TERMINALS.get(scenario, set())
    process_ok = not process["timed_out"] and process["exit_code"] == 0
    close_ok = close_code == 0
    passed = all(
        (
            process_ok,
            blocked,
            timing_order,
            no_early_expiry,
            within_tolerance,
            expected_terminal,
            close_ok,
        )
    )
    if passed:
        decision = "PASS"
    elif not blocked:
        decision = "NOT_BLOCKED"
    else:
        decision = "FAIL"
    return {
        "scenario": scenario,
        "budget_ms": budget_ms,
        "decision": decision,
        "blocked": blocked,
        "operation_start_delay_ms": start_delay_ms,
        "total_ms": total_ms,
        "deadline_owner_late_ms": owner_late_ms,
        "overshoot_ms": overshoot_ms,
        "wake_after_close_ms": wake_ms,
        "tolerance_ms": tolerance_ms,
        "terminal_code": terminal_code,
        "close_code": close_code,
        "terminal_before_close": terminal_before_close,
        "count_a": count_a,
        "count_b": count_b,
        "checkpoint_span_ms": checkpoint_span_ms,
        "process": dict(process),
    }


@contextlib.contextmanager
def passive_server(*, receive_buffer: int | None = None) -> Iterator[int]:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if receive_buffer is not None:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(0.2)
    port = int(listener.getsockname()[1])
    stop = threading.Event()
    accepted: list[socket.socket] = []

    def serve() -> None:
        while not stop.is_set():
            try:
                connection, _ = listener.accept()
                if receive_buffer is not None:
                    connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
                accepted.append(connection)
                break
            except socket.timeout:
                continue
            except OSError:
                return
        stop.wait()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield port
    finally:
        stop.set()
        for connection in accepted:
            try:
                connection.close()
            except OSError:
                pass
        try:
            listener.close()
        except OSError:
            pass
        thread.join(timeout=2)
        if thread.is_alive():
            raise GateError("passive server thread did not terminate")


@contextlib.contextmanager
def saturated_listener() -> Iterator[int]:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = int(listener.getsockname()[1])
    fillers: list[socket.socket] = []
    saturated = False
    for _ in range(64):
        candidate = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        candidate.settimeout(0.03)
        try:
            candidate.connect(("127.0.0.1", port))
            fillers.append(candidate)
        except (socket.timeout, TimeoutError):
            candidate.close()
            saturated = True
            break
        except OSError:
            candidate.close()
            break
    if not saturated:
        for candidate in fillers:
            candidate.close()
        listener.close()
        raise GateError("could not saturate local listen backlog")
    try:
        yield port
    finally:
        for candidate in fillers:
            try:
                candidate.close()
            except OSError:
                pass
        listener.close()


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def compile_probes(artifact_dir: Path, timeout_seconds: float) -> tuple[dict[str, Path], dict[str, str]]:
    binaries: dict[str, Path] = {}
    digests: dict[str, str] = {}
    for name, source in SOURCES.items():
        directory = artifact_dir / name
        directory.mkdir(parents=True, exist_ok=True)
        source_path = directory / f"{name}.cj"
        binary_path = directory / name
        source_path.write_text(source, encoding="utf-8")
        result = run_process(["cjc", str(source_path), "-o", str(binary_path)], directory, timeout_seconds)
        if result["timed_out"] or result["exit_code"] != 0 or not binary_path.is_file():
            raise GateError(f"compile failed for {name}: {result}")
        binaries[name] = binary_path
        digests[name] = evidence_digest.text_evidence_bytes_sha256(source.encode("utf-8"))
    return binaries, digests


def run_sample(
    name: str,
    budget_ms: int,
    binary: Path,
    artifact_dir: Path,
    timeout_seconds: float,
) -> dict[str, Any]:
    if name == "idle-read":
        context = passive_server()
    elif name == "partial-write":
        context = passive_server(receive_buffer=4096)
    elif name == "blocked-connect":
        context = saturated_listener()
    elif name == "blocked-accept":
        context = contextlib.nullcontext(reserve_port())
    else:
        raise GateError(f"unknown scenario: {name}")
    with context as port:
        process = run_process(
            [str(binary), str(port), str(budget_ms)],
            artifact_dir / name,
            timeout_seconds,
        )
    values = parse_result(process["stdout"])
    return classify(values, process)


def aggregate(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    metrics = {
        "total_ms": [float(sample["total_ms"]) for sample in samples],
        "deadline_owner_late_ms": [float(sample["deadline_owner_late_ms"]) for sample in samples],
        "overshoot_ms": [float(sample["overshoot_ms"]) for sample in samples],
        "wake_after_close_ms": [float(sample["wake_after_close_ms"]) for sample in samples],
    }
    return {
        key: {
            "p50": percentile(values, 50),
            "p95": percentile(values, 95),
            "p99": percentile(values, 99),
            "max": round(max(values), 3) if values else None,
        }
        for key, values in metrics.items()
    }


def execute(
    repo_root: Path,
    artifact_dir: Path,
    budgets_ms: Sequence[int],
    warmup: int,
    repetitions: int,
    timeout_seconds: float,
    repository_revision: str,
    scenarios: Sequence[str],
) -> dict[str, Any]:
    if shutil.which("cjc") is None:
        raise GateError("cjc is unavailable; source the supplied SDK environment")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    binaries, digests = compile_probes(artifact_dir, timeout_seconds)
    cases: list[dict[str, Any]] = []
    for name in scenarios:
        if name not in SOURCES:
            raise GateError(f"unknown scenario: {name}")
        for budget_ms in budgets_ms:
            print(f"running {name} budget={budget_ms}ms warmup={warmup} repetitions={repetitions}", flush=True)
            for _ in range(warmup):
                run_sample(name, budget_ms, binaries[name], artifact_dir, timeout_seconds)
            samples = [
                run_sample(name, budget_ms, binaries[name], artifact_dir, timeout_seconds)
                for _ in range(repetitions)
            ]
            if all(sample["decision"] == "PASS" for sample in samples):
                decision = "PASS"
            elif all(sample["decision"] == "NOT_BLOCKED" for sample in samples):
                decision = "BLOCKED"
            else:
                decision = "FAIL"
            cases.append(
                {
                    "scenario": name,
                    "budget_ms": budget_ms,
                    "decision": decision,
                    "sample_count": len(samples),
                    "source_sha256": digests[name],
                    "aggregate": aggregate(samples),
                    "samples": samples,
                }
            )
    overall = "PASS" if all(case["decision"] == "PASS" for case in cases) else "INCOMPLETE"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-008",
        "gate_id": "GATE-NET-03",
        "status": overall,
        "global_gate_status": "INCOMPLETE",
        "scope": "Linux x86_64 supplied-SDK absolute-deadline evidence using public close wakeup",
        "non_claims": [
            "not six-platform gate completion",
            "not Wirestack OperationContext implementation",
            "does not claim public abort exists",
            "does not use mutable per-socket timeout as the total budget",
        ],
        "thresholds": {
            "overshoot": "max(20 ms, budget * 5%)",
            "deadline_early_allowance_ms": 2.0,
        },
        "configuration": {
            "budgets_ms": list(budgets_ms),
            "warmup": warmup,
            "repetitions": repetitions,
            "timeout_seconds": timeout_seconds,
        },
        "environment": {
            "repository_revision": repository_revision,
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "os": platform.platform(),
            "architecture": platform.machine(),
            "python": sys.version.splitlines()[0],
            "cjc": command_text(["cjc", "--version"]),
            "cjpm": command_text(["cjpm", "--version"]),
            "cangjie_home": os.environ.get("CANGJIE_HOME"),
        },
        "cases": cases,
    }


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def parse_budgets(value: str) -> tuple[int, ...]:
    budgets = tuple(int(item.strip()) for item in value.split(",") if item.strip())
    if not budgets or any(item <= 0 for item in budgets):
        raise argparse.ArgumentTypeError("budgets must be positive comma-separated integers")
    return budgets


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=root)
    parser.add_argument(
        "--artifact-dir", type=Path, default=root / "build/gates/net03-absolute-deadline"
    )
    parser.add_argument(
        "--output", type=Path, default=root / "build/gates/net03-absolute-deadline.json"
    )
    parser.add_argument("--budgets-ms", type=parse_budgets, default=DEFAULT_BUDGETS_MS)
    parser.add_argument(
        "--scenarios",
        default=",".join(SOURCES),
        help="comma-separated scenario ids",
    )
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--timeout-seconds", type=float, default=8.0)
    parser.add_argument(
        "--repository-revision",
        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"),
    )
    parser.add_argument("--quick", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.warmup < 0 or args.repetitions <= 0 or args.timeout_seconds <= 0:
        print("warmup must be >= 0; repetitions and timeout must be > 0", file=sys.stderr)
        return 2
    if args.quick:
        args.warmup = 0
        args.repetitions = 2
        args.budgets_ms = (50, 200)
    try:
        report = execute(
            args.repo_root.resolve(),
            args.artifact_dir.resolve(),
            args.budgets_ms,
            args.warmup,
            args.repetitions,
            args.timeout_seconds,
            args.repository_revision,
            tuple(item.strip() for item in args.scenarios.split(",") if item.strip()),
        )
        atomic_write_json(args.output.resolve(), report)
    except (GateError, OSError, ValueError) as error:
        print(f"GATE-NET-03: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"GATE-NET-03 Linux x86_64: {report['status']} (global: INCOMPLETE)")
    for case in report["cases"]:
        aggregate_values = case["aggregate"]["overshoot_ms"]
        print(
            f"- {case['scenario']} budget={case['budget_ms']}ms: {case['decision']}; "
            f"overshoot p99={aggregate_values['p99']}ms max={aggregate_values['max']}ms"
        )
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
