from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPOSITORY_ROOT / "tools" / "build_linux_tls_provider.py"
SPEC = importlib.util.spec_from_file_location("build_linux_tls_provider", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class LinuxTlsProviderBuildTests(unittest.TestCase):
    def manifest_path(self) -> Path:
        return REPOSITORY_ROOT / "native" / "tls" / "aws_lc" / "provider.json"

    def test_repository_manifest_is_exactly_pinned(self) -> None:
        manifest = builder.load_provider_manifest(self.manifest_path())
        self.assertEqual("aws-lc", manifest["provider_id"])
        self.assertEqual(builder.REQUIRED_COMMIT, manifest["source"]["commit"])
        self.assertEqual(builder.REQUIRED_TREE, manifest["source"]["tree"])
        self.assertIn("-DBUILD_TOOL=OFF", manifest["cmake_options"])

    def test_source_pin_changes_fail_closed(self) -> None:
        manifest = json.loads(self.manifest_path().read_text(encoding="utf-8"))
        manifest["source"]["commit"] = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "provider.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(builder.BuildError):
                builder.load_provider_manifest(path)

    def test_build_fingerprint_covers_shim_and_target(self) -> None:
        manifest = builder.load_provider_manifest(self.manifest_path())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "shim.c"
            header = root / "shim.h"
            source.write_text("one", encoding="utf-8")
            header.write_text("header", encoding="utf-8")
            first, _ = builder.build_input_fingerprint(
                manifest, source, header, {"cc": "clang"}, {"libc": "glibc"}
            )
            source.write_text("two", encoding="utf-8")
            second, _ = builder.build_input_fingerprint(
                manifest, source, header, {"cc": "clang"}, {"libc": "glibc"}
            )
            third, _ = builder.build_input_fingerprint(
                manifest, source, header, {"cc": "clang"}, {"libc": "musl"}
            )
            self.assertNotEqual(first, second)
            self.assertNotEqual(second, third)

    def test_cached_archive_digest_is_revalidated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            final = Path(directory)
            library = final / "lib" / "libwirestack_tls_provider.a"
            library.parent.mkdir()
            library.write_bytes(b"archive")
            fingerprint = "f" * 64
            manifest = {
                "build_fingerprint": fingerprint,
                "archive": {"sha256": builder.sha256_path(library)},
                "externalOpenSslDependency": False,
            }
            (final / "provider-manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertIsNotNone(builder.validate_cached_build(final, fingerprint))
            library.write_bytes(b"tampered")
            self.assertIsNone(builder.validate_cached_build(final, fingerprint))


if __name__ == "__main__":
    unittest.main()
