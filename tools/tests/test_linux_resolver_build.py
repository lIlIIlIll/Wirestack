from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPOSITORY_ROOT / "tools" / "build_linux_resolver.py"
SPEC = importlib.util.spec_from_file_location("build_linux_resolver", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class LinuxResolverBuildTests(unittest.TestCase):
    def test_fingerprint_covers_source_header_and_target(self) -> None:
        source = REPOSITORY_ROOT / "native" / "resolver" / "linux" / "wirestack_resolver.c"
        header = REPOSITORY_ROOT / "native" / "resolver" / "linux" / "wirestack_resolver.h"
        tools = {
            "cc": builder.find_tool("CC", ("/usr/lib/llvm15/bin/clang", "clang", "cc")),
            "ar": builder.find_tool("AR", ("llvm-ar", "ar")),
            "ranlib": builder.find_tool("RANLIB", ("llvm-ranlib", "ranlib")),
        }
        first, inputs = builder.build_fingerprint(source, header, tools)
        self.assertEqual(64, len(first))
        self.assertIn("target", inputs)
        self.assertEqual(builder.sha256_path(source), inputs["source_sha256"])
        self.assertEqual(builder.sha256_path(header), inputs["header_sha256"])

    def test_build_is_content_addressed_and_cache_is_revalidated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "resolver"
            final, manifest = builder.build(REPOSITORY_ROOT, output)
            archive = final / "lib" / "libwirestack_resolver.a"
            current = output / "current"
            self.assertTrue(archive.is_file())
            self.assertTrue(current.is_symlink())
            self.assertEqual(final.resolve(), current.resolve())
            self.assertFalse(manifest["private_runtime_abi"])
            self.assertEqual(builder.sha256_path(archive), manifest["archive"]["sha256"])

            cached_final, cached_manifest = builder.build(REPOSITORY_ROOT, output)
            self.assertEqual(final, cached_final)
            self.assertEqual(manifest, cached_manifest)

            archive.write_bytes(b"tampered")
            self.assertIsNone(builder.validate_cached(final, manifest["build_fingerprint"]))

    def test_cached_manifest_requires_matching_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            final = Path(directory)
            archive = final / "lib" / "libwirestack_resolver.a"
            archive.parent.mkdir()
            archive.write_bytes(b"archive")
            manifest = {
                "build_fingerprint": "a" * 64,
                "archive": {"sha256": builder.sha256_path(archive)},
            }
            (final / "resolver-manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertIsNone(builder.validate_cached(final, "b" * 64))


if __name__ == "__main__":
    unittest.main()
