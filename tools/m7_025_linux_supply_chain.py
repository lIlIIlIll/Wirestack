#!/usr/bin/env python3
"""Generate and validate the M7-025 Linux release supply-chain bundle."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import json
import re
import sys
import tarfile
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.tls_provider.selection import select_provider

SELECTED_PROVIDER = select_provider(ROOT)
TASK_ID = "M7-025"
SCHEMA_VERSION = 1
CREATED_UTC = "2026-08-28T00:00:00Z"
QUALIFICATION = ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json"
PROVIDER_PIN = SELECTED_PROVIDER.manifest_path
DEFAULT_ARTIFACT = ROOT / "dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M7-025/linux_x86_64"
OUTPUT_NAMES = (
    "provider-manifest.json",
    "sbom.spdx.json",
    "build-fingerprint.json",
    "bundle.json",
)
PROJECT_LICENSE_EXPRESSION = "Apache-2.0"
LICENSE_MEMBERS = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    f"third_party/{SELECTED_PROVIDER.provider}/LICENSE",
    f"third_party/{SELECTED_PROVIDER.provider}/NOTICE",
)
FEATURES = [
    "client-certificate",
    "custom-roots",
    "external-signer",
    "http-1.1",
    "http-2",
    "https-client",
    "https-server",
    "mutual-tls",
    "proxy-connect",
    "request-connection-stream-cancellation",
    "session-resumption",
    "sse-streaming",
    "system-trust",
]
TRUST_POLICIES = [
    "system",
    "custom-roots",
    "system-plus-custom-roots",
    "pinned-public-keys",
]


class SupplyChainError(RuntimeError):
    """Raised when supply-chain evidence is incomplete or inconsistent."""


def provider_spdx_id(provider_id: str) -> str:
    stable = re.sub(r"[^A-Za-z0-9.-]", "-", provider_id)
    return f"SPDXRef-Package-TlsProvider-{stable}"


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SupplyChainError(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SupplyChainError(f"cannot read {path}: {error}") from error
    _require(isinstance(value, dict), f"expected a JSON object in {path}")
    return value


def _member_bytes(archive: tarfile.TarFile, suffix: str) -> bytes:
    matches = [member for member in archive.getmembers() if member.name.endswith(suffix)]
    _require(len(matches) == 1, f"artifact must contain exactly one {suffix}")
    member = matches[0]
    _require(member.isfile(), f"artifact member is not a file: {member.name}")
    _require(member.size <= 8 * 1024 * 1024, f"artifact metadata is too large: {member.name}")
    stream = archive.extractfile(member)
    _require(stream is not None, f"cannot read artifact member: {member.name}")
    return stream.read()


def _relative_member_bytes(archive: tarfile.TarFile, relative: str) -> bytes:
    matches = [
        member
        for member in archive.getmembers()
        if "/" in member.name and member.name.split("/", 1)[1] == relative
    ]
    _require(len(matches) == 1, f"artifact must contain exactly one {relative}")
    member = matches[0]
    _require(member.isfile(), f"artifact member is not a file: {member.name}")
    _require(member.size <= 8 * 1024 * 1024, f"artifact metadata is too large: {member.name}")
    stream = archive.extractfile(member)
    _require(stream is not None, f"cannot read artifact member: {member.name}")
    return stream.read()


def _json_bytes(value: bytes, name: str) -> dict[str, Any]:
    try:
        decoded = json.loads(value.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SupplyChainError(f"invalid JSON in artifact member {name}: {error}") from error
    _require(isinstance(decoded, dict), f"artifact member must contain an object: {name}")
    return decoded


def artifact_metadata(path: Path) -> dict[str, Any]:
    _require(path.is_file(), f"release artifact is absent: {path}")
    try:
        with tarfile.open(path, "r:gz") as archive:
            release_raw = _member_bytes(archive, "/release-manifest.json")
            provider_raw = _member_bytes(
                archive, "/target/native/current/provider-manifest.json"
            )
            resolver_raw = _member_bytes(
                archive, "/target/native/resolver/current/resolver-manifest.json"
            )
            license_files = {
                relative: _relative_member_bytes(archive, relative)
                for relative in LICENSE_MEMBERS
            }
    except (OSError, tarfile.TarError) as error:
        raise SupplyChainError(f"cannot inspect release artifact: {error}") from error
    return {
        "artifact_sha256": evidence_digest.artifact_byte_sha256(path),
        "artifact_bytes": path.stat().st_size,
        "release": _json_bytes(release_raw, "release-manifest.json"),
        "provider": _json_bytes(provider_raw, "provider-manifest.json"),
        "provider_manifest_sha256": evidence_digest.text_evidence_bytes_sha256(provider_raw),
        "resolver": _json_bytes(resolver_raw, "resolver-manifest.json"),
        "resolver_manifest_sha256": evidence_digest.text_evidence_bytes_sha256(resolver_raw),
        "license_sha256": {
            relative: evidence_digest.text_evidence_bytes_sha256(content)
            for relative, content in license_files.items()
        },
    }


def _target_triple(qualification: Mapping[str, Any]) -> str:
    toolchain = qualification.get("toolchain")
    _require(isinstance(toolchain, dict), "qualification toolchain is absent")
    cjc = toolchain.get("cjc")
    _require(isinstance(cjc, list), "qualification cjc inventory is absent")
    for line in cjc:
        if isinstance(line, str) and line.startswith("Target: "):
            return line.removeprefix("Target: ")
    raise SupplyChainError("qualification target triple is absent")


def _cangjie_version(qualification: Mapping[str, Any]) -> str:
    cjc = qualification["toolchain"]["cjc"]
    _require(bool(cjc) and isinstance(cjc[0], str), "qualification compiler version is absent")
    prefix = "Cangjie Compiler: "
    value = cjc[0].removeprefix(prefix).split(" ", 1)[0]
    _require(bool(value), "qualification compiler version is empty")
    return value


def validate_artifact_inputs(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    provider_pin: Mapping[str, Any],
) -> None:
    artifact = qualification.get("artifact")
    _require(isinstance(artifact, dict), "M7-021 artifact evidence is absent")
    _require(metadata["artifact_sha256"] == artifact.get("sha256"), "artifact digest mismatch")
    _require(metadata["artifact_bytes"] == artifact.get("bytes"), "artifact size mismatch")
    release = metadata["release"]
    provider = metadata["provider"]
    resolver = metadata["resolver"]
    _require(release.get("schema_version") == 1, "release manifest schema is unsupported")
    _require(release.get("package") == "wirestack", "release package identity is invalid")
    _require(release.get("payload_sha256") == artifact.get("payload_sha256"), "payload digest mismatch")
    _require(release.get("externalOpenSslDependency") is False, "release depends on system OpenSSL")
    release_license = release.get("license")
    _require(isinstance(release_license, dict), "release license identity is absent")
    _require(
        release_license.get("expression") == PROJECT_LICENSE_EXPRESSION,
        "release license expression is invalid",
    )
    _require(release_license.get("file") == "LICENSE", "release license path is invalid")
    _require(
        release_license.get("sha256") == metadata["license_sha256"]["LICENSE"],
        "embedded project license digest mismatch",
    )
    notices = release.get("thirdPartyNotices")
    _require(isinstance(notices, dict), "release third-party notices are absent")
    _require(notices.get("index") == "THIRD_PARTY_NOTICES.md", "notice index is invalid")
    expected_notice_files = [
        {"path": relative, "sha256": metadata["license_sha256"][relative]}
        for relative in LICENSE_MEMBERS[1:]
    ]
    _require(notices.get("files") == expected_notice_files, "notice inventory mismatch")
    _require(provider.get("externalOpenSslDependency") is False, "provider depends on system OpenSSL")
    _require(provider.get("runtimeLoaderLibraryStrings") == [], "provider has runtime loader strings")
    release_provider = release.get("provider")
    release_resolver = release.get("resolver")
    _require(isinstance(release_provider, dict), "release provider identity is absent")
    _require(isinstance(release_resolver, dict), "release resolver identity is absent")
    _require(
        release_provider.get("manifest_sha256") == metadata["provider_manifest_sha256"],
        "embedded provider manifest digest mismatch",
    )
    _require(
        release_provider.get("archive_sha256") == provider.get("archive", {}).get("sha256"),
        "embedded provider archive digest mismatch",
    )
    _require(
        release_resolver.get("manifest_sha256") == metadata["resolver_manifest_sha256"],
        "embedded resolver manifest digest mismatch",
    )
    _require(
        release_resolver.get("archive_sha256") == resolver.get("archive", {}).get("sha256"),
        "embedded resolver archive digest mismatch",
    )
    build_pin = provider.get("build_inputs", {}).get("provider")
    _require(build_pin == provider_pin, "artifact provider pin differs from repository pin")
    _require(
        qualification.get("runtime", {}).get("providerBuildFingerprint")
        == provider.get("build_fingerprint"),
        "runtime and embedded provider fingerprints differ",
    )
    _require(release.get("target") == qualification.get("platform"), "target identity mismatch")


def fingerprint_inputs(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    generator_sha256: str,
) -> dict[str, Any]:
    release = metadata["release"]
    provider = metadata["provider"]
    resolver = metadata["resolver"]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "package": {"name": "wirestack", "version": release["version"]},
        "license": {
            "expression": release["license"]["expression"],
            "files": metadata["license_sha256"],
        },
        "artifact": {
            "sha256": metadata["artifact_sha256"],
            "payloadSha256": release["payload_sha256"],
        },
        "nativeComponents": {
            "tlsProvider": {
                "archiveSha256": provider["archive"]["sha256"],
                "embeddedManifestSha256": metadata["provider_manifest_sha256"],
                "providerBuildFingerprint": provider["build_fingerprint"],
                "sourceContentSha256": provider["source"]["content_sha256"],
            },
            "resolver": {
                "archiveSha256": resolver["archive"]["sha256"],
                "embeddedManifestSha256": metadata["resolver_manifest_sha256"],
                "buildFingerprint": resolver["build_fingerprint"],
            },
        },
        "target": {
            **qualification["platform"],
            "triple": _target_triple(qualification),
        },
        "toolchain": qualification["toolchain"],
        "capabilities": provider["capabilities"],
        "features": FEATURES,
        "trust": {
            "backend": "linux-system",
            "policies": TRUST_POLICIES,
            "selection": "explicit CA bundle or hashed certificate directory",
            "providerDefaultFallback": False,
        },
        "generator": {
            "schemaVersion": SCHEMA_VERSION,
            "sha256": generator_sha256,
        },
    }


def release_provider_manifest(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    build_fingerprint: str,
) -> dict[str, Any]:
    release = metadata["release"]
    provider = metadata["provider"]
    resolver = metadata["resolver"]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "artifact": {
            "name": qualification["artifact"]["name"],
            "bytes": metadata["artifact_bytes"],
            "sha256": metadata["artifact_sha256"],
            "payloadSha256": release["payload_sha256"],
        },
        "package": {
            "name": "wirestack",
            "version": release["version"],
            "licenseExpression": release["license"]["expression"],
        },
        "buildFingerprint": build_fingerprint,
        "provider": {
            "providerId": provider["providerId"],
            "providerVersion": provider["providerVersion"],
            "providerBuildFingerprint": provider["build_fingerprint"],
            "cryptoBackend": provider["backend"],
            "abiVersion": provider["abiVersion"],
            "securityPatchLevel": provider["patchLevel"],
            "licenseExpression": provider["build_inputs"]["provider"]["license_expression"],
            "source": provider["build_inputs"]["provider"]["source"],
            "archive": provider["archive"],
            "embeddedManifestSha256": metadata["provider_manifest_sha256"],
            "externalOpenSslDependency": False,
            "runtimeLoaderLibraryStrings": [],
        },
        "crypto": {
            "supportedTlsVersions": ["1.2", "1.3"],
            "capabilities": provider["capabilities"],
            "secureRandom": "provider-csprng",
        },
        "trust": {
            "backend": "linux-system",
            "policies": TRUST_POLICIES,
            "systemSourceSelection": "explicit CA bundle or hashed certificate directory",
            "providerDefaultFallback": False,
        },
        "resolver": {
            "backend": resolver["worker_model"],
            "buildFingerprint": resolver["build_fingerprint"],
            "archive": resolver["archive"],
            "embeddedManifestSha256": metadata["resolver_manifest_sha256"],
            "privateRuntimeAbi": resolver["private_runtime_abi"],
        },
        "target": {**qualification["platform"], "triple": _target_triple(qualification)},
        "features": FEATURES,
        "runtimeDependencies": qualification["dependency_scan"]["needed"],
    }


def spdx_document(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    manifest: Mapping[str, Any],
) -> dict[str, Any]:
    artifact = manifest["artifact"]
    provider = manifest["provider"]
    resolver = manifest["resolver"]
    cangjie_version = _cangjie_version(qualification)
    libc_version = qualification["platform"]["libc_version"]
    packages = [
        {
            "name": artifact["name"],
            "SPDXID": "SPDXRef-Package-Wirestack-Artifact",
            "versionInfo": manifest["package"]["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "checksums": [{"algorithm": "SHA256", "checksumValue": artifact["sha256"]}],
            "licenseConcluded": PROJECT_LICENSE_EXPRESSION,
            "licenseDeclared": PROJECT_LICENSE_EXPRESSION,
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": "LIBRARY",
            "comment": (
                f"payload-sha256={artifact['payloadSha256']}; "
                f"build-fingerprint={manifest['buildFingerprint']}"
            ),
        },
        {
            "name": provider["providerId"],
            "SPDXID": provider_spdx_id(provider["providerId"]),
            "versionInfo": provider["providerVersion"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": provider["archive"]["sha256"]}
            ],
            "licenseConcluded": provider["licenseExpression"],
            "licenseDeclared": provider["licenseExpression"],
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": provider["source"]["url"] +
                        "@" + provider["source"]["commit"],
                }
            ],
        },
        {
            "name": "Wirestack native resolver bridge",
            "SPDXID": "SPDXRef-Package-Wirestack-Resolver",
            "versionInfo": manifest["package"]["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": resolver["archive"]["sha256"]}
            ],
            "licenseConcluded": PROJECT_LICENSE_EXPRESSION,
            "licenseDeclared": PROJECT_LICENSE_EXPRESSION,
            "copyrightText": "NOASSERTION",
        },
        {
            "name": "Cangjie runtime",
            "SPDXID": "SPDXRef-Package-Cangjie-Runtime",
            "versionInfo": cangjie_version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "comment": "Runtime dependency; not bundled in the Wirestack artifact.",
        },
        {
            "name": "glibc",
            "SPDXID": "SPDXRef-Package-glibc",
            "versionInfo": libc_version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "comment": "Target runtime dependency; not bundled in the Wirestack artifact.",
        },
        {
            "name": "GNU libstdc++",
            "SPDXID": "SPDXRef-Package-libstdcxx",
            "versionInfo": "NOASSERTION",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "comment": "Transitive runtime dependency; not bundled in the Wirestack artifact.",
        },
        {
            "name": "GNU libgcc",
            "SPDXID": "SPDXRef-Package-libgcc",
            "versionInfo": "NOASSERTION",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "comment": "Transitive runtime dependency; not bundled in the Wirestack artifact.",
        },
    ]
    artifact_id = "SPDXRef-Package-Wirestack-Artifact"
    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": artifact_id,
        },
        {
            "spdxElementId": artifact_id,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": provider_spdx_id(provider["providerId"]),
        },
        {
            "spdxElementId": artifact_id,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": "SPDXRef-Package-Wirestack-Resolver",
        },
    ]
    for dependency in (
        "SPDXRef-Package-Cangjie-Runtime",
        "SPDXRef-Package-glibc",
        "SPDXRef-Package-libstdcxx",
        "SPDXRef-Package-libgcc",
    ):
        relationships.append(
            {
                "spdxElementId": artifact_id,
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": dependency,
            }
        )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Wirestack {manifest['package']['version']} Linux x86_64 glibc SBOM",
        "documentNamespace": (
            "https://github.com/lIlIIlIll/Wirestack/sbom/"
            f"{manifest['package']['version']}/{artifact['sha256']}"
        ),
        "creationInfo": {
            "created": CREATED_UTC,
            "creators": ["Tool: Wirestack M7-025 supply-chain generator"],
        },
        "documentDescribes": [artifact_id],
        "packages": packages,
        "relationships": relationships,
    }


def build_documents(
    artifact_path: Path,
    qualification: Mapping[str, Any],
    provider_pin: Mapping[str, Any],
    *,
    generator_sha256: str,
) -> dict[str, dict[str, Any]]:
    metadata = artifact_metadata(artifact_path)
    validate_artifact_inputs(metadata, qualification, provider_pin)
    inputs = fingerprint_inputs(metadata, qualification, generator_sha256)
    fingerprint = evidence_digest.text_evidence_bytes_sha256(canonical_json(inputs))
    fingerprint_document = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "algorithm": "SHA-256",
        "buildFingerprint": fingerprint,
        "inputs": inputs,
    }
    manifest = release_provider_manifest(metadata, qualification, fingerprint)
    sbom = spdx_document(metadata, qualification, manifest)
    documents: dict[str, dict[str, Any]] = {
        "provider-manifest.json": manifest,
        "sbom.spdx.json": sbom,
        "build-fingerprint.json": fingerprint_document,
    }
    file_digests = {
        name: {
            "sha256": evidence_digest.text_evidence_bytes_sha256(canonical_json(value)),
            "mediaType": "application/spdx+json" if name == "sbom.spdx.json" else "application/json",
        }
        for name, value in documents.items()
    }
    documents["bundle.json"] = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "decision": "PASS",
        "artifact": manifest["artifact"],
        "buildFingerprint": fingerprint,
        "documents": file_digests,
        "unsigned": True,
        "nonClaims": [
            "M7-030 owns signatures for the artifact and sidecars.",
            "This bundle applies only to Linux x86_64 glibc.",
            "Cangjie runtime and system libraries are dependencies, not bundled payloads.",
            "Wirestack does not depend on runtime or std source changes; upstream changes are optional future work.",
        ],
    }
    return documents


def write_documents(documents: Mapping[str, Mapping[str, Any]], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for name in OUTPUT_NAMES:
        _require(name in documents, f"generated document is absent: {name}")
        (output / name).write_bytes(canonical_json(documents[name]))


def _package_checksum(sbom: Mapping[str, Any], package_id: str) -> str:
    packages = sbom.get("packages")
    _require(isinstance(packages, list), "SPDX package inventory is absent")
    for package in packages:
        if isinstance(package, dict) and package.get("SPDXID") == package_id:
            checksums = package.get("checksums")
            _require(
                isinstance(checksums, list) and len(checksums) == 1,
                f"SPDX checksum is absent for {package_id}",
            )
            return checksums[0].get("checksumValue", "")
    raise SupplyChainError(f"SPDX package is absent: {package_id}")


def validate_documents(
    evidence_dir: Path = DEFAULT_OUTPUT,
    *,
    artifact_path: Path | None = None,
    qualification_path: Path = QUALIFICATION,
    provider_pin_path: Path = PROVIDER_PIN,
    generator_path: Path | None = None,
) -> dict[str, Any]:
    generator = generator_path or Path(__file__)
    qualification = load_json(qualification_path)
    provider_pin = load_json(provider_pin_path)
    documents = {name: load_json(evidence_dir / name) for name in OUTPUT_NAMES}
    manifest = documents["provider-manifest.json"]
    sbom = documents["sbom.spdx.json"]
    fingerprint = documents["build-fingerprint.json"]
    bundle = documents["bundle.json"]
    _require(manifest.get("taskId") == TASK_ID, "provider manifest task identity is invalid")
    _require(fingerprint.get("taskId") == TASK_ID, "fingerprint task identity is invalid")
    _require(bundle.get("taskId") == TASK_ID and bundle.get("decision") == "PASS", "bundle decision is invalid")
    expected_fingerprint = evidence_digest.text_evidence_bytes_sha256(
        canonical_json(fingerprint.get("inputs"))
    )
    _require(
        fingerprint.get("buildFingerprint") == expected_fingerprint,
        "build fingerprint does not match its canonical inputs",
    )
    _require(manifest.get("buildFingerprint") == expected_fingerprint, "manifest fingerprint mismatch")
    _require(bundle.get("buildFingerprint") == expected_fingerprint, "bundle fingerprint mismatch")
    _require(
        fingerprint.get("inputs", {}).get("generator", {}).get("sha256") == evidence_digest.text_evidence_sha256(generator),
        "generator fingerprint is stale",
    )
    qualified_artifact = qualification.get("artifact", {})
    _require(
        manifest.get("artifact", {}).get("sha256") == qualified_artifact.get("sha256"),
        "manifest is not bound to the M7-021 artifact",
    )
    artifact_id = "SPDXRef-Package-Wirestack-Artifact"
    provider_id = provider_spdx_id(provider_pin["provider_id"])
    resolver_id = "SPDXRef-Package-Wirestack-Resolver"
    dependency_ids = {
        "SPDXRef-Package-Cangjie-Runtime",
        "SPDXRef-Package-glibc",
        "SPDXRef-Package-libstdcxx",
        "SPDXRef-Package-libgcc",
    }
    required_package_ids = {artifact_id, provider_id, resolver_id} | dependency_ids
    packages = sbom.get("packages")
    _require(isinstance(packages, list), "SPDX package inventory is absent")
    package_ids = [package.get("SPDXID") for package in packages if isinstance(package, dict)]
    _require(len(package_ids) == len(set(package_ids)), "SPDX package ids are not unique")
    _require(set(package_ids) == required_package_ids, "SPDX package inventory is incomplete")
    _require(
        _package_checksum(sbom, artifact_id) == qualified_artifact.get("sha256"),
        "SPDX artifact digest mismatch",
    )
    _require(sbom.get("spdxVersion") == "SPDX-2.3", "SPDX version is invalid")
    _require(sbom.get("documentDescribes") == [artifact_id], "SPDX subject is invalid")
    provider = manifest.get("provider", {})
    _require(provider.get("providerId") == provider_pin.get("provider_id"), "provider id differs from pin")
    _require(provider.get("providerVersion") == provider_pin.get("provider_version"), "provider version differs from pin")
    _require(provider.get("source") == provider_pin.get("source"), "provider source differs from pin")
    _require(provider.get("licenseExpression") == provider_pin.get("license_expression"), "provider license differs from pin")
    _require(provider.get("securityPatchLevel") == "abi-1;patches=none", "patch level is incomplete")
    _require(provider.get("externalOpenSslDependency") is False, "OpenSSL dependency flag is invalid")
    _require(
        _package_checksum(sbom, provider_id) == provider.get("archive", {}).get("sha256"),
        "SPDX provider digest mismatch",
    )
    _require(
        _package_checksum(sbom, resolver_id)
        == manifest.get("resolver", {}).get("archive", {}).get("sha256"),
        "SPDX resolver digest mismatch",
    )
    relationships = sbom.get("relationships")
    _require(isinstance(relationships, list), "SPDX relationship inventory is absent")
    relationship_tuples = {
        (
            relationship.get("spdxElementId"),
            relationship.get("relationshipType"),
            relationship.get("relatedSpdxElement"),
        )
        for relationship in relationships
        if isinstance(relationship, dict)
    }
    expected_relationships = {
        ("SPDXRef-DOCUMENT", "DESCRIBES", artifact_id),
        (artifact_id, "CONTAINS", provider_id),
        (artifact_id, "CONTAINS", resolver_id),
    } | {(artifact_id, "DEPENDS_ON", dependency_id) for dependency_id in dependency_ids}
    _require(
        relationship_tuples == expected_relationships,
        "SPDX relationships are incomplete or contain unknown entries",
    )
    _require(manifest.get("features") == FEATURES, "feature inventory is incomplete or reordered")
    _require(manifest.get("trust", {}).get("policies") == TRUST_POLICIES, "trust policy inventory is incomplete")
    for name in OUTPUT_NAMES[:-1]:
        expected = bundle.get("documents", {}).get(name, {}).get("sha256")
        _require(expected == evidence_digest.text_evidence_sha256(evidence_dir / name), f"bundle digest mismatch for {name}")
    serialized = canonical_json(documents).decode("utf-8")
    for forbidden in ("/home/", "Authorization", "privateKey", "sessionSecret"):
        _require(forbidden not in serialized, f"sensitive or host-local value appears in bundle: {forbidden}")
    if artifact_path is not None:
        expected_documents = build_documents(
            artifact_path,
            qualification,
            provider_pin,
            generator_sha256=evidence_digest.text_evidence_sha256(generator),
        )
        for name in OUTPUT_NAMES:
            _require(documents[name] == expected_documents[name], f"committed {name} is stale")
    return bundle


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, default=DEFAULT_ARTIFACT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--allow-missing-artifact", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.validate_only:
            artifact = args.artifact if args.artifact.is_file() else None
            if artifact is None and not args.allow_missing_artifact:
                raise SupplyChainError(f"release artifact is absent: {args.artifact}")
            bundle = validate_documents(args.output_dir, artifact_path=artifact)
        else:
            qualification = load_json(QUALIFICATION)
            provider_pin = load_json(PROVIDER_PIN)
            documents = build_documents(
                args.artifact,
                qualification,
                provider_pin,
                generator_sha256=evidence_digest.text_evidence_sha256(Path(__file__)),
            )
            write_documents(documents, args.output_dir)
            bundle = validate_documents(args.output_dir, artifact_path=args.artifact)
    except SupplyChainError as error:
        print(f"M7-025 Linux supply-chain bundle: FAIL: {error}")
        return 1
    print(
        "M7-025 Linux supply-chain bundle: PASS\n"
        f"artifact_sha256={bundle['artifact']['sha256']}\n"
        f"build_fingerprint={bundle['buildFingerprint']}\n"
        f"output={args.output_dir}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
