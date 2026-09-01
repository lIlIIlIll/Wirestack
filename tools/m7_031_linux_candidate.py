#!/usr/bin/env python3
"""Generate and validate the M7-031 Linux release-candidate report."""

from __future__ import annotations

from tools import evidence_digest

import argparse
import json
import os
import re
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

import architecture_guard
import m7_021_linux_release
import m7_025_linux_supply_chain
import m7_030_linux_release
import m7_032_public_api_inventory
from gates import m7_023_linux_fuzz
from gates import m7_024_linux_performance


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-031"
SCHEMA_VERSION = 1
PROFILE = "linux-x86_64-glibc"
DEFAULT_REPORT = ROOT / "docs/evidence/M7-031/linux_x86_64/release-candidate.json"
DEPENDENCIES = tuple(f"M7-{number:03d}" for number in range(19, 31)) + ("M7-032",)
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_SUBJECTS = ("artifact", "release-manifest", "sbom")

DOCUMENT_PATHS = {
    "m7_019": "docs/evidence/M7-019/linux_x86_64/audit.data",
    "m7_020": "docs/evidence/M7-020/linux_x86_64/audit.data",
    "m7_021": "docs/evidence/M7-021/linux_x86_64/qualification.json",
    "m7_022": "docs/evidence/M7-022/linux_x86_64/soak.json",
    "m7_023": "docs/evidence/M7-023/linux_glibc_x86_64/fuzz-report.json",
    "m7_024": "docs/evidence/M7-024/linux_glibc_x86_64/performance-gate.json",
    "m7_024_h2": "docs/evidence/M7-024/linux_glibc_x86_64/http2-benchmark-after-m6-026.json",
    "m7_025": "docs/evidence/M7-025/linux_x86_64/bundle.json",
    "m7_026": "docs/evidence/M7-026/linux_x86_64/api-compatibility.json",
    "m7_027": "docs/evidence/M7-027/linux_x86_64/examples.json",
    "m7_028": "docs/evidence/M7-028/linux_x86_64/review-package.json",
    "m7_029": "docs/evidence/M7-029/linux_x86_64/review-validation.json",
    "m7_029_review": "docs/evidence/M7-029/independent-review.json",
    "m7_030": "docs/evidence/M7-030/hosted-validation.json",
    "m7_030_hosted": "docs/evidence/M7-030/github-attestation.json",
    "m7_032": "docs/evidence/M7-032/linux_x86_64/public-api.json",
    "m7_032_consumer": "docs/evidence/M7-032/linux_x86_64/clean-consumer.json",
}

