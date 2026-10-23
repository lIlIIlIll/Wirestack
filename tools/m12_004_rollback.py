#!/usr/bin/env python3
"""Authenticate an exact historical release, probe STS, and gate private rollback."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest as digest
from tools import m7_021_linux_release as release
from tools import m7_030_linux_release as signing

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ".github/workflows/m8-007-linux-release-attestation.yml"
HISTORY = Path("docs/evidence/M8-007/linux_x86_64")
MAX_ARTIFACT = 128 * 1024 * 1024


def require(value: bool, code: str, detail: str) -> None:
    signing.require(value, code, detail)


def normalized(value: str, work: Path) -> str:
    return value.replace(str(work), "<rollback-work>").replace(str(ROOT), "<repo>").replace(str(Path.home()), "$HOME")


def command(argv: list[str], cwd: Path, report: dict, work: Path, timeout: int = 180) -> str:
    result = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout)
    entry = {"argv": [normalized(v, work) for v in argv], "exit_code": result.returncode,
             "stdout": normalized(result.stdout, work), "stderr": normalized(result.stderr, work)}
    report["commands"].append(entry)
    require(result.returncode == 0, "COMMAND_FAILED", entry["stderr"] or entry["stdout"])
    return result.stdout


def authenticated(args: argparse.Namespace, report: dict, work: Path) -> tuple[Path, dict]:
    require(args.artifact.is_file() and args.artifact.stat().st_size <= MAX_ARTIFACT,
            "ARTIFACT_BOUND", "missing or oversized historical archive")
    artifact = work / args.artifact.name
    signing.atomic_bytes(artifact, args.artifact.read_bytes())
    history = args.history_root / HISTORY
    bundle = work / "signatures"
    bundle.mkdir()
    for name in ("release-manifest.json", "artifact.sigstore.json", "sbom.sigstore.json", "release-manifest.sigstore.json"):
        path = history / "signatures" / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= signing.MAX_JSON_BYTES,
                "SIGNATURE_PATH", name)
        signing.atomic_bytes(bundle / name, path.read_bytes())
    sbom = bundle / "sbom.spdx.json"
    signing.atomic_bytes(sbom, (history / "supply-chain/sbom.spdx.json").read_bytes())
    manifest = signing.load_json(bundle / "release-manifest.json")
    signing.validate_release_manifest(manifest, task_id="M8-007", workflow=WORKFLOW)
    qualification = signing.load_json(args.qualification)
    require(qualification.get("decision") == "PASS" and qualification.get("source_task") == "M8-007",
            "QUALIFICATION_INVALID", "historical qualification required")
    binding = digest.artifact_byte_digest(artifact).to_json()
    report["bindings"]["artifact"] = binding
    require(digest.schema_artifact_sha256_equal(binding["sha256"], qualification["artifact"]["sha256"]),
            "ARTIFACT_DRIFT", "exact qualified archive required")
    inputs = manifest.get("qualifiedInputs", {})
    require(inputs.get(HISTORY.as_posix() + "/qualification.json") == digest.text_evidence_digest(args.qualification).to_json(),
            "QUALIFICATION_BINDING", "qualification must be signed")
    for relative, expected in inputs.items():
        path = args.history_root / relative
        require(path.is_file() and not path.is_symlink() and digest.text_evidence_digest(path).to_json() == expected,
                "EVIDENCE_DRIFT", relative)
    approval = signing.load_json(history / "signing-approval.json")
    require(approval.get("status") == "PASS" and approval.get("approved_source_commit") == args.signing_commit,
            "SIGNING_AUTHORIZATION", "original explicit approval/source mismatch")
    for name, subject, predicate in (
        ("artifact", artifact, "https://spdx.dev/Document/v2.3"),
        ("sbom", sbom, "https://slsa.dev/provenance/v1"),
        ("release-manifest", bundle / "release-manifest.json", "https://slsa.dev/provenance/v1"),
    ):
        if name != "release-manifest":
            expected = next(item for item in manifest["subjects"] if item["name"] == name)
            require(digest.schema_artifact_sha256_equal(digest.signed_payload_sha256(subject),
                    expected["signedPayloadSha256"]), "SUBJECT_DRIFT", name)
        output = command(["gh", "attestation", "verify", str(subject), "--bundle", str(bundle / f"{name}.sigstore.json"),
                          "--repo", signing.REPOSITORY, "--signer-workflow", f"{signing.REPOSITORY}/{WORKFLOW}",
                          "--source-digest", args.signing_commit, "--signer-digest", args.signing_commit,
                          "--predicate-type", predicate, "--deny-self-hosted-runners", "--format", "json"], ROOT, report, work)
        require(isinstance(json.loads(output), list) and bool(json.loads(output)), "SIGNATURE_EMPTY", name)
    for name in ("soak.json", "fuzz-report.json", "review-validation.json"):
        require((HISTORY / name).as_posix() in inputs, "QUALIFICATION_BINDING", name)
        gate = signing.load_json(history / name)
        require(gate.get("decision") == "PASS", "HISTORICAL_GATE", name)
        if name == "soak.json":
            require(gate.get("formal_parameters_met") is True and gate.get("parameters", {}).get("duration_seconds") == 86400,
                    "HISTORICAL_SOAK", "exact formal duration required")
    report["historical_formal_acceptance"] = "PASS"
    payload, _ = release.read_verified_payload(artifact)
    require(digest.schema_text_sha256_equal(release.source_tree_sha256(args.history_root), qualification["source_tree_sha256"]),
            "SOURCE_BINDING", "original production source inventory differs")
    for relative, content in payload.items():
        if relative.startswith("src/") or relative in {"cjpm.toml", "cjpm.lock"}:
            require((args.history_root / relative).read_bytes() == content, "SOURCE_BINDING", relative)
    report["historical_authentication"] = "PASS"
    report["bindings"]["qualification"] = digest.text_evidence_digest(args.qualification).to_json()
    report["bindings"]["manifest"] = digest.text_evidence_digest(bundle / "release-manifest.json").to_json()
    report["historical_toolchain"] = qualification["toolchain"]
    return artifact, manifest


def probe(args: argparse.Namespace, artifact: Path, report: dict, work: Path) -> None:
    require(args.sdk_root.resolve() == (Path.home() / "cangjie_sdk/sts1.1.3").resolve(),
            "SDK_SELECTION", "only explicitly selected STS1.1.3 is authorized")
    wrapper = Path.home() / ".codex/scripts/codex_cangjie_env"
    prefix = [str(wrapper), "--sdk-root", str(args.sdk_root)]
    version = command(prefix + ["cjc", "--version"], ROOT, report, work)
    require("Cangjie Compiler: 1.1.3 (cjnative)" in version, "SDK_VERSION", "STS compiler identity")
    command(prefix + ["cjpm", "--version"], ROOT, report, work)
    installed = release.extract_archive(artifact, work / "installed")
    consumer = work / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "cjpm.toml").write_text(release.consumer_manifest(installed), encoding="utf-8")
    shutil.copyfile(release.SMOKE_FIXTURE, consumer / "src/main.cj")
    report["bindings"]["consumer_source"] = digest.text_evidence_digest(consumer / "src/main.cj").to_json()
    report["bindings"]["compiler"] = digest.artifact_byte_digest(args.sdk_root / "bin/cjc").to_json()
    report["bindings"]["cjpm"] = digest.artifact_byte_digest(args.sdk_root / "tools/bin/cjpm").to_json()
    command(prefix + ["cjpm", "build"], consumer, report, work, timeout=600)
    binary = consumer / "target/release/bin/main"
    output = command(prefix + [str(binary)], consumer, report, work)
    release.validate_smoke_output(output)
    needed = release.parse_needed(command(["readelf", "-d", str(binary)], consumer, report, work))
    release.reject_openssl_dependencies(needed)
    report["consumer"] = {"status": "PASS", "sdk": "STS1.1.3", "archive_unchanged": digest.artifact_byte_digest(artifact).to_json() == report["bindings"]["artifact"],
                          "binary": digest.artifact_byte_digest(binary).to_json(), "needed": needed}
    require(report["consumer"]["archive_unchanged"], "ARTIFACT_DRIFT", "probe modified archive")



REVIEW_PATHS = (
    "docs/evidence/M8-007/security/requalification-protocol-review.json",
    "docs/evidence/M8-007/security/requalification-tls-native-review.json",
    "docs/evidence/M8-007/security/hpack-cost-triage.json",
    "docs/evidence/M12-004/review/independent-review.json",
    "docs/evidence/M12-004/review/independent-review-followup.json",
)
INTAKE = "docs/evidence/M12-004/inventory/candidate/inventory.json"


def security_requirements() -> tuple[dict, set[str]]:
    """Bind current review gaps and the preserved official advisory responses."""
    inputs, known = {}, set()
    for relative in REVIEW_PATHS:
        path = ROOT / relative
        inputs[relative] = digest.text_evidence_digest(path).to_json()
        review = signing.load_json(path)
        for field in ("findings", "gaps", "coverageGaps"):
            for item in review.get(field, []):
                if item.get("status") not in {"CLOSED", "COMPLETE", "REMEDIATED"}:
                    require(bool(item.get("id")), "SECURITY_REVIEW_INVALID", "review item has no stable ID")
                    known.add(item["id"])
    path = ROOT / INTAKE
    intake = signing.load_json(path)
    require(intake.get("status") == "PASS", "SECURITY_INTAKE_INVALID", "passing fresh intake required")
    inputs[INTAKE] = digest.text_evidence_digest(path).to_json()
    channels = intake["advisory_intake"]["channels"]
    require(bool(channels) and any(row["channel"] == "repository-advisories" for row in channels),
            "SECURITY_INTAKE_INVALID", "official repository advisory channel required")
    now = dt.datetime.now(dt.timezone.utc)
    for row in channels:
        require(row.get("status") == "AVAILABLE", "SECURITY_INTAKE_UNAVAILABLE", row["channel"])
        issued = signing.parse_utc(row["intake_utc"], "SECURITY_INTAKE_STALE", "intake_utc")
        require(dt.timedelta(0) <= now - issued <= dt.timedelta(days=1),
                "SECURITY_INTAKE_STALE", "refresh public advisory intake after 24 hours")
        name = row["response"]
        require(Path(name).name == name, "SECURITY_INTAKE_PATH", "response must be a basename")
        response = path.parent / name
        actual = digest.text_evidence_digest(response).to_json()
        require(actual == row["digest"], "SECURITY_INTAKE_DRIFT", row["channel"])
        inputs[response.relative_to(ROOT).as_posix()] = actual
        if row["channel"] == "repository-advisories":
            require(response.stat().st_size <= 2 * 1024 * 1024,
                    "SECURITY_INTAKE_INVALID", "public advisory response exceeds bound")
            advisories = json.loads(response.read_text(), object_pairs_hook=signing._unique_object)
            require(isinstance(advisories, list) and all(item.get("ghsa_id") for item in advisories),
                    "SECURITY_INTAKE_INVALID", "public advisory IDs required")
            known.update(item["ghsa_id"] for item in advisories)
    return inputs, known

def security(args: argparse.Namespace, report: dict) -> None:
    require(args.security_disposition is not None and args.security_key is not None and args.security_key_sha256 is not None,
            "SECURITY_DISPOSITION_MISSING", "fresh signed artifact-bound advisory disposition required")
    require(digest.artifact_byte_sha256(args.security_key) == args.security_key_sha256,
            "SECURITY_KEY_DRIFT", "independently pinned authority key required")
    signing.verify_file(args.security_key.read_bytes(), args.security_disposition,
                        Path(str(args.security_disposition) + ".sig"))
    policy = signing.load_json(args.security_disposition)
    now = dt.datetime.now(dt.timezone.utc)
    start = signing.parse_utc(policy.get("issued_at"), "SECURITY_TIME", "issued_at")
    end = signing.parse_utc(policy.get("expires_at"), "SECURITY_TIME", "expires_at")
    require(start <= now < end and (end - start).total_seconds() <= 86400, "SECURITY_STALE", "maximum 24-hour validity")
    require(policy.get("schema_version") == 1 and policy.get("purpose") == "nonproduction-rollback" and
            policy.get("decision") == "ALLOW" and policy.get("artifact") == report["bindings"]["artifact"] and
            digest.schema_artifact_sha256_equal(policy.get("candidate_sha256"), args.candidate_sha256) and
            policy.get("signing_commit") == args.signing_commit and
            policy.get("qualification") == report["bindings"]["qualification"], "SECURITY_BINDING", "explicit exact rollback authorization required")
    require(policy.get("advisory_review_complete") is True and isinstance(policy.get("advisories"), list) and
            all(item.get("disposition") in {"not_affected", "remediated"} and item.get("id") and item.get("evidence")
                for item in policy["advisories"]), "SECURITY_UNRESOLVED", "no ignored or risk-accepted advisories")
    current_reviews, known = security_requirements()
    require(known <= {item["id"] for item in policy["advisories"]}, "SECURITY_OMISSION",
            "current findings, review gaps and public advisories cannot be silently omitted")
    require(policy.get("current_review_inputs") == current_reviews,
            "SECURITY_REVIEW_DRIFT", "current review and official intake inputs must be bound")
    report["security"] = {"status": "PASS", "disposition": digest.text_evidence_digest(args.security_disposition).to_json()}


def active_candidate(pointer: dict, deployment: Path, candidate_sha256: str) -> Path:
    """Return the stored artifact readers actually resolve for this pointer.

    Readers resolve ``current.json`` through its ``version`` directory, so the
    compare-and-swap must bind that version to the candidate digest. A pointer
    whose digest and version disagree is not the candidate deployment.
    """
    require(digest.schema_artifact_sha256_equal(pointer.get("artifact", {}).get("sha256"), candidate_sha256),
            "DEPLOYMENT_CHANGED", "candidate compare-and-swap failed")
    version = pointer.get("version")
    require(isinstance(version, str) and version not in {"", ".", ".."} and Path(version).name == version,
            "DEPLOYMENT_CHANGED", "active deployment version is missing or unsafe")
    require(version == candidate_sha256, "DEPLOYMENT_CHANGED",
            "active deployment version does not match the candidate digest")
    stored = deployment / "versions" / version / "artifact.tar.gz"
    require(stored.is_file() and not stored.is_symlink(), "DEPLOYMENT_CHANGED",
            "active deployment artifact is missing")
    return stored


def restore(args: argparse.Namespace, artifact: Path, report: dict) -> None:
    deployment = args.deployment.resolve()
    require(deployment.is_relative_to(args.work_root.resolve()) and deployment != args.work_root.resolve(),
            "DEPLOYMENT_SCOPE", "deployment must be a child of private work root")
    require((deployment / ".wirestack-nonproduction").read_text() == "M12-004\n", "DEPLOYMENT_SCOPE", "explicit private deployment marker required")
    with (deployment / ".rollback.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        active = deployment / "current.json"
        before = active.read_bytes()
        current = signing.load_json(active)
        old = active_candidate(current, deployment, args.candidate_sha256)
        require(digest.schema_artifact_sha256_equal(digest.artifact_byte_sha256(old), args.candidate_sha256),
                "DEPLOYMENT_CHANGED", "installed candidate bytes differ")
        version = deployment / "versions" / report["bindings"]["artifact"]["sha256"]
        require(not version.exists(), "DEPLOYMENT_CHANGED", "rollback version already staged")
        staging = deployment / "versions" / (".staging-" + report["bindings"]["artifact"]["sha256"])
        shutil.rmtree(staging, ignore_errors=True)
        try:
            staging.mkdir(parents=True, exist_ok=False)
            signing.atomic_bytes(staging / "artifact.tar.gz", artifact.read_bytes())
            for path in (artifact.parent / "signatures").iterdir():
                require(path.is_file() and not path.is_symlink(), "SIGNATURE_PATH", "regular signature sidecars required")
                signing.atomic_bytes(staging / path.name, path.read_bytes())
            require(active.read_bytes() == before, "DEPLOYMENT_CHANGED", "deployment changed during staging")
            # Re-bind the staged candidate to the still-active version under the lock.
            active_candidate(signing.load_json(active), deployment, args.candidate_sha256)
            staging.rename(version)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        signing.atomic_bytes(deployment / "previous-current.json", before)
        signing.atomic_json(active, {"artifact": report["bindings"]["artifact"], "version": version.name})
        report["restore"] = "PASS"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("artifact", "history-root", "qualification", "sdk-root", "work-root", "deployment", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--signing-commit", required=True)
    parser.add_argument("--candidate-sha256", required=True)
    parser.add_argument("--security-disposition", type=Path)
    parser.add_argument("--security-key", type=Path)
    parser.add_argument("--security-key-sha256")
    parser.add_argument("--restore", action="store_true", help="replace only after all gates pass")
    args = parser.parse_args(argv)
    report = {"schema_version": 1, "task_id": "M12-004", "family": "rollback", "status": "BLOCKED",
              "qualification": "NOT_QUALIFIED", "bindings": {}, "commands": [], "historical_authentication": "NOT_RUN",
              "consumer": {"status": "NOT_RUN"}, "security": {"status": "NOT_RUN"}, "restore": "NOT_RUN"}
    active = args.deployment / "current.json"
    before_bytes = active.read_bytes() if active.is_file() else None
    report["deployment_before"] = digest.text_evidence_digest(active).to_json() if active.is_file() else None
    try:
        require(args.work_root.is_dir() and args.work_root.stat().st_mode & 0o077 == 0, "WORK_SCOPE", "private existing disk-backed work directory required")
        with tempfile.TemporaryDirectory(prefix="rehearsal-", dir=args.work_root) as directory:
            work = Path(directory)
            artifact, _ = authenticated(args, report, work)
            probe(args, artifact, report, work)
            security(args, report)
            if args.restore:
                restore(args, artifact, report)
            report["status"] = "PASS"
    except (signing.ReleaseError, release.ReleaseError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        report["blocker"] = {"code": getattr(error, "code", type(error).__name__),
                             "detail": normalized(str(error), args.work_root)}
        if report["historical_authentication"] == "PASS" and report["consumer"]["status"] == "NOT_RUN":
            report["consumer"]["status"] = "FAIL"
    report["deployment_after"] = digest.text_evidence_digest(active).to_json() if active.is_file() else None
    report["deployment_unchanged"] = before_bytes == (active.read_bytes() if active.is_file() else None)
    serialized = json.dumps(report).replace(str(args.work_root), "<rollback-work>")
    if args.work_root.is_relative_to(Path.home()):
        serialized = serialized.replace("$HOME/" + args.work_root.relative_to(Path.home()).as_posix(), "<rollback-work>")
    report = json.loads(serialized)
    signing.atomic_json(args.output, report)
    print(json.dumps({key: report[key] for key in ("status", "qualification", "restore", "deployment_unchanged")}))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
