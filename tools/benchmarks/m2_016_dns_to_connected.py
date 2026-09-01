#!/usr/bin/env python3
"""Run the M2-016 DNS-to-connected benchmark in an ephemeral Linux netns."""
from __future__ import annotations

from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/gates"))
from m2_015_native_network import (  # noqa: E402
    AcceptServer,
    configure_namespace,
    reset_impairment,
    run_checked,
    tc_stats,
)

ROUNDS = 11
SAMPLES_PER_ROUND = 8
WARMUP_ROUND = -1
CANCELLATION_P99_NS = 50_000_000
PROFILES = (
    "ipv6-available", "ipv6-blackhole", "rtt-20ms",
    "rtt-100ms", "loss-1pct", "cancellation",
)
SAMPLE_RE = re.compile(
    r"^\s*M2016_SAMPLE profile=(\S+) round=(-?\d+) index=(\d+) "
    r"terminal=(\S+) source=(\S+) dnsNs=(-?\d+) firstAttemptNs=(-?\d+) "
    r"winnerNs=(-?\d+) totalNs=(-?\d+) connectionCount=(\d+) "
    r"cancellationNs=(-?\d+)\s*$",
    re.MULTILINE,
)
COMPILE_OPTION_RE = re.compile(r'^(\s*compile-option\s*=\s*)"[^"]*"', re.MULTILINE)


class BenchmarkError(RuntimeError):
    pass


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def enable_o2_manifest(path: Path) -> None:
    manifest = path.read_text(encoding="utf-8")
    if len(COMPILE_OPTION_RE.findall(manifest)) != 1:
        raise BenchmarkError("expected one package compile-option in benchmark snapshot")
    path.write_text(COMPILE_OPTION_RE.sub(r'\1"-O2"', manifest, count=1), encoding="utf-8")


def prepare_snapshot(root: Path, destination: Path, timeout: float) -> tuple[Path, list[str]]:
    shutil.copytree(
        root, destination,
        ignore=shutil.ignore_patterns(
            ".git", ".cjpm", ".codex", "target", "build", "__pycache__", "*.pyc"
        ),
    )
    native = root / "target/native"
    if not native.is_dir():
        raise BenchmarkError("Wirestack native provider artifacts are missing")
    target = destination / "target"
    target.mkdir()
    (target / "native").symlink_to(native, target_is_directory=True)
    enable_o2_manifest(destination / "cjpm.toml")
    command = [
        "/home/elliot/.codex/scripts/codex_cangjie_env", "--cwd", str(destination),
        "cjpm", "test", "src/internal/transport_stdnet", "-j", "1", "--no-run",
    ]
    run_checked(command, timeout=timeout)
    binary = destination / "target/release/unittest_bin/wirestack.internal.transport_stdnet"
    if not binary.is_file():
        raise BenchmarkError("cjpm did not produce the M2-016 unittest binary")
    return binary, command


def configure_netem(*, delay_ms: int | None = None, loss: str | None = None) -> None:
    command = ["tc", "qdisc", "add", "dev", "lo", "root", "netem"]
    if delay_ms is not None:
        command.extend(["delay", f"{delay_ms}ms"])
    if loss is not None:
        command.extend(["loss", "random", loss, "seed", "2016"])
    run_checked(command)


def add_syn_drop_filters(*, ipv6: bool, ipv4: bool) -> None:
    run_checked(["tc", "qdisc", "add", "dev", "lo", "clsact"])
    if ipv6:
        run_checked([
            "tc", "filter", "add", "dev", "lo", "egress", "protocol", "ipv6",
            "flower", "dst_ip", "::1", "ip_proto", "tcp", "tcp_flags", "0x02/0x02",
            "action", "drop",
        ])
    if ipv4:
        run_checked([
            "tc", "filter", "add", "dev", "lo", "egress", "protocol", "ip",
            "flower", "dst_ip", "127.0.0.1", "ip_proto", "tcp",
            "tcp_flags", "0x02/0x02", "action", "drop",
        ])


