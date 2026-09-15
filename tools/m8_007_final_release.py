#!/usr/bin/env python3
"""Qualify the M8-007 Linux artifact and its current release evidence."""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import time
from concurrent.futures import ThreadPoolExecutor

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import evidence_digest as digest
from tools import m7_021_linux_release as release
from tools import m7_022_linux_release_soak as soak
from tools import m7_025_linux_supply_chain as supply
from tools import m7_026_linux_api_freeze as api
from tools import m7_028_security_review_package as security
from tools import m7_029_independent_security_review as review
from tools import m7_030_linux_release as signing
from tools import m7_032_public_api_inventory as public_api
from tools import m8_007_signing_authorization as authorization
from tools.gates import m7_023_linux_fuzz as fuzz
from tools.repository import repository_tooling as repository

ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M8-007"
EVIDENCE = ROOT / "docs/evidence/M8-007/linux_x86_64"
ARTIFACT = ROOT / "dist/m8-007" / release.ARTIFACT_NAME
QUALIFICATION = EVIDENCE / "qualification.json"
NATIVE_BUILD = EVIDENCE / "native-rebuild.json"
BASELINE = ROOT / "docs/api/baselines/wirestack-linux-pre1-m8-007.json"
API_REPORT = EVIDENCE / "api-inventory.json"
SUPPLY = EVIDENCE / "supply-chain"
LICENSE_REPORT = EVIDENCE / "licenses.json"
CORE_REPORT = EVIDENCE / "release-core.json"
FUZZ_REPORT = EVIDENCE / "fuzz-report.json"
ARCHIVE_CONTROLS = EVIDENCE.parent / "archive-review-controls.json"
ARCHIVE_CONTROL_DRIVER = "docs/evidence/M8-007/reproductions/archive-review-controls.py.txt"
ARCHIVE_CONTROL_SOURCE = "tools/m7_021_linux_release.py"
ARCHIVE_CONTROL_TESTS = "tools/tests/test_m7_021_linux_release.py"
REVIEW_BASELINE_REVISION = "14a9925dd78ded4f5d99eb8aa70c34f676404f3c"
PYTHON_CONTROL_TIMEOUT_SECONDS = 120
ARCHIVE_CASES = (
    "test_archive_member_limit_accepts_boundary_and_rejects_one_extra_byte",
    "test_archive_rejects_aggregate_payload_over_limit",
    "test_archive_budget_includes_serialized_headers_and_padding",
    "test_archive_rejects_oversized_pax_metadata",
    "test_archive_rejects_excessive_member_headers",
    "test_archive_bounds_cumulative_global_pax_fields",
    "test_archive_rejects_sparse_encodings_before_map_expansion",
)
PYTHON_CONTROL_CASE = re.compile(r"^(test_\w+) \([^\n]+\) \.\.\. (ok|FAIL|ERROR)$", re.MULTILINE)
HOSTED_SOURCE_CONTROLS = EVIDENCE.parent / "hosted-source-controls.json"
HOSTED_SOURCE_DRIVER = "docs/evidence/M8-007/reproductions/hosted-source-controls.py.txt"
HOSTED_SOURCE_CASES = (
    "test_verify_all_rejects_hosted_revision_not_independently_approved",
    "test_verify_all_rejects_unarchived_signing_inputs",
    "test_verify_all_rejects_unarchived_formal_inputs",
    "test_verify_all_rejects_weakened_approved_task",
    "test_verify_all_rejects_removed_approved_source_input",
    "test_frozen_command_rejects_weakened_release_contract",
)
INSTRUMENTATION_BASELINE = "8a6039051dd46e5c42c57f7debbe748ae52c266d"
BUILD_OUTPUT_CONTROLS = EVIDENCE.parent / "build-output-controls.json"
BUILD_OUTPUT_DRIVER = "docs/evidence/M8-007/reproductions/build-output-controls.py.txt"
BUILD_OUTPUT_CASES = (
    "test_successful_build_bounds_report_and_preserves_raw_diagnostics",
    "test_failed_build_bounds_error_and_preserves_raw_diagnostics",
    "test_build_excerpt_byte_bound_survives_invalid_utf8",
)
OWNER_REGISTRY_DRIVER = "docs/evidence/M8-007/reproductions/owner-registry-probe.py.txt"
OWNER_REGISTRY_PROBE = "docs/evidence/M8-007/reproductions/owner-registry-probe.cj.txt"
OWNER_REGISTRY_BEFORE = EVIDENCE.parent / "reproductions/owner-registry-before.json"
OWNER_REGISTRY_AFTER = EVIDENCE.parent / "reproductions/owner-registry-after.json"
RUNTIME_CONTROLS = EVIDENCE.parent / "runtime-review-controls.json"
RUNTIME_CONTROL_DRIVER = "docs/evidence/M8-007/reproductions/runtime-review-controls.py.txt"
OWNER_CONTROLS = EVIDENCE.parent / "soak-owner-controls.json"
OWNER_CONTROL_DRIVER = "docs/evidence/M8-007/reproductions/soak-owner-controls.py.txt"
OWNER_PREFLIGHT = EVIDENCE.parent / "reproductions/bounded-owner-preflight-600s.json"
SOAK_REPORT = EVIDENCE / "soak.json"
SECURITY_INDEX = EVIDENCE / "security-index.json"
SECURITY_PACKAGE = EVIDENCE / "security-package.json"
REVIEW_REQUEST = EVIDENCE / "review-request.json"
REVIEW = EVIDENCE / "independent-review.json"
REVIEW_REPORT = EVIDENCE / "review-validation.json"
WORKFLOW = ".github/workflows/m8-007-linux-release-attestation.yml"
SIGNATURES = EVIDENCE / "signatures"
SCOPE_DOCUMENT = "docs/evidence/M8-007/security-scope.md"
DOCUMENT_INPUTS = tuple(
    (topic, SCOPE_DOCUMENT)
    for topic in sorted(security.REQUIRED_TOPICS - {"fuzz", "sbom"})
)
EVIDENCE_INPUTS = tuple(
    (topic, TASK_ID, path.relative_to(ROOT).as_posix(), "CURRENT_PASS", True)
    for topic, path in (
        ("fuzz", FUZZ_REPORT), ("public-api", API_REPORT),
        ("installation", QUALIFICATION), ("artifact-audit", CORE_REPORT),
        ("licenses", LICENSE_REPORT), ("supply-chain-validation", SUPPLY / "bundle.json"),
        ("runtime-regressions", RUNTIME_CONTROLS),
        ("archive-resource-regressions", ARCHIVE_CONTROLS),
        ("hosted-source-regressions", HOSTED_SOURCE_CONTROLS),
        ("signing-authorization", ROOT / authorization.POLICY_RELATIVE),
        ("soak-owner-regressions", OWNER_CONTROLS),
        ("compiler-output-regressions", BUILD_OUTPUT_CONTROLS),
        ("owner-registry-negative-controls", OWNER_REGISTRY_BEFORE),
        ("owner-registry-corrected-controls", OWNER_REGISTRY_AFTER),
    )
) + tuple(
    (topic, TASK_ID, path.relative_to(ROOT).as_posix(), "CURRENT_BOUND_INPUT", False)
    for topic, path in (
        ("sbom", SUPPLY / "sbom.spdx.json"), ("provider-manifest", SUPPLY / "provider-manifest.json"),
        ("build-fingerprint", SUPPLY / "build-fingerprint.json"),
    )
)
FROZEN_CANDIDATE = EVIDENCE / "frozen-candidate.json"
SOAK_COMMAND = EVIDENCE / "soak-command.json"
INPUTS = (
    "tools/m8_007_final_release.py",
    "tools/tests/test_m8_007_final_release.py",
    ARCHIVE_CONTROL_DRIVER,
    HOSTED_SOURCE_DRIVER,
    ARCHIVE_CONTROL_SOURCE,
    ARCHIVE_CONTROL_TESTS,
    RUNTIME_CONTROL_DRIVER,
    OWNER_CONTROL_DRIVER,
    BUILD_OUTPUT_DRIVER,
    OWNER_REGISTRY_DRIVER,
    OWNER_REGISTRY_PROBE,
    "tools/tests/test_m7_022_linux_release_soak.py",
    "tools/m8_007_signing_authorization.py",
    "tools/tests/test_m8_007_signing_authorization.py",
    "tools/m7_022_linux_release_soak.py",
    "tools/m7_025_linux_supply_chain.py",
    "tools/m7_026_linux_api_freeze.py",
    "tools/m7_028_security_review_package.py",
    "tools/m7_029_independent_security_review.py",
    "tools/m7_030_linux_release.py",
    "tools/m7_032_public_api_inventory.py",
    "tools/release_soak/main.cj",
    "tools/evidence_digest.py",
    "tools/gates/m7_023_linux_fuzz.py",
    "tools/gates/campaigns/m7-023-linux-fuzz.json",
    "tools/repository/repository_tooling.py",
    WORKFLOW,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise release.ReleaseError(message)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(release.canonical_json(value))


def record(path: Path) -> dict:
    path = path.resolve()
    relative = path.relative_to(ROOT).as_posix()
    return {"path": relative, "digest": digest.text_evidence_digest(path).to_json()}


def source_inputs() -> dict:
    return {relative: digest.text_evidence_digest(ROOT / relative).to_json() for relative in INPUTS}


def validate_native(payload: dict[str, bytes]) -> dict:
    native = release.load_json(NATIVE_BUILD)
    require(native.get("source_task") == TASK_ID and native.get("status") == "PASS", "fresh native build is missing")
    for field in ("driver", "raw_log"):
        reference = native[field]
        require(record(ROOT / reference["path"]) == reference, f"native {field} changed")
    expected_inputs = {
        relative for relative in release.QUALIFICATION_INPUTS
        if relative.startswith(("native/", "tools/build_", "tools/tls_provider/"))
    }
    require(expected_inputs <= set(native["source_inputs"]), "native source inventory is incomplete")
    for relative in expected_inputs:
        require(digest.text_evidence_digest(ROOT / relative).to_json() == native["source_inputs"][relative], f"native source changed: {relative}")
    expected_members = {
        "target/native/current/lib/libwirestack_tls_provider.a",
        "target/native/current/provider-manifest.json",
        "target/native/resolver/current/lib/libwirestack_resolver.a",
        "target/native/resolver/current/resolver-manifest.json",
        "target/native/http_files/current/lib/libwirestack_http_files.a",
        "target/native/http_files/current/http-files-manifest.json",
    }
    require(set(native["artifact_members"]) == expected_members, "native output inventory is incomplete")
    for member, expected in native["artifact_members"].items():
        value = payload[member]
        require(expected == {"bytes": len(value), "digest": digest.artifact_byte_digest_bytes(value).to_json()}, f"fresh native output differs: {member}")
    return native


def created_utc(native: dict) -> str:
    return dt.datetime.fromisoformat(native["generated_at_utc"]).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def license_report(payload: dict[str, bytes]) -> dict:
    members = (*supply.LICENSE_MEMBERS, release.PUBLIC_SUFFIX_FILES[0])
    entries = {}
    for member in members:
        value = payload.get(member)
        require(bool(value), f"missing license deliverable: {member}")
        require(value == (ROOT / member).read_bytes(), f"license deliverable differs from source: {member}")
        entries[member] = {"bytes": len(value), "digest": digest.artifact_byte_digest_bytes(value).to_json()}
    return {
        "schema_version": 1, "source_task": TASK_ID, "decision": "PASS",
        "artifact_digest": digest.artifact_byte_digest(ARTIFACT).to_json(),
        "artifact_members": entries,
        "non_claims": ["Presence and exact-byte checks are not a legal opinion."]
    }


def prepare() -> dict:
    _, _, qualification = release.qualify(ROOT, ARTIFACT.parent, offline=True)
    payload, _ = release.read_verified_payload(ARTIFACT)
    native = validate_native(payload)
    qualification["source_task"] = TASK_ID
    qualification["final_release_inputs"] = source_inputs()
    qualification["native_rebuild"] = record(NATIVE_BUILD)
    write_json(QUALIFICATION, qualification)
    api.write_json(BASELINE, api.build_inventory(ROOT, task_id=TASK_ID))
    api.write_json(API_REPORT, api.validate(ROOT, BASELINE, API_REPORT, validate_report=False, task_id=TASK_ID))
    documents = supply.build_documents(
        ARTIFACT, qualification, supply.load_json(supply.PROVIDER_PIN),
        generator_sha256=digest.text_evidence_sha256(Path(supply.__file__)),
        task_id=TASK_ID, created_utc=created_utc(native),
    )
    supply.write_documents(documents, SUPPLY)
    write_json(LICENSE_REPORT, license_report(payload))
    result = verify_core(check_report=False)
    write_json(CORE_REPORT, result)
    return result


def verify_api() -> dict:
    public_api.build_inventory(ROOT)
    return api.validate(ROOT, BASELINE, API_REPORT, task_id=TASK_ID)


def verify_core(*, check_report: bool = True) -> dict:
    qualification = release.load_json(QUALIFICATION)
    release.validate_report(qualification, ROOT)
    require(qualification.get("source_task") == TASK_ID, "historical qualification cannot qualify M8-007")
    require(qualification.get("final_release_inputs") == source_inputs(), "final qualification tooling changed")
    require(qualification.get("native_rebuild") == record(NATIVE_BUILD), "native build evidence changed")
    require(digest.schema_artifact_sha256_equal(digest.artifact_byte_sha256(ARTIFACT), qualification["artifact"]["sha256"]), "qualified artifact changed")
    payload, manifest = release.read_verified_payload(ARTIFACT)
    native = validate_native(payload)
    verify_api()
    supply.validate_documents(SUPPLY, artifact_path=ARTIFACT, qualification_path=QUALIFICATION, task_id=TASK_ID, created_utc=created_utc(native))
    require(release.load_json(LICENSE_REPORT) == license_report(payload), "license evidence changed")
    result = {
        "schema_version": 1, "source_task": TASK_ID, "status": "PASS", "decision": "PASS",
        "scope": ["fresh-native-artifact", "clean-installed-consumer", "public-api-inventory", "sbom", "license-deliverables"],
        "artifact": {"name": ARTIFACT.name, "bytes": ARTIFACT.stat().st_size, "digest": digest.artifact_byte_digest(ARTIFACT).to_json()},
        "payload_files": len(payload), "release_schema_version": manifest["schema_version"],
        "evidence": [record(path) for path in (QUALIFICATION, NATIVE_BUILD, BASELINE, API_REPORT, LICENSE_REPORT, SUPPLY / "bundle.json")],
        "non_claims": ["The 86400-second soak, independent security review, and production signatures are separate required gates."]
    }
    if check_report:
        require(release.load_json(CORE_REPORT) == result, "core release evidence changed")
    return result


def download_artifact() -> dict:
    expected = release.load_json(QUALIFICATION)["artifact"]
    if ARTIFACT.is_file():
        require(ARTIFACT.stat().st_size == expected["bytes"] and
                digest.schema_artifact_sha256_equal(digest.artifact_byte_sha256(ARTIFACT), expected["sha256"]),
                "existing artifact differs from frozen qualification")
        return {"source_task": TASK_ID, "decision": "PASS", "mode": "verified-existing-artifact"}
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".m8-007-download-", dir=ARTIFACT.parent) as temporary:
        directory = Path(temporary)
        command = [
            "gh", "release", "download", f"m8-007-frozen-artifact-{expected['sha256'][:8]}",
            "--repo", signing.REPOSITORY, "--pattern", ARTIFACT.name, "--dir", str(directory),
        ]
        completed = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
        require(completed.returncode == 0, f"frozen artifact download failed: {completed.stderr}")
        downloaded = directory / ARTIFACT.name
        require(downloaded.stat().st_size == expected["bytes"] and
                digest.schema_artifact_sha256_equal(digest.artifact_byte_sha256(downloaded), expected["sha256"]),
                "downloaded artifact differs from frozen qualification")
        downloaded.replace(ARTIFACT)
    return {"source_task": TASK_ID, "decision": "PASS", "mode": "downloaded-and-verified-artifact"}


