#!/usr/bin/env python3
"""Run M2-015 against production connector code in an ephemeral Linux netns."""
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
import re
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence


RESULT_RE = re.compile(
    r"^\s*M2015_RESULT scenario=(\S+) outcome=(\S+) "
    r"(?:winners=(\d+) attempts=(\d+) cancelledLosers=(\d+)|"
    r"terminal=(\S+) attempts=(\d+)) elapsedMs=(\d+)\s*$",
    re.MULTILINE,
)
TC_RE = re.compile(r"Sent\s+(\d+)\s+bytes\s+(\d+)\s+pkt\s+\(dropped\s+(\d+)")
BLACKHOLE_ITERATIONS = 64
LOSS_ITERATIONS = 128
DEADLINE_MS = 350
DEADLINE_OVERSHOOT_MS = 250
DEADLINE_COUNT_DELTA_MS = 150


class GateError(RuntimeError):
    pass


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_checked(command: Sequence[str], *, timeout: float = 30.0) -> str:
    result = subprocess.run(
        list(command), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, errors="replace", timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise GateError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{(result.stderr or result.stdout)[-4000:]}"
        )
    return result.stdout


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def descendants(root_pid: int) -> set[int]:
    parents: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            for line in (entry / "status").read_text(encoding="utf-8").splitlines():
                if line.startswith("PPid:"):
                    parents[int(entry.name)] = int(line.split()[1])
                    break
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            continue
    result = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, parent in parents.items():
            if parent in result and pid not in result:
                result.add(pid)
                changed = True
    return result


