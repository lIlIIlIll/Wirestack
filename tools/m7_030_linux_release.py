#!/usr/bin/env python3
"""Generate and verify M7-030 Linux release signing and update evidence."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-030"
SCHEMA_VERSION = 1
NAMESPACE = "wirestack-release"
SIGNER_IDENTITY = "wirestack-release"
REPOSITORY = "lIlIIlIll/Wirestack"
WORKFLOW = ".github/workflows/linux-release-attestation.yml"
SIGNER_WORKFLOW_IDENTITY = f"{REPOSITORY}/{WORKFLOW}"
ARTIFACT = ROOT / "dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz"
FROZEN_ARTIFACT_TAG = "m7-030-frozen-artifact-c0988f62"
FROZEN_ARTIFACT_SHA256 = "c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee"
SUPPLY_CHAIN = ROOT / "docs/evidence/M7-025/linux_x86_64"
SBOM = SUPPLY_CHAIN / "sbom.spdx.json"
PROVIDER_MANIFEST = SUPPLY_CHAIN / "provider-manifest.json"
BUILD_FINGERPRINT = SUPPLY_CHAIN / "build-fingerprint.json"
BUNDLE = SUPPLY_CHAIN / "bundle.json"
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 10000
MAX_EXTRACTED_BYTES = 128 * 1024 * 1024
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FULL_ACTION_SHA = re.compile(r"^[0-9a-f]{40}$")
MANIFEST_KEYS = {
    "schemaVersion", "taskId", "release", "target", "provider", "subjects",
    "sourceBundle", "signingPolicy",
}
SUBJECT_KEYS = {"name", "path", "mediaType", "sha256"}


class ReleaseError(RuntimeError):
    """Stable failure with a machine-readable code."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


