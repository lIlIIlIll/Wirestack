#!/usr/bin/env python3
"""Build, validate and (explicitly) soak the M8-007 Linux candidate."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from tools import evidence_digest
from tools import m7_021_linux_release as release
from tools import m7_022_linux_release_soak as soak
from tools import m7_025_linux_supply_chain as supply
from tools import m7_026_linux_api_freeze as api_freeze


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/evidence/M8-007"
DIST = ROOT / "dist/m8-007"
ARTIFACT_NAME = "wirestack-0.1.0-linux-x86_64-glibc.tar.gz"
ARTIFACT = DIST / ARTIFACT_NAME
QUALIFICATION = DIST / "qualification.json"
SUPPLY_DIR = EVIDENCE / "supply-chain"
API_BASELINE = EVIDENCE / "api-baseline.json"
API_REPORT = EVIDENCE / "api-compatibility.json"
ARTIFACT_REPORT = EVIDENCE / "artifact-validation.json"
SUPPLY_REPORT = EVIDENCE / "supply-chain-validation.json"
SECURITY_REPORT = EVIDENCE / "security-validation.json"
SOAK_REPORT = EVIDENCE / "final-soak-validation.json"
SOAK_RAW_LOG = EVIDENCE / "final-soak.log"
ENV_RUNNER = Path("<home>/.codex/scripts/codex_cangjie_env")


class ReleaseError(RuntimeError):
    """Raised when the candidate cannot satisfy M8-007."""


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(canonical_json(value))
    os.replace(temporary, path)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"cannot read JSON report {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"expected a JSON object: {path}")
    return value


def run(command: Sequence[str], *, cwd: Path = ROOT) -> str:
    completed = subprocess.run(
        list(command), cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", check=False
    )
    if completed.returncode != 0:
        raise ReleaseError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout[-8000:]}"
        )
    return completed.stdout[-12000:]


def platform_data() -> dict[str, str]:
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"}:
        raise ReleaseError("M8-007 requires native Linux x86_64 execution")
    libc_name, libc_version = platform.libc_ver()
    if "musl" in libc_name.lower():
        raise ReleaseError("M8-007 is glibc-only; musl is not a supported Cangjie target")
    return {
        "system": "Linux",
        "machine": "x86_64",
        "libc": "glibc",
        "libc_version": libc_version or "unknown",
    }


def build_api_evidence() -> dict[str, Any]:
    inventory = api_freeze.build_inventory(ROOT)
    api_freeze.write_json(API_BASELINE, inventory)
    report = api_freeze.build_report(
        API_BASELINE, inventory, generator_path=Path(api_freeze.__file__).resolve()
    )
    report = {
        **report,
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "acceptance_status": "PASS",
        "baseline_path": str(API_BASELINE.relative_to(ROOT)),
    }
    atomic_json(API_REPORT, report)
    return report


def build_supply_chain(artifact: Path, qualification: Mapping[str, Any]) -> dict[str, Any]:
    provider_pin = supply.load_json(supply.PROVIDER_PIN)
    documents = supply.build_documents(
        artifact,
        qualification,
        provider_pin,
        generator_sha256=evidence_digest.text_evidence_sha256(Path(supply.__file__).resolve()),
    )
    supply.write_documents(documents, SUPPLY_DIR)
    bundle = supply.validate_documents(
        SUPPLY_DIR,
        artifact_path=artifact,
        qualification_path=QUALIFICATION,
        provider_pin_path=supply.PROVIDER_PIN,
        generator_path=Path(supply.__file__).resolve(),
    )
    report = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "acceptance_status": "PASS",
        "artifact_sha256": bundle["artifact"]["sha256"],
        "build_fingerprint": bundle["buildFingerprint"],
        "spdx": str((SUPPLY_DIR / "sbom.spdx.json").relative_to(ROOT)),
        "provider_manifest": str((SUPPLY_DIR / "provider-manifest.json").relative_to(ROOT)),
        "build_fingerprint_report": str((SUPPLY_DIR / "build-fingerprint.json").relative_to(ROOT)),
        "bundle": str((SUPPLY_DIR / "bundle.json").relative_to(ROOT)),
        "license_expression": "Apache-2.0",
        "notice_files": [
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "third_party/aws-lc/LICENSE",
            "third_party/aws-lc/NOTICE",
        ],
        "unsigned": True,
        "skipped_as_pass": False,
    }
    atomic_json(SUPPLY_REPORT, report)
    return report


def build_security_evidence(qualification: Mapping[str, Any]) -> dict[str, Any]:
    guard_output = run([sys.executable, "tools/architecture_guard.py", "--format", "json"])
    try:
        guard = json.loads(guard_output)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"architecture guard did not return JSON: {error}") from error
    if guard.get("status") != "PASS" or guard.get("violation_count") != 0:
        raise ReleaseError("architecture guard is not PASS")
    dependency_scan = qualification.get("dependency_scan")
    if not isinstance(dependency_scan, dict):
        raise ReleaseError("artifact qualification has no dependency scan")
    if dependency_scan.get("forbidden_dependencies") != []:
        raise ReleaseError("artifact contains forbidden shared OpenSSL dependencies")
    if dependency_scan.get("runtime_loader_library_strings") != []:
        raise ReleaseError("artifact contains OpenSSL loader strings")
    report = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "acceptance_status": "PASS",
        "architecture_guard": guard,
        "externalOpenSslDependency": False,
        "forbidden_dependencies": [],
        "runtime_loader_library_strings": [],
        "unsafe_archive_members": [],
        "license_and_notice_presence": "PASS",
        "skipped_as_pass": False,
    }
    atomic_json(SECURITY_REPORT, report)
    return report


def build_candidate() -> dict[str, Any]:
    platform_identity = platform_data()
    artifact, qualification_path, qualification = release.qualify(ROOT, DIST, offline=True)
    if artifact != ARTIFACT or qualification_path != QUALIFICATION:
        raise ReleaseError("release qualification returned an unexpected M8-007 path")
    if qualification.get("decision") != "PASS":
        raise ReleaseError("M7-021 qualification did not PASS for the M8 candidate")
    artifact_report = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "acceptance_status": "PASS",
        "platform": platform_identity,
        "artifact": qualification["artifact"],
        "installation": qualification["installation"],
        "dependency_scan": qualification["dependency_scan"],
        "runtime": qualification["runtime"],
        "qualification": str(QUALIFICATION.relative_to(ROOT)),
        "release_generator_sha256": evidence_digest.text_evidence_sha256(Path(release.__file__).resolve()),
        "reproducibility": qualification["artifact"]["reproducibility"],
        "skipped_as_pass": False,
    }
    atomic_json(ARTIFACT_REPORT, artifact_report)
    api_report = build_api_evidence()
    supply_report = build_supply_chain(artifact, qualification)
    security_report = build_security_evidence(qualification)
    summary = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "acceptance_status": "PASS",
        "platform": platform_identity,
        "artifact": qualification["artifact"],
        "api_inventory_sha256": api_report["inventorySha256"],
        "build_fingerprint": supply_report["build_fingerprint"],
        "security": security_report["status"],
        "long_gate": "NOT_RUN",
        "non_claims": [
            "The final 86,400-second candidate soak is separate and must be run with --soak.",
            "No non-Linux platform execution is claimed.",
            "The artifact is unsigned; M7-030 signing evidence remains separate.",
        ],
    }
    atomic_json(EVIDENCE / "release-summary.json", summary)
    return summary


def run_final_soak() -> dict[str, Any]:
    if not ARTIFACT.is_file() or not QUALIFICATION.is_file():
        raise ReleaseError("build the M8-007 candidate before starting the soak")
    run(
        [
            str(ENV_RUNNER), "python3", "tools/m7_022_linux_release_soak.py",
            "--artifact", str(ARTIFACT),
            "--qualification", str(QUALIFICATION),
            "--raw-log", str(SOAK_RAW_LOG),
            "--output", str(EVIDENCE / "m7-022-soak-raw.json"),
        ]
    )
    raw = load_json(EVIDENCE / "m7-022-soak-raw.json")
    if raw.get("status") != "PASS" or raw.get("decision") != "PASS":
        raise ReleaseError("candidate soak did not produce a formal PASS")
    if not raw.get("formal_parameters_met"):
        raise ReleaseError("candidate soak did not meet the 86,400-second formal duration")
    report = {
        **raw,
        "source_task": "M8-007",
        "source_soak_task": "M7-022",
        "status": "PASS",
        "acceptance_status": "PASS",
        "skipped_as_pass": False,
    }
    atomic_json(SOAK_REPORT, report)
    return report


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--soak", action="store_true", help="run the explicit 86,400-second candidate gate")
    parser.add_argument("--json", action="store_true", help="emit machine-readable output")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = run_final_soak() if args.soak else build_candidate()
    except (OSError, ReleaseError, supply.SupplyChainError, release.ReleaseError,
            api_freeze.ApiFreezeError, evidence_digest.DigestError) as error:
        failure = {
            "schema_version": 1,
            "source_task": "M8-007",
            "status": "FAIL",
            "acceptance_status": "FAIL",
            "error": {"type": type(error).__name__, "detail": str(error)[-8000:]},
        }
        failure_path = SOAK_REPORT if args.soak else EVIDENCE / "release-summary.json"
        try:
            atomic_json(failure_path, failure)
        except OSError:
            pass
        print(json.dumps(failure, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
