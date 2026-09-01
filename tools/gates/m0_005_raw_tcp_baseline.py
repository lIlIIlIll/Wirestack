#!/usr/bin/env python3
"""Capture the measurable Linux M0-005 raw std.net loopback baseline."""
from __future__ import annotations

from tools import evidence_digest

import argparse
import datetime as dt
import os
import platform
import re
import shutil
import socket
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import net05_large_buffer_profile as shared

SCHEMA_VERSION = 3
KIB = 1024
MIB = 1024 * KIB
BASELINE_CASES = (
    shared.Case("0B", 0),
    shared.Case("1KiB", 1 * KIB),
    shared.Case("16KiB", 16 * KIB),
    shared.Case("64KiB", 64 * KIB),
    shared.Case("1MiB", 1 * MIB),
    shared.Case("100MiB", 100 * MIB),
)
QUICK_CASES = (BASELINE_CASES[0], BASELINE_CASES[1], BASELINE_CASES[4])
HEAPTRACK_ALLOCATIONS_RE = re.compile(
    r"^\s*allocations:\s+([0-9][0-9,]*)\s*$", re.MULTILINE
)
STRACE_RECVFROM_RE = re.compile(
    r"(?:recvfrom\(|<\.\.\. recvfrom resumed>).*?=\s+(-?\d+)(?:\s+.*)?$"
)
PEER_METADATA_RE = re.compile(
    r"^WIRESTACK_M0_005_PEER schema=1 sysname=([^ ]+) release=([^ ]+) "
    r"machine=([^ ]+) payload_count=(\d+)$"
)


class RemoteServerEvidence:
    def __init__(self, payload_bytes: int) -> None:
        self.bytes_sent = payload_bytes
        self.send_sizes: list[int] = []


def parse_heaptrack_allocations(stderr: str) -> int:
    matches = HEAPTRACK_ALLOCATIONS_RE.findall(stderr)
    if len(matches) != 1:
        raise shared.GateError(
            f"expected one heaptrack allocation count, found {len(matches)}"
        )
    return int(matches[0].replace(",", ""))


def parse_strace_recvfrom(trace: str) -> tuple[int, int, int]:
    results = parse_strace_recvfrom_results(trace)
    successful = [value for value in results if value > 0]
    return len(results), len(successful), sum(successful)


def parse_strace_recvfrom_results(trace: str) -> list[int]:
    results = []
    for line in trace.splitlines():
        match = STRACE_RECVFROM_RE.search(line)
        if match is not None:
            results.append(int(match.group(1)))
    return results


def run_instrumented_sample(
    binary: Path,
    case: shared.Case,
    buffer_size: int,
    artifacts: Path,
    timeout: float,
    host: str | None = None,
    port: int | None = None,
) -> dict[str, Any]:
    topology = "lan" if host is not None else "loopback"
    sample_dir = artifacts / topology / "instrumentation" / case.name
    sample_dir.mkdir(parents=True, exist_ok=True)
    trace_path = sample_dir / "recvfrom.trace"
    heaptrack_prefix = sample_dir / "heaptrack-data"
    heaptrack_path = Path(f"{heaptrack_prefix}.zst")
    trace_path.unlink(missing_ok=True)
    heaptrack_path.unlink(missing_ok=True)

    def execute_probe(server: Any, peer_host: str, peer_port: int) -> dict[str, Any]:
        command = [
            "strace", "-f", "-qq", "-s", "0", "-e", "trace=recvfrom",
            "-o", str(trace_path),
            "heaptrack", "--record-only", "-o", str(heaptrack_prefix),
            str(binary), peer_host, str(peer_port), str(case.payload_bytes), str(buffer_size),
            "quiet",
        ]
        return shared.run_process(command, sample_dir, timeout, rss)

    rss = shared.RssSampler()
    if host is None:
        with shared.StreamServer(case.payload_bytes, 64 * KIB, timeout) as server:
            process = execute_probe(server, "127.0.0.1", server.port)
    else:
        if port is None:
            raise shared.GateError("LAN peer port is required")
        server = RemoteServerEvidence(case.payload_bytes)
        process = execute_probe(server, host, port)

    if not trace_path.is_file():
        raise shared.GateError("strace did not produce a recvfrom trace")
    if not heaptrack_path.is_file():
        raise shared.GateError("heaptrack did not produce an allocation record")

    trace = trace_path.read_text(encoding="utf-8", errors="replace")
    recvfrom_results = parse_strace_recvfrom_results(trace)
    read_sizes = [value for value in recvfrom_results if value > 0]
    _reported_read_sizes, fields = shared.parse_probe_output(process["stdout"])
    sample = shared.classify_sample(
        case, buffer_size, process, read_sizes, fields, server, rss
    )
    attempts, calls, copied_bytes = parse_strace_recvfrom(trace)
    allocations = parse_heaptrack_allocations(process["stderr"])
    heaptrack_sha256 = evidence_digest.artifact_bytes_sha256(heaptrack_path.read_bytes())
    valid = (
        sample["decision"] == "PASS"
        and allocations > 0
        and copied_bytes == case.payload_bytes
        and calls == sample["read_calls"]
    )
    sample["instrumentation"] = {
        "decision": "PASS" if valid else "FAIL",
        "native_allocation_events_per_process_operation": allocations,
        "recvfrom_attempts": attempts,
        "successful_recvfrom_calls": calls,
        "copied_bytes_per_process_operation": copied_bytes,
        "strace_trace": trace,
        "strace_trace_sha256": evidence_digest.text_evidence_bytes_sha256(trace.encode()),
        "heaptrack_record_sha256": heaptrack_sha256,
        "heaptrack_stderr": process["stderr"],
    }
    heaptrack_path.unlink()
    return sample


