from __future__ import annotations

import copy
import gzip
import io
import json
import os
import tarfile
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from tools import m7_030_linux_release as release


class M7030LinuxReleaseTest(unittest.TestCase):
    def key(self, root: Path, name: str = "release", kind: str = "ed25519") -> Path:
        private = root / name
        result = release._run([
            "ssh-keygen", "-q", "-t", kind, "-N", "", "-f", str(private)
        ])
        self.assertEqual(0, result.returncode)
        return private

    def test_current_inputs_build_strict_deterministic_manifest(self) -> None:
        first = release.build_release_manifest()
        second = release.build_release_manifest()
        self.assertEqual(release.canonical_json(first), release.canonical_json(second))
        self.assertEqual("c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee",
                         first["subjects"][0]["sha256"])
        self.assertEqual(["artifact", "sbom"], [item["name"] for item in first["subjects"]])

    def test_missing_or_stale_supply_chain_input_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("provider-manifest.json", "sbom.spdx.json",
                         "build-fingerprint.json", "bundle.json"):
                (root / name).write_bytes((release.SUPPLY_CHAIN / name).read_bytes())
            bundle = release.load_json(root / "bundle.json")
            bundle["documents"]["sbom.spdx.json"]["sha256"] = "0" * 64
            (root / "bundle.json").write_bytes(release.canonical_json(bundle))
            with self.assertRaisesRegex(release.ReleaseError, "SUPPLY_CHAIN_STALE"):
                release.build_release_manifest(supply_chain=root)
            (root / "provider-manifest.json").unlink()
            with self.assertRaisesRegex(release.ReleaseError, "JSON_INVALID"):
                release.build_release_manifest(supply_chain=root)

    def test_json_duplicates_unknown_schema_paths_and_subjects_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":2}', encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "JSON_DUPLICATE"):
                release.load_json(path)
        manifest = release.build_release_manifest()
        unknown = copy.deepcopy(manifest)
        unknown["unknown"] = True
        with self.assertRaisesRegex(release.ReleaseError, "MANIFEST_SCHEMA"):
            release.validate_release_manifest(unknown)
        escaped = copy.deepcopy(manifest)
        escaped["subjects"][0]["path"] = "../artifact"
        with self.assertRaisesRegex(release.ReleaseError, "PATH_UNSAFE"):
            release.validate_release_manifest(escaped)
        duplicate = copy.deepcopy(manifest)
        duplicate["subjects"][1]["name"] = "artifact"
        with self.assertRaisesRegex(release.ReleaseError, "MANIFEST_SUBJECT"):
            release.validate_release_manifest(duplicate)

    def test_key_type_identity_and_location_fail_closed_without_secret_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = self.key(root, "good")
            wrong = self.key(root, "wrong")
            rsa = self.key(root, "rsa", "rsa")
            output = root / "output"
            with self.assertRaisesRegex(release.ReleaseError, "SIGNING_KEY_MISMATCH"):
                release.validate_signing_key(good, wrong.with_suffix(".pub"), output)
            with self.assertRaisesRegex(release.ReleaseError, "SIGNING_KEY_TYPE"):
                release.validate_signing_key(rsa, rsa.with_suffix(".pub"), output)
            with self.assertRaisesRegex(release.ReleaseError, "SIGNING_KEY_LOCATION"):
                release.validate_signing_key(release.ROOT / "LICENSE", good.with_suffix(".pub"), output)

    def test_offline_rehearsal_verifies_and_all_subject_or_signature_mutations_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = self.key(root)
            output = root / "signed"
            index = release.create_offline_bundle(
                private, private.with_suffix(".pub"), output, allow_temporary_key=True
            )
            self.assertEqual("REHEARSAL", index["classification"])
            public = output / "release-signing-key.pub"
            self.assertEqual("PASS", release.verify_offline_bundle(output, public)["decision"])

            artifact = root / release.ARTIFACT.name
            artifact.write_bytes(release.ARTIFACT.read_bytes() + b"x")
            with self.assertRaises(release.ReleaseError):
                release.verify_offline_bundle(output, public, artifact=artifact)
            sbom = root / "sbom.spdx.json"
            sbom.write_bytes(release.SBOM.read_bytes() + b" ")
            with self.assertRaises(release.ReleaseError):
                release.verify_offline_bundle(output, public, sbom=sbom)
            manifest_path = output / "release-manifest.json"
            original_manifest = manifest_path.read_bytes()
            manifest = release.load_json(manifest_path)
            manifest["release"]["version"] = "tampered"
            manifest_path.write_bytes(release.canonical_json(manifest))
            with self.assertRaisesRegex(release.ReleaseError, "SIGNATURE_INVALID"):
                release.verify_offline_bundle(output, public)
            manifest_path.write_bytes(original_manifest)

            for name in ("artifact", "sbom", "release-manifest"):
                signature = output / f"{name}.sig"
                original = signature.read_bytes()
                mutation = len(original) // 2
                signature.write_bytes(
                    original[:mutation] + bytes([original[mutation] ^ 1]) + original[mutation + 1:]
                )
                with self.assertRaisesRegex(release.ReleaseError, "SIGNATURE_INVALID"):
                    release.verify_offline_bundle(output, public)
                signature.write_bytes(original)

    def test_atomic_report_failure_preserves_previous_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b"previous\n")
            def fail_replace(_source: Path, _target: Path) -> None:
                raise OSError("injected")
            with self.assertRaises(OSError):
                release.atomic_json(path, {"decision": "PASS"}, replace=fail_replace)
            self.assertEqual(b"previous\n", path.read_bytes())
            self.assertEqual([], list(path.parent.glob(f".{path.name}.*")))

    def archive(self, path: Path, members: list[tuple[str, bytes, str]]) -> None:
        with path.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for name, value, kind in members:
                        info = tarfile.TarInfo(name)
                        info.size = len(value)
                        if kind == "symlink":
                            info.type = tarfile.SYMTYPE
                            info.linkname = "../../escape"
                            info.size = 0
                        archive.addfile(info, io.BytesIO(value) if info.isfile() else None)

    def test_clean_consumer_and_malicious_archives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            extracted = release.safe_extract(release.ARTIFACT, root / "consumer")
            self.assertTrue((extracted / "release-manifest.json").is_file())
            cases = (
                [("../escape", b"x", "file")],
                [("/absolute", b"x", "file")],
                [("wirestack-0.1.0/link", b"", "symlink")],
                [("wirestack-0.1.0/a", b"x", "file"), ("other/b", b"y", "file")],
                [("wirestack-0.1.0/test_tls_provider.cj", b"x", "file")],
                [("wirestack-0.1.0/private-key.pem", b"x", "file")],
            )
            for index, members in enumerate(cases):
                archive = root / f"unsafe-{index}.tar.gz"
                self.archive(archive, members)
                destination = root / f"unsafe-{index}"
                with self.assertRaises(release.ReleaseError, msg=str(members)):
                    release.safe_extract(archive, destination)
                self.assertFalse((root / "escape").exists())

    def signed_update_fixture(self, root: Path):
        private = self.key(root)
        public = release.public_key(private)
        installed = {
            "sequence": 1, "providerId": "aws-lc", "providerVersion": "5.5.0",
            "providerArchiveSha256": "1" * 64, "providerManifestSha256": "2" * 64,
            "sbomSha256": "3" * 64,
        }
        candidate = {**installed, "sequence": 2, "providerVersion": "5.5.1",
                     "providerArchiveSha256": "4" * 64,
                     "providerManifestSha256": "5" * 64}
        sbom = {
            "packages": [{"SPDXID": "SPDXRef-Package-TlsProvider-aws-lc",
                          "versionInfo": "5.5.1",
                          "checksums": [{"algorithm": "SHA256", "checksumValue": "4" * 64}]}]
        }
        candidate["sbomSha256"] = release.sha256_bytes(release.canonical_json(sbom))
        advisory = {
            "schemaVersion": 1, "advisoryId": "WSA-TEST", "severity": "HIGH",
            "issuedUtc": "2026-01-01T00:00:00Z", "expiresUtc": "2099-01-01T00:00:00Z",
            "fromManifestSha256": installed["providerManifestSha256"],
            "toManifestSha256": candidate["providerManifestSha256"],
            "toSbomSha256": candidate["sbomSha256"], "summary": "test",
        }
        signature = root / "advisory.sig"
        release.sign_bytes(private, release.canonical_json(advisory), signature)
        return private, public, installed, candidate, sbom, advisory, signature

    def test_upgrade_requires_matching_signed_advisory_and_sbom(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.signed_update_fixture(Path(directory))
            _, public, installed, candidate, sbom, advisory, signature = values
            updated = release.authorize_transition(
                installed, candidate, sbom, advisory, public=public,
                advisory_signature=signature,
                now=datetime(2026, 8, 30, tzinfo=timezone.utc),
            )
            self.assertEqual(2, updated["sequence"])
            stale = copy.deepcopy(sbom)
            stale["packages"][0]["versionInfo"] = "5.5.0"
            with self.assertRaisesRegex(release.ReleaseError, "SBOM_STALE"):
                release.authorize_transition(installed, candidate, stale, advisory, public=public,
                                             advisory_signature=signature)
            tampered = copy.deepcopy(advisory)
            tampered["summary"] = "tampered"
            with self.assertRaisesRegex(release.ReleaseError, "SIGNATURE_INVALID"):
                release.authorize_transition(installed, candidate, sbom, tampered, public=public,
                                             advisory_signature=signature)

    def test_rollback_requires_exact_signed_unexpired_authorization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private, public, old, current, new_sbom, _, _ = self.signed_update_fixture(root)
            old_sbom = {"packages": [{
                "SPDXID": "SPDXRef-Package-TlsProvider-aws-lc", "versionInfo": "5.5.0",
                "checksums": [{"algorithm": "SHA256", "checksumValue": "1" * 64}],
            }]}
            old["sbomSha256"] = release.sha256_bytes(release.canonical_json(old_sbom))
            advisory = {
                "schemaVersion": 1, "advisoryId": "WSA-ROLLBACK", "severity": "CRITICAL",
                "issuedUtc": "2026-01-01T00:00:00Z", "expiresUtc": "2099-01-01T00:00:00Z",
                "fromManifestSha256": current["providerManifestSha256"],
                "toManifestSha256": old["providerManifestSha256"],
                "toSbomSha256": old["sbomSha256"], "summary": "rollback",
            }
            advisory_signature = root / "rollback-advisory.sig"
            release.sign_bytes(private, release.canonical_json(advisory), advisory_signature)
            with self.assertRaisesRegex(release.ReleaseError, "ROLLBACK_UNAUTHORIZED"):
                release.authorize_transition(current, old, old_sbom, advisory, public=public,
                                             advisory_signature=advisory_signature)
            payload = release.transition_payload(current, old, old_sbom, advisory)
            authorization = {"schemaVersion": 1, "authorization": "rollback", **payload,
                             "expiresUtc": "2099-01-01T00:00:00Z"}
            authorization_signature = root / "rollback-authorization.sig"
            release.sign_bytes(private, release.canonical_json(authorization),
                               authorization_signature)
            restored = release.authorize_transition(
                current, old, old_sbom, advisory, public=public,
                advisory_signature=advisory_signature,
                rollback_authorization=authorization, rollback_signature=authorization_signature,
                now=datetime(2026, 8, 30, tzinfo=timezone.utc),
            )
            self.assertEqual(1, restored["sequence"])
            expired = {**authorization, "expiresUtc": "2020-01-01T00:00:00Z"}
            expired_signature = root / "expired.sig"
            release.sign_bytes(private, release.canonical_json(expired), expired_signature)
            with self.assertRaisesRegex(release.ReleaseError, "ROLLBACK_EXPIRED"):
                release.authorize_transition(
                    current, old, old_sbom, advisory, public=public,
                    advisory_signature=advisory_signature,
                    rollback_authorization=expired, rollback_signature=expired_signature,
                    now=datetime(2026, 8, 30, tzinfo=timezone.utc),
                )

    def test_workflow_is_pinned_and_missing_or_wrong_hosted_report_never_passes(self) -> None:
        workflow = release.inspect_workflow()
        self.assertEqual("PASS", workflow["decision"])
        self.assertEqual("frozen", workflow["artifactMode"])
        self.assertEqual(release.FROZEN_ARTIFACT_TAG, workflow["artifactSource"]["tag"])
        self.assertEqual(release.FROZEN_ARTIFACT_SHA256,
                         workflow["artifactSource"]["sha256"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "workflow.yml"
            text = (release.ROOT / release.WORKFLOW).read_text(encoding="utf-8")
            path.write_text(text + "\n      - uses: Zxilly/setup-cangjie@" + "a" * 40 + "\n",
                            encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "WORKFLOW_ARTIFACT_REBUILD"):
                release.inspect_workflow(path)
            path.write_text(
                text.replace(release.FROZEN_ARTIFACT_TAG, "m7-030-wrong-artifact"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "WORKFLOW_ARTIFACT_SOURCE"):
                release.inspect_workflow(path)
            path.write_text(
                text.replace(release.FROZEN_ARTIFACT_SHA256, "0" * 64),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "WORKFLOW_ARTIFACT_DIGEST"):
                release.inspect_workflow(path)
            path.write_text(text.replace("$FROZEN_ARTIFACT_TAG", "--latest"),
                            encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError,
                                       "WORKFLOW_ARTIFACT_SOURCE|WORKFLOW_ARTIFACT_FALLBACK"):
                release.inspect_workflow(path)
            validation = "scripts/generate-m7-025-linux-supply-chain --validate-only"
            path.write_text(text.replace(validation, "true", 1) + f"\n      - run: {validation}\n",
                            encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "WORKFLOW_SUPPLY_CHAIN"):
                release.inspect_workflow(path)
            path.write_text(
                text + "\n      - run: scripts/qualify-m7-021-linux-release\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "WORKFLOW_ARTIFACT_REBUILD"):
                release.inspect_workflow(path)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.json"
            with self.assertRaisesRegex(release.ReleaseError, "HOSTED_ATTESTATION_BLOCKED"):
                release.validate_hosted_report(path)
            wrong = {
                "schemaVersion": 1, "taskId": "M7-030", "decision": "PASS",
                "repository": "other/repo", "workflow": release.WORKFLOW,
                "runner": "self-hosted", "commit": "a" * 40, "subjects": [],
            }
            path.write_bytes(release.canonical_json(wrong))
            with self.assertRaises(release.ReleaseError):
                release.validate_hosted_report(path)

    def test_hosted_report_binds_three_verified_subjects(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subjects = []
            for name in ("artifact", "sbom", "release-manifest"):
                subject = root / name
                bundle = root / f"{name}.bundle"
                verification = root / f"{name}.verification.json"
                subject.write_text(name, encoding="utf-8")
                bundle.write_text(f"bundle:{name}", encoding="utf-8")
                verification.write_bytes(release.canonical_json({"verified": 1}))
                subjects.append((name, subject, bundle, verification))
            report = release.build_hosted_report("a" * 40, subjects)
            self.assertEqual("PASS", report["decision"])
            self.assertEqual("GitHub-hosted", report["runner"])
            self.assertEqual(3, len(report["subjects"]))
            (subjects[0][3]).write_bytes(release.canonical_json({"verified": 0}))
            with self.assertRaisesRegex(release.ReleaseError, "HOSTED_VERIFY_EMPTY"):
                release.build_hosted_report("a" * 40, subjects)

    def test_rehearsal_is_bounded_and_does_not_promote_hosted_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = release.local_rehearsal(Path(directory))
            self.assertEqual("PASS", report["decision"])
            self.assertEqual("REHEARSAL", report["classification"])
            self.assertEqual("PASS", report["updateFlow"]["decision"])
            self.assertIn(report["productionAttestation"]["decision"], {"BLOCKED", "FAIL"})
            serialized = json.dumps(report)
            self.assertNotIn("PRIVATE KEY", serialized)
            self.assertNotIn(str(Path(directory).parent), serialized)


if __name__ == "__main__":
    unittest.main()
