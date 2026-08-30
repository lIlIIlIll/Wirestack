#!/usr/bin/env python3
"""Tests for the fail-closed cjdoc qualification record."""

from __future__ import annotations

import hashlib
import pathlib
import tempfile
import textwrap
import unittest

from check_cjdoc_qualification import CjdocQualificationError, validate_qualification


class CjdocQualificationTest(unittest.TestCase):
    def qualified_fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        binary = root / ".ci" / "tools" / "cjdoc"
        binary.parent.mkdir(parents=True)
        binary.write_text(
            "#!/bin/sh\nprintf '%s\\n' 'Doxygen version 1.9.3-cangjie-test'\n",
            encoding="utf-8",
        )
        binary.chmod(0o755)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        config = root / "cjdoc-tool.toml"
        config.write_text(textwrap.dedent(f'''
            schema_version = 1
            status = "qualified"
            platform = "linux-x86_64"
            binary_path = ".ci/tools/cjdoc"
            artifact_url = "https://example.invalid/cjdoc.tar.gz"
            artifact_sha256 = "{digest}"
            version_output = "Doxygen version 1.9.3-cangjie-test"
            version_args = ["-v"]
            source_url = "https://example.invalid/cjdoc-source"
            source_revision = "0123456789abcdef"
            license_spdx = "GPL-2.0-only"
            manual_url = "https://example.invalid/cjdoc-manual"
        '''), encoding="utf-8")
        return config, binary

    def test_accepts_pinned_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            actual_binary, digest = validate_qualification(config, root=root)
            self.assertEqual(actual_binary, binary)
            self.assertEqual(digest, hashlib.sha256(binary.read_bytes()).hexdigest())

    def test_rejects_unqualified_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "cjdoc-tool.toml"
            config.write_text(
                'schema_version = 1\nstatus = "unqualified"\nreason = "missing tool"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(CjdocQualificationError, "missing tool"):
                validate_qualification(config, root=pathlib.Path(directory))

    def test_rejects_checksum_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            binary.chmod(0o755)
            with self.assertRaisesRegex(CjdocQualificationError, "checksum mismatch"):
                validate_qualification(config, root=root)


if __name__ == "__main__":
    unittest.main()