def run_remote_sample(
    binary: Path,
    case: shared.Case,
    buffer_size: int,
    artifacts: Path,
    timeout: float,
    host: str,
    port: int,
) -> dict[str, Any]:
    probe_dir = artifacts / "lan" / "probe"
    probe_dir.mkdir(parents=True, exist_ok=True)
    rss = shared.RssSampler()
    server = RemoteServerEvidence(case.payload_bytes)
    process = shared.run_process(
        [str(binary), host, str(port), str(case.payload_bytes), str(buffer_size), "verbose"],
        probe_dir,
        timeout,
        rss,
    )
    read_sizes, fields = shared.parse_probe_output(process["stdout"])
    return shared.classify_sample(
        case, buffer_size, process, read_sizes, fields, server, rss
    )


def read_lan_peer_metadata(host: str, port: int, timeout: float) -> dict[str, Any]:
    try:
        with socket.create_connection((host, port), timeout=min(timeout, 10.0)) as connection:
            connection.settimeout(min(timeout, 10.0))
            chunks = []
            size = 0
            while size <= 4096:
                chunk = connection.recv(4097 - size)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
    except OSError as error:
        raise shared.GateError(f"LAN peer metadata connection failed: {error}") from error
    if size > 4096:
        raise shared.GateError("LAN peer metadata exceeds 4096 bytes")
    raw = b"".join(chunks).decode("ascii", errors="strict").strip()
    match = PEER_METADATA_RE.fullmatch(raw)
    if match is None:
        raise shared.GateError(f"invalid LAN peer metadata: {raw!r}")
    sysname, release, machine, payload_count = match.groups()
    if (
        sysname != "Linux"
        or machine not in ("x86_64", "amd64")
        or int(payload_count) != len(BASELINE_CASES)
    ):
        raise shared.GateError("LAN peer metadata does not describe the required Linux peer")
    return {
        "raw": raw,
        "sysname": sysname,
        "kernel_release": release,
        "machine": machine,
        "payload_count": int(payload_count),
    }