def fuzz_inputs() -> dict:
    return {
        "qualification": record(QUALIFICATION),
        "sources": digest.text_evidence_inventory_sha256(ROOT, sorted((ROOT / "src").rglob("*.cj"))),
        "native_build": record(NATIVE_BUILD),
    }


def verify_native_cache() -> None:
    for member, expected in release.load_json(NATIVE_BUILD)["artifact_members"].items():
        path = ROOT / member
        require(path.stat().st_size == expected["bytes"] and
                digest.artifact_byte_digest(path).to_json() == expected["digest"],
                f"fuzz native cache differs from qualified artifact: {member}")


def run_fuzz() -> dict:
    verify_core()
    verify_native_cache()
    before = fuzz_inputs()
    exit_code = fuzz.main(["--output", str(FUZZ_REPORT)])
    require(exit_code == 0, "current fuzz campaign failed")
    require(before == fuzz_inputs(), "fuzz execution inputs changed")
    verify_native_cache()
    result = release.load_json(FUZZ_REPORT)
    result["status"] = result["decision"]
    result["source_task"] = TASK_ID
    result["final_release_inputs"] = before
    write_json(FUZZ_REPORT, result)
    return verify_fuzz()


def verify_fuzz() -> dict:
    result = release.load_json(FUZZ_REPORT)
    require(result.get("source_task") == TASK_ID and result.get("decision") == "PASS", "current fuzz evidence is absent")
    require(result.get("final_release_inputs") == fuzz_inputs(), "fuzz qualification inputs changed")
    manifest, targets = fuzz.load_manifest(ROOT, ROOT / "tools/gates/campaigns/m7-023-linux-fuzz.json")
    require(result["manifest"] == "tools/gates/campaigns/m7-023-linux-fuzz.json" and
            digest.schema_text_sha256_equal(result["manifest_sha256"], digest.text_evidence_sha256(ROOT / result["manifest"])), "fuzz manifest changed")
    require(digest.schema_text_sha256_equal(result["source_sha256"], fuzz.source_fingerprint(ROOT)), "fuzz parser sources changed")
    require(result["gate_id"] == manifest["gate_id"] and result["profile"] == manifest["profile"] and
            result["corpus_version"] == manifest["corpus_version"], "fuzz campaign identity changed")
    require(result["mode"] == "campaign" and len(result["targets"]) == len(targets), "fuzz campaign is incomplete")
    require(result["build"]["exit_code"] == 0 and not result["build"]["timed_out"], "fuzz build failed")
    for expected, actual in zip(targets, result["targets"]):
        decision, reasons, marker = fuzz.classify(expected, manifest["seed"], actual["process"])
        require(decision == "PASS" and actual["decision"] == decision and actual["marker"] == marker and not reasons, f"fuzz target failed: {expected['name']}")
    return {"source_task": TASK_ID, "decision": "PASS", "targets": len(targets), "evidence": record(FUZZ_REPORT)}


