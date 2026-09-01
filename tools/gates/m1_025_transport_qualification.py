#!/usr/bin/env python3
"""Qualify the Linux M1-025 Transport performance and resource evidence."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parents[2]
NET05 = ROOT / "docs/evidence/M1-027/linux_x86_64/final-net05-formal11.data"
NET06 = ROOT / "docs/evidence/M0-011/linux_x86_64/production-cleanup.json"
NET06_MANIFEST = ROOT / "docs/evidence/M0-011/linux_x86_64/manifest.json"
NET06_SOAK = ROOT / "docs/evidence/M0-011/linux_x86_64/linux-profile.json"
EXPECTED_PAYLOADS = [1024, 16 * 1024, 64 * 1024, 1024 * 1024, 100 * 1024 * 1024]
MAX_CANCELLATION_NS = 50_000_000
MARKER = re.compile(
    r"^[ \t]*M125_CANCEL scenario=(blocked-read|blocked-write) index=(\d+) "
    r"measured=(true|false) active=(true|false) terminal=(cancelled|other) "
    r"latencyNs=(\d+) completed=(true|false) progress=(\d+)$",
    re.MULTILINE,
)


class QualificationError(RuntimeError):
    pass


def percentile(values: Sequence[int], percent: float) -> int:
    if not values:
        raise QualificationError("cannot calculate a percentile without samples")
    ordered = sorted(values)
    return ordered[max(1, math.ceil(percent / 100 * len(ordered))) - 1]


def validate_net05(report: dict[str, Any]) -> list[dict[str, Any]]:
    config = report.get("configuration", {})
    if config.get("warmup") != 1 or config.get("repetitions") != 11:
        raise QualificationError("NET-05 must retain one warmup and eleven measured rounds")
    if config.get("comparison_process_shape") != "same_unittest_binary":
        raise QualificationError("NET-05 implementations must share one unittest binary")
    cases = report.get("cases", [])
    if [case.get("payload_bytes") for case in cases] != EXPECTED_PAYLOADS:
        raise QualificationError("NET-05 payload matrix is incomplete or reordered")
    summary = []
    for case in cases:
        comparison = case.get("comparison", {})
        throughput = comparison.get("throughput_ratio")
        latency = comparison.get("p95_latency_ratio")
        if (
            case.get("decision") != "PASS"
            or comparison.get("decision") != "PASS"
            or comparison.get("throughput_minimum") != 0.95
            or comparison.get("p95_latency_maximum") != 1.1
            or not isinstance(throughput, (int, float))
            or not isinstance(latency, (int, float))
            or throughput < 0.95
            or latency > 1.1
        ):
            raise QualificationError(f"NET-05 case failed: {case.get('name')}")
        summary.append(
            {
                "name": case.get("name"),
                "payload_bytes": case.get("payload_bytes"),
                "throughput_ratio": throughput,
                "p95_latency_ratio": latency,
                "decision": "PASS",
            }
        )
    return summary


def validate_net06(
    cleanup: dict[str, Any], manifest: dict[str, Any], soak_path: Path
) -> dict[str, Any]:
    if manifest.get("linux_acceptance_status") != "PASS":
        raise QualificationError("NET-06 Linux acceptance is not PASS")
    if manifest.get("unmeasured_acceptance_classes") != []:
        raise QualificationError("NET-06 has unmeasured resource classes")
    executed = {item.get("mode"): item for item in manifest.get("executed", [])}
    required_iterations = (
        "connect-close",
        "peer-reset",
        "close-during-read",
        "tls-handshake-failure-cleanup",
        "production-cancel-close",
        "production-tls-transport-cleanup",
    )
    for mode in required_iterations:
        item = executed.get(mode, {})
        if item.get("iterations", 0) < 100_000 or item.get("decision") != "PASS":
            raise QualificationError(f"NET-06 workload is incomplete: {mode}")
    soak = executed.get("mixed-soak", {})
    if soak.get("seconds", 0) < 86_400 or soak.get("decision") != "PASS":
        raise QualificationError("NET-06 retained soak is shorter than 24 hours")
    retained_soak = cleanup.get("reused_24_hour_soak", {})
    if not evidence_digest.text_evidence_sha256_equal(
        retained_soak.get("sha256"), evidence_digest.text_evidence_sha256(soak_path),
    ):
        raise QualificationError("NET-06 retained soak digest does not match")
    cancellation = cleanup.get("production_cancellation", {})
    marker = cancellation.get("marker", {})
    if (
        cancellation.get("decision") != "PASS"
        or cancellation.get("iterations", 0) < 100_000
        or marker.get("completed") != marker.get("requested")
        or marker.get("active_reads") != 0
        or marker.get("background_tasks") != 0
        or cancellation.get("heap", {}).get("decision") != "PASS"
        or cancellation.get("resources", {}).get("lifecycle_trend", {}).get("decision") != "PASS"
    ):
        raise QualificationError("NET-06 production cancellation cleanup is incomplete")
    return {
        "decision": "PASS",
        "executed": manifest.get("executed"),
        "measured_resource_classes": manifest.get("measured_resource_classes"),
        "production_cancellation_marker": marker,
        "production_cancellation_heap_growth_bytes": cancellation.get("heap", {}).get("growth_bytes"),
        "production_cancellation_lifecycle_growth": cancellation.get("resources", {})
        .get("lifecycle_trend", {})
        .get("growth"),
        "soak_sha256": retained_soak.get("sha256"),
    }


def parse_cancellation(stdout: str, warmup: int, repetitions: int) -> dict[str, Any]:
    samples: dict[str, list[dict[str, Any]]] = {"blocked-read": [], "blocked-write": []}
    for match in MARKER.finditer(stdout):
        scenario, index, measured, active, terminal, latency, completed, progress = match.groups()
        samples[scenario].append(
            {
                "index": int(index),
                "measured": measured == "true",
                "active": active == "true",
                "terminal": terminal,
                "latency_ns": int(latency),
                "completed": completed == "true",
                "progress": int(progress),
            }
        )
    expected_count = warmup + repetitions
    result: dict[str, Any] = {}
    for scenario, values in samples.items():
        if len(values) != expected_count:
            raise QualificationError(
                f"{scenario} emitted {len(values)} samples, expected {expected_count}"
            )
        if [item["index"] for item in values] != list(range(expected_count)):
            raise QualificationError(f"{scenario} indexes are not contiguous")
        if any(
            not item["active"]
            or item["terminal"] != "cancelled"
            or not item["completed"]
            or item["measured"] != (item["index"] >= warmup)
            for item in values
        ):
            raise QualificationError(f"{scenario} contains an invalid terminal sample")
        measured_values = [item["latency_ns"] for item in values if item["measured"]]
        p99 = percentile(measured_values, 99)
        if p99 > MAX_CANCELLATION_NS:
            raise QualificationError(f"{scenario} cancellation P99 exceeds 50 ms")
        result[scenario] = {
            "decision": "PASS",
            "sample_count": len(measured_values),
            "warmup_count": warmup,
            "p50_ns": percentile(measured_values, 50),
            "p95_ns": percentile(measured_values, 95),
            "p99_ns": p99,
            "max_ns": max(measured_values),
            "limit_ns": MAX_CANCELLATION_NS,
            "samples": values,
        }
    return result


def run_cancellation(warmup: int, repetitions: int, timeout: float) -> dict[str, Any]:
    command = [
        "/home/elliot/.codex/scripts/codex_cangjie_env",
        "cjpm",
        "test",
        "src/internal/transport_stdnet",
        "-j",
        "1",
        "--parallel",
        "1",
        "--filter=M125TransportCancellationProfileTest.*",
        "--show-all-output",
        "--no-progress",
        "--no-color",
    ]
    environment = dict(os.environ)
    environment["DISABLE_ZOXIDE"] = "1"
    environment["WIRESTACK_M125_WARMUP"] = str(warmup)
    environment["WIRESTACK_M125_REPETITIONS"] = str(repetitions)
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        timeout=timeout,
        check=False,
    )
    process = {
        "command": command,
        "exit_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "timed_out": False,
    }
    if completed.returncode != 0:
        raise QualificationError(f"cancellation profile failed: {process}")
    try:
        summary = parse_cancellation(completed.stdout, warmup, repetitions)
    except QualificationError as error:
        raise QualificationError(
            f"{error}; cancellation stdout={completed.stdout!r}; stderr={completed.stderr!r}"
        ) from error
    return {"summary": summary, "process": process}


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise QualificationError(f"expected a JSON object: {path}")
    return value


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository-revision", required=True)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--repetitions", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args(argv)
    if args.warmup <= 0 or args.repetitions < 20:
        parser.error("warmup must be positive and repetitions must be at least 20")

    try:
        net05 = validate_net05(load_json(NET05))
        net06 = validate_net06(load_json(NET06), load_json(NET06_MANIFEST), NET06_SOAK)
        cancellation = run_cancellation(args.warmup, args.repetitions, args.timeout)
        report = {
            "schema_version": 1,
            "task_id": "M1-025",
            "platform": "linux-x86_64-glibc",
            "repository_revision": args.repository_revision,
            "decision": "PASS",
            "configuration": {
                "warmup": args.warmup,
                "repetitions": args.repetitions,
                "cancellation_p99_limit_ns": MAX_CANCELLATION_NS,
                "retained_soak_reused": True,
            },
            "net05": {"decision": "PASS", "cases": net05, "source_sha256": evidence_digest.text_evidence_sha256(NET05)},
            "net06": {**net06, "source_sha256": evidence_digest.text_evidence_sha256(NET06)},
            "cancellation": cancellation,
            "source_sha256": {
                "profile_test": evidence_digest.text_evidence_sha256(
                    ROOT / "src/internal/transport_stdnet/m1_025_cancellation_profile_test.cj"
                ),
                "qualification_runner": evidence_digest.text_evidence_sha256(Path(__file__)),
            },
            "non_claims": [
                "No other platform was executed.",
                "The retained 24-hour soak was verified by digest and not rerun.",
                "No runtime, std, or SDK source was changed or built.",
            ],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"decision": "PASS", "output": str(args.output)}))
        return 0
    except (QualificationError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(f"M1-025 qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