def run_topology(
    binary: Path,
    cases: Sequence[shared.Case],
    buffer_size: int,
    artifacts: Path,
    timeout: float,
    warmup: int,
    repetitions: int,
    host: str | None = None,
    port: int | None = None,
) -> list[dict[str, Any]]:
    results = []
    for case in cases:
        if host is None:
            run = lambda: shared.run_sample(binary, case, buffer_size, artifacts, timeout)
        else:
            if port is None:
                raise shared.GateError("LAN peer port is required")
            run = lambda: run_remote_sample(
                binary, case, buffer_size, artifacts, timeout, host, port
            )
        warmups = [run() for _ in range(warmup)]
        samples = [run() for _ in range(repetitions)]
        instrumented = run_instrumented_sample(
            binary, case, buffer_size, artifacts, timeout, host=host, port=port
        )
        decision = "PASS" if (
            all(item["decision"] == "PASS" for item in samples)
            and instrumented["instrumentation"]["decision"] == "PASS"
        ) else "FAIL"
        results.append({
            "name": case.name,
            "payload_bytes": case.payload_bytes,
            "decision": decision,
            "sample_count": len(samples),
            "aggregate": shared.aggregate(case, samples),
            "warmup_samples": warmups,
            "samples": samples,
            "instrumented_sample": instrumented,
        })
    return results