def _control_logs(command: dict, family: str) -> tuple[dict[str, str], list[dict]]:
    output, files = {}, []
    directory = (EVIDENCE.parent / "commands" / family).resolve()
    for stream in ("stdout", "stderr"):
        path = (ROOT / command[f"{stream}_path"]).resolve()
        require(path.is_relative_to(directory), "control log escaped its capture directory")
        captured = record(path)
        require(digest.text_evidence_sha256_equal(captured["digest"], command[f"{stream}_digest"]), f"control log changed: {path}")
        files.append(captured)
        output[stream] = path.read_text()
    return output, files


def verify_archive_controls() -> dict:
    report = release.load_json(ARCHIVE_CONTROLS)
    require(
        report.get("schema_version") == 1
        and report.get("source_task") == TASK_ID
        and report.get("status") == "PASS",
        "archive review controls did not pass",
    )
    require(report.get("driver") == record(ROOT / ARCHIVE_CONTROL_DRIVER),
            "archive control driver changed")
    require(report.get("baseline_revision") == REVIEW_BASELINE_REVISION,
            "archive controls use a different baseline")
    baseline_source = {
        "path": ARCHIVE_CONTROL_SOURCE,
        "digest": repository._source_digest_at_commit(
            ROOT, REVIEW_BASELINE_REVISION, ARCHIVE_CONTROL_SOURCE
        ).to_json(),
    }
    require(report.get("baseline_source") == baseline_source,
            "archive baseline source does not match the preserved candidate blob")
    expected_sources = {
        relative: record(ROOT / relative)
        for relative in (ARCHIVE_CONTROL_SOURCE, ARCHIVE_CONTROL_TESTS)
    }
    require(report.get("source_records") == expected_sources,
            "archive control source inventory changed")
    require(report.get("expected_cases") == list(ARCHIVE_CASES),
            "archive control case inventory changed")
    argv = ["python3", "-m", "unittest", "-v", *(
        f"tools.tests.test_m7_021_linux_release.M7021LinuxReleaseTest.{case}"
        for case in ARCHIVE_CASES
    )]
    files = [
        record(ARCHIVE_CONTROLS),
        record(ROOT / ARCHIVE_CONTROL_DRIVER),
        *expected_sources.values(),
    ]
    for phase, case_status, exit_code in (("before", "FAIL", 1), ("after", "ok", 0)):
        command = report[phase]
        duration = command.get("duration_ms")
        require(
            command.get("id") == f"{phase}-archive"
            and command.get("status") == ("FAIL" if phase == "before" else "PASS")
            and command.get("argv") == argv
            and command.get("exit_code") == exit_code
            and command.get("timed_out") is False
            and type(duration) in (int, float)
            and 0 <= duration <= PYTHON_CONTROL_TIMEOUT_SECONDS * 1000,
            f"archive {phase} command changed",
        )
        output, captured = _control_logs(command, "archive-review-controls")
        matches = PYTHON_CONTROL_CASE.findall(output["stdout"] + output["stderr"])
        observed = dict(matches)
        expected = {case: case_status for case in ARCHIVE_CASES}
        require(len(matches) == len(ARCHIVE_CASES) and observed == expected,
                f"archive {phase} raw cases changed")
        require(command.get("observed_cases") == observed,
                f"archive {phase} reported cases differ from raw logs")
        files.extend(captured)
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def verify_hosted_source_controls() -> dict:
    report = release.load_json(HOSTED_SOURCE_CONTROLS)
    require(report.get("schema_version") == 1 and report.get("source_task") == TASK_ID
            and report.get("status") == "PASS", "hosted source controls did not pass")
    require(report.get("driver") == record(ROOT / HOSTED_SOURCE_DRIVER), "hosted source driver changed")
    require(report.get("baseline_revision") == REVIEW_BASELINE_REVISION, "hosted source baseline changed")
    production = "tools/m8_007_final_release.py"
    baseline = {
        "path": production,
        "digest": repository._source_digest_at_commit(ROOT, REVIEW_BASELINE_REVISION, production).to_json(),
    }
    require(report.get("baseline_source") == baseline, "hosted source baseline blob changed")
    sources = {path: record(ROOT / path) for path in (production, "tools/tests/test_m8_007_final_release.py")}
    require(report.get("source_records") == sources, "hosted source control inputs changed")
    require(report.get("expected_cases") == list(HOSTED_SOURCE_CASES), "hosted source case inventory changed")
    files = [record(HOSTED_SOURCE_CONTROLS), record(ROOT / HOSTED_SOURCE_DRIVER), *sources.values()]
    for phase, status, exit_code in (("before", "FAIL", 1), ("after", "ok", 0)):
        command = report[phase]
        argv = ["python3", HOSTED_SOURCE_DRIVER, "--baseline", REVIEW_BASELINE_REVISION, "--phase", phase]
        duration = command.get("duration_ms")
        require(command.get("id") == f"{phase}-hosted-source" and command.get("argv") == argv
                and command.get("status") == ("FAIL" if phase == "before" else "PASS")
                and command.get("exit_code") == exit_code and command.get("timed_out") is False
                and type(duration) in (int, float) and 0 <= duration <= PYTHON_CONTROL_TIMEOUT_SECONDS * 1000,
                f"hosted source {phase} command changed")
        output, captured = _control_logs(command, "hosted-source-controls")
        cases = PYTHON_CONTROL_CASE.findall(output["stdout"] + output["stderr"])
        require(cases == [(case, status) for case in HOSTED_SOURCE_CASES] and command.get("observed_cases") == dict(cases),
                f"hosted source {phase} raw outcome changed")
        files.extend(captured)
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def verify_build_output_controls() -> dict:
    report = release.load_json(BUILD_OUTPUT_CONTROLS)
    require(report.get("source_task") == TASK_ID and report.get("status") == "PASS",
            "compiler output controls did not pass")
    require(report.get("baseline_revision") == INSTRUMENTATION_BASELINE, "compiler output baseline changed")
    require(report.get("driver") == record(ROOT / BUILD_OUTPUT_DRIVER), "compiler output driver changed")
    source = "tools/m7_022_linux_release_soak.py"
    tests = "tools/tests/test_m7_022_linux_release_soak.py"
    require(report.get("baseline_source_digest") == repository._source_digest_at_commit(
        ROOT, INSTRUMENTATION_BASELINE, source
    ).to_json(), "compiler output baseline blob changed")
    inputs = {path: record(ROOT / path)["digest"] for path in (source, tests)}
    require(report.get("source_inputs") == inputs and report.get("cases") == list(BUILD_OUTPUT_CASES),
            "compiler output control inputs changed")
    files = [record(BUILD_OUTPUT_CONTROLS), record(ROOT / BUILD_OUTPUT_DRIVER),
             record(ROOT / source), record(ROOT / tests)]
    for phase, status, exit_code in (("before", "FAIL", 1), ("after", "ok", 0)):
        command = report[phase]
        argv = (["python3", BUILD_OUTPUT_DRIVER, "--baseline", INSTRUMENTATION_BASELINE, "--phase", "before"]
                if phase == "before" else ["python3", "-m", "unittest", "-v", *(
                    f"tools.tests.test_m7_022_linux_release_soak.M7022LinuxReleaseSoakTest.{case}"
                    for case in BUILD_OUTPUT_CASES
                )])
        duration = command.get("duration_ms")
        require(command.get("id") == phase and command.get("argv") == argv
                and command.get("exit_code") == exit_code and command.get("timed_out") is False
                and command.get("status") == ("FAIL" if phase == "before" else "PASS")
                and type(duration) in (int, float) and 0 <= duration <= PYTHON_CONTROL_TIMEOUT_SECONDS * 1000,
                f"compiler output {phase} command changed")
        output, captured = _control_logs(command, "build-output-controls")
        require(PYTHON_CONTROL_CASE.findall(output["stdout"] + output["stderr"])
                == [(case, status) for case in BUILD_OUTPUT_CASES],
                f"compiler output {phase} raw cases changed")
        files.extend(captured)
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def owner_registry_probe_source(source: str) -> str:
    entry = "main(args: Array<String>): Int64 {"
    owner = "private class SoakControlledResponseOwner {"
    require(source.count(entry) == 1 and source.count(owner) == 1, "owner probe source shape changed")
    source = source.replace(entry, "private func originalSoakMain(args: Array<String>): Int64 {", 1)
    source = source.replace(owner, owner + "\n    func observedProbeSlots(): Int64 { synchronized(mutex) { cancellationProbes.size } }\n", 1)
    return source + "\n" + (ROOT / OWNER_REGISTRY_PROBE).read_text()


