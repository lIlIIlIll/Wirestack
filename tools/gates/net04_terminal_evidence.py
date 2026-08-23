#!/usr/bin/env python3
"""Run the Linux x86_64 portion of GATE-NET-04 against the active Cangjie SDK."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

from net04_terminal_evidence_sources import (
    ABORT_SOURCE,
    CANCEL_SOURCE,
    LOCAL_CLOSE_SOURCE,
    PEER_SOURCE,
    RACE_SOURCE,
)

SCHEMA_VERSION = 1
RESULT_RE = re.compile(r"^RESULT\s+(.+)$", re.M)
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")


class GateError(RuntimeError):
    pass


def percentile(values: Sequence[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(1, math.ceil(percent / 100.0 * len(ordered))) - 1
    return round(ordered[index], 3)


def run_process(command: Sequence[str], cwd: Path, timeout: float) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "args": list(command), "cwd": cwd, "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
        "text": True, "errors": "replace", "shell": False,
    }
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True
    started = time.monotonic()
    process = subprocess.Popen(**kwargs)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
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
        "command": list(command), "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000.0, 3),
        "stdout": stdout[-65536:], "stderr": stderr[-65536:],
    }


def parse_result(stdout: str) -> dict[str, str]:
    matches = RESULT_RE.findall(stdout)
    if len(matches) != 1:
        raise GateError(f"expected one RESULT line, found {len(matches)}")
    fields = dict(FIELD_RE.findall(matches[0]))
    if "scenario" not in fields or "terminalCode" not in fields:
        raise GateError(f"incomplete RESULT fields: {fields}")
    return fields


def command_text(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=10)
    except Exception:
        return None
    return (result.stdout or result.stderr).strip()[:4096] or None


class OneShotServer:
    def __init__(self, mode: str, delay_ms: int) -> None:
        self.mode = mode
        self.delay_ms = delay_ms
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.port = int(self.listener.getsockname()[1])
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: str | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        connection: socket.socket | None = None
        self.ready.set()
        try:
            while not self.stop.is_set():
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
                except OSError:
                    return
            if connection is None:
                return
            if self.mode == "hold":
                self.stop.wait()
                return
            if self.stop.wait(self.delay_ms / 1000.0):
                return
            if self.mode == "fin":
                try:
                    connection.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                self.stop.wait(0.05)
            elif self.mode == "rst":
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            else:
                raise GateError(f"unknown server mode: {self.mode}")
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
        finally:
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass
            try:
                self.listener.close()
            except OSError:
                pass

    def __enter__(self) -> "OneShotServer":
        self.thread.start()
        if not self.ready.wait(2):
            raise GateError("server did not become ready")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop.set()
        try:
            self.listener.close()
        except OSError:
            pass
        self.thread.join(2)
        if self.thread.is_alive():
            raise GateError("server thread leaked")
        if self.error:
            raise GateError(self.error)


def compile_source(source: str, name: str, artifacts: Path, timeout: float) -> tuple[Path, dict[str, Any]]:
    directory = artifacts / name
    directory.mkdir(parents=True, exist_ok=True)
    source_path = directory / f"{name}.cj"
    binary = directory / name
    source_path.write_text(source, encoding="utf-8")
    result = run_process(["cjc", str(source_path), "-o", str(binary)], directory, timeout)
    if result["timed_out"] or result["exit_code"] != 0 or not binary.is_file():
        raise GateError(f"compile failed for {name}: {result}")
    return binary, {
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "compile": result,
    }


def capability_probe(source: str, name: str, artifacts: Path, timeout: float) -> dict[str, Any]:
    directory = artifacts / name
    directory.mkdir(parents=True, exist_ok=True)
    source_path = directory / f"{name}.cj"
    source_path.write_text(source, encoding="utf-8")
    result = run_process(["cjc", str(source_path), "-o", str(directory / name)], directory, timeout)
    return {
        "id": name,
        "decision": "SUPPORTED" if result["exit_code"] == 0 and not result["timed_out"] else "BLOCKED",
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "diagnostic_sha256": hashlib.sha256(result["stderr"].encode()).hexdigest(),
        "process": result,
    }


def classify_peer(kind: str, fields: Mapping[str, str], process: Mapping[str, Any]) -> dict[str, Any]:
    code = int(fields["terminalCode"])
    bytes_read = int(fields.get("bytes", "-1"))
    process_ok = process["exit_code"] == 0 and not process["timed_out"]
    passed = process_ok and ((kind == "peer-fin" and code == 1 and bytes_read == 0) or
                             (kind == "peer-rst" and code == 4 and bytes_read == -1))
    return {"kind": kind, "decision": "PASS" if passed else "FAIL",
            "terminal_code": code, "bytes": bytes_read, "process": dict(process)}


def classify_local(fields: Mapping[str, str], process: Mapping[str, Any]) -> dict[str, Any]:
    code = int(fields["terminalCode"])
    before = fields["terminalBeforeClose"] == "true"
    close_start = int(fields["closeStartNs"])
    terminal = int(fields["terminalNs"])
    close_code = int(fields["closeCode"])
    distinct = code != 1
    passed = (process["exit_code"] == 0 and not process["timed_out"] and not before and
              terminal >= close_start and close_code == 0 and distinct)
    return {"kind": "local-close", "decision": "PASS" if passed else ("AMBIGUOUS" if not distinct else "FAIL"),
            "terminal_code": code, "bytes": int(fields.get("bytes", "-1")),
            "terminal_before_close": before,
            "wake_ms": round((terminal - close_start) / 1_000_000, 3),
            "close_code": close_code, "process": dict(process)}


def classify_race(ordering: str, fields: Mapping[str, str], process: Mapping[str, Any]) -> dict[str, Any]:
    code = int(fields["terminalCode"])
    before = fields["terminalBeforeLocalClose"] == "true"
    close_start = int(fields["closeStartNs"])
    terminal = int(fields["terminalNs"])
    process_ok = process["exit_code"] == 0 and not process["timed_out"]
    if ordering == "peer-first":
        passed = process_ok and before and code == 1
    elif ordering == "local-first":
        passed = process_ok and not before and terminal >= close_start and code != 1
    else:
        passed = process_ok and code in {1, 4}
    return {"kind": "close-read-race", "ordering": ordering,
            "decision": "PASS" if passed else ("AMBIGUOUS" if ordering == "local-first" and code == 1 else "FAIL"),
            "seed": int(fields["seed"]), "terminal_code": code,
            "bytes": int(fields.get("bytes", "-1")),
            "terminal_before_local_close": before, "process": dict(process)}


def race_delays(seed: int) -> tuple[str, int, int]:
    jitter = seed % 5
    if seed % 3 == 0:
        return "peer-first", 60 + jitter, 20 + jitter
    if seed % 3 == 1:
        return "local-first", 20 + jitter, 60 + jitter
    return "simultaneous", 30 + jitter, 30 + jitter


def aggregate(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    decisions: dict[str, int] = {}
    codes: dict[str, int] = {}
    durations: list[float] = []
    for sample in samples:
        decisions[str(sample["decision"])] = decisions.get(str(sample["decision"]), 0) + 1
        codes[str(sample["terminal_code"])] = codes.get(str(sample["terminal_code"]), 0) + 1
        durations.append(float(sample["process"]["duration_ms"]))
    return {"decision_counts": decisions, "terminal_code_counts": codes,
            "duration_ms": {"p50": percentile(durations, 50), "p95": percentile(durations, 95),
                            "p99": percentile(durations, 99), "max": round(max(durations), 3)}}


def execute(artifacts: Path, repetitions: int, race_seeds: int, timeout: float, revision: str) -> dict[str, Any]:
    artifacts.mkdir(parents=True, exist_ok=True)
    peer, peer_compile = compile_source(PEER_SOURCE, "peer-terminal", artifacts, timeout)
    local, local_compile = compile_source(LOCAL_CLOSE_SOURCE, "local-close", artifacts, timeout)
    race, race_compile = compile_source(RACE_SOURCE, "close-read-race", artifacts, timeout)

    fin_samples = []
    rst_samples = []
    local_samples = []
    race_samples = []
    for _ in range(repetitions):
        with OneShotServer("fin", 30) as server:
            process = run_process([str(peer), str(server.port)], artifacts / "peer-terminal", timeout)
        fin_samples.append(classify_peer("peer-fin", parse_result(process["stdout"]), process))
        with OneShotServer("rst", 30) as server:
            process = run_process([str(peer), str(server.port)], artifacts / "peer-terminal", timeout)
        rst_samples.append(classify_peer("peer-rst", parse_result(process["stdout"]), process))
        with OneShotServer("hold", 0) as server:
            process = run_process([str(local), str(server.port), "30"], artifacts / "local-close", timeout)
        local_samples.append(classify_local(parse_result(process["stdout"]), process))
    for seed in range(race_seeds):
        ordering, local_delay, peer_delay = race_delays(seed)
        with OneShotServer("fin", peer_delay) as server:
            process = run_process([str(race), str(server.port), str(local_delay), str(seed)],
                                  artifacts / "close-read-race", timeout)
        race_samples.append(classify_race(ordering, parse_result(process["stdout"]), process))

    scenarios = []
    for identifier, samples, compile_info in (
        ("peer-fin", fin_samples, peer_compile), ("peer-rst", rst_samples, peer_compile),
        ("local-close", local_samples, local_compile), ("close-read-race", race_samples, race_compile),
    ):
        scenarios.append({"id": identifier,
                          "decision": "PASS" if all(x["decision"] == "PASS" for x in samples) else "FAIL",
                          "sample_count": len(samples), "compile": compile_info,
                          "aggregate": aggregate(samples), "samples": samples})
    capabilities = [capability_probe(ABORT_SOURCE, "abort-capability", artifacts, timeout),
                    capability_probe(CANCEL_SOURCE, "cancel-capability", artifacts, timeout)]
    semantics_pass = all(x["decision"] == "PASS" for x in scenarios)
    capabilities_present = all(x["decision"] == "SUPPORTED" for x in capabilities)
    linux_gate = "PASS" if semantics_pass and capabilities_present else ("INCOMPLETE" if semantics_pass else "FAIL")
    return {
        "schema_version": SCHEMA_VERSION, "task_id": "M0-009", "task_status": "COMPLETE",
        "gate_id": "GATE-NET-04", "linux_gate_status": linux_gate,
        "global_gate_status": "INCOMPLETE",
        "terminal_code_vocabulary": {"1": "read returned 0", "2": "positive read",
                                     "3": "SocketTimeoutException", "4": "SocketException",
                                     "5": "other Exception"},
        "configuration": {"repetitions": repetitions, "race_seeds": race_seeds,
                          "timeout_seconds": timeout},
        "environment": {"repository_revision": revision,
                        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "os": platform.platform(), "architecture": platform.machine(),
                        "python": sys.version.splitlines()[0],
                        "cjc": command_text(["cjc", "--version"]),
                        "cjpm": command_text(["cjpm", "--version"]),
                        "cangjie_home": os.environ.get("CANGJIE_HOME")},
        "non_claims": ["not six-platform completion", "not Wirestack Transport semantics",
                       "does not use exception-message control flow", "does not claim abort/cancel exists"],
        "scenarios": scenarios, "capabilities": capabilities,
    }


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path, default=root / "build/gates/net04-terminal-evidence")
    parser.add_argument("--output", type=Path, default=root / "build/gates/net04-terminal-evidence.json")
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--race-seeds", type=int, default=90)
    parser.add_argument("--timeout-seconds", type=float, default=8)
    parser.add_argument("--repository-revision", default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args(argv)
    if args.quick:
        args.repetitions = 2; args.race_seeds = 6
    try:
        report = execute(args.artifact_dir.resolve(), args.repetitions, args.race_seeds,
                         args.timeout_seconds, args.repository_revision)
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-04: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"M0-009 task={report['task_status']} Linux={report['linux_gate_status']} global=INCOMPLETE")
    for scenario in report["scenarios"]:
        print(f"- {scenario['id']}: {scenario['decision']} samples={scenario['sample_count']} codes={scenario['aggregate']['terminal_code_counts']}")
    for capability in report["capabilities"]:
        print(f"- {capability['id']}: {capability['decision']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
