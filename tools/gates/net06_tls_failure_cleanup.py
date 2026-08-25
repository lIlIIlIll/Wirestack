#!/usr/bin/env python3
"""Run 100,000 AWS-LC failed-handshake cleanup cycles for GATE-NET-06."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.gates.net06_leak_soak import ResourceSampler, atomic_json, resource_aggregate, resource_trend, run_process
from tools.tls_provider_poc import run as poc

FAILURE_METRIC_RE = re.compile(r"^METRIC failure_cleanup_cycles=(\d+)$", re.M)


class CleanupError(RuntimeError):
    pass


def parse_completed_cycles(stdout: str) -> int:
    matches = FAILURE_METRIC_RE.findall(stdout)
    if len(matches) != 1:
        raise CleanupError(
            f"expected one failure_cleanup_cycles metric, found {len(matches)}")
    return int(matches[0])


def execute(work: Path, cycles: int, timeout: float,
            sample_interval: float, revision: str) -> dict[str, Any]:
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    log = work / "build.log"
    specs = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
    spec = next(item for item in specs["providers"] if item["id"] == "aws-lc")
    source, source_info = poc.source_provider(spec, work, log)
    prefix, archives = poc.build_provider(spec, source, work, log)
    fixtures = poc.generate_fixtures(work, log)
    binary = poc.compile_poc(
        spec, ROOT, prefix, archives, work, log,
        extra_cflags=("-DCLEANUP_CYCLES=0", f"-DFAILURE_CLEANUP_CYCLES={cycles}"),
    )
    build = poc.inspect_binary(binary, archives, work, log)
    sampler = ResourceSampler(sample_interval)
    process = run_process([
        str(binary), str(fixtures / "server.pem"), str(fixtures / "server.key"),
        str(fixtures / "ca.pem"), str(fixtures / "client.pem"),
        str(fixtures / "client.key"),
    ], work, timeout, sampler)
    completed = parse_completed_cycles(process["stdout"])
    trend = resource_trend(sampler.samples)
    passed = (
        process["exit_code"] == 0 and not process["timed_out"] and
        completed == cycles and trend["decision"] == "PASS" and
        not build["system_tls_dependencies"] and
        not build["runtime_loader_library_strings"]
    )
    return {
        "schema_version": 1,
        "task_id": "M0-011",
        "gate_id": "GATE-NET-06",
        "scenario": "tls-handshake-failure-cleanup",
        "decision": "PASS" if passed else "FAIL",
        "requested_cycles": cycles,
        "completed_cycles": completed,
        "repository_revision": revision,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": source_info,
        "build": build,
        "resources": {
            "aggregate": resource_aggregate(sampler.samples),
            "trend": trend,
            "samples": sampler.samples,
        },
        "process": process,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path,
                        default=ROOT / "build/gates/net06-tls-failure-cleanup")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "build/gates/net06-tls-failure-cleanup.json")
    parser.add_argument("--cycles", type=int, default=100_000)
    parser.add_argument("--timeout-seconds", type=float, default=7200.0)
    parser.add_argument("--sample-interval-seconds", type=float, default=0.25)
    parser.add_argument("--repository-revision",
                        default=os.environ.get("WIRESTACK_REPOSITORY_REVISION", "unknown"))
    args = parser.parse_args(argv)
    if args.cycles <= 0:
        parser.error("--cycles must be positive")
    if args.sample_interval_seconds <= 0:
        parser.error("--sample-interval-seconds must be positive")
    try:
        report = execute(args.work_dir.resolve(), args.cycles, args.timeout_seconds,
                         args.sample_interval_seconds, args.repository_revision)
        atomic_json(args.output.resolve(), report)
    except Exception as error:
        print(f"GATE-NET-06 TLS cleanup: ERROR: {type(error).__name__}: {error}",
              file=sys.stderr)
        return 1
    print(f"M0-011 TLS failure cleanup: {report['decision']} "
          f"cycles={report['completed_cycles']}")
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