def verify_owner_registry_controls() -> dict:
    source = "tools/release_soak/main.cj"
    baseline = subprocess.check_output(
        ["git", "cat-file", "blob", f"{INSTRUMENTATION_BASELINE}:{source}"], cwd=ROOT, timeout=10
    ).decode("utf-8")
    files = [record(ROOT / source), record(ROOT / OWNER_REGISTRY_DRIVER), record(ROOT / OWNER_REGISTRY_PROBE)]
    directory = (EVIDENCE.parent / "commands/owner-registry-controls").resolve()
    for phase, path in (("before", OWNER_REGISTRY_BEFORE), ("after", OWNER_REGISTRY_AFTER)):
        report = release.load_json(path)
        require(report.get("source_task") == TASK_ID and report.get("status") == "PASS"
                and report.get("phase") == phase and report.get("baseline_revision") == INSTRUMENTATION_BASELINE,
                f"owner registry {phase} control did not pass")
        require(report.get("driver") == record(ROOT / OWNER_REGISTRY_DRIVER)
                and report.get("probe") == record(ROOT / OWNER_REGISTRY_PROBE),
                "owner registry reproduction changed")
        original = baseline if phase == "before" else (ROOT / source).read_text()
        require(report.get("source_digest") == digest.text_evidence_digest_bytes(original.encode("utf-8")).to_json(),
                f"owner registry {phase} source changed")
        require(digest.schema_artifact_sha256_equal(report.get("artifact_sha256"), digest.artifact_byte_digest(ARTIFACT).sha256),
                "owner registry artifact changed")
        derived = (ROOT / report["derived_source"]["path"]).resolve()
        require(derived.is_relative_to(directory) and report["derived_source"] == record(derived)
                and derived.read_text() == owner_registry_probe_source(original), "owner registry derived consumer changed")
        files.extend((record(path), record(derived)))
        commands = report["commands"]
        require(set(commands) == {"build", "stale", "live", "transports"}, "owner registry command inventory changed")
        prefix = commands["build"]["argv"][:3]
        require(len(prefix) == 3 and Path(prefix[0]).name == "codex_cangjie_env"
                and prefix[1] == "--sdk-root" and Path(prefix[2]).parts[-2:] == ("cangjie_sdk", "daily"),
                "owner registry SDK invocation changed")
        for mode, command in commands.items():
            argv, duration = command.get("argv"), command.get("duration_ms")
            expected_exit = 0 if mode == "build" or phase == "after" else 1
            require(isinstance(argv, list) and len(argv) == 5 and argv[:3] == prefix
                    and command.get("exit_code") == expected_exit
                    and type(duration) in (int, float) and 0 <= duration <= 600_000,
                    f"owner registry {phase}/{mode} command changed")
            require(argv[3:] == ["cjpm", "build"] if mode == "build" else
                    argv[4] == mode and Path(argv[3]).parts[-5:] == ("consumer", "target", "release", "bin", "main"),
                    "owner registry executable changed")
            capture = {f"{stream}_{field}": command[stream][field]
                       for stream in ("stdout", "stderr") for field in ("path", "digest")}
            output, captured = _control_logs(capture, "owner-registry-controls")
            files.extend(captured)
            if mode == "build":
                continue
            lines = [line for line in output["stdout"].splitlines() if line.startswith(f"OWNER_PROBE mode={mode} ")]
            require(len(lines) == 1, "owner registry observation is absent or duplicated")
            observed = dict(token.split("=", 1) for token in lines[0].split()[1:])
            require(report["observations"].get(mode) == observed, "owner registry report differs from its raw observation")
            if mode == "stale":
                peak = int(observed["peakSlots"])
                require(observed["claims"] == "4096" and observed["limit"] == "1024"
                        and (peak > 1024 if phase == "before" else 0 <= peak <= 1024),
                        "owner registry capacity control changed")
            else:
                held = "sentinels" if mode == "live" else "held"
                retained = int(observed["retained"])
                require(observed[held] == "1024" and observed["rejected"] == ("false" if phase == "before" else "true")
                        and (retained >= 1024 if phase == "before" else retained == 1024),
                        "owner registry live-owner control changed")
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def verify_runtime_controls() -> dict:
    report = release.load_json(RUNTIME_CONTROLS)
    require(report.get("source_task") == TASK_ID and report.get("status") == "PASS", "runtime review controls did not pass")
    require(report.get("driver") == record(ROOT / RUNTIME_CONTROL_DRIVER), "runtime control driver changed")
    require(digest.schema_text_sha256_equal(report["fixed_source_sha256"], release.source_tree_sha256(ROOT)), "runtime regression sources changed")
    expected_sources = {
        "src/internal/http1/server_reader.cj", "src/internal/http1/server_reader_test.cj",
        "src/internal/http1/client_connection.cj", "src/internal/http1/tls_client_pipeline_test.cj",
        "src/internal/http1/http2_connection_pool.cj", "src/internal/http1/http2_connection_pool_test.cj",
        "src/internal/tls_engine/connection.cj", "src/internal/tls_engine/connection_test.cj",
        "src/internal/tls_engine/engine.cj",
        "src/net/m8_007_tls_cleanup_test.cj",
    }
    require(set(report["source_inputs"]) == expected_sources, "runtime control source inventory changed")
    for relative, expected in report["source_inputs"].items():
        require(digest.text_evidence_sha256_equal(record(ROOT / relative)["digest"], expected), f"runtime test input changed: {relative}")
    expected_failures = {
        "http1": {
            "rejectsOversizedFixedRequestBeforeReadingItsBody",
            "zeroLengthConnectionCloseDoesNotWaitForTlsPeerShutdown",
            "closeRacingUnpublishedAdmissionReleasesConnectionOwners",
        },
        "tls": {
            "closeDeadlineExpiresWhileAnExistingBackgroundReadOwnsPumpAdmission",
            "closeCancellationInterruptsAnExistingBackgroundReadWithinTheBound",
            "closeCancellationDoesNotWaitBehindAnExistingCiphertextWrite",
            "expiredCloseBudgetStillClosesTransportAndReleasesEngine",
            "cancelledCloseReleasesEngineWhenImmediateAbortCallbackThrows",
            "peerWaitingGracefulCloseStaysBoundedByTheCallerBudget",
        },
        "native": {"closeDeadlineReleasesAnExistingNativeTcpReadWithoutPeerAssistance"},
    }
    files = [record(RUNTIME_CONTROLS), record(ROOT / RUNTIME_CONTROL_DRIVER)]
    native_baseline = "c0f13f575eae4ebce07a5ff17add0758f8fca561"
    require(report.get("native_baseline_commit") == native_baseline, "native cleanup baseline changed")
    native_source = subprocess.check_output(
        ["git", "cat-file", "blob", f"{native_baseline}:src/internal/tls_engine/connection.cj"],
        cwd=ROOT, timeout=10,
    )
    native_snapshot = (ROOT / report["native_baseline_source"]["path"]).resolve()
    require(native_snapshot.is_relative_to((EVIDENCE.parent / "commands/runtime-review-controls").resolve())
            and report["native_baseline_source"] == record(native_snapshot)
            and native_snapshot.read_bytes() == native_source, "native cleanup baseline source changed")
    files.append(record(native_snapshot))
    for phase in ("before", "after"):
        require(set(report[phase]) == set(expected_failures), f"runtime {phase} suite inventory changed")
        for name, expected in expected_failures.items():
            command = report[phase][name]
            package = {"http1": "src/internal/http1", "tls": "src/internal/tls_engine", "native": "src/net"}[name]
            argv = ["cjpm", "test", package, "--exclude-tags=Performance",
                    "--parallel", "1", "--no-progress", "--no-color"]
            require(command["argv"] == argv and not command["timed_out"], f"runtime {phase} command changed: {name}")
            require(command["exit_code"] == (1 if phase == "before" else 0), f"runtime {phase} command failed: {name}")
            output, captured = _control_logs(command, "runtime-review-controls")
            files.extend(captured)
            cases = {case: status for status, case in re.findall(r"^\s*\[\s*(\w+)\s*\]\s+CASE:\s+(\w+)", output["stdout"] + output["stderr"], re.MULTILINE)}
            failures = {case for case, status in cases.items() if status not in {"PASSED", "SKIPPED"}}
            if phase == "before":
                require(failures == expected, f"runtime baseline did not reproduce the exact findings: {name}")
            else:
                required = expected | ({"cancelledCloseReleasesEngineWhenImmediateAbortCallbackThrows"} if name == "tls" else set())
                require(not failures and all(cases.get(case) == "PASSED" for case in required), f"runtime correction did not pass: {name}")
    registration_report = EVIDENCE.parent / "reproductions/tls-close-registration-before.json"
    registration_snapshot = EVIDENCE.parent / "reproductions/tls-close-registration-before.cj.txt"
    registration = release.load_json(registration_report)
    registration_case = "cancelledCloseReleasesEngineWhenImmediateAbortCallbackThrows"
    require(registration.get("status") == "FAIL" and registration.get("failure_case") == registration_case,
            "TLS registration negative control changed")
    require(registration.get("production_snapshot_path") == registration_snapshot.relative_to(ROOT).as_posix(),
            "TLS registration negative source snapshot changed")
    command = registration["command"]
    require(command["argv"] == ["cjpm", "test", "src/internal/tls_engine", "--exclude-tags=Performance",
                               "--parallel", "1", "--no-progress", "--no-color"]
            and command["exit_code"] == 1 and not command["timed_out"],
            "TLS registration negative command changed")
    output, captured = _control_logs(command, "")
    cases = {case: status for status, case in re.findall(r"^\s*\[\s*(\w+)\s*\]\s+CASE:\s+(\w+)", output["stdout"] + output["stderr"], re.MULTILINE)}
    require({case for case, status in cases.items() if status not in {"PASSED", "SKIPPED"}} == {registration_case},
            "TLS registration negative control did not reproduce the exact failure")
    files.extend([record(registration_report), record(registration_snapshot), *captured])
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def verify_owner_controls() -> dict:
    report = release.load_json(OWNER_CONTROLS)
    require(report.get("source_task") == TASK_ID and report.get("status") == "PASS", "soak owner controls did not pass")
    require(report["driver"] == record(ROOT / OWNER_CONTROL_DRIVER), "soak owner control driver changed")
    require(report["historical_log"] == record(EVIDENCE.parent / "reproductions/soak-preflight.log"), "historical owner log changed")
    require(report["baseline_revision"] == release.load_json(RUNTIME_CONTROLS)["baseline_commit"], "owner controls use a different baseline")
    expected_sources = {
        "tools/m7_022_linux_release_soak.py", "tools/release_soak/main.cj",
        "tools/tests/test_m7_022_linux_release_soak.py",
    }
    require(set(report["source_inputs"]) == expected_sources, "owner control source inventory changed")
    for relative, expected in report["source_inputs"].items():
        require(digest.text_evidence_sha256_equal(record(ROOT / relative)["digest"], expected), f"owner control input changed: {relative}")
    files = [record(OWNER_CONTROLS), report["driver"], report["historical_log"]]
    live = release.load_json(OWNER_PREFLIGHT)
    require(report["runtime_preflight"] == record(OWNER_PREFLIGHT), "owner controls reference a different live preflight")
    require(live["source_task"] == TASK_ID and live["preflight_status"] == "PASS", "measured-owner preflight did not pass")
    require(live["process"]["exit_code"] == 0 and not live["process"]["timed_out"], "measured-owner process did not complete")
    duration = live["parameters"]["duration_seconds"]
    require(60 <= duration < soak.FORMAL_SECONDS, "owner preflight duration is not a separate short run")
    require(digest.artifact_byte_sha256_equal(live["artifact"]["digest"], digest.artifact_byte_digest(ARTIFACT).to_json()), "owner preflight used different artifact bytes")
    for name, path in (("consumer", soak.SOURCE), ("fixture", soak.FIXTURE), ("driver", soak.DRIVER)):
        require(digest.text_evidence_sha256_equal(live["source"][f"{name}_digest"], record(path)["digest"]), f"owner preflight {name} changed")
    raw_path = OWNER_PREFLIGHT.with_suffix(".log")
    raw = record(raw_path)
    require(live["raw_log"]["path"] == raw["path"] and digest.text_evidence_sha256_equal(live["raw_log"]["digest"], raw["digest"]), "owner preflight raw log changed")
    samples, terminal = soak.parse_output(raw_path.read_text())
    require(all(soak.validate_workload(terminal, duration, live["process"]["wall_elapsed_ms"]).values()), "owner preflight workload failed")
    require(soak.application_trend(samples, minimum_samples=5)["decision"] == "PASS", "owner preflight application trend failed")
    require(soak.resource_trend(live["resources"]["process_tree"]["samples"], minimum_samples=5)["decision"] == "PASS", "owner preflight process trend failed")
    files.extend((record(OWNER_PREFLIGHT), raw))
    for phase in ("before", "after"):
        command = report[phase]
        argv = (
            ["python3", OWNER_CONTROL_DRIVER, "--baseline", report["baseline_revision"], "--phase", "before"]
            if phase == "before" else
            ["python3", "-m", "unittest", "-v", "tools.tests.test_m7_022_linux_release_soak"]
        )
        require(command["argv"] == argv and not command["timed_out"], f"owner {phase} command changed")
        require(command["exit_code"] == (1 if phase == "before" else 0), f"owner {phase} control failed")
        output, captured = _control_logs(command, "soak-owner-controls")
        files.extend(captured)
        if phase == "before":
            observed = json.loads(output["stdout"])
            require(observed["old_literal_log_accepted"] is True and observed["tests_run"] == 1 and observed["failures"] == 1 and observed["errors"] == 0, "baseline did not reproduce literal owner acceptance")
            require(digest.text_evidence_sha256_equal(observed["baseline_source_digest"], report["baseline_source_digest"]), "owner baseline digest changed")
        else:
            require(re.search(r"^test_old_literal_owner_evidence_schema_is_rejected .* \.\.\. ok$", output["stderr"], re.MULTILINE) is not None, "corrected literal-owner regression was not exercised")
    return {"source_task": TASK_ID, "status": "PASS", "files": files}


