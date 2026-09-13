from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import build_linux_http_files as builder
from tools import evidence_digest


class BuildLinuxHttpFilesTests(unittest.TestCase):
    def test_fingerprint_binds_source_builder_target_and_every_tool(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            source = repo / "native/http_files/wirestack_http_files.c"
            header = repo / "native/http_files/wirestack_http_files.h"
            source.parent.mkdir(parents=True)
            source.write_text("int implementation;\n", encoding="utf-8")
            header.write_text("int declaration;\n", encoding="utf-8")
            tools = {
                "cc": "/usr/bin/cc",
                "ar": "/usr/bin/ar",
                "ranlib": "/usr/bin/ranlib",
            }

            def output(command, *, cwd):
                if command[1:] == ["-dumpmachine"]:
                    return "x86_64-unknown-linux-gnu\n"
                return f"{Path(command[0]).name} test version\n"

            with mock.patch.object(builder, "run", side_effect=output):
                first, inputs = builder.build_fingerprint(
                    repo,
                    source,
                    header,
                    tools,
                    {"os": "linux", "architecture": "x86_64", "libc": "glibc"},
                )
                source.write_text("int changed;\n", encoding="utf-8")
                second, _ = builder.build_fingerprint(
                    repo,
                    source,
                    header,
                    tools,
                    {"os": "linux", "architecture": "x86_64", "libc": "glibc"},
                )

            self.assertNotEqual(first, second)
            self.assertEqual({"ar", "cc", "ranlib"}, set(inputs["tools"]))
            self.assertIn("builder_sha256", inputs)
            self.assertEqual("x86_64-unknown-linux-gnu", inputs["compiler_target"])

    def test_cached_archive_requires_matching_fingerprint_and_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            final = Path(directory)
            archive = final / "lib/libwirestack_http_files.a"
            archive.parent.mkdir()
            archive.write_bytes(b"archive")
            manifest = {
                "schema_version": 1,
                "component": "wirestack-http-files",
                "abi_version": 1,
                "build_fingerprint": "a" * 64,
                "archive": {
                    "path": "lib/libwirestack_http_files.a",
                    "bytes": archive.stat().st_size,
                    "sha256": evidence_digest.artifact_byte_sha256(archive),
                },
            }
            (final / "http-files-manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertEqual(manifest, builder.validate_cached(final, "a" * 64))

            changed = copy.deepcopy(manifest)
            changed["archive"]["sha256"] = "0" * 64
            (final / "http-files-manifest.json").write_text(
                json.dumps(changed), encoding="utf-8"
            )
            self.assertIsNone(builder.validate_cached(final, "a" * 64))

    def test_cache_pruning_is_bounded_and_preserves_current(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cache = output / "cache"
            cache.mkdir()
            entries = []
            for index in range(builder.MAX_CACHE_ENTRIES + 2):
                entry = cache / f"fingerprint-{index}"
                entry.mkdir()
                os.utime(entry, ns=(index + 1, index + 1))
                entries.append(entry)
            (output / "current").symlink_to(entries[0].relative_to(output))

            builder.prune_cache(output, entries[-1])

            remaining = [path for path in cache.iterdir() if path.is_dir()]
            self.assertLessEqual(len(remaining), builder.MAX_CACHE_ENTRIES)
            self.assertTrue(entries[0].is_dir())
            self.assertTrue(entries[-1].is_dir())

    def test_platform_selection_rejects_non_linux_and_musl(self) -> None:
        with mock.patch.object(builder.sys, "platform", "darwin"):
            with self.assertRaisesRegex(builder.BuildError, "requires Linux"):
                builder.platform_identity()
        with (
            mock.patch.object(builder.sys, "platform", "linux"),
            mock.patch.object(builder.platform, "machine", return_value="x86_64"),
            mock.patch.object(builder.platform, "libc_ver", return_value=("musl", "1.2")),
        ):
            with self.assertRaisesRegex(builder.BuildError, "requires glibc"):
                builder.platform_identity()


if __name__ == "__main__":
    unittest.main()
