from __future__ import annotations

from tools import evidence_digest

import importlib.util
import json
import contextlib
import io
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_git_diagnostics_do_not_change_source_identity(self) -> None:
        git = shutil.which("git")
        self.assertIsNotNone(git)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            environment = builder.git_environment()

            def invoke(*arguments: str) -> str:
                return subprocess.run(
                    [git, *arguments], env=environment, check=True,
                    text=True, capture_output=True,
                ).stdout.strip()

            invoke("init", str(source))
            invoke("-C", str(source), "-c", "user.name=Fixture",
                   "-c", "user.email=fixture@example.invalid",
                   "commit", "--allow-empty", "-m", "fixture")
            commit = invoke("-C", str(source), "rev-parse", "HEAD")
            tree = invoke("-C", str(source), "rev-parse", "HEAD^{tree}")
            manifest = {"source": {
                "commit": commit, "tree": tree,
                "content_sha256": evidence_digest.text_evidence_bytes_sha256(
                    f"{commit}\n{tree}\n".encode()),
            }}
            binaries = root / "bin"
            binaries.mkdir()
            wrapper = binaries / "git"
            wrapper.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'git diagnostic' >&2\n"
                f"exec {shlex.quote(git)} \"$@\"\n", encoding="utf-8")
            wrapper.chmod(0o755)
            diagnostics = io.StringIO()
            with mock.patch.dict(os.environ, {
                "PATH": str(binaries) + os.pathsep + os.environ.get("PATH", ""),
            }), contextlib.redirect_stderr(diagnostics):
                identity = builder.verify_source(source, manifest)
                self.assertEqual(commit, identity["commit"])
                (source / "untracked").write_text("dirty", encoding="utf-8")
                with self.assertRaises(builder.BuildError):
                    builder.verify_source(source, manifest)
            self.assertIn("git diagnostic", diagnostics.getvalue())

    def test_build_fingerprint_covers_shim_and_target(self) -> None:
        manifest = builder.load_provider_manifest(self.manifest_path())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "shim.c"
            header = root / "shim.h"
            abi = root / "abi.json"
            source.write_text("one", encoding="utf-8")
            header.write_text("header", encoding="utf-8")
            abi.write_text("contract-one", encoding="utf-8")
            first, _ = builder.build_input_fingerprint(
                manifest, source, header, abi, {"cc": "clang"}, {"libc": "glibc"}
            )
            source.write_text("two", encoding="utf-8")
            second, _ = builder.build_input_fingerprint(
                manifest, source, header, abi, {"cc": "clang"}, {"libc": "glibc"}
            )
            third, _ = builder.build_input_fingerprint(
                manifest, source, header, abi, {"cc": "clang"}, {"libc": "musl"}
            )
            abi.write_text("contract-two", encoding="utf-8")
            fourth, _ = builder.build_input_fingerprint(
                manifest, source, header, abi, {"cc": "clang"}, {"libc": "musl"}
            )
            self.assertNotEqual(first, second)
            self.assertNotEqual(second, third)
            self.assertNotEqual(third, fourth)

    def test_cached_archive_digest_is_revalidated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            final = Path(directory)
            library = final / "lib" / "libwirestack_tls_provider.a"
            library.parent.mkdir()
            library.write_bytes(b"archive")
            fingerprint = "f" * 64
            manifest = {
                "build_fingerprint": fingerprint,
                "archive": {"sha256": evidence_digest.artifact_byte_sha256(library)},
                "externalOpenSslDependency": False,
            }
            (final / "provider-manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertIsNotNone(builder.validate_cached_build(final, fingerprint))
            library.write_bytes(b"tampered")
            self.assertIsNone(builder.validate_cached_build(final, fingerprint))

    def test_multicall_tool_symlink_name_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            multicall = root / "llvm-ar"
            multicall.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            multicall.chmod(0o755)
            ranlib = root / "llvm-ranlib"
            ranlib.symlink_to(multicall.name)
            resolved = builder.resolve_tool(str(ranlib), "/missing", "missing")
            self.assertEqual(str(ranlib.absolute()), resolved)
            self.assertEqual("llvm-ranlib", Path(resolved).name)


if __name__ == "__main__":
    unittest.main()
