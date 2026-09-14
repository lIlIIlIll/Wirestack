import copy
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import m7_021_linux_release as release


class M7021LinuxReleaseTest(unittest.TestCase):

    @staticmethod
    def archive_payload(files: dict[str, bytes], schema: int = 2) -> dict[str, bytes]:
        entries = [
            {"path": path, "bytes": len(data), "sha256": release.artifact_payload_sha256(data)}
            for path, data in sorted(files.items())
        ]
        fingerprint = release.evidence_digest.text_evidence_bytes_sha256(release.canonical_json(entries))
        manifest = {
            "schema_version": schema, "package": "wirestack", "version": release.VERSION,
            "payload": entries, "payload_sha256": fingerprint,
            "artifactBuildFingerprint": fingerprint,
        }
        return {**files, "release-manifest.json": release.canonical_json(manifest)}

    def test_http_files_manifest_binds_sources_tools_and_archive(self) -> None:
        archive = b"native archive"
        payload = {
            f"{release.HTTP_FILES_PAYLOAD_ROOT}/{release.HTTP_FILES_ARCHIVE}": archive
        }
        manifest = {
            "schema_version": 1,
            "component": "wirestack-http-files",
            "abi_version": 1,
            "private_runtime_abi": False,
            "build_fingerprint": "a" * 64,
            "inputs": {
                "builder_sha256": "b" * 64,
                "sources": {
                    "native/http_files/wirestack_http_files.c": "c" * 64,
                    "native/http_files/wirestack_http_files.h": "d" * 64,
                },
                "tools": {
                    name: {"path": f"/usr/bin/{name}", "version": f"{name} test"}
                    for name in ("ar", "cc", "ranlib")
                },
            },
            "archive": {
                "path": release.HTTP_FILES_ARCHIVE,
                "bytes": len(archive),
                "sha256": release.artifact_payload_sha256(archive),
            },
        }
        manifest["build_fingerprint"] = release.evidence_digest.text_evidence_bytes_sha256(
            release.canonical_json(manifest["inputs"])
        )
        release.validate_http_files_manifest(manifest, payload)
        changed = copy.deepcopy(manifest)
        changed["archive"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(release.ReleaseError, "archive provenance"):
            release.validate_http_files_manifest(changed, payload)

    def test_text_metadata_digest_is_line_ending_stable_while_payload_digest_is_exact(self) -> None:
        variants = (
            b"line one\nline two\n",
            b"line one\r\nline two\r\n",
            b"line one\rline two\r",
        )
        text_digests = {
            release.evidence_digest.text_evidence_bytes_sha256(value) for value in variants
        }
        payload_digests = {release.artifact_payload_sha256(value) for value in variants}
        self.assertEqual(1, len(text_digests))
        self.assertEqual(3, len(payload_digests))

    def test_main_translates_invalid_text_digest_to_controlled_failure(self) -> None:
        error = release.evidence_digest.DigestError("TEXT_UTF8", "license is not valid UTF-8")
        args = mock.Mock(root=release.ROOT, output_dir=None, offline=True)
        with mock.patch.object(release, "parse_args", return_value=args), \
                mock.patch.object(release, "qualify", side_effect=error), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(1, release.main())
        self.assertIn("M7-021 Linux release qualification: FAIL", stdout.getvalue())
        self.assertNotIn("Traceback", stdout.getvalue())

    def test_production_sources_exclude_every_test_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/unit").mkdir(parents=True)
            (root / "src/internal/platform/windows").mkdir(parents=True)
            (root / "src/package.cj").write_text("package sample\n", encoding="utf-8")
            (root / "src/unit/package_test.cj").write_text("package sample.unit\n", encoding="utf-8")
            (root / "src/internal/platform/windows/package.cj").write_text(
                "package sample.windows\n", encoding="utf-8"
            )
            paths = release.production_sources(root)
            self.assertEqual([root / "src/package.cj"], paths)

    def test_archive_is_byte_reproducible_and_has_normalized_metadata(self) -> None:
        payload = {"src/package.cj": b"package wirestack\n", "cjpm.toml": b"[package]\n"}
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.tar.gz"
            second = Path(directory) / "second.tar.gz"
            release.write_reproducible_archive(first, payload)
            release.write_reproducible_archive(second, payload)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as archive:
                files = [member for member in archive.getmembers() if member.isfile()]
                self.assertTrue(files)
                self.assertTrue(all(member.mtime == 0 for member in files))
                self.assertTrue(all(member.uid == 0 and member.gid == 0 for member in files))

    def test_safe_extract_rejects_parent_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "unsafe.tar.gz"
            with tarfile.open(archive_path, "w:gz") as archive:
                info = tarfile.TarInfo("../escape")
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
            with self.assertRaisesRegex(release.ReleaseError, "unsafe release archive"):
                release.extract_archive(archive_path, Path(directory) / "install")

    def test_verified_extraction_preserves_exact_bytes_and_rejects_same_size_mutation(self) -> None:
        payload = self.archive_payload({"src/package.cj": b"package wirestack\r\n"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, root / "install")
            self.assertEqual(b"package wirestack\r\n", (installed / "src/package.cj").read_bytes())
            payload["src/package.cj"] = b"package wirestacK\r\n"
            release.write_reproducible_archive(archive, payload)
            with self.assertRaisesRegex(release.ReleaseError, "payload bytes"):
                release.extract_archive(archive, root / "changed")
            self.assertFalse((root / "changed").exists())

    def test_unlisted_and_missing_files_cannot_enter_an_installation(self) -> None:
        original = self.archive_payload({"src/package.cj": b"package wirestack\n"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.tar.gz"
            extra = {**original, "src/unlisted.cj": b"package wirestack\n"}
            release.write_reproducible_archive(archive, extra)
            with self.assertRaisesRegex(release.ReleaseError, "missing or extra files"):
                release.extract_archive(archive, root / "extra")
            self.assertFalse((root / "extra").exists())
            missing = {"release-manifest.json": original["release-manifest.json"]}
            release.write_reproducible_archive(archive, missing)
            with self.assertRaisesRegex(release.ReleaseError, "payload bytes"):
                release.extract_archive(archive, root / "missing")
            self.assertFalse((root / "missing").exists())

    def test_duplicate_members_and_fifos_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            duplicate = root / "duplicate.tar.gz"
            with tarfile.open(duplicate, "w:gz") as archive:
                for _ in range(2):
                    info = tarfile.TarInfo(f"{release.PACKAGE_ROOT}/same")
                    info.size = 1
                    archive.addfile(info, io.BytesIO(b"x"))
            with self.assertRaisesRegex(release.ReleaseError, "duplicate release archive"):
                release.extract_archive(duplicate, root / "duplicate")
            fifo = root / "fifo.tar.gz"
            with tarfile.open(fifo, "w:gz") as archive:
                info = tarfile.TarInfo(f"{release.PACKAGE_ROOT}/pipe")
                info.type = tarfile.FIFOTYPE
                archive.addfile(info)
            with self.assertRaisesRegex(release.ReleaseError, "regular files"):
                release.extract_archive(fifo, root / "fifo")
            self.assertFalse((root / "fifo").exists())

    def test_noncanonical_root_and_file_directory_overlap_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "release.tar.gz"
            with tarfile.open(archive_path, "w:gz") as archive:
                info = tarfile.TarInfo(".")
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            with self.assertRaisesRegex(release.ReleaseError, "unsafe release archive"):
                release.read_verified_payload(archive_path)
            payload = self.archive_payload({"src": b"file", "src/package.cj": b"package wirestack\n"})
            with tarfile.open(archive_path, "w:gz") as archive:
                for relative, content in payload.items():
                    info = tarfile.TarInfo(f"{release.PACKAGE_ROOT}/{relative}")
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))
            with self.assertRaisesRegex(release.ReleaseError, "overlaps a directory"):
                release.extract_archive(archive_path, root / "install")
            self.assertFalse((root / "install").exists())

    def test_extraction_refuses_a_contaminated_installation_directory(self) -> None:
        payload = self.archive_payload({"src/package.cj": b"package wirestack\n"}, schema=1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = root / "install" / release.PACKAGE_ROOT
            installed.mkdir(parents=True)
            sentinel = installed / "unlisted"
            sentinel.write_bytes(b"do not overwrite")
            with self.assertRaisesRegex(release.ReleaseError, "already exists"):
                release.extract_archive(archive, root / "install")
            self.assertEqual(b"do not overwrite", sentinel.read_bytes())
            self.assertFalse((installed / "src").exists())

    def test_openssl_dependency_names_fail_closed(self) -> None:
        for name in ("libssl.so", "libssl.so.3", "/usr/lib/libcrypto.so.3"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(release.ReleaseError, "system OpenSSL"):
                    release.reject_openssl_dependencies([name])
        release.reject_openssl_dependencies(["libc.so.6", "libcangjie-runtime.so"])

    def test_payload_loader_strings_fail_closed(self) -> None:
        with self.assertRaisesRegex(release.ReleaseError, "loader strings"):
            release.reject_loader_strings({"bad.bin": b"prefix libssl.so suffix"})

    def test_smoke_output_requires_https_runtime_and_fingerprint(self) -> None:
        output = "\n".join(sorted(release.EXPECTED_SMOKE_LINES | {"buildFingerprint=abc"}))
        release.validate_smoke_output(output)
        with self.assertRaisesRegex(release.ReleaseError, "omitted required output"):
            release.validate_smoke_output("buildFingerprint=abc")
        with self.assertRaisesRegex(release.ReleaseError, "empty build fingerprint"):
            release.validate_smoke_output("\n".join(sorted(release.EXPECTED_SMOKE_LINES)) + "\nbuildFingerprint=")

    def test_dependency_parsers_return_stable_names_without_addresses(self) -> None:
        needed = release.parse_needed(
            " 0x1 (NEEDED) Shared library: [libc.so.6]\n"
            " 0x1 (NEEDED) Shared library: [libm.so.6]\n"
        )
        self.assertEqual(["libc.so.6", "libm.so.6"], needed)
        resolved = release.parse_ldd(
            "libc.so.6 => /usr/lib/libc.so.6 (0x123)\nlinux-vdso.so.1 (0x456)\n"
        )
        self.assertEqual(
            [
                {"name": "libc.so.6", "resolved": "/usr/lib/libc.so.6"},
                {"name": "linux-vdso.so.1", "resolved": "linux-vdso.so.1"},
            ],
            resolved,
        )

    def test_consumer_manifest_points_only_at_installed_package(self) -> None:
        manifest = release.consumer_manifest(Path("/tmp/installed wirestack"))
        self.assertIn('wirestack = { path = "/tmp/installed wirestack" }', manifest)
        self.assertNotIn(str(release.ROOT), manifest)

    def test_committed_qualification_report_is_structurally_valid(self) -> None:
        report_path = release.ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json"
        if not report_path.is_file():
            self.skipTest("M7-021 qualification evidence is not committed yet")
        release.validate_report(
            json.loads(report_path.read_text(encoding="utf-8")),
            release.ROOT,
            verify_current_sources=False,
        )

    def test_strict_validation_rejects_source_drift(self) -> None:
        report_path = release.ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in release.QUALIFICATION_INPUTS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n", encoding="utf-8")
            source = root / "src/package.cj"
            source.parent.mkdir(parents=True)
            source.write_text("package wirestack\n", encoding="utf-8")
            report["source_tree_sha256"] = release.source_tree_sha256(root)
            report["qualification_inputs"] = {
                relative: release.evidence_digest.text_evidence_sha256(root / relative)
                for relative in release.QUALIFICATION_INPUTS
            }
            release.validate_report(report, root)
            (root / "README.md").write_text("changed packaged documentation\n", encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.validate_report(report, root)
            (root / "README.md").write_text("fixture\n", encoding="utf-8")
            planning = root / "docs/planning/implementation-backlog.md"
            planning.parent.mkdir(parents=True, exist_ok=True)
            planning.write_text("updated non-payload task state\n", encoding="utf-8")
            release.validate_report(report, root)
            source.write_text("package wirestack\npublic func changed(): Unit {}\n", encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.validate_report(report, root)
            source.write_text("package wirestack\n", encoding="utf-8")
            native = root / "native/tls/aws_lc/wirestack_tls_provider.c"
            native.write_text("changed native implementation\n", encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.validate_report(report, root)

    def test_structural_validation_accepts_frozen_input_keys_but_rejects_escape(self) -> None:
        report_path = release.ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        changed = copy.deepcopy(report)
        changed["qualification_inputs"] = {"historical/input.txt": "0" * 64}
        release.validate_report(changed, release.ROOT, verify_current_sources=False)
        changed["qualification_inputs"] = {"../escape": "0" * 64}
        with self.assertRaisesRegex(release.ReleaseError, "fingerprint is invalid"):
            release.validate_report(changed, release.ROOT, verify_current_sources=False)


if __name__ == "__main__":
    unittest.main()