def prepare_security() -> dict:
    verify_core()
    verify_fuzz()
    verify_runtime_controls()
    verify_owner_controls()
    verify_archive_controls()
    verify_hosted_source_controls()
    verify_build_output_controls()
    verify_owner_registry_controls()
    authorization.verify_policy(ROOT)
    index = security.build_index(ROOT, task_id=TASK_ID, document_inputs=DOCUMENT_INPUTS, evidence_inputs=EVIDENCE_INPUTS)
    write_json(SECURITY_INDEX, index)
    package = security.validate(ROOT, SECURITY_INDEX, task_id=TASK_ID, document_inputs=DOCUMENT_INPUTS, evidence_inputs=EVIDENCE_INPUTS)
    write_json(SECURITY_PACKAGE, package)
    request = review.build_request(
        ROOT, task_id=TASK_ID, package_path=SECURITY_INDEX.relative_to(ROOT).as_posix(),
        report_path=REVIEW.relative_to(ROOT).as_posix(),
    )
    write_json(REVIEW_REQUEST, request)
    return package


def verify_review() -> dict:
    verify_core()
    verify_fuzz()
    verify_runtime_controls()
    verify_owner_controls()
    verify_archive_controls()
    verify_hosted_source_controls()
    verify_build_output_controls()
    verify_owner_registry_controls()
    authorization.verify_policy(ROOT)
    security.validate(ROOT, SECURITY_INDEX, SECURITY_PACKAGE, task_id=TASK_ID, document_inputs=DOCUMENT_INPUTS, evidence_inputs=EVIDENCE_INPUTS)
    return review.validate(ROOT, REVIEW_REQUEST, REVIEW, task_id=TASK_ID, package_path=SECURITY_INDEX.relative_to(ROOT).as_posix())


