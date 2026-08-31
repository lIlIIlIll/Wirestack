import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import m7_021_linux_release as release


class M7021LinuxReleaseTest(unittest.TestCase):
    def test_qualification_inputs_bind_native_manifests_sources_and_build_logic(self) -> None:
        required = {
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "build.cj",
            "cjpm.lock",
            "cjpm.toml",
            "native/resolver/linux/wirestack_resolver.c",
            "native/resolver/linux/wirestack_resolver.h",
            "native/tls/aws_lc/provider.json",
            "native/tls/aws_lc/wirestack_tls_provider.c",
            "native/tls/aws_lc/wirestack_tls_provider.h",
            "tools/build_linux_resolver.py",
            "tools/build_linux_tls_provider.py",
            "third_party/aws-lc/LICENSE",
            "third_party/aws-lc/NOTICE",
        }
        self.assertTrue(required.issubset(set(release.QUALIFICATION_INPUTS)))

    def test_release_metadata_inventory_is_complete(self) -> None:
        self.assertEqual("Apache-2.0", release.PROJECT_LICENSE_EXPRESSION)
        self.assertEqual(
            {
                "LICENSE",
                "THIRD_PARTY_NOTICES.md",
                "third_party/aws-lc/LICENSE",
                "third_party/aws-lc/NOTICE",
            },
            set(release.RELEASE_METADATA_FILES),
        )

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
        with mock.patch.object(release, "source_tree_sha256", return_value="0" * 64):
            with self.assertRaisesRegex(release.ReleaseError, "source tree fingerprint is stale"):
                release.validate_report(report, release.ROOT)


if __name__ == "__main__":
    unittest.main()