CRITERION_EVIDENCE = {
    "REL-01": [DOCUMENT_PATHS["m7_021"], DOCUMENT_PATHS["m7_032_consumer"]],
    "REL-02": ["docs/evidence/M6-021/README.md", DOCUMENT_PATHS["m7_021"]],
    "REL-03": [
        "docs/architecture/adr/0002-linux-first-delivery-profile.md",
        "docs/architecture/adr/0004-linux-glibc-support.md",
    ],
    "REL-04": [DOCUMENT_PATHS["m7_021"], DOCUMENT_PATHS["m7_025"]],
    "REL-05": [
        "docs/evidence/M3-028/linux_glibc_x86_64/tls-qualification.json",
        "docs/evidence/M3-030/linux-aws-lc-results.json",
    ],
    "REL-06": ["docs/evidence/M6-019/README.md", DOCUMENT_PATHS["m7_023"]],
    "REL-07": ["docs/evidence/M2-015/linux_glibc_x86_64/report.json"],
    "REL-08": ["docs/evidence/M6-022/README.md", DOCUMENT_PATHS["m7_032_consumer"]],
    "REL-09": ["docs/evidence/M1-003/README.md", DOCUMENT_PATHS["m7_019"]],
    "REL-10": [
        "docs/evidence/M3-028/linux_glibc_x86_64/tls-qualification.json",
        "docs/evidence/M0-009/README.md",
    ],
    "REL-11": ["docs/evidence/M1-024/README.md", DOCUMENT_PATHS["m7_019"]],
    "REL-12": ["docs/evidence/M0-011/README.md", DOCUMENT_PATHS["m7_022"]],
    "REL-13": [DOCUMENT_PATHS["m7_024"]],
    "REL-14": [DOCUMENT_PATHS["m7_023"], "docs/evidence/M7-023/linux_glibc_x86_64/replay-report.json"],
    "REL-15": [DOCUMENT_PATHS["m7_029"], DOCUMENT_PATHS["m7_029_review"]],
    "REL-16": [
        DOCUMENT_PATHS["m7_025"],
        "docs/evidence/M7-025/linux_x86_64/sbom.spdx.json",
        "docs/evidence/M7-025/linux_x86_64/provider-manifest.json",
        "docs/evidence/M7-025/linux_x86_64/build-fingerprint.json",
    ],
    "REL-17": ["docs/guides/migrate-to-wirestack-linux.md", "docs/architecture/linux-tls-provider-build.md"],
    "REL-18": [DOCUMENT_PATHS["m7_020"], "docs/evidence/M3-030/architecture-guard.json"],
    "REL-19": [DOCUMENT_PATHS["m7_022"]],
    "REL-20": ["docs/evidence/M1-022/README.md", "docs/evidence/M5-030/README.md"],
    "REL-21": [DOCUMENT_PATHS["m7_020"]],
    "REL-22": [
        "docs/architecture/adr/0005-upstream-independent-transport-capabilities.md",
        "docs/evidence/M0-024/README.md",
    ],
}

CRITERION_NOTES = {
    "REL-01": "Native Linux clean-consumer HTTPS client execution passes. Non-Linux client cells remain open globally.",
    "REL-02": "Native Linux TLS HTTP/1.1 and HTTP/2 server execution passes.",
    "REL-03": "This criterion contains only Android and iOS listener cells and is not a Linux PASS.",
    "REL-04": "The frozen artifact has no system libssl or libcrypto dependency or loader string.",
    "REL-05": "AWS-LC 5.5.0 native qualification passes TLS 1.2 and TLS 1.3 client and server interoperability.",
    "REL-06": "HTTP/1.1 security and HTTP/2 conformance evidence passes with the release fuzz corpus.",
    "REL-07": "Native Linux Happy Eyeballs blackhole, cancellation, winner, and loser-cleanup cases pass.",
    "REL-08": "Public request, connection, and stream cancellation uses the canonical operation context.",
    "REL-09": "The stack uses one monotonic absolute Deadline and does not add another timeout owner.",
    "REL-10": "Peer EOF, local close, RST, cancellation, deadline, and TLS truncation retain distinct results.",
    "REL-11": "The one-reader and one-writer contract and same-direction exclusion pass deterministic races.",
    "REL-12": "Connections use Cangjie tasks and bounded shared infrastructure, not one OS thread per connection.",
    "REL-13": "The consolidated Linux gate passes all raw TCP, DNS, TLS, H1, H2, cancellation, SSE, and memory domains.",
    "REL-14": "All ten release fuzz targets pass their iteration thresholds with no current-run crash artifact.",
    "REL-15": "The independent review has 17 Fixed findings and zero unresolved High or Critical findings.",
    "REL-16": "The SPDX SBOM, provider manifest, and build fingerprint bind the frozen artifact.",
    "REL-17": "Maintained Linux documentation uses the bundled build-selected provider and requires no OpenSSL installation.",
    "REL-18": "The architecture guard finds no legacy global provider or runtime provider lookup.",
    "REL-19": "The frozen artifact completed the uninterrupted 86,400-second mixed soak with bounded resource trends.",
    "REL-20": "Transport, TLS, and HTTP errors retain stable category, phase, code, and retryability.",
    "REL-21": "The current architecture guard finds no CJ_MRT_Sock private ABI call.",
    "REL-22": "The Linux release uses only the public SDK; runtime and std source changes remain optional future work.",
}