def frozen_source_paths() -> list[str]:
    paths = set(INPUTS) | set(release.QUALIFICATION_INPUTS)
    paths.update(path.relative_to(ROOT).as_posix() for path in (ROOT / "src").rglob("*.cj"))
    paths.update(item["path"] for item in verify_runtime_controls()["files"])
    paths.update(item["path"] for item in verify_owner_controls()["files"])
    paths.update(item["path"] for item in verify_archive_controls()["files"])
    paths.update(item["path"] for item in verify_hosted_source_controls()["files"])
    paths.update(item["path"] for item in verify_build_output_controls()["files"])
    paths.update(item["path"] for item in verify_owner_registry_controls()["files"])
    paths.update(item["path"] for item in authorization.verify_policy(ROOT)["files"])
    paths.add(authorization.POLICY_RELATIVE)
    paths.update(path.relative_to(ROOT).as_posix() for path in (
        soak.FIXTURE, QUALIFICATION, CORE_REPORT, NATIVE_BUILD, BASELINE, API_REPORT,
        LICENSE_REPORT, FUZZ_REPORT, SECURITY_INDEX, SECURITY_PACKAGE,
        REVIEW_REQUEST, REVIEW, REVIEW_REPORT, ROOT / SCOPE_DOCUMENT,
        *(SUPPLY / name for name in supply.OUTPUT_NAMES),
    ))
    native = release.load_json(NATIVE_BUILD)
    paths.update(native[field]["path"] for field in ("driver", "raw_log"))
    _, targets = fuzz.load_manifest(ROOT, ROOT / "tools/gates/campaigns/m7-023-linux-fuzz.json")
    paths.update(target["corpus"] for target in targets)
    return sorted(paths)