def process_tree_snapshot(root_pid: int, elapsed_ms: int) -> dict[str, int]:
    sample = {
        "elapsed_ms": elapsed_ms, "process_count": 0, "rss_kib": 0,
        "fd_count": 0, "socket_count": 0, "thread_count": 0,
    }
    for pid in descendants(root_pid):
        try:
            lines = Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines()
            entries = list(Path(f"/proc/{pid}/fd").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        links: list[str] = []
        for entry in entries:
            try:
                links.append(entry.readlink().as_posix())
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        sample["process_count"] += 1
        sample["fd_count"] += len(entries)
        sample["socket_count"] += sum(item.startswith("socket:[") for item in links)
        for line in lines:
            if line.startswith("VmRSS:"):
                sample["rss_kib"] += int(line.split()[1])
            elif line.startswith("Threads:"):
                sample["thread_count"] += int(line.split()[1])
    return sample


class ProcessTreeSampler:
    def __init__(self, interval: float = 0.025) -> None:
        self.interval = interval
        self.samples: list[dict[str, int]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        started = time.monotonic_ns()

        def sample() -> None:
            while not self._stop.is_set():
                item = process_tree_snapshot(
                    pid, int((time.monotonic_ns() - started) / 1_000_000)
                )
                if item["process_count"]:
                    self.samples.append(item)
                self._stop.wait(self.interval)

        self._thread = threading.Thread(target=sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(2)
            if self._thread.is_alive():
                raise GateError("process-tree sampler did not stop")


def resource_trend(samples: Sequence[Mapping[str, int]]) -> dict[str, Any]:
    if len(samples) < 20:
        return {"decision": "INCONCLUSIVE", "reason": "fewer than 20 samples"}
    warmup = max(1, len(samples) // 5)
    steady = list(samples[warmup:])
    window = max(1, len(steady) // 5)
    first = steady[:window]
    last = steady[-window:]
    limits = {
        "process_count": 0.0, "socket_count": 2.0, "thread_count": 4.0,
        "fd_count": 8.0, "rss_kib": 16384.0,
    }
    growth: dict[str, Any] = {}
    passed = True
    for key, limit in limits.items():
        first_value = statistics.median(float(item[key]) for item in first)
        last_value = statistics.median(float(item[key]) for item in last)
        delta = last_value - first_value
        growth[key] = {
            "first_median": first_value, "last_median": last_value,
            "growth": delta, "growth_limit": limit,
        }
        passed = passed and delta <= limit
    return {
        "decision": "PASS" if passed else "FAIL",
        "sample_count": len(samples), "warmup_samples_excluded": warmup,
        "comparison_window_samples": window, "growth": growth,
    }


class AcceptServer:
    def __init__(self, family: int, address: str, expected: int) -> None:
        self.expected = expected
        self.accepted = 0
        self.error: str | None = None
        self._stop = threading.Event()
        self.socket = socket.socket(family, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            self.socket.bind((address, 0, 0, 0))
        else:
            self.socket.bind((address, 0))
        self.socket.listen(256)
        self.socket.settimeout(0.1)
        self.port = int(self.socket.getsockname()[1])
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self) -> None:
        try:
            while not self._stop.is_set() and self.accepted < self.expected:
                try:
                    connection, _ = self.socket.accept()
                except socket.timeout:
                    continue
                self.accepted += 1
                connection.close()
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"

    def __enter__(self) -> "AcceptServer":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        self.socket.close()
        self.thread.join(2)
        if self.thread.is_alive():
            raise GateError("accept server thread did not stop")


def configure_namespace() -> None:
    run_checked(["ip", "link", "set", "lo", "up"])
    for address in ("192.0.2.2", *(f"192.0.2.{value}" for value in range(10, 18))):
        run_checked(["ip", "addr", "add", f"{address}/32", "dev", "lo"])
    run_checked(["ip", "-6", "addr", "add", "2001:db8::2/128", "dev", "lo"])


def reset_impairment() -> None:
    subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run(["tc", "qdisc", "del", "dev", "lo", "clsact"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def configure_netem(*, delay_ms: int | None = None, loss: str | None = None) -> None:
    command = ["tc", "qdisc", "add", "dev", "lo", "root", "netem"]
    if delay_ms is not None:
        command.extend(["delay", f"{delay_ms}ms"])
    if loss is not None:
        command.extend(["loss", "random", loss, "seed", "2015"])
    run_checked(command)


def configure_drop(family: str) -> None:
    run_checked(["tc", "qdisc", "add", "dev", "lo", "clsact"])
    if family == "ipv6":
        protocol, destination = "ipv6", "2001:db8::2"
    else:
        protocol, destination = "ip", "192.0.2.0/24"
    run_checked([
        "tc", "filter", "add", "dev", "lo", "egress", "protocol", protocol,
        "flower", "dst_ip", destination, "ip_proto", "tcp",
        "tcp_flags", "0x02/0x02", "action", "drop",
    ])


def tc_stats(kind: str) -> dict[str, Any]:
    command = ["tc", "-s", kind, "show", "dev", "lo"]
    if kind == "filter":
        command.append("egress")
    output = run_checked(command)
    matches = [(int(a), int(b), int(c)) for a, b, c in TC_RE.findall(output)]
    return {
        "command": command, "raw": output,
        "bytes": sum(item[0] for item in matches),
        "packets": sum(item[1] for item in matches),
        "dropped": sum(item[2] for item in matches),
    }


def run_test(
    root: Path, scenario: str, port: int, iterations: int, *, skip_build: bool,
    timeout: float, sample_resources: bool,
) -> tuple[dict[str, Any], list[dict[str, int]]]:
    command = [
        "/home/elliot/.codex/scripts/codex_cangjie_env", "--cwd", str(root),
        "cjpm", "test", "src/internal/transport_stdnet", "-j", "1",
        "--parallel", "1", "--filter", "M2015NativeNetworkGateTest.*",
        "--show-all-output", "--no-progress", "--no-color",
    ]
    if skip_build:
        command.append("--skip-build")
    environment = os.environ.copy()
    environment.update({
        "DISABLE_ZOXIDE": "1", "WIRESTACK_M2_015_SCENARIO": scenario,
        "WIRESTACK_M2_015_PORT": str(port),
        "WIRESTACK_M2_015_ITERATIONS": str(iterations),
    })
    process = subprocess.Popen(
        command, cwd=root, env=environment, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", start_new_session=True,
    )
    sampler = ProcessTreeSampler()
    if sample_resources:
        sampler.start(process.pid)
    started = time.monotonic()
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate(process)
        stdout, stderr = process.communicate()
    finally:
        if sample_resources:
            sampler.stop()
    return ({
        "command": command, "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000, 3),
        "stdout": stdout[-1024 * 1024:], "stderr": stderr[-1024 * 1024:],
    }, sampler.samples)


def parse_result(process: Mapping[str, Any], scenario: str) -> dict[str, Any]:
    matches = RESULT_RE.findall(str(process["stdout"]))
    if len(matches) != 1:
        raise GateError(
            f"expected one M2015_RESULT for {scenario}, found {len(matches)}; "
            f"exit={process.get('exit_code')} timed_out={process.get('timed_out')} "
            f"stdout_tail={str(process.get('stdout', ''))[-3000:]!r} "
            f"stderr_tail={str(process.get('stderr', ''))[-3000:]!r}"
        )
    name, outcome, winners, success_attempts, losers, terminal, error_attempts, elapsed = matches[0]
    if name != scenario:
        raise GateError(f"scenario marker mismatch: expected {scenario}, got {name}")
    return {
        "scenario": name, "outcome": outcome,
        "winners": int(winners) if winners else None,
        "attempts": int(success_attempts or error_attempts),
        "cancelled_losers": int(losers) if losers else None,
        "terminal": terminal or None, "elapsed_ms": int(elapsed),
    }


def run_success_scenario(
    root: Path, scenario: str, family: int, address: str, iterations: int,
    *, skip_build: bool, delay_ms: int | None = None, loss: str | None = None,
    drop_family: str | None = None, sample_resources: bool = False,
) -> dict[str, Any]:
    reset_impairment()
    if delay_ms is not None or loss is not None:
        configure_netem(delay_ms=delay_ms, loss=loss)
    if drop_family is not None:
        configure_drop(drop_family)
    with AcceptServer(family, address, iterations) as server:
        process, samples = run_test(
            root, scenario, server.port, iterations, skip_build=skip_build,
            timeout=180.0, sample_resources=sample_resources,
        )
    parsed = parse_result(process, scenario)
    stats = tc_stats("filter" if drop_family else "qdisc") if (
        delay_ms is not None or loss is not None or drop_family is not None
    ) else None
    trend = resource_trend(samples) if sample_resources else None
    expected_attempts = iterations * (1 if scenario == "loss-1pct" else 2)
    expected_cancelled = 0 if scenario == "loss-1pct" else iterations
    passed = (
        process["exit_code"] == 0 and not process["timed_out"] and
        server.error is None and server.accepted == iterations and
        parsed["outcome"] == "success" and parsed["winners"] == iterations and
        parsed["attempts"] == expected_attempts and
        parsed["cancelled_losers"] == expected_cancelled and
        (stats is None or stats["packets"] > 0) and
        (loss is None or (stats is not None and stats["dropped"] > 0)) and
        (drop_family is None or (stats is not None and stats["dropped"] >= iterations)) and
        (trend is None or trend["decision"] == "PASS")
    )
    return {
        "decision": "PASS" if passed else "FAIL", "result": parsed,
        "listener": {"accepted": server.accepted, "expected": iterations,
                     "error": server.error},
        "impairment": stats, "resources": {"trend": trend, "samples": samples},
        "process": process,
    }


def run_deadline_scenario(root: Path, scenario: str, count: int) -> dict[str, Any]:
    reset_impairment()
    configure_drop("ipv4")
    process, samples = run_test(
        root, scenario, 45678, 1, skip_build=True, timeout=10.0,
        sample_resources=True,
    )
    parsed = parse_result(process, scenario)
    stats = tc_stats("filter")
    upper = DEADLINE_MS + DEADLINE_OVERSHOOT_MS
    passed = (
        process["exit_code"] == 0 and not process["timed_out"] and
        parsed["outcome"] == "deadline" and parsed["terminal"] == "TimedOut" and
        parsed["attempts"] == count and DEADLINE_MS <= parsed["elapsed_ms"] <= upper and
        stats["dropped"] >= count
    )
    return {
        "decision": "PASS" if passed else "FAIL", "result": parsed,
        "impairment": stats, "resources": {"samples": samples}, "process": process,
        "elapsed_limit_ms": {"lower": DEADLINE_MS, "upper": upper},
    }


def tool_version(root: Path, tool: str) -> str:
    result = subprocess.run(
        ["/home/elliot/.codex/scripts/codex_cangjie_env", "--cwd", str(root), tool, "--version"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", timeout=30, check=False,
    )
    return result.stdout.strip()


def execute(root: Path) -> dict[str, Any]:
    configure_namespace()
    scenarios: dict[str, Any] = {}
    scenarios["ipv6-available"] = run_success_scenario(
        root, "ipv6-available", socket.AF_INET6, "2001:db8::2", 1,
        skip_build=False,
    )
    scenarios["ipv6-blackhole"] = run_success_scenario(
        root, "ipv6-blackhole", socket.AF_INET, "192.0.2.2", BLACKHOLE_ITERATIONS,
        skip_build=True, drop_family="ipv6", sample_resources=True,
    )
    scenarios["rtt-20ms"] = run_success_scenario(
        root, "rtt-20ms", socket.AF_INET6, "2001:db8::2", 1,
        skip_build=True, delay_ms=10,
    )
    scenarios["rtt-100ms"] = run_success_scenario(
        root, "rtt-100ms", socket.AF_INET6, "2001:db8::2", 1,
        skip_build=True, delay_ms=50,
    )
    scenarios["loss-1pct"] = run_success_scenario(
        root, "loss-1pct", socket.AF_INET, "192.0.2.2", LOSS_ITERATIONS,
        skip_build=True, loss="1%", sample_resources=True,
    )
    scenarios["deadline-2"] = run_deadline_scenario(root, "deadline-2", 2)
    scenarios["deadline-8"] = run_deadline_scenario(root, "deadline-8", 8)
    deadline_delta = abs(
        scenarios["deadline-8"]["result"]["elapsed_ms"] -
        scenarios["deadline-2"]["result"]["elapsed_ms"]
    )
    deadline_scaling = {
        "decision": "PASS" if deadline_delta <= DEADLINE_COUNT_DELTA_MS else "FAIL",
        "two_candidates_ms": scenarios["deadline-2"]["result"]["elapsed_ms"],
        "eight_candidates_ms": scenarios["deadline-8"]["result"]["elapsed_ms"],
        "absolute_delta_ms": deadline_delta, "delta_limit_ms": DEADLINE_COUNT_DELTA_MS,
    }
    passed = (
        all(item["decision"] == "PASS" for item in scenarios.values()) and
        deadline_scaling["decision"] == "PASS"
    )
    reset_impairment()
    return {
        "schema_version": 1, "task_id": "M2-015",
        "platform_scope": "linux-glibc-x86_64",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "decision": "PASS" if passed else "FAIL",
        "environment": {
            "uname": platform.uname()._asdict(), "libc": platform.libc_ver(),
            "cjc": tool_version(root, "cjc"), "cjpm": tool_version(root, "cjpm"),
            "ip": run_checked(["ip", "-Version"]).strip(),
            "tc": run_checked(["tc", "-Version"]).strip(),
            "namespace": "unshare --user --map-root-user --net",
        },
        "thresholds": {
            "blackhole_iterations": BLACKHOLE_ITERATIONS,
            "loss_iterations": LOSS_ITERATIONS, "deadline_ms": DEADLINE_MS,
            "deadline_overshoot_ms": DEADLINE_OVERSHOOT_MS,
            "candidate_count_delta_ms": DEADLINE_COUNT_DELTA_MS,
        },
        "source_digests": {
            str(path.relative_to(root)): evidence_digest.text_evidence_sha256(path) for path in (
                root / "src/internal/transport_stdnet/m2_015_native_network_test.cj",
                root / "tools/gates/m2_015_native_network.py",
                root / "docs/evidence/M2-015/test-plan.md",
            )
        },
        "scenarios": scenarios, "deadline_scaling": deadline_scaling,
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--inside-namespace", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.repo_root.resolve()
    output = (args.output or (
        root / "docs/evidence/M2-015/linux_glibc_x86_64/report.json"
    )).resolve()
    if not args.inside_namespace:
        command = [
            "unshare", "--user", "--map-root-user", "--net", sys.executable,
            str(Path(__file__).resolve()), "--repo-root", str(root),
            "--output", str(output), "--inside-namespace",
        ]
        os.execvp(command[0], command)
    try:
        report = execute(root)
    except Exception as error:
        report = {
            "schema_version": 1, "task_id": "M2-015",
            "platform_scope": "linux-glibc-x86_64",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "decision": "FAIL", "error": f"{type(error).__name__}: {error}",
        }
    atomic_json(output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