def require(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise ReleaseError(code, detail)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_path(path: Path) -> str:
    require(path.is_file(), "INPUT_MISSING", path.as_posix())
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseError("JSON_DUPLICATE", key)
        result[key] = value
    return result


def load_json(path: Path, *, max_bytes: int = MAX_JSON_BYTES) -> dict[str, Any]:
    try:
        size = path.stat().st_size
        require(size <= max_bytes, "JSON_TOO_LARGE", path.name)
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except ReleaseError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("JSON_INVALID", path.name) from error
    require(isinstance(value, dict), "JSON_SCHEMA", f"{path.name} must be an object")
    return value


def atomic_bytes(
    path: Path,
    value: bytes,
    *,
    mode: int = 0o644,
    replace: Callable[[Path, Path], None] = os.replace,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_json(path: Path, value: Mapping[str, Any], **kwargs: Any) -> None:
    atomic_bytes(path, canonical_json(value), **kwargs)


def _strict_keys(value: Mapping[str, Any], expected: set[str], code: str) -> None:
    require(set(value) == expected, code, f"expected {sorted(expected)}, got {sorted(value)}")


def _strict_digest(value: Any, field: str) -> str:
    require(isinstance(value, str) and SHA256.fullmatch(value) is not None,
            "DIGEST_INVALID", field)
    return value


def build_release_manifest(
    artifact: Path = ARTIFACT,
    supply_chain: Path = SUPPLY_CHAIN,
) -> dict[str, Any]:
    provider = load_json(supply_chain / "provider-manifest.json")
    fingerprint = load_json(supply_chain / "build-fingerprint.json")
    bundle = load_json(supply_chain / "bundle.json")
    sbom = supply_chain / "sbom.spdx.json"
    require(bundle.get("decision") == "PASS" and bundle.get("unsigned") is True,
            "SUPPLY_CHAIN_INVALID", "M7-025 bundle decision")
    artifact_digest = sha256_path(artifact)
    require(artifact_digest == bundle.get("artifact", {}).get("sha256"),
            "ARTIFACT_STALE", artifact.name)
    document_digests = bundle.get("documents")
    require(isinstance(document_digests, dict), "SUPPLY_CHAIN_INVALID", "documents")
    for name in ("provider-manifest.json", "sbom.spdx.json", "build-fingerprint.json"):
        actual = sha256_path(supply_chain / name)
        expected = document_digests.get(name, {}).get("sha256")
        require(actual == expected, "SUPPLY_CHAIN_STALE", name)
    provider_data = provider.get("provider")
    target = provider.get("target")
    package = provider.get("package")
    require(all(isinstance(item, dict) for item in (provider_data, target, package)),
            "SUPPLY_CHAIN_INVALID", "provider identity")
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "release": {
            "name": package["name"],
            "version": package["version"],
            "licenseExpression": package["licenseExpression"],
        },
        "target": target,
        "provider": {
            "id": provider_data["providerId"],
            "version": provider_data["providerVersion"],
            "sourceContentSha256": provider_data["source"]["content_sha256"],
            "archiveSha256": provider_data["archive"]["sha256"],
            "abiVersion": provider_data["abiVersion"],
        },
        "subjects": [
            {
                "name": "artifact",
                "path": artifact.name,
                "mediaType": "application/gzip",
                "sha256": artifact_digest,
            },
            {
                "name": "sbom",
                "path": "sbom.spdx.json",
                "mediaType": "application/spdx+json",
                "sha256": sha256_path(sbom),
            },
        ],
        "sourceBundle": {
            "m7_025BundleSha256": sha256_path(supply_chain / "bundle.json"),
            "providerManifestSha256": sha256_path(supply_chain / "provider-manifest.json"),
            "buildFingerprintDocumentSha256": sha256_path(supply_chain / "build-fingerprint.json"),
            "buildFingerprint": fingerprint.get("buildFingerprint"),
        },
        "signingPolicy": {
            "production": "github-oidc-sigstore",
            "offline": "openssh-ed25519-detached",
            "namespace": NAMESPACE,
            "repository": REPOSITORY,
            "workflow": WORKFLOW,
            "requiredSubjects": ["artifact", "sbom", "release-manifest"],
            "runtimeFallback": False,
        },
    }
    validate_release_manifest(manifest)
    return manifest


def validate_release_manifest(manifest: Mapping[str, Any]) -> None:
    _strict_keys(manifest, MANIFEST_KEYS, "MANIFEST_SCHEMA")
    require(manifest["schemaVersion"] == SCHEMA_VERSION, "MANIFEST_SCHEMA", "version")
    require(manifest["taskId"] == TASK_ID, "MANIFEST_TASK", str(manifest["taskId"]))
    release = manifest["release"]
    target = manifest["target"]
    provider = manifest["provider"]
    source = manifest["sourceBundle"]
    policy = manifest["signingPolicy"]
    require(all(isinstance(item, dict) for item in (release, target, provider, source, policy)),
            "MANIFEST_SCHEMA", "nested objects")
    _strict_keys(release, {"name", "version", "licenseExpression"}, "MANIFEST_RELEASE")
    _strict_keys(target, {"os", "architecture", "libc", "libc_version", "triple"},
                 "MANIFEST_TARGET")
    _strict_keys(provider, {"id", "version", "sourceContentSha256", "archiveSha256",
                            "abiVersion"}, "MANIFEST_PROVIDER")
    _strict_keys(source, {"m7_025BundleSha256", "providerManifestSha256",
                          "buildFingerprintDocumentSha256", "buildFingerprint"},
                 "MANIFEST_SOURCE")
    _strict_keys(policy, {"production", "offline", "namespace", "repository", "workflow",
                          "requiredSubjects", "runtimeFallback"}, "MANIFEST_POLICY")
    require(release["name"] == "wirestack" and release["licenseExpression"] == "Apache-2.0",
            "MANIFEST_RELEASE", "identity or license")
    require(target["os"] == "linux" and target["architecture"] == "x86_64" and
            target["libc"] == "glibc", "MANIFEST_TARGET", "linux-x86_64-glibc required")
    require(provider["id"] == "aws-lc" and isinstance(provider["abiVersion"], int),
            "MANIFEST_PROVIDER", "identity or ABI")
    _strict_digest(provider["sourceContentSha256"], "provider.sourceContentSha256")
    _strict_digest(provider["archiveSha256"], "provider.archiveSha256")
    subjects = manifest["subjects"]
    require(isinstance(subjects, list) and len(subjects) == 2,
            "MANIFEST_SUBJECTS", "artifact and SBOM required")
    names: set[str] = set()
    for subject in subjects:
        require(isinstance(subject, dict), "MANIFEST_SUBJECT", "not an object")
        _strict_keys(subject, SUBJECT_KEYS, "MANIFEST_SUBJECT")
        name = subject["name"]
        require(name in {"artifact", "sbom"} and name not in names,
                "MANIFEST_SUBJECT", str(name))
        names.add(name)
        path = PurePosixPath(subject["path"])
        require(not path.is_absolute() and ".." not in path.parts and len(path.parts) == 1,
                "PATH_UNSAFE", subject["path"])
        _strict_digest(subject["sha256"], f"subjects.{name}.sha256")
    require(names == {"artifact", "sbom"}, "MANIFEST_SUBJECTS", "incomplete")
    require(policy.get("repository") == REPOSITORY and policy.get("workflow") == WORKFLOW,
            "MANIFEST_POLICY", "signer identity")
    require(policy.get("requiredSubjects") == ["artifact", "sbom", "release-manifest"],
            "MANIFEST_POLICY", "required subjects")
    require(policy.get("runtimeFallback") is False, "MANIFEST_POLICY", "fallback")
    for field in (
        "m7_025BundleSha256", "providerManifestSha256",
        "buildFingerprintDocumentSha256", "buildFingerprint",
    ):
        _strict_digest(source.get(field), f"sourceBundle.{field}")


def _run(argv: Sequence[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            argv, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError("COMMAND_UNAVAILABLE", Path(argv[0]).name) from error
    require(len(result.stdout) <= 1024 * 1024 and len(result.stderr) <= 1024 * 1024,
            "COMMAND_OUTPUT_BOUND", Path(argv[0]).name)
    return result


def public_key(private_key: Path) -> bytes:
    result = _run(["ssh-keygen", "-y", "-f", str(private_key)])
    require(result.returncode == 0, "SIGNING_KEY_INVALID", private_key.name)
    value = result.stdout.strip() + b"\n"
    require(value.startswith(b"ssh-ed25519 "), "SIGNING_KEY_TYPE", "Ed25519 required")
    return value


def validate_signing_key(private_key: Path, trusted_public_key: Path, output: Path) -> bytes:
    key = private_key.resolve()
    trusted = trusted_public_key.resolve()
    repository = ROOT.resolve()
    output_root = output.resolve()
    require(key.is_file() and trusted.is_file(), "SIGNING_KEY_MISSING", "key or trust anchor")
    require(repository not in key.parents and output_root not in key.parents,
            "SIGNING_KEY_LOCATION", "private key must remain outside repository and output")
    derived = public_key(key)
    expected = trusted.read_bytes().strip() + b"\n"
    require(derived == expected, "SIGNING_KEY_MISMATCH", "public key")
    return derived


def sign_file(private_key: Path, subject: Path, signature: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-030-sign-") as directory:
        temporary_subject = Path(directory) / subject.name
        shutil.copyfile(subject, temporary_subject)
        result = _run(["ssh-keygen", "-Y", "sign", "-f", str(private_key), "-n", NAMESPACE,
                       str(temporary_subject)])
        require(result.returncode == 0, "SIGNATURE_CREATE", subject.name)
        generated = Path(str(temporary_subject) + ".sig")
        require(generated.is_file(), "SIGNATURE_MISSING", subject.name)
        atomic_bytes(signature, generated.read_bytes())


def sign_bytes(private_key: Path, value: bytes, signature: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-030-sign-json-") as directory:
        subject = Path(directory) / "subject.json"
        subject.write_bytes(value)
        sign_file(private_key, subject, signature)


def verify_file(public: bytes, subject: Path, signature: Path) -> None:
    verify_bytes(public, subject.read_bytes(), signature, subject.name)


def verify_bytes(public: bytes, value: bytes, signature: Path, name: str) -> None:
    require(signature.is_file(), "SIGNATURE_MISSING", signature.name)
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-030-verify-") as directory:
        allowed = Path(directory) / "allowed_signers"
        allowed.write_bytes(SIGNER_IDENTITY.encode() + b" " + public)
        result = _run([
            "ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", SIGNER_IDENTITY,
            "-n", NAMESPACE, "-s", str(signature),
        ], input_bytes=value)
    require(result.returncode == 0, "SIGNATURE_INVALID", name)


def _subject_paths(output: Path, artifact: Path, sbom: Path) -> dict[str, Path]:
    return {
        "artifact": artifact,
        "sbom": sbom,
        "release-manifest": output / "release-manifest.json",
    }


def create_offline_bundle(
    private_key: Path,
    trusted_public_key: Path,
    output: Path,
    *,
    artifact: Path = ARTIFACT,
    supply_chain: Path = SUPPLY_CHAIN,
    allow_temporary_key: bool = False,
) -> dict[str, Any]:
    public = public_key(private_key) if allow_temporary_key else validate_signing_key(
        private_key, trusted_public_key, output
    )
    if allow_temporary_key:
        require(public == trusted_public_key.read_bytes().strip() + b"\n",
                "SIGNING_KEY_MISMATCH", "temporary key")
    manifest = build_release_manifest(artifact, supply_chain)
    output.mkdir(parents=True, exist_ok=True)
    atomic_json(output / "release-manifest.json", manifest)
    atomic_bytes(output / "release-signing-key.pub", public)
    subjects = _subject_paths(output, artifact, supply_chain / "sbom.spdx.json")
    signatures: dict[str, Any] = {}
    for name, subject in subjects.items():
        signature = output / f"{name}.sig"
        sign_file(private_key, subject, signature)
        verify_file(public, subject, signature)
        signatures[name] = {
            "subjectSha256": sha256_path(subject),
            "signatureSha256": sha256_path(signature),
        }
    index = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "classification": "REHEARSAL" if allow_temporary_key else "OFFLINE_RELEASE",
        "scheme": "OpenSSH-Ed25519",
        "namespace": NAMESPACE,
        "trustedPublicKeySha256": sha256_bytes(public),
        "signatures": signatures,
    }
    atomic_json(output / "signature-index.json", index)
    return index


def verify_offline_bundle(
    output: Path,
    public_key_path: Path,
    *,
    artifact: Path = ARTIFACT,
    sbom: Path = SBOM,
) -> dict[str, Any]:
    public = public_key_path.read_bytes().strip() + b"\n"
    require(public.startswith(b"ssh-ed25519 "), "SIGNING_KEY_TYPE", "trusted key")
    manifest = load_json(output / "release-manifest.json")
    validate_release_manifest(manifest)
    subject_map = {subject["name"]: subject for subject in manifest["subjects"]}
    require(sha256_path(artifact) == subject_map["artifact"]["sha256"],
            "SUBJECT_DIGEST", "artifact")
    require(sha256_path(sbom) == subject_map["sbom"]["sha256"],
            "SUBJECT_DIGEST", "sbom")
    subjects = _subject_paths(output, artifact, sbom)
    for name, subject in subjects.items():
        verify_file(public, subject, output / f"{name}.sig")
    return {"decision": "PASS", "verifiedSubjects": sorted(subjects)}


def safe_extract(archive_path: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    try:
        archive = tarfile.open(archive_path, "r:gz")
    except (OSError, tarfile.TarError) as error:
        raise ReleaseError("ARCHIVE_INVALID", archive_path.name) from error
    with archive:
        members = archive.getmembers()
        require(0 < len(members) <= MAX_ARCHIVE_MEMBERS, "ARCHIVE_BOUND", "member count")
        validate_payload_inventory(member.name for member in members)
        roots: set[str] = set()
        total = 0
        for member in members:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and path.parts and ".." not in path.parts,
                    "ARCHIVE_PATH", member.name)
            require(member.isfile() or member.isdir(), "ARCHIVE_LINK", member.name)
            roots.add(path.parts[0])
            total += member.size
            require(total <= MAX_EXTRACTED_BYTES, "ARCHIVE_BOUND", "expanded bytes")
        require(len(roots) == 1, "ARCHIVE_ROOT", "exactly one root required")
        root = next(iter(roots))
        require(root == "wirestack-0.1.0", "ARCHIVE_ROOT", root)
        for member in members:
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            require(source is not None, "ARCHIVE_INVALID", member.name)
            atomic_bytes(target, source.read(), mode=member.mode & 0o755 or 0o644)
    return destination / root


def validate_payload_inventory(names: Sequence[str] | Any) -> None:
    for name in names:
        lowered = str(name).lower()
        basename = PurePosixPath(lowered).name
        provider_fixture = any(token in basename for token in (
            "testtlsprovider", "test_tls_provider", "test-provider", "rehearsal-provider",
        ))
        private_key_file = (
            basename.startswith("id_ed25519")
            or basename.endswith((".pem", ".key"))
            or basename in {"private-key", "private_key"}
        )
        require(not provider_fixture and not private_key_file,
                "PAYLOAD_FORBIDDEN", str(name))


def provider_sbom_checksum(sbom: Mapping[str, Any], provider_id: str) -> tuple[str, str]:
    packages = sbom.get("packages")
    require(isinstance(packages, list), "SBOM_INVALID", "packages")
    expected = f"SPDXRef-Package-TlsProvider-{provider_id}"
    matches = [item for item in packages if isinstance(item, dict) and item.get("SPDXID") == expected]
    require(len(matches) == 1, "SBOM_PROVIDER", provider_id)
    package = matches[0]
    checksums = package.get("checksums")
    require(isinstance(checksums, list) and len(checksums) == 1,
            "SBOM_PROVIDER", "checksum")
    checksum = checksums[0]
    require(checksum.get("algorithm") == "SHA256", "SBOM_PROVIDER", "algorithm")
    return str(package.get("versionInfo")), _strict_digest(
        checksum.get("checksumValue"), "SBOM provider checksum"
    )


def transition_payload(
    installed: Mapping[str, Any], candidate: Mapping[str, Any], sbom: Mapping[str, Any],
    advisory: Mapping[str, Any],
) -> dict[str, Any]:
    _strict_keys(installed, {"sequence", "providerId", "providerVersion", "providerArchiveSha256",
                             "providerManifestSha256", "sbomSha256"}, "STATE_SCHEMA")
    _strict_keys(candidate, set(installed), "CANDIDATE_SCHEMA")
    require(isinstance(installed["sequence"], int) and isinstance(candidate["sequence"], int),
            "SEQUENCE_INVALID", "integer required")
    require(candidate["providerId"] == installed["providerId"],
            "PROVIDER_ID", "provider switch prohibited")
    sbom_version, sbom_archive = provider_sbom_checksum(sbom, str(candidate["providerId"]))
    require(sbom_version == candidate["providerVersion"] and
            sbom_archive == candidate["providerArchiveSha256"],
            "SBOM_STALE", "provider version or archive")
    required_advisory = {
        "schemaVersion", "advisoryId", "severity", "issuedUtc", "expiresUtc",
        "fromManifestSha256", "toManifestSha256", "toSbomSha256", "summary",
    }
    _strict_keys(advisory, required_advisory, "ADVISORY_SCHEMA")
    require(advisory["schemaVersion"] == 1 and advisory["severity"] in
            {"LOW", "MEDIUM", "HIGH", "CRITICAL"}, "ADVISORY_SCHEMA", "value")
    require(advisory["fromManifestSha256"] == installed["providerManifestSha256"] and
            advisory["toManifestSha256"] == candidate["providerManifestSha256"] and
            advisory["toSbomSha256"] == candidate["sbomSha256"],
            "ADVISORY_BINDING", "transition")
    for field in ("fromManifestSha256", "toManifestSha256", "toSbomSha256"):
        _strict_digest(advisory[field], field)
    return {
        "fromSequence": installed["sequence"],
        "toSequence": candidate["sequence"],
        "fromManifestSha256": installed["providerManifestSha256"],
        "toManifestSha256": candidate["providerManifestSha256"],
        "toSbomSha256": candidate["sbomSha256"],
        "advisorySha256": sha256_bytes(canonical_json(advisory)),
    }


def authorize_transition(
    installed: Mapping[str, Any], candidate: Mapping[str, Any], sbom: Mapping[str, Any],
    advisory: Mapping[str, Any], *, public: bytes, advisory_signature: Path,
    rollback_authorization: Mapping[str, Any] | None = None,
    rollback_signature: Path | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    verify_bytes(public, canonical_json(advisory), advisory_signature, "security-advisory")
    payload = transition_payload(installed, candidate, sbom, advisory)
    current_time = now or datetime.now(timezone.utc)
    issued = parse_utc(advisory["issuedUtc"], "ADVISORY_TIME", "issuedUtc")
    expires = parse_utc(advisory["expiresUtc"], "ADVISORY_TIME", "expiresUtc")
    require(issued <= current_time, "ADVISORY_TIME", "issuedUtc is in the future")
    require(expires > current_time, "ADVISORY_EXPIRED", str(advisory["advisoryId"]))
    if candidate["sequence"] < installed["sequence"]:
        require(rollback_authorization is not None, "ROLLBACK_UNAUTHORIZED", "missing authorization")
        require(rollback_signature is not None, "ROLLBACK_UNAUTHORIZED", "missing signature")
        expected = {
            "schemaVersion": 1,
            "authorization": "rollback",
            **payload,
            "expiresUtc": rollback_authorization.get("expiresUtc"),
        }
        _strict_keys(rollback_authorization, set(expected), "ROLLBACK_SCHEMA")
        require(dict(rollback_authorization) == expected, "ROLLBACK_BINDING", "transition")
        verify_bytes(public, canonical_json(rollback_authorization), rollback_signature,
                     "rollback-authorization")
        rollback_expires = parse_utc(
            rollback_authorization["expiresUtc"], "ROLLBACK_TIME", "expiresUtc"
        )
        require(rollback_expires > current_time, "ROLLBACK_EXPIRED", "authorization")
    elif candidate["sequence"] == installed["sequence"]:
        require(candidate == installed, "SEQUENCE_REUSE", "different candidate")
    return copy.deepcopy(dict(candidate))


def parse_utc(value: Any, code: str, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as error:
        raise ReleaseError(code, field) from error
    require(parsed.tzinfo is not None and parsed.utcoffset() == timezone.utc.utcoffset(parsed),
            code, f"{field} must be UTC")
    return parsed


def run_update_rehearsal(private: Path, public: bytes, output: Path) -> dict[str, Any]:
    provider = load_json(PROVIDER_MANIFEST)
    sbom = load_json(SBOM)
    provider_data = provider["provider"]
    installed = {
        "sequence": 100,
        "providerId": provider_data["providerId"],
        "providerVersion": provider_data["providerVersion"],
        "providerArchiveSha256": provider_data["archive"]["sha256"],
        "providerManifestSha256": sha256_path(PROVIDER_MANIFEST),
        "sbomSha256": sha256_path(SBOM),
    }
    candidate = copy.deepcopy(installed)
    candidate.update({
        "sequence": 101,
        "providerVersion": "5.5.1-rehearsal",
        "providerArchiveSha256": "a" * 64,
        "providerManifestSha256": "b" * 64,
    })
    updated_sbom = copy.deepcopy(sbom)
    for package in updated_sbom["packages"]:
        if package.get("SPDXID") == "SPDXRef-Package-TlsProvider-aws-lc":
            package["versionInfo"] = candidate["providerVersion"]
            package["checksums"] = [{"algorithm": "SHA256", "checksumValue": "a" * 64}]
    candidate["sbomSha256"] = sha256_bytes(canonical_json(updated_sbom))
    advisory = {
        "schemaVersion": 1,
        "advisoryId": "WSA-REHEARSAL-0001",
        "severity": "HIGH",
        "issuedUtc": "2026-08-30T00:00:00Z",
        "expiresUtc": "2099-01-01T00:00:00Z",
        "fromManifestSha256": installed["providerManifestSha256"],
        "toManifestSha256": candidate["providerManifestSha256"],
        "toSbomSha256": candidate["sbomSha256"],
        "summary": "Synthetic provider update used only for release-process rehearsal.",
    }
    advisory_signature = output / "security-advisory.sig"
    sign_bytes(private, canonical_json(advisory), advisory_signature)
    upgraded = authorize_transition(
        installed, candidate, updated_sbom, advisory, public=public,
        advisory_signature=advisory_signature,
        now=datetime(2026, 8, 30, tzinfo=timezone.utc),
    )
    rollback_advisory = {
        **advisory,
        "advisoryId": "WSA-REHEARSAL-0002",
        "fromManifestSha256": candidate["providerManifestSha256"],
        "toManifestSha256": installed["providerManifestSha256"],
        "toSbomSha256": installed["sbomSha256"],
        "summary": "Synthetic authorized rollback used only for release-process rehearsal.",
    }
    rollback_advisory_signature = output / "rollback-advisory.sig"
    sign_bytes(private, canonical_json(rollback_advisory), rollback_advisory_signature)
    rollback_payload = transition_payload(candidate, installed, sbom, rollback_advisory)
    rollback = {
        "schemaVersion": 1,
        "authorization": "rollback",
        **rollback_payload,
        "expiresUtc": "2099-01-01T00:00:00Z",
    }
    rollback_signature = output / "rollback-authorization.sig"
    sign_bytes(private, canonical_json(rollback), rollback_signature)
    restored = authorize_transition(
        upgraded, installed, sbom, rollback_advisory, public=public,
        advisory_signature=rollback_advisory_signature,
        rollback_authorization=rollback, rollback_signature=rollback_signature,
        now=datetime(2026, 8, 30, tzinfo=timezone.utc),
    )
    return {
        "decision": "PASS",
        "classification": "REHEARSAL",
        "upgrade": {"fromSequence": 100, "toSequence": upgraded["sequence"]},
        "rollback": {"fromSequence": 101, "toSequence": restored["sequence"]},
        "advisoryIds": [advisory["advisoryId"], rollback_advisory["advisoryId"]],
        "sbomUpdated": candidate["sbomSha256"] != installed["sbomSha256"],
    }


def inspect_workflow(path: Path = ROOT / WORKFLOW) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    require(text.count("runs-on: ubuntu-latest") == 2,
            "WORKFLOW_RUNNER", "two GitHub-hosted Linux jobs required")
    require("permissions: {}" in text, "WORKFLOW_PERMISSION", "default token permissions disabled")
    stage_start = text.index("  stage-frozen-artifact:")
    attest_start = text.index("  attest-linux-release:")
    require(stage_start < attest_start, "WORKFLOW_STAGE_PERMISSION", "stage job order")
    stage_text = text[stage_start:attest_start]
    attest_text = text[attest_start:]
    require("permissions:\n      contents: write" in stage_text and
            "id-token: write" not in stage_text and
            "attestations: write" not in stage_text,
            "WORKFLOW_STAGE_PERMISSION", "isolated draft-reader token required")
    for permission in ("contents: read", "id-token: write", "attestations: write"):
        require(permission in attest_text, "WORKFLOW_ATTEST_PERMISSION", permission)
    require("contents: write" not in attest_text and
            "needs: stage-frozen-artifact" in attest_text,
            "WORKFLOW_ATTEST_PERMISSION", "attestation job must be read-only for contents")
    uses = re.findall(r"^\s*uses:\s*([^\s#]+)", text, re.MULTILINE)
    require(bool(uses), "WORKFLOW_ACTION", "none")
    for action in uses:
        require("@" in action and FULL_ACTION_SHA.fullmatch(action.rsplit("@", 1)[1]) is not None,
                "WORKFLOW_ACTION_PIN", action)
    require(uses.count("actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d") == 3,
            "WORKFLOW_ATTEST", "three immutable attest calls required")
    require(uses.count("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02") == 2 and
            uses.count("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093") == 1,
            "WORKFLOW_TRANSFER", "one bounded cross-job artifact transfer required")
    require("setup-cangjie@" not in text and
            "scripts/qualify-m7-021-linux-release" not in text,
            "WORKFLOW_ARTIFACT_REBUILD", "hosted signing must consume frozen artifact")
    require(f"FROZEN_ARTIFACT_TAG: {FROZEN_ARTIFACT_TAG}" in text,
            "WORKFLOW_ARTIFACT_SOURCE", "exact draft release tag required")
    require(f"FROZEN_ARTIFACT_SHA256: {FROZEN_ARTIFACT_SHA256}" in text,
            "WORKFLOW_ARTIFACT_DIGEST", "exact frozen artifact digest required")
    download = f'gh release download "$FROZEN_ARTIFACT_TAG"'
    require(text.count(download) == 1 and
            f"--repo {REPOSITORY}" in text and
            "--pattern wirestack-0.1.0-linux-x86_64-glibc.tar.gz" in text and
            "--dir dist/m7-021" in text,
            "WORKFLOW_ARTIFACT_SOURCE", "single exact release asset download required")
    require(text.count("sha256sum --check --strict") == 2,
            "WORKFLOW_ARTIFACT_DIGEST", "download and job transfer bytes must be checked")
    require("--latest" not in text and "releases/latest" not in text,
            "WORKFLOW_ARTIFACT_FALLBACK", "latest or fallback lookup forbidden")
    require("scripts/generate-m7-025-linux-supply-chain --validate-only" in text,
            "WORKFLOW_SUPPLY_CHAIN", "frozen bundle validation")
    require(text.index(download) <
            text.index("scripts/generate-m7-025-linux-supply-chain --validate-only") <
            text.index("id: attest-artifact"),
            "WORKFLOW_SUPPLY_CHAIN", "download, validate, then attest")
    for subject in ("artifact", "sbom", "release-manifest"):
        require(f"id: attest-{subject}" in text, "WORKFLOW_ATTEST", subject)
        require(f"id: verify-{subject}" in text, "WORKFLOW_VERIFY", subject)
        require(text.count(f"steps.attest-{subject}.outputs.bundle-path") == 3,
                "WORKFLOW_BUNDLE", subject)
    require(text.count("--deny-self-hosted-runners") == 3, "WORKFLOW_VERIFY", "runner policy")
    require(text.count(f"--repo {REPOSITORY}") == 4,
            "WORKFLOW_VERIFY", "one download and three verifications")
    require(text.count(f"--signer-workflow {SIGNER_WORKFLOW_IDENTITY}") == 3,
            "WORKFLOW_VERIFY", "workflow identity")
    require(text.count("--predicate-type https://spdx.dev/Document/v2.3") == 1,
            "WORKFLOW_VERIFY", "SPDX predicate")
    return {
        "decision": "PASS",
        "uses": uses,
        "attestationSubjects": 3,
        "artifactMode": "frozen",
        "artifactSource": {
            "tag": FROZEN_ARTIFACT_TAG,
            "sha256": FROZEN_ARTIFACT_SHA256,
        },
        "artifactStaging": {
            "contentsPermission": "write",
            "idTokenPermission": "none",
            "attestationContentsPermission": "read",
        },
    }


def validate_hosted_report(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ReleaseError("HOSTED_ATTESTATION_BLOCKED", path.as_posix())
    report = load_json(path)
    required = {"schemaVersion", "taskId", "decision", "repository", "workflow", "runner",
                "commit", "subjects"}
    _strict_keys(report, required, "HOSTED_REPORT_SCHEMA")
    require(report["schemaVersion"] == 1 and report["taskId"] == TASK_ID,
            "HOSTED_REPORT_SCHEMA", "identity")
    require(report["decision"] == "PASS", "HOSTED_REPORT_FAIL", str(report["decision"]))
    require(report["repository"] == REPOSITORY and report["workflow"] == WORKFLOW,
            "HOSTED_REPORT_IDENTITY", "repository or workflow")
    require(report["runner"] == "GitHub-hosted", "HOSTED_REPORT_RUNNER", str(report["runner"]))
    require(isinstance(report["commit"], str) and FULL_ACTION_SHA.fullmatch(report["commit"]),
            "HOSTED_REPORT_COMMIT", str(report["commit"]))
    subjects = report["subjects"]
    require(isinstance(subjects, list) and {item.get("name") for item in subjects
            if isinstance(item, dict)} == {"artifact", "sbom", "release-manifest"},
            "HOSTED_REPORT_SUBJECTS", "exact three subjects required")
    for subject in subjects:
        _strict_keys(subject, {"name", "sha256", "bundleSha256", "verification"},
                     "HOSTED_REPORT_SUBJECT")
        _strict_digest(subject["sha256"], "hosted subject")
        _strict_digest(subject["bundleSha256"], "hosted bundle")
        require(subject["verification"] == "PASS", "HOSTED_REPORT_SUBJECT", subject["name"])
    return report


def build_hosted_report(
    commit: str,
    subjects: Sequence[tuple[str, Path, Path, Path]],
) -> dict[str, Any]:
    require(FULL_ACTION_SHA.fullmatch(commit) is not None, "HOSTED_REPORT_COMMIT", commit)
    rows: list[dict[str, Any]] = []
    require({name for name, _, _, _ in subjects} == {"artifact", "sbom", "release-manifest"},
            "HOSTED_REPORT_SUBJECTS", "exact three subjects required")
    for name, subject, bundle, verification in subjects:
        require(bundle.is_file(), "HOSTED_BUNDLE_MISSING", name)
        verified = load_json(verification)
        _strict_keys(verified, {"verified"}, "HOSTED_VERIFY_SCHEMA")
        require(isinstance(verified["verified"], int) and verified["verified"] > 0,
                "HOSTED_VERIFY_EMPTY", name)
        rows.append({
            "name": name,
            "sha256": sha256_path(subject),
            "bundleSha256": sha256_path(bundle),
            "verification": "PASS",
        })
    report = {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "decision": "PASS",
        "repository": REPOSITORY,
        "workflow": WORKFLOW,
        "runner": "GitHub-hosted",
        "commit": commit,
        "subjects": sorted(rows, key=lambda item: item["name"]),
    }
    validate_hosted_report_value(report)
    return report


def validate_hosted_report_value(report: Mapping[str, Any]) -> None:
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-030-hosted-") as directory:
        path = Path(directory) / "report.json"
        path.write_bytes(canonical_json(report))
        validate_hosted_report(path)


def local_rehearsal(output: Path) -> dict[str, Any]:
    inspect_workflow()
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-030-key-") as key_directory:
        private = Path(key_directory) / "release"
        result = _run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private)])
        require(result.returncode == 0, "KEYGEN_FAILED", "ssh-keygen")
        signed = output / "offline"
        index = create_offline_bundle(private, private.with_suffix(".pub"), signed,
                                      allow_temporary_key=True)
        verified = verify_offline_bundle(signed, signed / "release-signing-key.pub")
        consumer = output / "consumer"
        safe_extract(ARTIFACT, consumer)
        update = run_update_rehearsal(private, public_key(private), output / "update")
    hosted = "PASS"
    hosted_detail = "verified"
    try:
        validate_hosted_report(ROOT / "docs/evidence/M7-030/github-attestation.json")
    except ReleaseError as error:
        hosted = "BLOCKED" if error.code == "HOSTED_ATTESTATION_BLOCKED" else "FAIL"
        hosted_detail = error.code
    return {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "decision": "PASS" if verified["decision"] == "PASS" else "FAIL",
        "classification": "REHEARSAL",
        "offlineSigning": {
            "classification": index["classification"],
            "scheme": index["scheme"],
            "namespace": index["namespace"],
            "verifiedSubjects": verified["verifiedSubjects"],
            "subjectSha256": {
                name: value["subjectSha256"]
                for name, value in sorted(index["signatures"].items())
            },
        },
        "consumer": {"decision": "PASS", "root": "wirestack-0.1.0"},
        "updateFlow": update,
        "workflow": inspect_workflow(),
        "productionAttestation": {"decision": hosted, "detail": hosted_detail},
        "nonClaims": [
            "Temporary-key signatures are not production release signatures.",
            "The synthetic update is not an AWS-LC security release.",
            "Production completion requires the GitHub-hosted attestation report.",
        ],
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--output", type=Path, required=True)
    rehearsal = subparsers.add_parser("rehearse")
    rehearsal.add_argument("--work-dir", type=Path, default=ROOT / "build/m7-030")
    rehearsal.add_argument("--output", type=Path, required=True)
    workflow = subparsers.add_parser("validate-workflow")
    workflow.add_argument("--output", type=Path)
    hosted = subparsers.add_parser("validate-hosted")
    hosted.add_argument("--report", type=Path,
                        default=ROOT / "docs/evidence/M7-030/github-attestation.json")
    hosted.add_argument("--output", type=Path)
    create_hosted = subparsers.add_parser("hosted-report")
    create_hosted.add_argument("--commit", required=True)
    for name in ("artifact", "sbom", "release-manifest"):
        create_hosted.add_argument(f"--{name}", type=Path, required=True)
        create_hosted.add_argument(f"--{name}-bundle", type=Path, required=True)
        create_hosted.add_argument(f"--{name}-verification", type=Path, required=True)
    create_hosted.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "manifest":
            atomic_json(args.output, build_release_manifest())
            result = {"decision": "PASS", "output": args.output.as_posix()}
        elif args.command == "rehearse":
            args.work_dir.mkdir(parents=True, exist_ok=True)
            result = local_rehearsal(args.work_dir)
            atomic_json(args.output, result)
        elif args.command == "validate-workflow":
            result = inspect_workflow()
            if args.output:
                atomic_json(args.output, result)
        elif args.command == "validate-hosted":
            result = validate_hosted_report(args.report)
            if args.output:
                atomic_json(args.output, result)
        else:
            subjects = [
                (name, getattr(args, name.replace("-", "_")),
                 getattr(args, name.replace("-", "_") + "_bundle"),
                 getattr(args, name.replace("-", "_") + "_verification"))
                for name in ("artifact", "sbom", "release-manifest")
            ]
            result = build_hosted_report(args.commit, subjects)
            atomic_json(args.output, result)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except ReleaseError as error:
        decision = "BLOCKED" if error.code == "HOSTED_ATTESTATION_BLOCKED" else "FAIL"
        report = {"schemaVersion": 1, "taskId": TASK_ID, "decision": decision,
                  "code": error.code, "detail": error.detail}
        output = getattr(args, "output", None)
        if output:
            atomic_json(output, report)
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
        return 2 if decision == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