def _committed_task(revision: str) -> dict:
    stored = subprocess.run(
        ["git", "cat-file", "blob", f"{revision}:tools/tasks/M8-007.json"], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    require(stored.returncode == 0, "committed release task is unavailable")
    task = json.loads(stored.stdout)
    require(isinstance(task, dict) and isinstance(task.get("source_paths"), list),
            "committed release task is invalid")
    return task


def _verify_task_extension(current: dict, original: dict) -> set[str]:
    sources = set(current["source_paths"])
    require(set(original["source_paths"]) <= sources, "release task removed a committed source input")
    require(current == {**original, "source_paths": current["source_paths"]},
            "release task contract changed outside additive source inputs")
    return sources


def frozen_command(revision: str) -> dict:
    task = repository.load_task(ROOT / "tools/tasks/M8-007.json", ROOT)
    _verify_task_extension(task, _committed_task(revision))
    commands = [item for item in task["acceptance_commands"] if item["id"] == "final-candidate-soak"]
    require(len(commands) == 1, "formal soak command is absent or duplicated")
    return commands[0]


def capture_frozen_candidate(revision: str) -> dict:
    revision = repository._resolve_candidate_commit(ROOT, revision)
    sources = {}
    for relative in frozen_source_paths():
        actual = digest.text_evidence_digest(ROOT / relative)
        committed = repository._source_digest_at_commit(ROOT, revision, relative)
        require(actual == committed, f"soak input differs from committed candidate: {relative}")
        sources[relative] = committed.to_json()
    return {
        "schema_version": 1, "source_task": TASK_ID, "decision": "PASS",
        "scope": "committed-soak-inputs", "revision": revision,
        "source_sha256": sources, "command": frozen_command(revision),
    }


def run_soak_gate(revision: str) -> dict:
    verify_core()
    verify_fuzz()
    require(release.load_json(REVIEW_REPORT) == verify_review(), "independent review validation changed")
    frozen = capture_frozen_candidate(revision)
    directory = EVIDENCE / "commands/formal-soak"
    directory.mkdir(parents=True, exist_ok=False)
    write_json(FROZEN_CANDIDATE, frozen)
    ready = False
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(repository.run_command, ROOT, frozen["command"], directory)
        output = directory / "final-candidate-soak.stdout.log"
        while True:
            if not ready and output.is_file():
                for line in output.read_text(encoding="utf-8").splitlines():
                    if re.fullmatch(r"SOAK_READY task=M8-007 cycles=[1-9][0-9]*.*", line):
                        print(line, flush=True)
                        ready = True
                        break
            if future.done():
                break
            time.sleep(0.2)
        command = future.result()
    result = {
        "schema_version": 1, "source_task": TASK_ID,
        "status": command["status"] if ready else "FAIL",
        "readiness_observed": ready, "command": command,
        "frozen_candidate": record(FROZEN_CANDIDATE),
        "raw_output": [record(ROOT / command[field]) for field in ("stdout_path", "stderr_path")],
    }
    write_json(SOAK_COMMAND, result)
    require(result["status"] == "PASS", "formal soak command failed")
    return verify_soak()


def verify_soak() -> dict:
    frozen = release.load_json(FROZEN_CANDIDATE)
    require(frozen == capture_frozen_candidate(frozen["revision"]), "frozen candidate inputs changed")
    command = release.load_json(SOAK_COMMAND)
    require(command.get("source_task") == TASK_ID and command.get("status") == "PASS" and
            command.get("readiness_observed") is True, "formal soak command evidence is absent")
    require(command["frozen_candidate"] == record(FROZEN_CANDIDATE), "formal command candidate changed")
    execution = command["command"]
    require(execution["argv"] == frozen["command"]["argv"] and execution["exit_code"] == 0 and
            execution["timed_out"] is False and execution["duration_ms"] >= soak.FORMAL_SECONDS * 1000,
            "formal command did not complete the required duration")
    require(command["raw_output"] == [record(ROOT / execution[field]) for field in ("stdout_path", "stderr_path")],
            "formal command output changed")
    result = release.load_json(SOAK_REPORT)
    require(result.get("source_task") == TASK_ID and result.get("decision") == "PASS" and result.get("formal_parameters_met") is True, "formal M8-007 soak did not pass")
    require(result["parameters"]["duration_seconds"] == soak.FORMAL_SECONDS, "final soak must run for 86400 seconds")
    require(result["process"]["exit_code"] == 0 and result["process"]["timed_out"] is False, "soak process did not complete")
    soak.require_execution_inputs(SimpleNamespace(artifact=ARTIFACT, qualification=QUALIFICATION), result["input_identities"])
    text = soak.read_verified_text(EVIDENCE / "soak.log", result["raw_log"], drift_code="FINAL_SOAK_LOG_DRIFT")
    samples, terminal = soak.parse_output(text)
    require(terminal == result["workload"]["result"], "soak terminal record changed")
    checks = soak.validate_workload(terminal, soak.FORMAL_SECONDS, result["process"]["wall_elapsed_ms"])
    require(all(checks.values()) and checks == result["workload"]["checks"], "formal workload checks failed")
    resources = result["resources"]
    require(samples == resources["application"]["samples"], "soak application samples changed")
    for name, trend in (
        ("application", soak.application_trend(samples, minimum_samples=20)),
        ("process_tree", soak.resource_trend(resources["process_tree"]["samples"], minimum_samples=20)),
    ):
        require(trend["decision"] == "PASS" and trend == resources[name]["trend"], f"soak resource trend failed: {name}")
    return {"source_task": TASK_ID, "decision": "PASS", "evidence": record(SOAK_REPORT)}


def signing_manifest() -> dict:
    verify_core()
    verify_fuzz()
    verify_soak()
    require(release.load_json(REVIEW_REPORT) == verify_review(), "independent review validation changed")
    return signing.build_release_manifest(
        ARTIFACT, SUPPLY, task_id=TASK_ID, workflow=WORKFLOW, root=ROOT,
        qualified_inputs=(QUALIFICATION, CORE_REPORT, BASELINE, API_REPORT, LICENSE_REPORT,
                          FUZZ_REPORT, SOAK_REPORT, SECURITY_INDEX, SECURITY_PACKAGE,
                          REVIEW_REQUEST, REVIEW, REVIEW_REPORT, FROZEN_CANDIDATE, SOAK_COMMAND,
                          ROOT / authorization.POLICY_RELATIVE),
    )


def verify_signatures(directory: Path, commit: str, *, save: bool) -> dict:
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "signing source revision is invalid")
    manifest_path = directory / "release-manifest.json"
    require(signing.load_json(manifest_path) == signing_manifest(), "signed release manifest does not match qualification")
    subjects = (
        ("artifact", ARTIFACT, "https://spdx.dev/Document/v2.3"),
        ("sbom", SUPPLY / "sbom.spdx.json", "https://slsa.dev/provenance/v1"),
        ("release-manifest", manifest_path, "https://slsa.dev/provenance/v1"),
    )
    results = {}
    for name, subject, predicate in subjects:
        bundle = directory / f"{name}.sigstore.json"
        command = [
            "gh", "attestation", "verify", subject.relative_to(ROOT).as_posix(),
            "--bundle", bundle.relative_to(ROOT).as_posix(), "--repo", signing.REPOSITORY,
            "--signer-workflow", f"{signing.REPOSITORY}/{WORKFLOW}",
            "--source-digest", commit, "--signer-digest", commit,
            "--predicate-type", predicate, "--deny-self-hosted-runners", "--format", "json",
        ]
        completed = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
        require(completed.returncode == 0, f"{name} signature verification failed: {completed.stderr}")
        verified = json.loads(completed.stdout)
        require(isinstance(verified, list) and bool(verified), f"{name} has no verified attestation")
        if save:
            (directory / f"{name}-verification.json").write_text(completed.stdout, encoding="utf-8")
        results[name] = {
            "bundle": {"name": bundle.name, "digest": digest.text_evidence_digest(bundle).to_json()},
            "command": command, "exit_code": completed.returncode,
            "stderr": completed.stderr, "verification": verified,
        }
    result = {"schema_version": 1, "source_task": TASK_ID, "status": "PASS", "decision": "PASS", "source_revision": commit, "workflow": WORKFLOW, "subjects": results}
    if save:
        write_json(directory / "github-attestation.json", result)
    return result


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    try:
        if args == ["prepare"]:
            result = prepare()
        elif args == ["verify-core"]:
            result = verify_core()
        elif args == ["verify-api"]:
            result = verify_api()
        elif args == ["download-artifact"]:
            result = download_artifact()
        elif args == ["verify-fuzz"]:
            result = verify_fuzz()
        elif args == ["fuzz"]:
            result = run_fuzz()
        elif args == ["prepare-security"]:
            result = prepare_security()
        elif args == ["review-report"]:
            result = verify_review()
            write_json(REVIEW_REPORT, result)
        elif args == ["verify-soak"]:
            result = verify_soak()
        elif args == ["signing-manifest"]:
            result = signing_manifest()
            write_json(ROOT / "build/m8-007/signatures/release-manifest.json", result)
        elif args and args[0] == "verify-signatures":
            parser = argparse.ArgumentParser()
            parser.add_argument("--commit", required=True)
            parser.add_argument("--directory", type=Path, required=True)
            options = parser.parse_args(args[1:])
            result = verify_signatures(options.directory.resolve(), options.commit, save=True)
        elif args == ["verify-all"]:
            hosted = release.load_json(SIGNATURES / "github-attestation.json")
            require(hosted.get("source_task") == TASK_ID and hosted.get("decision") == "PASS", "hosted signature evidence is absent")
            expected_commit = authorization.approved_source_commit(ROOT)
            require(hosted.get("source_revision") == expected_commit,
                    "hosted signature source revision differs from independently approved source")
            task = repository.load_task(ROOT / "tools/tasks/M8-007.json", ROOT)
            sources = _verify_task_extension(task, _committed_task(expected_commit))
            generated_inputs = {
                (EVIDENCE / name).relative_to(ROOT).as_posix()
                for name in (
                    "frozen-candidate.json", "soak.json", "soak.log",
                    "commands/formal-soak/final-candidate-soak.stdout.log",
                    "commands/formal-soak/final-candidate-soak.stderr.log",
                    "signatures/release-manifest.json", "signatures/artifact.sigstore.json",
                    "signatures/sbom.sigstore.json", "signatures/release-manifest.sigstore.json",
                )
            }
            require(generated_inputs <= sources, "release task must archive every generated soak and signing input")
            result = verify_signatures(SIGNATURES, expected_commit, save=False)
        elif args and args[0] == "run-soak-gate":
            parser = argparse.ArgumentParser()
            parser.add_argument("--revision", required=True)
            options = parser.parse_args(args[1:])
            result = run_soak_gate(options.revision)
        elif args and args[0] == "soak":
            verify_core()
            return soak.main([
                "--artifact", str(ARTIFACT), "--qualification", str(QUALIFICATION),
                "--output", str(EVIDENCE / "soak.json"), "--raw-log", str(EVIDENCE / "soak.log"),
                *args[1:],
            ], task_id=TASK_ID)
        else:
            raise release.ReleaseError("usage: m8_007_final_release.py {prepare|download-artifact|verify-core|verify-api|fuzz|verify-fuzz|prepare-security|review-report|run-soak-gate --revision SHA|soak [options]|verify-soak|signing-manifest|verify-signatures --commit SHA --directory PATH|verify-all}")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (release.ReleaseError, supply.SupplyChainError, api.ApiFreezeError, public_api.PublicApiInventoryError, security.ReviewPackageError, review.IndependentReviewError, signing.ReleaseError, soak.SoakError, repository.ContractError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"source_task": TASK_ID, "decision": "FAIL", "error": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
