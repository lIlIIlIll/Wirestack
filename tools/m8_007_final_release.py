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
    )
) + tuple(
    (topic, TASK_ID, (SUPPLY / filename).relative_to(ROOT).as_posix(), "CURRENT_BOUND_INPUT", False)
    for topic, filename in (
        ("sbom", "sbom.spdx.json"), ("provider-manifest", "provider-manifest.json"),
        ("build-fingerprint", "build-fingerprint.json"),
    )
)
FROZEN_CANDIDATE = EVIDENCE / "frozen-candidate.json"
SOAK_COMMAND = EVIDENCE / "soak-command.json"
INPUTS = (
    "tools/m8_007_final_release.py",
    "tools/m7_022_linux_release_soak.py",
    "tools/m7_025_linux_supply_chain.py",
    "tools/m7_026_linux_api_freeze.py",
    "tools/m7_028_security_review_package.py",
    "tools/m7_029_independent_security_review.py",
    "tools/m7_030_linux_release.py",
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


def verify_core(*, check_report: bool = True) -> dict:
    qualification = release.load_json(QUALIFICATION)
    release.validate_report(qualification, ROOT)
    require(qualification.get("source_task") == TASK_ID, "historical qualification cannot qualify M8-007")
    require(qualification.get("final_release_inputs") == source_inputs(), "final qualification tooling changed")
    require(qualification.get("native_rebuild") == record(NATIVE_BUILD), "native build evidence changed")
    require(digest.artifact_byte_sha256(ARTIFACT) == qualification["artifact"]["sha256"], "qualified artifact changed")
    payload, manifest = release.read_verified_payload(ARTIFACT)
    native = validate_native(payload)
    api.validate(ROOT, BASELINE, API_REPORT, task_id=TASK_ID)
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
                digest.artifact_byte_sha256(ARTIFACT) == expected["sha256"],
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
                digest.artifact_byte_sha256(downloaded) == expected["sha256"],
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
            result["manifest_sha256"] == digest.text_evidence_sha256(ROOT / result["manifest"]), "fuzz manifest changed")
    require(result["source_sha256"] == fuzz.source_fingerprint(ROOT), "fuzz parser sources changed")
    require(result["gate_id"] == manifest["gate_id"] and result["profile"] == manifest["profile"] and
            result["corpus_version"] == manifest["corpus_version"], "fuzz campaign identity changed")
    require(result["mode"] == "campaign" and len(result["targets"]) == len(targets), "fuzz campaign is incomplete")
    require(result["build"]["exit_code"] == 0 and not result["build"]["timed_out"], "fuzz build failed")
    for expected, actual in zip(targets, result["targets"]):
        decision, reasons, marker = fuzz.classify(expected, manifest["seed"], actual["process"])
        require(decision == "PASS" and actual["decision"] == decision and actual["marker"] == marker and not reasons, f"fuzz target failed: {expected['name']}")
    return {"source_task": TASK_ID, "decision": "PASS", "targets": len(targets), "evidence": record(FUZZ_REPORT)}


def prepare_security() -> dict:
    verify_core()
    verify_fuzz()
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
    security.validate(ROOT, SECURITY_INDEX, SECURITY_PACKAGE, task_id=TASK_ID, document_inputs=DOCUMENT_INPUTS, evidence_inputs=EVIDENCE_INPUTS)
    return review.validate(ROOT, REVIEW_REQUEST, REVIEW, task_id=TASK_ID, package_path=SECURITY_INDEX.relative_to(ROOT).as_posix())


def frozen_source_paths() -> list[str]:
    paths = set(INPUTS) | set(release.QUALIFICATION_INPUTS)
    paths.update(path.relative_to(ROOT).as_posix() for path in (ROOT / "src").rglob("*.cj"))
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


def frozen_command(revision: str) -> dict:
    relative = "tools/tasks/M8-007.json"
    task = repository.load_task(ROOT / relative, ROOT)
    current = [item for item in task["acceptance_commands"] if item["id"] == "final-candidate-soak"]
    stored = subprocess.run(
        ["git", "cat-file", "blob", f"{revision}:{relative}"], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    require(stored.returncode == 0, "frozen candidate has no task manifest")
    original = [item for item in json.loads(stored.stdout)["acceptance_commands"] if item["id"] == "final-candidate-soak"]
    require(len(current) == 1 and current == original, "formal soak command differs from committed candidate")
    return current[0]


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
                          REVIEW_REQUEST, REVIEW, REVIEW_REPORT, FROZEN_CANDIDATE, SOAK_COMMAND),
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
            result = verify_signatures(SIGNATURES, hosted["source_revision"], save=False)
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
            raise release.ReleaseError("usage: m8_007_final_release.py {prepare|download-artifact|verify-core|fuzz|verify-fuzz|prepare-security|review-report|run-soak-gate --revision SHA|soak [options]|verify-soak|signing-manifest|verify-signatures --commit SHA --directory PATH|verify-all}")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (release.ReleaseError, supply.SupplyChainError, api.ApiFreezeError, security.ReviewPackageError, review.IndependentReviewError, signing.ReleaseError, soak.SoakError, repository.ContractError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"source_task": TASK_ID, "decision": "FAIL", "error": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
