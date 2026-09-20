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
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import m7_021_linux_release
from tools.tls_provider.selection import select_provider

PUBLIC_SUFFIX_FILES = m7_021_linux_release.PUBLIC_SUFFIX_FILES

SELECTED_PROVIDER = select_provider(ROOT)
TASK_ID = "M7-025"
SCHEMA_VERSION = 1
CREATED_UTC = "2026-08-28T00:00:00Z"
SUPPORTED_RELEASE_SCHEMA_VERSIONS = {1, 2}
HTTP_FILES_MANIFEST = "target/native/http_files/current/http-files-manifest.json"
HTTP_FILES_ARCHIVE = "target/native/http_files/current/lib/libwirestack_http_files.a"
HTTP_FILES_SPDX_ID = "SPDXRef-Package-Wirestack-HttpFiles"
PUBLIC_SUFFIX_SPDX_ID = "SPDXRef-Package-PublicSuffixList"
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


def _payload_bytes(payload: Mapping[str, bytes], relative: str) -> bytes:
    content = payload.get(relative)
    _require(isinstance(content, bytes), f"artifact must contain exactly one {relative}")
    return content


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
        payload, release = m7_021_linux_release.read_verified_payload(path)
    except (OSError, m7_021_linux_release.ReleaseError) as error:
        raise SupplyChainError(f"cannot inspect release artifact: {error}") from error

    provider_manifest_path = "target/native/current/provider-manifest.json"
    resolver_manifest_path = "target/native/resolver/current/resolver-manifest.json"
    provider_raw = _payload_bytes(payload, provider_manifest_path)
    resolver_raw = _payload_bytes(payload, resolver_manifest_path)
    provider = _json_bytes(provider_raw, provider_manifest_path)
    resolver = _json_bytes(resolver_raw, resolver_manifest_path)

    provider_archive_manifest = provider.get("archive")
    _require(isinstance(provider_archive_manifest, dict), "provider archive identity is absent")
    provider_archive_name = provider_archive_manifest.get("name")
    _require(
        provider_archive_name == "libwirestack_tls_provider.a",
        "provider archive name is invalid",
    )
    provider_archive_raw = _payload_bytes(
        payload, "target/native/current/lib/libwirestack_tls_provider.a"
    )
    provider_archive = {
        "name": provider_archive_name,
        "bytes": len(provider_archive_raw),
        "sha256": evidence_digest.artifact_bytes_sha256(provider_archive_raw),
    }

    resolver_archive_manifest = resolver.get("archive")
    _require(isinstance(resolver_archive_manifest, dict), "resolver archive identity is absent")
    resolver_archive_path = resolver_archive_manifest.get("path")
    _require(
        resolver_archive_path == "lib/libwirestack_resolver.a",
        "resolver archive path is invalid",
    )
    resolver_archive_raw = _payload_bytes(
        payload, "target/native/resolver/current/lib/libwirestack_resolver.a"
    )
    resolver_archive = {
        "path": resolver_archive_path,
        "bytes": len(resolver_archive_raw),
        "sha256": evidence_digest.artifact_bytes_sha256(resolver_archive_raw),
    }

    http_files_raw: bytes | None = None
    http_files_archive_raw: bytes | None = None
    public_suffix_files: dict[str, bytes] = {}
    if release.get("schema_version") == 2:
        http_files_raw = _payload_bytes(payload, HTTP_FILES_MANIFEST)
        http_files_archive_raw = _payload_bytes(payload, HTTP_FILES_ARCHIVE)
        public_suffix_files = {
            relative: _payload_bytes(payload, relative)
            for relative in PUBLIC_SUFFIX_FILES
        }
    license_files = {
        relative: _payload_bytes(payload, relative)
        for relative in LICENSE_MEMBERS
    }
    if public_suffix_files:
        license_files[PUBLIC_SUFFIX_FILES[0]] = public_suffix_files[PUBLIC_SUFFIX_FILES[0]]

    return {
        "artifact_sha256": evidence_digest.artifact_byte_sha256(path),
        "artifact_bytes": path.stat().st_size,
        "release": release,
        "provider": provider,
        "provider_manifest_sha256": evidence_digest.text_evidence_bytes_sha256(provider_raw),
        "provider_archive": provider_archive,
        "resolver": resolver,
        "resolver_manifest_sha256": evidence_digest.text_evidence_bytes_sha256(resolver_raw),
        "resolver_archive": resolver_archive,
        "http_files": (
            _json_bytes(http_files_raw, HTTP_FILES_MANIFEST)
            if http_files_raw is not None else None
        ),
        "http_files_manifest_sha256": (
            evidence_digest.text_evidence_bytes_sha256(http_files_raw)
            if http_files_raw is not None else None
        ),
        "http_files_manifest_bytes": (
            len(http_files_raw) if http_files_raw is not None else None
        ),
        "http_files_archive_sha256": (
            evidence_digest.artifact_bytes_sha256(http_files_archive_raw)
            if http_files_archive_raw is not None else None
        ),
        "http_files_archive_bytes": (
            len(http_files_archive_raw) if http_files_archive_raw is not None else None
        ),
        "public_suffix": (
            _json_bytes(public_suffix_files[PUBLIC_SUFFIX_FILES[2]], PUBLIC_SUFFIX_FILES[2])
            if public_suffix_files else None
        ),
        "public_suffix_payload": {
            relative: {
                "bytes": len(content),
                "sha256": evidence_digest.artifact_bytes_sha256(content),
            }
            for relative, content in public_suffix_files.items()
        },
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
    _require(
        evidence_digest.schema_artifact_sha256_equal(
            metadata["artifact_sha256"], artifact.get("sha256"),
        ),
        "artifact digest mismatch",
    )
    _require(metadata["artifact_bytes"] == artifact.get("bytes"), "artifact size mismatch")
    release = metadata["release"]
    provider = metadata["provider"]
    resolver = metadata["resolver"]
    release_schema = release.get("schema_version")
    _require(
        release_schema in SUPPORTED_RELEASE_SCHEMA_VERSIONS,
        "release manifest schema is unsupported",
    )
    _require(release.get("package") == "wirestack", "release package identity is invalid")
    _require(
        evidence_digest.schema_artifact_sha256_equal(
            release.get("payload_sha256"), artifact.get("payload_sha256"),
        ),
        "payload digest mismatch",
    )
    _require(release.get("externalOpenSslDependency") is False, "release depends on system OpenSSL")
    release_license = release.get("license")
    _require(isinstance(release_license, dict), "release license identity is absent")
    _require(
        release_license.get("expression") == PROJECT_LICENSE_EXPRESSION,
        "release license expression is invalid",
    )
    _require(release_license.get("file") == "LICENSE", "release license path is invalid")
    _require(
        evidence_digest.schema_text_sha256_equal(
            release_license.get("sha256"), metadata["license_sha256"]["LICENSE"],
        ),
        "embedded project license digest mismatch",
    )
    notices = release.get("thirdPartyNotices")
    _require(isinstance(notices, dict), "release third-party notices are absent")
    _require(notices.get("index") == "THIRD_PARTY_NOTICES.md", "notice index is invalid")
    expected_notice_files = [
        {"path": relative, "sha256": metadata["license_sha256"][relative]}
        for relative in (
            *LICENSE_MEMBERS[1:],
            *((PUBLIC_SUFFIX_FILES[0],) if release.get("schema_version") == 2 else ()),
        )
    ]
    notice_files = notices.get("files")
    _require(
        isinstance(notice_files, list)
        and len(notice_files) == len(expected_notice_files)
        and all(
            isinstance(actual, dict)
            and set(actual) == {"path", "sha256"}
            and actual.get("path") == expected["path"]
            and evidence_digest.schema_text_sha256_equal(
                actual.get("sha256"), expected["sha256"]
            )
            for actual, expected in zip(notice_files, expected_notice_files)
        ),
        "notice inventory mismatch",
    )
    _require(provider.get("externalOpenSslDependency") is False, "provider depends on system OpenSSL")
    _require(provider.get("runtimeLoaderLibraryStrings") == [], "provider has runtime loader strings")
    release_provider = release.get("provider")
    release_resolver = release.get("resolver")
    _require(isinstance(release_provider, dict), "release provider identity is absent")
    _require(isinstance(release_resolver, dict), "release resolver identity is absent")
    _require(
        evidence_digest.schema_text_sha256_equal(
            release_provider.get("manifest_sha256"), metadata["provider_manifest_sha256"],
        ),
        "embedded provider manifest digest mismatch",
    )
    provider_archive = provider.get("archive")
    actual_provider_archive = metadata["provider_archive"]
    _require(
        isinstance(provider_archive, dict)
        and provider_archive.get("name") == "libwirestack_tls_provider.a"
        and provider_archive.get("name") == actual_provider_archive["name"]
        and provider_archive.get("bytes") == actual_provider_archive["bytes"]
        and evidence_digest.schema_artifact_sha256_equal(
            provider_archive.get("sha256"), actual_provider_archive["sha256"],
        )
        and evidence_digest.schema_artifact_sha256_equal(
            release_provider.get("archive_sha256"), actual_provider_archive["sha256"],
        ),
        "embedded provider archive identity mismatch",
    )
    _require(
        evidence_digest.schema_text_sha256_equal(
            release_resolver.get("manifest_sha256"), metadata["resolver_manifest_sha256"],
        ),
        "embedded resolver manifest digest mismatch",
    )
    resolver_archive = resolver.get("archive")
    actual_resolver_archive = metadata["resolver_archive"]
    _require(
        isinstance(resolver_archive, dict)
        and resolver_archive.get("path") == "lib/libwirestack_resolver.a"
        and resolver_archive.get("path") == actual_resolver_archive["path"]
        and evidence_digest.schema_artifact_sha256_equal(
            resolver_archive.get("sha256"), actual_resolver_archive["sha256"],
        )
        and evidence_digest.schema_artifact_sha256_equal(
            release_resolver.get("archive_sha256"), actual_resolver_archive["sha256"],
        ),
        "embedded resolver archive identity mismatch",
    )
    if release_schema == 2:
        http_files = metadata.get("http_files")
        release_http_files = release.get("httpFiles")
        _require(isinstance(http_files, dict), "embedded HTTP files manifest is absent")
        _require(
            isinstance(release_http_files, dict),
            "release HTTP files identity is absent",
        )
        _require(
            http_files.get("schema_version") == 1
            and http_files.get("component") == "wirestack-http-files"
            and http_files.get("abi_version") == 1
            and http_files.get("private_runtime_abi") is False,
            "embedded HTTP files manifest identity is invalid",
        )
        http_files_inputs = http_files.get("inputs")
        _require(
            isinstance(http_files_inputs, dict)
            and evidence_digest.schema_text_sha256_equal(
                http_files.get("build_fingerprint"),
                evidence_digest.text_evidence_bytes_sha256(
                    canonical_json(http_files_inputs)
                ),
            ),
            "embedded HTTP files build fingerprint is invalid",
        )
        _require(
            release_http_files.get("component") == http_files.get("component")
            and release_http_files.get("abi_version") == http_files.get("abi_version")
            and release_http_files.get("build_fingerprint")
            == http_files.get("build_fingerprint"),
            "release and embedded HTTP files identities differ",
        )
        _require(
            evidence_digest.schema_text_sha256_equal(
                release_http_files.get("manifest_sha256"),
                metadata.get("http_files_manifest_sha256"),
            ),
            "embedded HTTP files manifest digest mismatch",
        )
        _require(
            evidence_digest.schema_artifact_sha256_equal(
                http_files.get("archive", {}).get("sha256"),
                metadata.get("http_files_archive_sha256"),
            )
            and http_files.get("archive", {}).get("bytes")
            == metadata.get("http_files_archive_bytes")
            and evidence_digest.schema_artifact_sha256_equal(
                release_http_files.get("archive_sha256"),
                metadata.get("http_files_archive_sha256"),
            ),
            "embedded HTTP files archive digest mismatch",
        )
        public_suffix = metadata.get("public_suffix")
        _require(isinstance(public_suffix, dict), "public suffix source identity is absent")
        _require(
            public_suffix.get("name") == "publicsuffix/list"
            and public_suffix.get("license") == "MPL-2.0"
            and public_suffix.get("upstream_repository") == "https://github.com/publicsuffix/list"
            and isinstance(public_suffix.get("upstream_revision"), str)
            and re.fullmatch(r"[0-9a-f]{40}", public_suffix["upstream_revision"]) is not None,
            "public suffix source identity is invalid",
        )
        suffix_payload = metadata["public_suffix_payload"]
        _require(
            evidence_digest.schema_artifact_sha256_equal(
                public_suffix.get("sha256"), suffix_payload[PUBLIC_SUFFIX_FILES[1]]["sha256"]
            ),
            "public suffix source digest mismatch",
        )
        _require(
            public_suffix.get("license_file") == "LICENSE.MPL-2.0"
            and evidence_digest.schema_artifact_sha256_equal(
                public_suffix.get("license_sha256"), suffix_payload[PUBLIC_SUFFIX_FILES[0]]["sha256"]
            ),
            "public suffix license digest mismatch",
        )
    else:
        _require(
            metadata.get("http_files") is None and release.get("httpFiles") is None,
            "legacy release schema contains an ambiguous HTTP files component",
        )
    qualified_release_schema = artifact.get("release_schema_version")
    _require(
        qualified_release_schema is None or qualified_release_schema == release_schema,
        "qualified release manifest schema differs from the artifact",
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
    native_components = {
        "tlsProvider": {
            "archiveName": metadata["provider_archive"]["name"],
            "archiveBytes": metadata["provider_archive"]["bytes"],
            "archiveSha256": metadata["provider_archive"]["sha256"],
            "embeddedManifestSha256": metadata["provider_manifest_sha256"],
            "providerBuildFingerprint": provider["build_fingerprint"],
            "sourceContentSha256": provider["source"]["content_sha256"],
        },
        "resolver": {
            "archivePath": metadata["resolver_archive"]["path"],
            "archiveBytes": metadata["resolver_archive"]["bytes"],
            "archiveSha256": metadata["resolver_archive"]["sha256"],
            "embeddedManifestSha256": metadata["resolver_manifest_sha256"],
            "buildFingerprint": resolver["build_fingerprint"],
        },
    }
    http_files = metadata.get("http_files")
    if isinstance(http_files, dict):
        native_components["httpFiles"] = {
            "archiveSha256": metadata["http_files_archive_sha256"],
            "embeddedManifestSha256": metadata["http_files_manifest_sha256"],
            "buildFingerprint": http_files["build_fingerprint"],
            "buildInputsSha256": evidence_digest.text_evidence_bytes_sha256(
                canonical_json(http_files["inputs"])
            ),
        }
    inputs = {
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
        "nativeComponents": native_components,
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
    public_suffix = metadata.get("public_suffix")
    if isinstance(public_suffix, dict):
        inputs["publicSuffix"] = {
            "name": public_suffix["name"],
            "upstreamRepository": public_suffix["upstream_repository"],
            "upstreamRevision": public_suffix["upstream_revision"],
            "sha256": public_suffix["sha256"],
            "licenseExpression": public_suffix["license"],
            "licenseSha256": public_suffix["license_sha256"],
        }
    return inputs


def release_provider_manifest(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    build_fingerprint: str,
    *,
    task_id: str,
) -> dict[str, Any]:
    release = metadata["release"]
    provider = metadata["provider"]
    resolver = metadata["resolver"]
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": task_id,
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
            "archive": metadata["provider_archive"],
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
            "archive": metadata["resolver_archive"],
            "embeddedManifestSha256": metadata["resolver_manifest_sha256"],
            "privateRuntimeAbi": resolver["private_runtime_abi"],
        },
        "target": {**qualification["platform"], "triple": _target_triple(qualification)},
        "features": FEATURES,
        "runtimeDependencies": qualification["dependency_scan"]["needed"],
    }
    http_files = metadata.get("http_files")
    if isinstance(http_files, dict):
        manifest["httpFiles"] = {
            "component": http_files["component"],
            "abiVersion": http_files["abi_version"],
            "buildFingerprint": http_files["build_fingerprint"],
            "archive": http_files["archive"],
            "embeddedManifestSha256": metadata["http_files_manifest_sha256"],
            "buildInputsSha256": evidence_digest.text_evidence_bytes_sha256(
                canonical_json(http_files["inputs"])
            ),
            "privateRuntimeAbi": http_files["private_runtime_abi"],
        }
    return manifest


def spdx_document(
    metadata: Mapping[str, Any],
    qualification: Mapping[str, Any],
    manifest: Mapping[str, Any],
    *,
    task_id: str,
    created_utc: str,
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
                    "referenceCategory": "OTHER",
                    "referenceType": "vcs",
                    "referenceLocator": (
                        "git+" + provider["source"]["url"] + "@"
                        + provider["source"]["commit"]
                    ),
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
    http_files = manifest.get("httpFiles")
    if isinstance(http_files, dict):
        packages.insert(
            3,
            {
                "name": "Wirestack native HTTP filesystem bridge",
                "SPDXID": HTTP_FILES_SPDX_ID,
                "versionInfo": manifest["package"]["version"],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "checksums": [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": http_files["archive"]["sha256"],
                    }
                ],
                "licenseConcluded": PROJECT_LICENSE_EXPRESSION,
                "licenseDeclared": PROJECT_LICENSE_EXPRESSION,
                "copyrightText": "NOASSERTION",
                "comment": (
                    f"build-fingerprint={http_files['buildFingerprint']}; "
                    f"embedded-manifest-sha256={http_files['embeddedManifestSha256']}"
                ),
            },
        )
    public_suffix = metadata.get("public_suffix")
    if isinstance(public_suffix, dict):
        packages.append(
            {
                "name": "Public Suffix List",
                "SPDXID": PUBLIC_SUFFIX_SPDX_ID,
                "versionInfo": public_suffix["upstream_revision"],
                "downloadLocation": (
                    public_suffix["upstream_repository"] + "/raw/"
                    + public_suffix["upstream_revision"] + "/public_suffix_list.dat"
                ),
                "filesAnalyzed": False,
                "checksums": [{"algorithm": "SHA256", "checksumValue": public_suffix["sha256"]}],
                "licenseConcluded": "MPL-2.0",
                "licenseDeclared": "MPL-2.0",
                "copyrightText": "NOASSERTION",
                "primaryPackagePurpose": "SOURCE",
            }
        )
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
    if isinstance(http_files, dict):
        relationships.append(
            {
                "spdxElementId": artifact_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": HTTP_FILES_SPDX_ID,
            }
        )
    if isinstance(public_suffix, dict):
        relationships.append(
            {
                "spdxElementId": artifact_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": PUBLIC_SUFFIX_SPDX_ID,
            }
        )
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
            "created": created_utc,
            "creators": [f"Tool: Wirestack {task_id} supply-chain generator"],
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
    task_id: str = TASK_ID,
    created_utc: str = CREATED_UTC,
) -> dict[str, dict[str, Any]]:
    metadata = artifact_metadata(artifact_path)
    validate_artifact_inputs(metadata, qualification, provider_pin)
    inputs = fingerprint_inputs(metadata, qualification, generator_sha256)
    fingerprint = evidence_digest.text_evidence_bytes_sha256(canonical_json(inputs))
    fingerprint_document = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": task_id,
        "algorithm": "SHA-256",
        "buildFingerprint": fingerprint,
        "inputs": inputs,
    }
    manifest = release_provider_manifest(
        metadata, qualification, fingerprint, task_id=task_id
    )
    sbom = spdx_document(
        metadata,
        qualification,
        manifest,
        task_id=task_id,
        created_utc=created_utc,
    )
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
        "taskId": task_id,
        "decision": "PASS",
        "artifact": manifest["artifact"],
        "buildFingerprint": fingerprint,
        "documents": file_digests,
        "unsigned": True,
        "nonClaims": [
            "Artifact and sidecar signatures are a separate release gate.",
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


def _spdx_package(
    sbom: Mapping[str, Any], package_id: str
) -> Mapping[str, Any]:
    packages = sbom.get("packages")
    _require(isinstance(packages, list), "SPDX package inventory is absent")
    for package in packages:
        if isinstance(package, dict) and package.get("SPDXID") == package_id:
            return package
    raise SupplyChainError(f"SPDX package is absent: {package_id}")


def _package_checksum(sbom: Mapping[str, Any], package_id: str) -> str:
    package = _spdx_package(sbom, package_id)
    checksums = package.get("checksums")
    _require(
        isinstance(checksums, list)
        and len(checksums) == 1
        and isinstance(checksums[0], dict)
        and checksums[0].get("algorithm") == "SHA256",
        f"SPDX SHA256 checksum is absent for {package_id}",
    )
    return checksums[0].get("checksumValue", "")


def validate_documents(
    evidence_dir: Path = DEFAULT_OUTPUT,
    *,
    artifact_path: Path | None = None,
    qualification_path: Path = QUALIFICATION,
    provider_pin_path: Path = PROVIDER_PIN,
    generator_path: Path | None = None,
    task_id: str = TASK_ID,
    created_utc: str = CREATED_UTC,
) -> dict[str, Any]:
    generator = generator_path or Path(__file__)
    qualification = load_json(qualification_path)
    provider_pin = load_json(provider_pin_path)
    documents = {name: load_json(evidence_dir / name) for name in OUTPUT_NAMES}
    manifest = documents["provider-manifest.json"]
    sbom = documents["sbom.spdx.json"]
    fingerprint = documents["build-fingerprint.json"]
    bundle = documents["bundle.json"]
    _require(manifest.get("taskId") == task_id, "provider manifest task identity is invalid")
    _require(fingerprint.get("taskId") == task_id, "fingerprint task identity is invalid")
    _require(
        bundle.get("taskId") == task_id and bundle.get("decision") == "PASS",
        "bundle decision is invalid",
    )
    _require(
        sbom.get("creationInfo")
        == {
            "created": created_utc,
            "creators": [f"Tool: Wirestack {task_id} supply-chain generator"],
        },
        "SPDX creation metadata is invalid",
    )
    expected_fingerprint = evidence_digest.text_evidence_bytes_sha256(
        canonical_json(fingerprint.get("inputs"))
    )
    _require(
        evidence_digest.schema_text_sha256_equal(
            fingerprint.get("buildFingerprint"), expected_fingerprint,
        ),
        "build fingerprint does not match its canonical inputs",
    )
    _require(
        evidence_digest.schema_text_sha256_equal(
            manifest.get("buildFingerprint"), expected_fingerprint,
        ),
        "manifest fingerprint mismatch",
    )
    _require(
        evidence_digest.schema_text_sha256_equal(
            bundle.get("buildFingerprint"), expected_fingerprint,
        ),
        "bundle fingerprint mismatch",
    )
    _require(
        evidence_digest.schema_text_sha256_equal(
            fingerprint.get("inputs", {}).get("generator", {}).get("sha256"),
            evidence_digest.text_evidence_sha256(generator),
        ),
        "generator fingerprint is stale",
    )
    qualified_artifact = qualification.get("artifact", {})
    _require(
        evidence_digest.schema_artifact_sha256_equal(
            manifest.get("artifact", {}).get("sha256"), qualified_artifact.get("sha256"),
        ),
        "manifest is not bound to the M7-021 artifact",
    )
    artifact_id = "SPDXRef-Package-Wirestack-Artifact"
    provider_id = provider_spdx_id(provider_pin["provider_id"])
    resolver_id = "SPDXRef-Package-Wirestack-Resolver"
    http_files = manifest.get("httpFiles")
    fingerprint_http_files = (
        fingerprint.get("inputs", {}).get("nativeComponents", {}).get("httpFiles")
    )
    fingerprint_public_suffix = fingerprint.get("inputs", {}).get("publicSuffix")
    _require(
        (http_files is None and fingerprint_http_files is None)
        or (isinstance(http_files, dict) and isinstance(fingerprint_http_files, dict)),
        "HTTP files supply-chain inventory is inconsistent",
    )
    qualified_release_schema = qualified_artifact.get("release_schema_version")
    _require(
        qualified_release_schema in {None, 1, 2},
        "qualified release manifest schema is unsupported",
    )
    if qualified_release_schema == 2:
        _require(
            isinstance(http_files, dict)
            and isinstance(fingerprint_http_files, dict)
            and isinstance(fingerprint_public_suffix, dict),
            "qualified release requires the HTTP files and public suffix supply-chain inventories",
        )
    elif qualified_release_schema == 1:
        _require(
            fingerprint_public_suffix is None,
            "legacy release contains an ambiguous public suffix supply-chain inventory",
        )
    dependency_ids = {
        "SPDXRef-Package-Cangjie-Runtime",
        "SPDXRef-Package-glibc",
        "SPDXRef-Package-libstdcxx",
        "SPDXRef-Package-libgcc",
    }
    required_package_ids = {artifact_id, provider_id, resolver_id} | dependency_ids
    if isinstance(http_files, dict):
        required_package_ids.add(HTTP_FILES_SPDX_ID)
    if isinstance(fingerprint_public_suffix, dict):
        required_package_ids.add(PUBLIC_SUFFIX_SPDX_ID)
    packages = sbom.get("packages")
    _require(isinstance(packages, list), "SPDX package inventory is absent")
    package_ids = [package.get("SPDXID") for package in packages if isinstance(package, dict)]
    _require(len(package_ids) == len(set(package_ids)), "SPDX package ids are not unique")
    _require(set(package_ids) == required_package_ids, "SPDX package inventory is incomplete")
    _require(
        evidence_digest.schema_artifact_sha256_equal(
            _package_checksum(sbom, artifact_id), qualified_artifact.get("sha256"),
        ),
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
        evidence_digest.schema_artifact_sha256_equal(
            _package_checksum(sbom, provider_id), provider.get("archive", {}).get("sha256"),
        ),
        "SPDX provider digest mismatch",
    )
    provider_source = provider.get("source", {})
    _require(
        _spdx_package(sbom, provider_id).get("externalRefs")
        == [
            {
                "referenceCategory": "OTHER",
                "referenceType": "vcs",
                "referenceLocator": (
                    "git+" + provider_source.get("url", "") + "@"
                    + provider_source.get("commit", "")
                ),
            }
        ],
        "SPDX provider source reference is invalid",
    )
    _require(
        evidence_digest.schema_artifact_sha256_equal(
            _package_checksum(sbom, resolver_id),
            manifest.get("resolver", {}).get("archive", {}).get("sha256"),
        ),
        "SPDX resolver digest mismatch",
    )
    native_components = fingerprint.get("inputs", {}).get("nativeComponents", {})
    fingerprint_provider = native_components.get("tlsProvider", {})
    fingerprint_resolver = native_components.get("resolver", {})
    provider_archive = provider.get("archive", {})
    resolver_archive = manifest.get("resolver", {}).get("archive", {})
    _require(
        fingerprint_provider.get("archiveName") == provider_archive.get("name")
        and fingerprint_provider.get("archiveBytes") == provider_archive.get("bytes")
        and evidence_digest.schema_artifact_sha256_equal(
            fingerprint_provider.get("archiveSha256"), provider_archive.get("sha256"),
        )
        and evidence_digest.schema_text_sha256_equal(
            fingerprint_provider.get("embeddedManifestSha256"),
            provider.get("embeddedManifestSha256"),
        )
        and fingerprint_provider.get("providerBuildFingerprint")
        == provider.get("providerBuildFingerprint"),
        "provider archive fingerprint inputs differ from the manifest",
    )
    _require(
        fingerprint_resolver.get("archivePath") == resolver_archive.get("path")
        and fingerprint_resolver.get("archiveBytes") == resolver_archive.get("bytes")
        and evidence_digest.schema_artifact_sha256_equal(
            fingerprint_resolver.get("archiveSha256"), resolver_archive.get("sha256"),
        )
        and evidence_digest.schema_text_sha256_equal(
            fingerprint_resolver.get("embeddedManifestSha256"),
            manifest.get("resolver", {}).get("embeddedManifestSha256"),
        )
        and fingerprint_resolver.get("buildFingerprint")
        == manifest.get("resolver", {}).get("buildFingerprint"),
        "resolver archive fingerprint inputs differ from the manifest",
    )
    if isinstance(http_files, dict):
        _require(
            http_files.get("component") == "wirestack-http-files"
            and http_files.get("abiVersion") == 1
            and http_files.get("privateRuntimeAbi") is False,
            "HTTP files manifest identity is invalid",
        )
        _require(
            evidence_digest.schema_artifact_sha256_equal(
                _package_checksum(sbom, HTTP_FILES_SPDX_ID),
                http_files.get("archive", {}).get("sha256"),
            ),
            "SPDX HTTP files digest mismatch",
        )
        _require(
            evidence_digest.schema_artifact_sha256_equal(
                fingerprint_http_files.get("archiveSha256"),
                http_files.get("archive", {}).get("sha256"),
            )
            and evidence_digest.schema_text_sha256_equal(
                fingerprint_http_files.get("embeddedManifestSha256"),
                http_files.get("embeddedManifestSha256"),
            )
            and fingerprint_http_files.get("buildFingerprint")
            == http_files.get("buildFingerprint")
            and evidence_digest.schema_text_sha256_equal(
                fingerprint_http_files.get("buildInputsSha256"),
                http_files.get("buildInputsSha256"),
            ),
            "HTTP files fingerprint inputs differ from the manifest",
        )
    if isinstance(fingerprint_public_suffix, dict):
        public_suffix_package = _spdx_package(sbom, PUBLIC_SUFFIX_SPDX_ID)
        _require(
            public_suffix_package.get("name") == "Public Suffix List"
            and public_suffix_package.get("versionInfo")
            == fingerprint_public_suffix.get("upstreamRevision")
            and public_suffix_package.get("downloadLocation")
            == (
                fingerprint_public_suffix.get("upstreamRepository", "")
                + "/raw/"
                + fingerprint_public_suffix.get("upstreamRevision", "")
                + "/public_suffix_list.dat"
            )
            and public_suffix_package.get("licenseDeclared") == "MPL-2.0"
            and public_suffix_package.get("licenseConcluded") == "MPL-2.0"
            and public_suffix_package.get("primaryPackagePurpose") == "SOURCE"
            and fingerprint_public_suffix.get("name") == "publicsuffix/list"
            and fingerprint_public_suffix.get("licenseExpression") == "MPL-2.0"
            and evidence_digest.schema_artifact_sha256_equal(
                _package_checksum(sbom, PUBLIC_SUFFIX_SPDX_ID),
                fingerprint_public_suffix.get("sha256"),
            ),
            "SPDX public suffix package is invalid",
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
    if isinstance(http_files, dict):
        expected_relationships.add(
            (artifact_id, "CONTAINS", HTTP_FILES_SPDX_ID)
        )
    if isinstance(fingerprint_public_suffix, dict):
        expected_relationships.add(
            (artifact_id, "CONTAINS", PUBLIC_SUFFIX_SPDX_ID)
        )
    _require(
        relationship_tuples == expected_relationships,
        "SPDX relationships are incomplete or contain unknown entries",
    )
    _require(manifest.get("features") == FEATURES, "feature inventory is incomplete or reordered")
    _require(manifest.get("trust", {}).get("policies") == TRUST_POLICIES, "trust policy inventory is incomplete")
    for name in OUTPUT_NAMES[:-1]:
        expected = bundle.get("documents", {}).get(name, {}).get("sha256")
        _require(
            evidence_digest.schema_text_sha256_equal(
                expected, evidence_digest.text_evidence_sha256(evidence_dir / name)
            ),
            f"bundle digest mismatch for {name}",
        )
    serialized = canonical_json(documents).decode("utf-8")
    for forbidden in ("/home/", "Authorization", "privateKey", "sessionSecret"):
        _require(forbidden not in serialized, f"sensitive or host-local value appears in bundle: {forbidden}")
    if artifact_path is not None:
        expected_documents = build_documents(
            artifact_path,
            qualification,
            provider_pin,
            generator_sha256=evidence_digest.text_evidence_sha256(generator),
            task_id=task_id,
            created_utc=created_utc,
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
    except (SupplyChainError, evidence_digest.DigestError) as error:
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