def execute(
    artifacts: Path,
    warmup: int,
    repetitions: int,
    timeout: float,
    revision: str,
    cases: Sequence[shared.Case] = BASELINE_CASES,
    buffer_size: int = 64 * KIB,
    lan_peer: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if shutil.which("cjc") is None:
        raise shared.GateError("cjc unavailable; source the supplied SDK environment")
    for tool in ("heaptrack", "strace"):
        if shutil.which(tool) is None:
            raise shared.GateError(f"{tool} unavailable; Linux instrumentation is required")
    if warmup < 0 or repetitions <= 0:
        raise shared.GateError("warmup must be non-negative and repetitions must be positive")
    artifacts.mkdir(parents=True, exist_ok=True)
    binary, compile_info = shared.compile_probe(artifacts, timeout)
    results = run_topology(
        binary, cases, buffer_size, artifacts, timeout, warmup, repetitions
    )
    loopback_status = "PASS" if all(item["decision"] == "PASS" for item in results) else "FAIL"
    lan_results: list[dict[str, Any]] = []
    peer_evidence: dict[str, Any] | None = None
    lan_status = "NOT_RUN"
    if lan_peer is not None:
        required = {
            "host", "port", "image_id", "image_sha256", "hypervisor",
            "peer_binary_sha256",
        }
        missing = required - lan_peer.keys()
        if missing:
            raise shared.GateError(f"LAN peer metadata fields missing: {sorted(missing)}")
        host = str(lan_peer["host"])
        port = int(lan_peer["port"])
        if not 0 < port <= 65535:
            raise shared.GateError("LAN peer port is out of range")
        for field in ("image_sha256", "peer_binary_sha256"):
            if re.fullmatch(r"[0-9a-f]{64}", str(lan_peer[field])) is None:
                raise shared.GateError(f"LAN peer {field} must be a SHA-256 digest")
        route = shared.command_text(["ip", "route", "get", host])
        if not route or " dev lo " in f" {route} " or route.startswith("local "):
            raise shared.GateError(f"LAN peer route is not non-loopback: {route!r}")
        peer_evidence = dict(lan_peer)
        peer_evidence["route"] = route
        peer_evidence["reported_metadata"] = read_lan_peer_metadata(host, port, timeout)
        lan_results = run_topology(
            binary, cases, buffer_size, artifacts, timeout, warmup, repetitions,
            host=host, port=port,
        )
        lan_status = "PASS" if all(
            item["decision"] == "PASS" for item in lan_results
        ) else "FAIL"
    complete = loopback_status == "PASS" and lan_status == "PASS"
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": "M0-005",
        "task_status": "COMPLETE" if complete else "BLOCKED",
        "linux_baseline_status": "PASS" if complete else "INCOMPLETE",
        "loopback_status": loopback_status,
        "lan_status": lan_status,
        "configuration": {
            "topologies": ["loopback"] + (["lan"] if lan_peer is not None else []),
            "warmup": warmup,
            "repetitions": repetitions,
            "timeout_seconds": timeout,
            "receive_buffer_bytes": buffer_size,
            "server_send_chunk_bytes": 64 * KIB,
        },
        "environment": {
            "repository_revision": revision,
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "os": platform.platform(),
            "architecture": platform.machine(),
            "python": sys.version.splitlines()[0],
            "cjc": shared.command_text(["cjc", "--version"]),
            "cjpm": shared.command_text(["cjpm", "--version"]),
            "cangjie_home": os.environ.get("CANGJIE_HOME"),
        },
        "metric_availability": {
            "exact_bytes": "MEASURED",
            "application_visible_read_sizes": "MEASURED",
            "throughput": "MEASURED",
            "latency_percentiles": "MEASURED",
            "peak_rss": "MEASURED",
            "process_thread_count": "MEASURED",
            "allocation_count": "MEASURED_BY_HEAPTRACK",
            "copied_bytes_per_operation": "MEASURED_BY_STRACE_RECVFROM",
        },
        "missing_requirements": [] if complete else ["native LAN peer measurements"],
        "non_claims": (
            ([] if complete else ["not a complete M0-005 baseline"])
            + [
                "not a StdNetTransport comparison",
                "allocation events are native allocator calls for one process operation",
                "copied bytes are successful recvfrom bytes entering the process buffer",
            ]
        ),
        "instrumentation": {
            "heaptrack": shared.command_text(["heaptrack", "--version"]),
            "strace": shared.command_text(["strace", "--version"]),
            "performance_samples_are_uninstrumented": True,
            "instrumented_samples_per_payload": 1,
        },
        "compile": compile_info,
        "cases": results,
        "lan_peer": peer_evidence,
        "lan_cases": lan_results,
    }


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path,
                        default=root / "build/gates/m0-005-raw-tcp-baseline")
    parser.add_argument("--output", type=Path,
                        default=root / "build/gates/m0-005-raw-tcp-baseline.json")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--lan-peer-host")
    parser.add_argument("--lan-peer-port", type=int)
    parser.add_argument("--lan-peer-image-id")
    parser.add_argument("--lan-peer-image-sha256")
    parser.add_argument("--lan-peer-hypervisor")
    parser.add_argument("--lan-peer-binary-sha256")
    args = parser.parse_args(argv)
    cases = BASELINE_CASES
    if args.quick:
        args.warmup = 0
        args.repetitions = 1
        cases = QUICK_CASES
    peer_values = (
        args.lan_peer_host, args.lan_peer_port, args.lan_peer_image_id,
        args.lan_peer_image_sha256, args.lan_peer_hypervisor,
        args.lan_peer_binary_sha256,
    )
    if any(value is not None for value in peer_values) and not all(
        value is not None for value in peer_values
    ):
        parser.error("all --lan-peer-* options must be supplied together")
    if args.quick and args.lan_peer_host is not None:
        parser.error("--quick cannot be combined with the formal LAN peer matrix")
    lan_peer = None
    if all(value is not None for value in peer_values):
        lan_peer = {
            "host": args.lan_peer_host,
            "port": args.lan_peer_port,
            "image_id": args.lan_peer_image_id,
            "image_sha256": args.lan_peer_image_sha256,
            "hypervisor": args.lan_peer_hypervisor,
            "peer_binary_sha256": args.lan_peer_binary_sha256,
        }
    try:
        report = execute(
            args.artifact_dir.resolve(), args.warmup, args.repetitions,
            args.timeout_seconds, args.repository_revision, cases=cases,
            lan_peer=lan_peer,
        )
        shared.atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"M0-005 baseline: ERROR: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(
        f"M0-005 task={report['task_status']} loopback={report['loopback_status']} "
        f"LAN={report['lan_status']} Linux={report['linux_baseline_status']}"
    )
    for case in report["cases"]:
        aggregate = case["aggregate"]
        print(
            f"- {case['name']}: {case['decision']} samples={case['sample_count']} "
            f"reads-p50={aggregate['read_calls']['p50']} "
            f"throughput-p50={aggregate['throughput_mib_per_second']['p50']} MiB/s "
            f"rss-max={aggregate['peak_rss_kib']['max']} KiB "
            f"threads-max={aggregate['peak_thread_count']['max']}"
        )
    for case in report["lan_cases"]:
        aggregate = case["aggregate"]
        print(
            f"- LAN {case['name']}: {case['decision']} samples={case['sample_count']} "
            f"reads-p50={aggregate['read_calls']['p50']} "
            f"throughput-p50={aggregate['throughput_mib_per_second']['p50']} MiB/s "
            f"rss-max={aggregate['peak_rss_kib']['max']} KiB "
            f"threads-max={aggregate['peak_thread_count']['max']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