class CandidateError(RuntimeError):
    """Raised when the candidate cannot satisfy the release contract."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


def require(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise CandidateError(code, detail)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def safe_path(root: Path, relative: str, *, must_exist: bool = True) -> Path:
    require(isinstance(relative, str) and relative != "", "PATH_INVALID", "path must be a non-empty string")
    base = root.resolve()
    candidate = (base / relative).resolve()
    try:
        candidate.relative_to(base)
    except ValueError as error:
        raise CandidateError("PATH_ESCAPE", relative) from error
    if must_exist:
        require(candidate.is_file(), "PATH_MISSING", relative)
    return candidate


def _object_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise CandidateError("JSON_DUPLICATE_KEY", key)
        value[key] = item
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_object_no_duplicates)
    except CandidateError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CandidateError("JSON_INVALID", str(path)) from error
    require(isinstance(value, dict), "JSON_TYPE", str(path))
    schema = value.get("schema_version", value.get("schemaVersion"))
    require(schema == SCHEMA_VERSION, "SCHEMA_UNSUPPORTED", str(path))
    return value


def load_documents(root: Path) -> dict[str, dict[str, Any]]:
    return {key: load_json(safe_path(root, relative)) for key, relative in DOCUMENT_PATHS.items()}


def validate_dependency_status(root: Path) -> None:
    text = safe_path(root, "docs/planning/status.md").read_text(encoding="utf-8")
    for task_id in DEPENDENCIES:
        pattern = re.compile(rf"^\| {re.escape(task_id)} \| COMPLETE \|", re.MULTILINE)
        require(pattern.search(text) is not None, "DEPENDENCY_INCOMPLETE", task_id)


def require_pass(value: Mapping[str, Any], label: str) -> None:
    seen = False
    for key in ("decision", "status", "acceptance_status"):
        if key in value:
            seen = True
            require(value[key] == "PASS", "REPORT_NOT_PASS", f"{label}.{key}={value[key]!r}")
    require(seen, "REPORT_STATUS_MISSING", label)
    checks = value.get("checks")
    if isinstance(checks, Mapping) and "skippedAsPass" in checks:
        require(checks["skippedAsPass"] is False, "SKIPPED_AS_PASS", label)


def strict_digest(value: Any, label: str) -> str:
    require(isinstance(value, str) and DIGEST_RE.fullmatch(value) is not None, "DIGEST_INVALID", label)
    return value


def validate_artifact_identity(
    documents: Mapping[str, Mapping[str, Any]], root: Path,
    *, verify_local_artifact: bool = True,
) -> dict[str, Any]:
    qualification = documents["m7_021"]
    soak = documents["m7_022"]
    bundle = documents["m7_025"]
    hosted = documents["m7_030_hosted"]
    artifact = qualification.get("artifact")
    require(isinstance(artifact, Mapping), "ARTIFACT_MISSING", "M7-021")
    digest = strict_digest(artifact.get("sha256"), "M7-021 artifact")
    payload = strict_digest(artifact.get("payload_sha256"), "M7-021 payload")
    require(isinstance(artifact.get("bytes"), int) and artifact["bytes"] > 0,
            "ARTIFACT_SIZE", "invalid frozen artifact size")

    soak_artifact = soak.get("artifact", {})
    require(soak_artifact.get("sha256") == digest, "ARTIFACT_MISMATCH", "M7-022")
    require(soak_artifact.get("payload_sha256") == payload, "PAYLOAD_MISMATCH", "M7-022")
    supply_artifact = bundle.get("artifact", {})
    require(supply_artifact.get("sha256") == digest, "ARTIFACT_MISMATCH", "M7-025")
    require(supply_artifact.get("payloadSha256") == payload, "PAYLOAD_MISMATCH", "M7-025")

    subjects = hosted.get("subjects")
    require(isinstance(subjects, list), "HOSTED_SUBJECTS", "subjects must be an array")
    subject_map = {
        item.get("name"): item for item in subjects if isinstance(item, Mapping)
    }
    require(tuple(item.get("name") for item in subjects) == EXPECTED_SUBJECTS,
            "HOSTED_SUBJECTS", "artifact, release-manifest, and sbom are required in order")
    require(subject_map["artifact"].get("sha256") == digest,
            "ARTIFACT_MISMATCH", "M7-030 hosted artifact")
    for name in EXPECTED_SUBJECTS:
        require(subject_map[name].get("verification") == "PASS", "HOSTED_NOT_VERIFIED", name)
        strict_digest(subject_map[name].get("sha256"), f"M7-030 {name}")
        strict_digest(subject_map[name].get("bundleSha256"), f"M7-030 {name} bundle")

    documents_map = bundle.get("documents", {})
    sbom_digest = strict_digest(
        documents_map.get("sbom.spdx.json", {}).get("sha256"), "M7-025 SBOM"
    )
    require(subject_map["sbom"].get("sha256") == sbom_digest,
            "SBOM_MISMATCH", "M7-030 hosted SBOM")
    if verify_local_artifact:
        local_artifact = safe_path(root, f"dist/m7-021/{artifact.get('name')}")
        require(evidence_digest.artifact_byte_sha256(local_artifact) == digest, "ARTIFACT_BYTES_STALE", str(local_artifact))
        require(local_artifact.stat().st_size == artifact.get("bytes"), "ARTIFACT_SIZE", str(local_artifact))

    return {
        "name": artifact["name"],
        "bytes": artifact["bytes"],
        "sha256": digest,
        "payloadSha256": payload,
        "sourceTreeSha256": strict_digest(qualification.get("source_tree_sha256"), "M7-021 source tree"),
        "buildFingerprint": strict_digest(bundle.get("buildFingerprint"), "M7-025 build fingerprint"),
        "providerManifestSha256": strict_digest(
            documents_map.get("provider-manifest.json", {}).get("sha256"), "M7-025 provider manifest"
        ),
        "sbomSha256": sbom_digest,
        "releaseManifestSha256": subject_map["release-manifest"]["sha256"],
        "hostedAttestationCommit": hosted.get("commit"),
    }


def validate_soak(
    root: Path, soak: Mapping[str, Any], artifact_digest: str,
    *, report_sha256: str | None = None,
) -> dict[str, Any]:
    require_pass(soak, "M7-022")
    require(soak.get("formal_parameters_met") is True, "SOAK_NOT_FORMAL", "formal parameters")
    parameters = soak.get("parameters", {})
    process = soak.get("process", {})
    require(parameters.get("duration_seconds", 0) >= 86400, "SOAK_TOO_SHORT", "requested duration")
    require(parameters.get("minimum_formal_seconds", 0) >= 86400, "SOAK_TOO_SHORT", "formal minimum")
    require(process.get("wall_elapsed_ms", 0) >= 86400000, "SOAK_TOO_SHORT", "wall duration")
    require(process.get("exit_code") == 0 and process.get("timed_out") is False,
            "SOAK_INTERRUPTED", "process did not complete normally")
    require(soak.get("artifact", {}).get("sha256") == artifact_digest,
            "ARTIFACT_MISMATCH", "M7-022 soak")
    workload = soak.get("workload", {})
    require(workload.get("decision") == "PASS", "SOAK_WORKLOAD", "workload decision")
    checks = workload.get("checks", {})
    require(isinstance(checks, Mapping) and checks and all(value is True for value in checks.values()),
            "SOAK_WORKLOAD", "not every workload check passed")
    return {
        "reportSha256": (
            strict_digest(report_sha256, "M7-022 recorded report")
            if report_sha256 is not None
            else evidence_digest.text_evidence_sha256(safe_path(root, DOCUMENT_PATHS["m7_022"]))
        ),
        "wallElapsedMs": process["wall_elapsed_ms"],
        "requestedSeconds": parameters["duration_seconds"],
        "formalParametersMet": True,
    }


def validate_security(
    validation: Mapping[str, Any], review: Mapping[str, Any]
) -> dict[str, Any]:
    require_pass(validation, "M7-029 validation")
    checks = validation.get("checks", {})
    require(checks.get("unresolvedHighCritical") == 0,
            "SECURITY_BLOCKER", "validation reports unresolved High or Critical")
    findings = review.get("findings")
    require(isinstance(findings, list) and findings, "FINDINGS_MISSING", "M7-029")
    open_high_critical = []
    for finding in findings:
        require(isinstance(finding, Mapping), "FINDING_INVALID", "finding must be an object")
        severity = finding.get("severity")
        status = finding.get("status")
        if severity in {"High", "Critical"} and status != "Fixed":
            open_high_critical.append(finding.get("id", "unknown"))
    require(not open_high_critical, "SECURITY_BLOCKER", ",".join(open_high_critical))
    statuses: dict[str, int] = {}
    for finding in findings:
        status = str(finding.get("status"))
        statuses[status] = statuses.get(status, 0) + 1
    require(statuses == {"Fixed": len(findings)}, "FINDING_STATUS", str(statuses))
    return {
        "findingCount": len(findings),
        "findingStatuses": statuses,
        "unresolvedHighCritical": 0,
        "reviewPackageSha256": validation.get("packageSha256"),
    }


def validate_public_api(
    root: Path, report: Mapping[str, Any], *, verify_current_sources: bool = True
) -> dict[str, Any]:
    require_pass(report, "M7-032 public API")
    require(report.get("profile") == PROFILE, "API_PROFILE", str(report.get("profile")))
    require(report.get("compatibilityPolicy") == "NOT_EVALUATED_PRE_1_0",
            "API_COMPATIBILITY_POLICY", str(report.get("compatibilityPolicy")))
    require(report.get("internalAliasCount") == 0, "API_INTERNAL_ALIAS", "nonzero internal aliases")
    if verify_current_sources:
        m7_032_public_api_inventory.validate(root)
    return {
        "inventorySha256": strict_digest(report.get("inventorySha256"), "M7-032 inventory"),
        "declarationCount": report.get("declarationCount"),
        "resolvedAliasCount": report.get("resolvedAliasCount"),
        "internalAliasCount": 0,
        "compatibilityPolicy": report["compatibilityPolicy"],
    }


def validate_current_sources(
    root: Path, documents: Mapping[str, Mapping[str, Any]]
) -> dict[str, str]:
    qualification = documents["m7_021"]
    m7_021_linux_release.validate_report(qualification, root)
    current_release_source = m7_021_linux_release.source_tree_sha256(root)
    require(current_release_source == qualification.get("source_tree_sha256"),
            "SOURCE_STALE", "M7-021 production source tree")

    current_fuzz_source = m7_023_linux_fuzz.source_fingerprint(root)
    require(current_fuzz_source == documents["m7_023"].get("source_sha256"),
            "SOURCE_STALE", "M7-023 fuzz source")
    manifest = safe_path(root, "tools/gates/campaigns/m7-023-linux-fuzz.json")
    require(evidence_digest.text_evidence_sha256(manifest) == documents["m7_023"].get("manifest_sha256"),
            "SOURCE_STALE", "M7-023 manifest")
    m7_023_linux_fuzz.load_manifest(root, manifest)

    current_http2_source = m7_024_linux_performance.http2_source_sha256(root)
    expected_http2_source = documents["m7_024_h2"].get("source", {}).get(
        "production_source_sha256"
    )
    require(current_http2_source == expected_http2_source,
            "SOURCE_STALE", "M7-024 HTTP/2 production source")
    require(not architecture_guard.run_guard(root), "ARCHITECTURE_FAIL", "current guard has violations")

    m7_025_linux_supply_chain.validate_documents(
        safe_path(root, "docs/evidence/M7-025/linux_x86_64", must_exist=False),
        artifact_path=safe_path(root, "dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz"),
        qualification_path=safe_path(root, DOCUMENT_PATHS["m7_021"]),
        provider_pin_path=safe_path(root, "native/tls/aws_lc/provider.json"),
        generator_path=safe_path(root, "tools/m7_025_linux_supply_chain.py"),
    )
    return {
        "releaseSourceTreeSha256": current_release_source,
        "fuzzSourceSha256": current_fuzz_source,
        "http2PerformanceSourceSha256": current_http2_source,
    }


def validate_recorded_sources(
    root: Path,
    documents: Mapping[str, Mapping[str, Any]],
) -> dict[str, str]:
    qualification = documents["m7_021"]
    m7_021_linux_release.validate_report(
        qualification,
        root,
        verify_current_sources=False,
    )
    release_source = strict_digest(
        qualification.get("source_tree_sha256"), "M7-021 production source tree"
    )
    fuzz_source = strict_digest(
        documents["m7_023"].get("source_sha256"), "M7-023 fuzz source"
    )
    http2_source = strict_digest(
        documents["m7_024_h2"].get("source", {}).get("production_source_sha256"),
        "M7-024 HTTP/2 production source",
    )
    return {
        "releaseSourceTreeSha256": release_source,
        "fuzzSourceSha256": fuzz_source,
        "http2PerformanceSourceSha256": http2_source,
    }


def validate_criteria(criteria: Sequence[Mapping[str, Any]]) -> dict[str, int]:
    expected_ids = [f"REL-{number:02d}" for number in range(1, 23)]
    actual_ids = [item.get("id") for item in criteria]
    require(actual_ids == expected_ids, "CRITERIA_INVENTORY", str(actual_ids))
    allowed = {"PASS", "FAIL", "NOT_APPLICABLE_TO_LINUX_PROFILE"}
    for item in criteria:
        require(item.get("status") in allowed, "CRITERION_STATUS", str(item.get("id")))
        require(item.get("status") != "FAIL", "CRITERION_FAIL", str(item.get("id")))
        evidence = item.get("evidence")
        require(isinstance(evidence, list) and evidence, "CRITERION_EVIDENCE", str(item.get("id")))
    pass_count = sum(item["status"] == "PASS" for item in criteria)
    not_applicable = sum(
        item["status"] == "NOT_APPLICABLE_TO_LINUX_PROFILE" for item in criteria
    )
    require(pass_count == 21 and not_applicable == 1, "CRITERIA_SUMMARY",
            f"pass={pass_count},not_applicable={not_applicable}")
    require(criteria[2]["status"] == "NOT_APPLICABLE_TO_LINUX_PROFILE",
            "LINUX_SCOPE", "only REL-03 may be not applicable")
    return {"total": 22, "pass": pass_count, "fail": 0, "notApplicable": not_applicable}


def build_evidence_index(root: Path, criteria: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    paths = sorted({path for item in criteria for path in item["evidence"]})
    entries = []
    for relative in paths:
        path = safe_path(root, relative)
        match = re.search(r"docs/evidence/([^/]+)/", relative)
        source_task = match.group(1) if match else "M7-031"
        entries.append({
            "path": relative,
            "sha256": evidence_digest.text_evidence_sha256(path),
            "sourceTask": source_task,
            "acceptanceStatus": (
                "NOT_APPLICABLE_TO_LINUX_PROFILE" if relative in CRITERION_EVIDENCE["REL-03"]
                else "BOUND_INPUT"
            ),
        })
    return entries


def expected_evidence_metadata() -> dict[str, tuple[str, str]]:
    metadata: dict[str, tuple[str, str]] = {}
    for relative in sorted({path for paths in CRITERION_EVIDENCE.values() for path in paths}):
        match = re.search(r"docs/evidence/([^/]+)/", relative)
        source_task = match.group(1) if match else TASK_ID
        acceptance_status = (
            "NOT_APPLICABLE_TO_LINUX_PROFILE"
            if relative in CRITERION_EVIDENCE["REL-03"]
            else "BOUND_INPUT"
        )
        metadata[relative] = (source_task, acceptance_status)
    return metadata


def recorded_candidate(root: Path) -> dict[str, Any]:
    report = load_json(
        safe_path(root, "docs/evidence/M7-031/linux_x86_64/release-candidate.json")
    )
    evidence = report.get("evidenceIndex")
    require(isinstance(evidence, list) and evidence, "EVIDENCE_INDEX", "missing")
    expected = expected_evidence_metadata()
    paths: set[str] = set()
    for item in evidence:
        require(isinstance(item, Mapping), "EVIDENCE_INDEX", "entry must be an object")
        relative = item.get("path")
        safe_path(root, relative, must_exist=False)
        require(relative not in paths, "EVIDENCE_INDEX", f"duplicate {relative}")
        paths.add(relative)
        strict_digest(item.get("sha256"), f"evidence {relative}")
        require(relative in expected, "EVIDENCE_INDEX", f"unexpected {relative}")
        source_task, acceptance_status = expected[relative]
        require(item.get("sourceTask") == source_task, "EVIDENCE_INDEX", str(relative))
        require(
            item.get("acceptanceStatus") == acceptance_status,
            "EVIDENCE_INDEX", str(relative),
        )
    require(paths == set(expected), "EVIDENCE_INDEX", "recorded inventory is incomplete")
    return report


def build_candidate(
    root: Path = ROOT,
    *,
    documents: Mapping[str, Mapping[str, Any]] | None = None,
    verify_current_sources: bool = True,
) -> dict[str, Any]:
    root = root.resolve()
    validate_dependency_status(root)
    values = deepcopy(documents) if documents is not None else load_documents(root)
    recorded = None if verify_current_sources else recorded_candidate(root)

    audit = values["m7_019"]
    require(audit.get("task_id") == "M7-019", "AUDIT_ID", "M7-019")
    release_inventory = audit.get("release_acceptance")
    require(isinstance(release_inventory, list), "CRITERIA_INVENTORY", "M7-019 release acceptance")
    for key in ("m7_020", "m7_021", "m7_022", "m7_023", "m7_024", "m7_025",
                "m7_026", "m7_027", "m7_028", "m7_029", "m7_030", "m7_032",
                "m7_032_consumer"):
        require_pass(values[key], key)
    require(values["m7_023"].get("target_count") == 10, "FUZZ_TARGETS", "expected ten targets")
    require(values["m7_023"].get("crash_artifacts") == [], "FUZZ_CRASH", "current crash artifact")
    require(values["m7_024"].get("failed_domains") == [], "PERFORMANCE_FAIL", "failed domain")
    require(values["m7_024"].get("decision") == "PASS", "PERFORMANCE_FAIL", "aggregate")

    artifact = validate_artifact_identity(
        values, root, verify_local_artifact=verify_current_sources
    )
    recorded_soak_sha = (
        recorded.get("longEvidence", {}).get("soak", {}).get("reportSha256")
        if isinstance(recorded, Mapping) else None
    )
    soak = validate_soak(
        root, values["m7_022"], artifact["sha256"],
        report_sha256=recorded_soak_sha,
    )
    security = validate_security(values["m7_029"], values["m7_029_review"])
    public_api = validate_public_api(
        root, values["m7_032"], verify_current_sources=verify_current_sources
    )
    sources = (
        validate_current_sources(root, values)
        if verify_current_sources
        else validate_recorded_sources(root, values)
    )
    hosted = m7_030_linux_release.validate_hosted_report(
        safe_path(root, DOCUMENT_PATHS["m7_030_hosted"])
    )
    require(hosted.get("commit") == values["m7_030"].get("commit"),
            "HOSTED_COMMIT", "validation and hosted report differ")

    criteria = []
    by_id = {item.get("id"): item for item in release_inventory if isinstance(item, Mapping)}
    for number in range(1, 23):
        criterion_id = f"REL-{number:02d}"
        source = by_id.get(criterion_id)
        require(source is not None, "CRITERIA_INVENTORY", criterion_id)
        status = "NOT_APPLICABLE_TO_LINUX_PROFILE" if criterion_id == "REL-03" else "PASS"
        criteria.append({
            "id": criterion_id,
            "source": source.get("source"),
            "requirement": source.get("requirement"),
            "status": status,
            "evidence": CRITERION_EVIDENCE[criterion_id],
            "note": CRITERION_NOTES[criterion_id],
        })
    summary = validate_criteria(criteria)

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "profile": PROFILE,
        "platform": PROFILE,
        "status": "PASS",
        "decision": "GO_FOR_LINUX_STABLE_RELEASE",
        "acceptance_status": "PASS",
        "artifact": artifact,
        "sourceFreshness": sources,
        "longEvidence": {
            "soak": soak,
            "sseProfile": {
                "reportPath": "docs/evidence/M6-023/linux_x86_64/sse-streaming-profile.json",
                "reportSha256": (
                    strict_digest(
                        recorded.get("longEvidence", {}).get("sseProfile", {}).get("reportSha256"),
                        "recorded SSE profile",
                    )
                    if isinstance(recorded, Mapping)
                    else evidence_digest.text_evidence_sha256(safe_path(
                        root, "docs/evidence/M6-023/linux_x86_64/sse-streaming-profile.json"
                    ))
                ),
                "reusedByDigest": True,
            },
            "rerunByM7031": False,
        },
        "securityReview": security,
        "publicApi": public_api,
        "hostedSigning": {
            "commit": hosted["commit"],
            "workflow": hosted["workflow"],
            "subjects": [
                {"name": item["name"], "sha256": item["sha256"], "verification": item["verification"]}
                for item in hosted["subjects"]
            ],
        },
        "criteria": criteria,
        "criteriaSummary": summary,
        "evidenceIndex": (
            deepcopy(recorded["evidenceIndex"])
            if isinstance(recorded, Mapping)
            else build_evidence_index(root, criteria)
        ),
        "knownLimitations": [
            "This candidate covers Linux x86_64 glibc only. It does not complete the six-platform M7 tasks.",
            "Linux musl is outside the profile because the Cangjie SDK has no supported musl target, standard library, or runtime.",
            "Wirestack reports supportsHalfClose=false on the current public SDK and returns the stable Unsupported result for directional TCP shutdown.",
            "Native socket error codes and the exact operating-system event backend remain optional when the public SDK does not expose them.",
            "The API inventory is pre-1.0 and does not promise compatibility with the historical experimental API.",
            "M7-030 hosted attestations bind the frozen bytes. The staging draft Release is not the public stable Release.",
        ],
        "nonClaims": [
            "No non-Linux platform cell is reported as PASS.",
            "M7-031 does not rerun or shorten the 86,400-second soak or one-hour SSE profile.",
            "The release does not depend on runtime, std, stdx, or SDK source changes.",
        ],
    }
    return report


def atomic_json(
    path: Path,
    value: Mapping[str, Any],
    *,
    replace: Callable[[Path, Path], None] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        (replace or (lambda source, target: source.replace(target)))(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def validate_committed(root: Path, report_path: Path) -> dict[str, Any]:
    expected = build_candidate(root)
    actual = load_json(report_path)
    require(actual == expected, "REPORT_STALE", str(report_path))
    return expected


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.root.resolve()
    report_path = args.report if args.report.is_absolute() else root / args.report
    try:
        report = build_candidate(root)
        if args.write:
            atomic_json(report_path, report)
        report = validate_committed(root, report_path)
    except (CandidateError, m7_021_linux_release.ReleaseError,
            m7_025_linux_supply_chain.SupplyChainError,
            m7_030_linux_release.ReleaseError,
            m7_032_public_api_inventory.PublicApiInventoryError,
            m7_023_linux_fuzz.GateError,
            m7_024_linux_performance.GateError) as error:
        payload = {"taskId": TASK_ID, "status": "FAIL", "error": str(error)}
        print(json.dumps(payload, sort_keys=True) if args.json
              else f"M7-031 candidate: FAIL: {error}")
        return 1
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print(
            "M7-031 candidate: PASS\n"
            f"decision={report['decision']}\n"
            f"artifact_sha256={report['artifact']['sha256']}\n"
            f"criteria={report['criteriaSummary']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
