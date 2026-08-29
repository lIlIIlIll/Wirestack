from __future__ import annotations

import copy
import gzip
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

from tools import m7_025_linux_supply_chain as supply


class M7025LinuxSupplyChainTest(unittest.TestCase):
    def test_committed_bundle_is_current(self) -> None:
        artifact = supply.DEFAULT_ARTIFACT if supply.DEFAULT_ARTIFACT.is_file() else None
        bundle = supply.validate_documents(artifact_path=artifact)
        self.assertEqual("PASS", bundle["decision"])

    def test_fingerprint_is_stable_and_dependency_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact, qualification, _ = self.fixture(Path(temporary))
            metadata = supply.artifact_metadata(artifact)
            inputs = supply.fingerprint_inputs(metadata, qualification, "f" * 64)
            first = supply.sha256_bytes(supply.canonical_json(inputs))
            second = supply.sha256_bytes(supply.canonical_json(copy.deepcopy(inputs)))
            self.assertEqual(first, second)

            changes = (
                ("artifact", "sha256"),
                ("nativeComponents", "tlsProvider", "archiveSha256"),
                ("nativeComponents", "tlsProvider", "sourceContentSha256"),
                ("nativeComponents", "resolver", "archiveSha256"),
                ("nativeComponents", "resolver", "buildFingerprint"),
            )
            for path in changes:
                changed = copy.deepcopy(inputs)
                node = changed
                for key in path[:-1]:
                    node = node[key]
                node[path[-1]] = "d" * 64
                self.assertNotEqual(
                    first,
                    supply.sha256_bytes(supply.canonical_json(changed)),
                    msg="fingerprint ignored " + ".".join(path),
                )

    def test_artifact_digest_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact, qualification, provider_pin = self.fixture(root)
            qualification["artifact"]["sha256"] = "0" * 64
            metadata = supply.artifact_metadata(artifact)
            with self.assertRaisesRegex(supply.SupplyChainError, "artifact digest mismatch"):
                supply.validate_artifact_inputs(metadata, qualification, provider_pin)

    def test_generation_is_byte_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact, qualification, provider_pin = self.fixture(Path(temporary))
            first = supply.build_documents(
                artifact, qualification, provider_pin, generator_sha256="f" * 64
            )
            second = supply.build_documents(
                artifact, qualification, provider_pin, generator_sha256="f" * 64
            )
            self.assertEqual(
                {name: supply.canonical_json(value) for name, value in first.items()},
                {name: supply.canonical_json(value) for name, value in second.items()},
            )

    def test_project_and_resolver_sbom_packages_use_apache_2_0(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact, qualification, provider_pin = self.fixture(Path(temporary))
            documents = supply.build_documents(
                artifact, qualification, provider_pin, generator_sha256="f" * 64
            )
            packages = {
                package["SPDXID"]: package
                for package in documents["sbom.spdx.json"]["packages"]
            }
            for package_id in (
                "SPDXRef-Package-Wirestack-Artifact",
                "SPDXRef-Package-Wirestack-Resolver",
            ):
                self.assertEqual("Apache-2.0", packages[package_id]["licenseDeclared"])
                self.assertEqual("Apache-2.0", packages[package_id]["licenseConcluded"])

    def test_wrong_project_license_expression_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact, qualification, provider_pin = self.fixture(
                Path(temporary), license_expression="MIT"
            )
            metadata = supply.artifact_metadata(artifact)
            with self.assertRaisesRegex(
                supply.SupplyChainError, "release license expression is invalid"
            ):
                supply.validate_artifact_inputs(metadata, qualification, provider_pin)

    def fixture(self, root: Path, *, license_expression: str = "Apache-2.0"):
        provider_pin = supply.load_json(supply.PROVIDER_PIN)
        provider = {
            "abiVersion": 1,
            "archive": {"bytes": 3, "name": "libprovider.a", "sha256": "1" * 64},
            "backend": "aws-lc-static",
            "build_fingerprint": "2" * 64,
            "build_inputs": {"provider": provider_pin},
            "capabilities": provider_pin["capabilities"],
            "externalOpenSslDependency": False,
            "patchLevel": "abi-1;patches=none",
            "providerId": provider_pin["provider_id"],
            "providerVersion": provider_pin["provider_version"],
            "runtimeLoaderLibraryStrings": [],
            "source": provider_pin["source"],
        }
        resolver = {
            "archive": {"path": "libresolver.a", "sha256": "3" * 64},
            "build_fingerprint": "4" * 64,
            "private_runtime_abi": False,
            "worker_model": "fixed bounded worker pool",
        }
        provider_raw = supply.canonical_json(provider)
        resolver_raw = supply.canonical_json(resolver)
        release = {
            "schema_version": 1,
            "package": "wirestack",
            "version": "0.1.0",
            "payload_sha256": "5" * 64,
            "externalOpenSslDependency": False,
            "license": {
                "expression": license_expression,
                "file": "LICENSE",
                "sha256": supply.sha256_bytes(b"project license\n"),
            },
            "thirdPartyNotices": {
                "index": "THIRD_PARTY_NOTICES.md",
                "files": [
                    {"path": "THIRD_PARTY_NOTICES.md", "sha256": supply.sha256_bytes(b"notices\n")},
                    {"path": "third_party/aws-lc/LICENSE", "sha256": supply.sha256_bytes(b"aws license\n")},
                    {"path": "third_party/aws-lc/NOTICE", "sha256": supply.sha256_bytes(b"aws notice\n")},
                ],
            },
            "provider": {
                "archive_sha256": provider["archive"]["sha256"],
                "manifest_sha256": supply.sha256_bytes(provider_raw),
            },
            "resolver": {
                "archive_sha256": resolver["archive"]["sha256"],
                "manifest_sha256": supply.sha256_bytes(resolver_raw),
            },
            "target": {
                "os": "linux",
                "architecture": "x86_64",
                "libc": "glibc",
                "libc_version": "2.44",
            },
        }
        artifact = root / "wirestack.tar.gz"
        members = {
            "wirestack/release-manifest.json": supply.canonical_json(release),
            "wirestack/LICENSE": b"project license\n",
            "wirestack/THIRD_PARTY_NOTICES.md": b"notices\n",
            "wirestack/third_party/aws-lc/LICENSE": b"aws license\n",
            "wirestack/third_party/aws-lc/NOTICE": b"aws notice\n",
            "wirestack/target/native/current/provider-manifest.json": provider_raw,
            "wirestack/target/native/resolver/current/resolver-manifest.json": resolver_raw,
        }
        with artifact.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for name, value in sorted(members.items()):
                        info = tarfile.TarInfo(name)
                        info.size = len(value)
                        info.mtime = 0
                        archive.addfile(info, io.BytesIO(value))
        qualification = {
            "artifact": {
                "name": artifact.name,
                "bytes": artifact.stat().st_size,
                "sha256": supply.sha256_path(artifact),
                "payload_sha256": release["payload_sha256"],
            },
            "runtime": {"providerBuildFingerprint": provider["build_fingerprint"]},
            "platform": release["target"],
            "toolchain": {
                "cjc": [
                    "Cangjie Compiler: 1.1.0-alpha.test (cjnative)",
                    "Target: x86_64-unknown-linux-gnu",
                ],
                "cjpm": ["Cangjie Project Manager: test"],
            },
            "dependency_scan": {
                "needed": ["libboundscheck.so", "libcangjie-runtime.so", "libc.so.6"]
            },
        }
        return artifact, qualification, provider_pin


if __name__ == "__main__":
    unittest.main()
