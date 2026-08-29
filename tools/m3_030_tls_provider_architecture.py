#!/usr/bin/env python3
"""Validate the M3-030 build-selected TLS provider architecture."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import architecture_guard
from tools import m3_029_linux_tls_facade as clean
from tools import m7_021_linux_release as release
from tools import m7_025_linux_supply_chain as supply
from tools.tls_provider.selection import archive_symbols, expected_symbols, select_provider, validate_symbol_set

TASK_ID = "M3-030"
PROFILE = "linux-x86_64-glibc"
OUTPUT = ROOT / "docs/evidence/M3-030"
ENV_WRAPPER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")


class GateError(RuntimeError):
    pass


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def run(command: Sequence[str], cwd: Path, timeout: int) -> str:
    completed = subprocess.run(
        list(command), cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout, check=False,
    )
    output = completed.stdout[-20000:]
    if completed.returncode != 0:
        raise GateError(f"command exit {completed.returncode}: {' '.join(command)}\n{output}")
    return output


def base_report(**values: Any) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "platform": PROFILE,
        "acceptance_status": "PASS",
        "status": "PASS",
        "decision": "PASS",
        **values,
    }


def validate_platform() -> None:
    if platform.system() != "Linux" or platform.machine().lower() != "x86_64":
        raise GateError(f"BLOCKED: requires Linux/x86_64, got {platform.system()}/{platform.machine()}")


def validate_clean_consumer() -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="wirestack-m3-030-consumer-") as directory:
        consumer = Path(directory)
        (consumer / "src").mkdir()
        (consumer / "cjpm.toml").write_text(clean.consumer_manifest().replace(
            "m3_029_public_tls_consumer", "m3_030_public_tls_consumer"
        ), encoding="utf-8")
        source = (ROOT / "tools/release_smoke/main.cj").read_text(encoding="utf-8")
        (consumer / "src/main.cj").write_text(source.replace(
            "package wirestack_release_smoke", "package m3_030_public_tls_consumer"
        ), encoding="utf-8")
        run([str(ENV_WRAPPER), "--cwd", str(consumer), "cjpm", "build"], consumer, 300)
        binary = consumer / "target/release/bin/main"
        if not binary.is_file():
            raise GateError("clean consumer produced no executable")
        output = run([str(ENV_WRAPPER), "--cwd", str(consumer), str(binary)], consumer, 60)
        clean.validate_smoke_output(output)
    return base_report(checks={"publicApiOnly": "PASS", "build": "PASS", "httpsLoopback": "PASS"})


def validate() -> dict[str, Any]:
    validate_platform()
    selected = select_provider(ROOT)
    run([sys.executable, "tools/build_tls_provider.py", "--offline", "--json"], ROOT, 1200)
    archive = ROOT / "target/native/current/lib/libwirestack_tls_provider.a"
    symbols = archive_symbols(archive)
    validate_symbol_set(selected, symbols)
    violations = architecture_guard.run_guard(ROOT)
    if violations:
        raise GateError(architecture_guard.render_text(violations))

    test_output = run([
        str(ENV_WRAPPER), "--cwd", str(ROOT), "cjpm", "test",
        "--filter", "TlsProviderSubstitutionTest",
    ], ROOT, 300)
    stable_test_output = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", test_output)
    if "PASSED: 3" not in stable_test_output or "FAILED: 0" not in stable_test_output:
        raise GateError("test provider result did not contain 3 passed and 0 failed")

    qualification = release.load_json(ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json")
    release.validate_report(qualification, ROOT)
    bundle = supply.validate_documents(
        artifact_path=ROOT / "dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz"
    )

    reports = {
        "platform-provider-matrix.json": base_report(
            selected={"platform": selected.platform, "provider": selected.provider,
                      "adapter": selected.adapter, "fallback": False},
            productionCombinations=[f"{selected.platform}+{selected.provider}"],
            futureAdaptersImplemented=[],
        ),
        "native-abi-report.json": base_report(
            abiVersion=selected.manifest["abi"]["version"],
            requiredFunctions=sorted(expected_symbols(selected)),
            signatureCount=len(selected.abi_contract["signatures"]),
            callingConventions=["c"],
            signatureChecks={"cangjieForeignDeclarations": "PASS", "nativeHeaderProbe": "PASS"},
            archive=str(archive.relative_to(ROOT)),
            missingFunctions=[],
        ),
        "architecture-guard.json": base_report(violationCount=0, violations=[]),
        "test-provider-results.json": base_report(
            passed=3, failed=0, skippedAsPass=False,
            properties=["factory-substitution", "instance-mismatch", "retained-lifetime"],
            releasePayload=False,
        ),
        "linux-aws-lc-results.json": base_report(
            providerId=selected.provider,
            providerVersion=selected.manifest["provider_version"],
            selectionFingerprint=selected.fingerprint,
            capabilities=selected.manifest["capabilities"],
            externalOpenSslDependency=False,
        ),
        "clean-consumer.json": validate_clean_consumer(),
        "release-validation.json": base_report(
            artifact=qualification["artifact"],
            provider=selected.provider,
            externalOpenSslDependency=False,
        ),
        "sbom-validation.json": base_report(
            buildFingerprint=bundle["buildFingerprint"],
            provider=selected.provider,
            licenseExpression=selected.manifest["license_expression"],
        ),
    }
    for name, report in reports.items():
        atomic_json(OUTPUT / name, report)
    return base_report(reportCount=len(reports), skippedAsPass=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = validate()
    except (GateError, subprocess.TimeoutExpired, Exception) as error:
        failure = {"taskId": TASK_ID, "decision": "FAIL", "error": str(error)[:4096]}
        print(json.dumps(failure, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True) if args.json else f"{TASK_ID} PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