def run_profile(binary: Path, snapshot: Path, profile: str, round_index: int,
                samples: int, port: int, timeout: float) -> dict[str, Any]:
    command = [
        str(binary), "--filter=M2016DnsToConnectedBenchmarkTest.runProfile",
        "--show-all-output", "--no-progress", "--no-color",
    ]
    environment = dict(os.environ)
    environment.update({
        "WIRESTACK_M2_016_PROFILE": profile,
        "WIRESTACK_M2_016_ROUND": str(round_index),
        "WIRESTACK_M2_016_SAMPLES": str(samples),
        "WIRESTACK_M2_016_PORT": str(port),
    })
    try:
        result = subprocess.run(
            command, cwd=snapshot, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        raise BenchmarkError(
            f"{profile} round {round_index} timed out\n"
            f"stdout_tail={stdout[-6000:]}\nstderr_tail={stderr[-6000:]}"
        ) from error
    if result.returncode != 0:
        raise BenchmarkError(
            f"{profile} round {round_index} failed ({result.returncode})\n"
            f"{(result.stderr or result.stdout)[-6000:]}"
        )
    parsed = parse_samples(result.stdout, profile, round_index, samples)
    return {
        "round": round_index, "samples": parsed, "command": command,
        "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
    }


def parse_samples(output: str, profile: str, round_index: int,
                  expected: int) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    for match in SAMPLE_RE.findall(output):
        (name, round_value, index, terminal, source, dns, first, winner,
         total, connections, cancellation) = match
        samples.append({
            "profile": name, "round": int(round_value), "index": int(index),
            "terminal": terminal, "source": source, "dns_ns": int(dns),
            "first_attempt_ns": int(first), "winner_ns": int(winner),
            "total_ns": int(total), "connection_count": int(connections),
            "cancellation_ns": int(cancellation),
        })
    if len(samples) != expected:
        raise BenchmarkError(
            f"{profile} round {round_index}: expected {expected} samples, found {len(samples)}"
        )
    expected_indexes = set(range(expected))
    if {sample["index"] for sample in samples} != expected_indexes:
        raise BenchmarkError(f"{profile} round {round_index}: duplicate or missing indexes")
    for sample in samples:
        if sample["profile"] != profile or sample["round"] != round_index:
            raise BenchmarkError(f"{profile} round {round_index}: marker mismatch")
        validate_sample(sample)
    return sorted(samples, key=lambda item: item["index"])


def validate_sample(sample: Mapping[str, Any]) -> None:
    profile = str(sample["profile"])
    if sample["source"] != "system" or int(sample["dns_ns"]) < 0:
        raise BenchmarkError(f"{profile}: missing system DNS timing")
    if int(sample["first_attempt_ns"]) < 0 or int(sample["total_ns"]) < int(sample["first_attempt_ns"]):
        raise BenchmarkError(f"{profile}: invalid attempt or total timestamp")
    if profile == "cancellation":
        valid = (
            sample["terminal"] == "cancelled" and int(sample["winner_ns"]) == -1 and
            int(sample["connection_count"]) == 1 and int(sample["cancellation_ns"]) >= 0
        )
    else:
        expected_connections = 2 if profile == "ipv6-blackhole" else 1
        connection_count = int(sample["connection_count"])
        connection_count_valid = (
            1 <= connection_count <= 2 if profile == "loss-1pct"
            else connection_count == expected_connections
        )
        valid = (
            sample["terminal"] == "success" and
            int(sample["winner_ns"]) >= int(sample["first_attempt_ns"]) and
            int(sample["total_ns"]) >= int(sample["winner_ns"]) and
            connection_count_valid and
            int(sample["cancellation_ns"]) == -1
        )
    if not valid:
        raise BenchmarkError(f"{profile}: sample contract failed: {dict(sample)}")


def nearest_rank(values: Sequence[int], percentile: int) -> int:
    if not values:
        raise BenchmarkError("cannot aggregate an empty sample set")
    ordered = sorted(values)
    rank = max(1, (percentile * len(ordered) + 99) // 100)
    return ordered[rank - 1]


def aggregate(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    fields = ("dns_ns", "first_attempt_ns", "winner_ns", "total_ns", "cancellation_ns")
    result: dict[str, Any] = {"sample_count": len(samples)}
    for field in fields:
        values = [int(sample[field]) for sample in samples if int(sample[field]) >= 0]
        result[field] = None if not values else {
            "p50": nearest_rank(values, 50), "p95": nearest_rank(values, 95),
            "p99": nearest_rank(values, 99), "min": min(values), "max": max(values),
        }
    counts = [int(sample["connection_count"]) for sample in samples]
    result["connection_count"] = {"min": min(counts), "max": max(counts), "sum": sum(counts)}
    return result


def run_success_round(binary: Path, snapshot: Path, profile: str, round_index: int,
                      timeout: float) -> tuple[dict[str, Any], dict[str, Any]]:
    family = socket.AF_INET if profile == "ipv6-blackhole" else socket.AF_INET6
    address = "127.0.0.1" if family == socket.AF_INET else "::1"
    with AcceptServer(family, address, SAMPLES_PER_ROUND) as server:
        process = run_profile(
            binary, snapshot, profile, round_index, SAMPLES_PER_ROUND, server.port, timeout
        )
        # The connector may return just before the listener thread dequeues the
        # final established socket. Let the bounded accept loop reach its known
        # terminal count before the context manager closes the listening fd.
        server.thread.join(2)
    listener = {"expected": SAMPLES_PER_ROUND, "accepted": server.accepted, "error": server.error}
    if server.error is not None or server.accepted != SAMPLES_PER_ROUND:
        raise BenchmarkError(f"{profile} round {round_index}: listener contract failed: {listener}")
    return process, listener


def setup_profile(profile: str) -> None:
    reset_impairment()
    if profile == "ipv6-blackhole":
        add_syn_drop_filters(ipv6=True, ipv4=False)
    elif profile == "rtt-20ms":
        configure_netem(delay_ms=10)
    elif profile == "rtt-100ms":
        configure_netem(delay_ms=50)
    elif profile == "loss-1pct":
        configure_netem(loss="1%")
    elif profile == "cancellation":
        add_syn_drop_filters(ipv6=True, ipv4=True)


def profile_stats(profile: str) -> dict[str, Any] | None:
    if profile in ("ipv6-blackhole", "cancellation"):
        return tc_stats("filter")
    if profile in ("rtt-20ms", "rtt-100ms", "loss-1pct"):
        return tc_stats("qdisc")
    return None


def execute(root: Path, rounds: int, samples_per_round: int,
            timeout: float, build_timeout: float) -> dict[str, Any]:
    if rounds != ROUNDS or samples_per_round != SAMPLES_PER_ROUND:
        raise BenchmarkError("formal M2-016 evidence requires 11 rounds and 8 samples per round")
    configure_namespace()
    with tempfile.TemporaryDirectory(prefix="wirestack-m2-016-") as temporary:
        snapshot = Path(temporary) / "repository"
        binary, build_command = prepare_snapshot(root, snapshot, build_timeout)
        profiles: dict[str, Any] = {}
        for profile in PROFILES:
            setup_profile(profile)
            if profile == "cancellation":
                warmup = run_profile(binary, snapshot, profile, WARMUP_ROUND, samples_per_round, 45678, timeout)
                measured = [run_profile(binary, snapshot, profile, index, samples_per_round, 45678, timeout) for index in range(rounds)]
                listeners: list[dict[str, Any]] = []
            else:
                warmup, _ = run_success_round(binary, snapshot, profile, WARMUP_ROUND, timeout)
                measured = []
                listeners = []
                for index in range(rounds):
                    process, listener = run_success_round(binary, snapshot, profile, index, timeout)
                    measured.append(process)
                    listeners.append(listener)
            samples = [sample for round_result in measured for sample in round_result["samples"]]
            summary = aggregate(samples)
            impairment = profile_stats(profile)
            expected_total = rounds * samples_per_round
            passed = len(measured) == rounds and len(samples) == expected_total
            if profile == "loss-1pct":
                passed = passed and impairment is not None and impairment["dropped"] > 0
            if profile in ("ipv6-blackhole", "cancellation"):
                passed = passed and impairment is not None and impairment["dropped"] >= (rounds + 1) * samples_per_round
            if profile == "cancellation":
                passed = passed and summary["cancellation_ns"]["p99"] <= CANCELLATION_P99_NS
            profiles[profile] = {
                "decision": "PASS" if passed else "FAIL", "warmup": warmup,
                "rounds": measured, "listeners": listeners, "aggregate": summary,
                "impairment": impairment,
            }
        reset_impairment()
        decision = "PASS" if all(item["decision"] == "PASS" for item in profiles.values()) else "FAIL"
        return {
            "schema_version": 1, "task_id": "M2-016", "decision": decision,
            "platform_scope": "linux-glibc-x86_64",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "benchmark": {
                "warmup_rounds": 1, "measured_rounds": rounds,
                "samples_per_round": samples_per_round,
                "samples_per_profile": rounds * samples_per_round,
                "percentile_method": "nearest-rank",
                "cancellation_p99_limit_ns": CANCELLATION_P99_NS,
                "build_compile_option": "-O2", "build_command": build_command,
            },
            "environment": environment_metadata(root),
            "source_digests": {
                str(path.relative_to(root)): evidence_digest.text_evidence_sha256(path) for path in (
                    root / "src/internal/transport_stdnet/m2_016_dns_to_connected_benchmark_test.cj",
                    root / "tools/benchmarks/m2_016_dns_to_connected.py",
                    root / "docs/evidence/M2-016/benchmark-plan.md",
                )
            },
            "profiles": profiles,
        }


def tool_version(root: Path, tool: str) -> str:
    command = ["/home/elliot/.codex/scripts/codex_cangjie_env", "--cwd", str(root), tool, "--version"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace", timeout=30, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        raise BenchmarkError(f"could not record {tool} version")
    return result.stdout.strip()


def environment_metadata(root: Path) -> dict[str, Any]:
    cpu_model = ""
    for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
        if line.startswith("model name"):
            cpu_model = line.split(":", 1)[1].strip()
            break
    governors = sorted({
        path.read_text(encoding="utf-8").strip()
        for path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_governor")
    })
    metadata = {
        "uname": platform.uname()._asdict(), "libc": platform.libc_ver(),
        "cpu_model": cpu_model, "cpu_affinity": sorted(os.sched_getaffinity(0)),
        "scaling_governors": governors, "cjc": tool_version(root, "cjc"),
        "cjpm": tool_version(root, "cjpm"), "ip": run_checked(["ip", "-Version"]).strip(),
        "tc": run_checked(["tc", "-Version"]).strip(),
        "namespace": "unshare --user --map-root-user --net",
    }
    if not metadata["libc"][0] or not cpu_model or not governors:
        raise BenchmarkError("required libc, CPU, or scaling-governor metadata is missing")
    return metadata


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--rounds", type=int, default=ROUNDS)
    parser.add_argument("--samples-per-round", type=int, default=SAMPLES_PER_ROUND)
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--build-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--inside-namespace", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.repo_root.resolve()
    output = (args.output or root / "docs/evidence/M2-016/linux_glibc_x86_64/dns-to-connected.json").resolve()
    if not args.inside_namespace:
        command = [
            "unshare", "--user", "--map-root-user", "--net", sys.executable,
            str(Path(__file__).resolve()), "--repo-root", str(root), "--output", str(output),
            "--rounds", str(args.rounds), "--samples-per-round", str(args.samples_per_round),
            "--timeout-seconds", str(args.timeout_seconds),
            "--build-timeout-seconds", str(args.build_timeout_seconds), "--inside-namespace",
        ]
        os.execvp(command[0], command)
    try:
        report = execute(root, args.rounds, args.samples_per_round,
                         args.timeout_seconds, args.build_timeout_seconds)
    except Exception as error:
        report = {
            "schema_version": 1, "task_id": "M2-016", "decision": "FAIL",
            "platform_scope": "linux-glibc-x86_64",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "error": f"{type(error).__name__}: {error}",
        }
    atomic_json(output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
