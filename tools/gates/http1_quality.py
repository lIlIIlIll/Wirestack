#!/usr/bin/env python3
"""Run bounded Linux HTTP/1 conformance and deterministic-fuzz gates."""
from __future__ import annotations

from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Sequence

SCHEMA_VERSION = 1
MAX_CAPTURE_BYTES = 4 * 1024 * 1024
SUMMARY_RE = re.compile(
    r"Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+), SKIPPED:\s*(\d+), ERROR:\s*(\d+)\s+FAILED:\s*(\d+)",
    re.MULTILINE,
)


class GateError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.kill()
    else:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=2)


def run(command: Sequence[str], cwd: Path, timeout: float) -> dict[str, Any]:
    started = time.monotonic()
    kwargs: dict[str, Any] = {
        "args": list(command), "cwd": cwd, "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE, "stderr": subprocess.PIPE, "shell": False,
        "start_new_session": os.name != "nt",
    }
    process = subprocess.Popen(**kwargs)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate(process)
        stdout, stderr = process.communicate()
    return {
        "command": list(command), "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000, 3),
        "stdout": stdout[-MAX_CAPTURE_BYTES:].decode("utf-8", errors="replace"),
        "stderr": stderr[-MAX_CAPTURE_BYTES:].decode("utf-8", errors="replace"),
    }


def parse_summary(output: str) -> dict[str, int]:
    matches = list(SUMMARY_RE.finditer(output))
    if not matches:
        raise GateError("cjpm test output has no project summary")
    total, passed, skipped, errors, failed = (int(value) for value in matches[-1].groups())
    if total != passed + skipped + errors + failed:
        raise GateError("cjpm test project summary totals are inconsistent")
    return {"total": total, "passed": passed, "skipped": skipped, "errors": errors, "failed": failed}


def classify(process: dict[str, Any], minimum_passed: int,
             required_cases: Sequence[str]) -> tuple[str, dict[str, int] | None, list[str]]:
    reasons: list[str] = []
    summary: dict[str, int] | None = None
    if process["timed_out"]:
        reasons.append("test process timed out")
    if process["exit_code"] != 0:
        reasons.append(f"test process exited {process['exit_code']}")
    try:
        summary = parse_summary(process["stdout"])
    except GateError as error:
        reasons.append(str(error))
    if summary is not None:
        if summary["passed"] < minimum_passed:
            reasons.append(f"passed {summary['passed']} tests; required at least {minimum_passed}")
        if summary["failed"] or summary["errors"]:
            reasons.append("project summary contains failed or errored tests")
    for case in required_cases:
        if f"[ PASSED ] CASE: {case}" not in process["stdout"]:
            reasons.append(f"required case did not pass: {case}")
    return ("PASS" if not reasons else "FAIL", summary, reasons)


def source_fingerprint(root: Path) -> str:
    paths = sorted((root / "src/http").glob("*.cj")) + sorted((root / "src/internal/http1").glob("*.cj"))
    return evidence_digest.text_evidence_inventory_sha256(root, paths)


def tool_version(command: Sequence[str], root: Path) -> str:
    result = run(command, root, 10)
    text = (result["stdout"] + result["stderr"]).strip()
    return text[:4096] if result["exit_code"] == 0 else f"UNAVAILABLE(exit={result['exit_code']})"


def suites(name: str) -> list[tuple[str, list[str], int, list[str]]]:
    common = ["cjpm", "test", "--no-progress", "--no-color"]
    fuzz_cases = [
        "everyAcceptedSingleByteMutationHasACanonicalReparse",
        "acceptedUrlMutationsRoundTripToOneCanonicalIdentity",
        "acceptedNoProxyMutationsRemainDeterministicAcrossTargets",
        "proxyAuthorizationMutationCannotInjectBeforeDnsOrConnect",
    ]
    if name == "conformance":
        return [("full-http1-regression", common, 263, [
            "clientAndServerFramingRejectTheSameAmbiguousHeaderCorpus",
            "connectAuthenticatesProxyThenHandshakesTheOriginAndReusesTunnel",
            "forwardProxyUsesAbsoluteFormIndependentDnsAndHookCredentials",
        ])]
    if name == "fuzz":
        return [
            ("smuggling-mutations", common + ["--filter", "Http1SmugglingCorpusTest"], 6, fuzz_cases[:1]),
            ("url-proxy-mutations", common + ["--filter", "Http1DeterministicFuzzTest"], 3, fuzz_cases[1:]),
        ]
    raise GateError(f"unknown suite: {name}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", choices=("conformance", "fuzz"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    args = parser.parse_args(argv)
    if args.timeout_seconds <= 0 or args.timeout_seconds > 3600:
        parser.error("--timeout-seconds must be in (0, 3600]")
    root = Path(__file__).resolve().parents[2]
    started = utc_now()
    results: list[dict[str, Any]] = []
    decision = "PASS"
    for scenario_id, command, minimum, required in suites(args.suite):
        process = run(command, root, args.timeout_seconds)
        scenario_decision, summary, reasons = classify(process, minimum, required)
        if scenario_decision != "PASS":
            decision = "FAIL"
        results.append({
            "id": scenario_id, "decision": scenario_decision,
            "minimum_passed": minimum, "required_cases": required,
            "summary": summary, "reasons": reasons, "process": process,
        })
    report = {
        "schema_version": SCHEMA_VERSION,
        "gate_id": "GATE-HTTP1-CONFORMANCE" if args.suite == "conformance" else "GATE-HTTP1-FUZZ",
        "suite": args.suite, "decision": decision,
        "started_at_utc": started, "finished_at_utc": utc_now(),
        "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
        "toolchain": {"cjc": tool_version(["cjc", "-v"], root), "cjpm": tool_version(["cjpm", "-v"], root)},
        "source_sha256": source_fingerprint(root), "scenarios": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"gate_id": report["gate_id"], "decision": decision, "output": str(args.output)}))
    return 0 if decision == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
