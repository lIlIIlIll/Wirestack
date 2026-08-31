#!/usr/bin/env python3
"""Tests for the fail-closed cjdoc qualification record."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

from check_cjdoc_qualification import CjdocQualificationError, validate_qualification


class CjdocQualificationTest(unittest.TestCase):
    CJC_VERSION = (
        "Cangjie Compiler: 1.1.0-alpha.20260829040003 (cjnative)\n"
        "Target: x86_64-unknown-linux-gnu"
    )
    CJPM_VERSION = "Cangjie Project Manager: 1.1.3"

    def qualified_fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        binary = root / ".ci" / "tools" / "cjdoc"
        binary.parent.mkdir(parents=True)
        binary.write_text(
            "#!/bin/sh\nprintf '%s\\n' 'cjdoc 0.6.0'\n",
            encoding="utf-8",
        )
        binary.chmod(0o755)
        revision = "0123456789abcdef0123456789abcdef01234567"
        archive_digest = "a" * 64
        config = root / "cjdoc-tool.toml"
        config.write_text(textwrap.dedent(f'''
            schema_version = 3
            status = "qualified"
            distribution = "source"
            platform = "linux-x86_64"

            version = "0.6.0"
            version_output = "cjdoc 0.6.0"
            version_args = ["--version"]

            source_url = "https://example.invalid/cjdoc/tree/{revision}"
            source_archive_url = "https://example.invalid/cjdoc/archive/{revision}.tar.gz"
            source_archive_sha256 = "{archive_digest}"
            source_revision = "{revision}"
            source_directory = "cjdoc-{revision}"
            binary_path = "target/release/bin/main"
            build_command = ["cjpm", "build"]

            cjc_channel = "nightly"

            license_spdx = "MIT"
            license_url = "https://example.invalid/cjdoc/blob/{revision}/LICENSE"
            manual_url = "https://example.invalid/cjdoc/blob/{revision}/README.md"
        '''), encoding="utf-8")
        evidence = {
            "schemaVersion": "yjson.cjdoc-build/1",
            "configSha256": hashlib.sha256(config.read_bytes()).hexdigest(),
            "sourceRevision": revision,
            "sourceArchiveSha256": archive_digest,
            "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "cjcVersion": self.CJC_VERSION,
            "cjpmVersion": self.CJPM_VERSION,
            "buildCommand": ["cjpm", "build"],
        }
        (binary.parent / "qualification.json").write_text(
            json.dumps(evidence), encoding="utf-8")
        return config, binary

    def qualified_commands(
        self, arguments: list[str], **_: object
    ) -> subprocess.CompletedProcess[str]:
        if arguments[0] == "cjc":
            output = self.CJC_VERSION
        elif arguments[0] == "cjpm":
            output = self.CJPM_VERSION
        else:
            output = "cjdoc 0.6.0"
        return subprocess.CompletedProcess(arguments, 0, stdout=output)

    @mock.patch("check_cjdoc_qualification.subprocess.run")
    def test_accepts_pinned_executable(self, run: mock.Mock) -> None:
        run.side_effect = self.qualified_commands
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            actual_binary, digest = validate_qualification(
                config, root=root, binary_override=binary)
            self.assertEqual(actual_binary, binary)
            self.assertEqual(digest, hashlib.sha256(binary.read_bytes()).hexdigest())

    def test_rejects_unqualified_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "cjdoc-tool.toml"
            config.write_text(
                'schema_version = 3\nstatus = "unqualified"\nreason = "missing tool"\n',
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
            with self.assertRaisesRegex(CjdocQualificationError, "binarySha256 mismatch"):
                validate_qualification(config, root=root, binary_override=binary)

    @mock.patch("check_cjdoc_qualification.subprocess.run")
    def test_accepts_a_different_complete_nightly(self, run: mock.Mock) -> None:
        self.CJC_VERSION = (
            "Cangjie Compiler: 1.3.0-alpha.20260831010012 (cjnative)\n"
            "Target: x86_64-unknown-linux-gnu"
        )
        run.side_effect = self.qualified_commands
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            validate_qualification(config, root=root, binary_override=binary)

    @mock.patch("check_cjdoc_qualification.subprocess.run")
    def test_rejects_non_nightly_compiler(self, run: mock.Mock) -> None:
        self.CJC_VERSION = "Cangjie Compiler: 1.3.0 (cjnative)"
        run.side_effect = self.qualified_commands
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            with self.assertRaisesRegex(CjdocQualificationError, "dated nightly"):
                validate_qualification(config, root=root, binary_override=binary)

    @mock.patch("check_cjdoc_qualification.subprocess.run")
    def test_rejects_shared_weekly_version_mismatch(self, run: mock.Mock) -> None:
        run.side_effect = self.qualified_commands
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, binary = self.qualified_fixture(root)
            with mock.patch.dict(
                "os.environ", {"YJSON_RESOLVED_NIGHTLY": "1.3.0-alpha.20260831010012"}
            ):
                with self.assertRaisesRegex(CjdocQualificationError, "shared weekly"):
                    validate_qualification(config, root=root, binary_override=binary)


if __name__ == "__main__":
    unittest.main()
