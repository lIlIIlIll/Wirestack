#!/usr/bin/env python3

import pathlib
import subprocess
import sys
import tempfile
import unittest


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from release_temp_tree import (
    ensure_identity_unchanged,
    manifest_paths,
    release_identity,
    validate_manifest_closure,
)


class ReleaseTempTreeTest(unittest.TestCase):
    def git_fixture(self, root: pathlib.Path) -> list[pathlib.Path]:
        (root / "release").mkdir()
        (root / "src").mkdir()
        (root / "src" / "core.cj").write_text("package fixture\n", encoding="utf-8")
        manifest = root / "release" / "release-files.txt"
        manifest.write_text(
            "release/release-files.txt\nsrc/core.cj\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-f", "."], check=True)
        subprocess.run([
            "git", "-C", str(root), "-c", "user.name=Release Test",
            "-c", "user.email=release-test@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture",
        ], check=True)
        return manifest_paths(manifest)

    def fixture(self, root: pathlib.Path) -> list[pathlib.Path]:
        (root / "cjpm.toml").write_text("[package]\n", encoding="utf-8")
        (root / "src").mkdir()
        (root / "src" / "test_core.cj").write_text("package fixture\n", encoding="utf-8")
        (root / "scripts").mkdir()
        (root / "scripts" / "helper.py").write_text("VALUE = 1\n", encoding="utf-8")
        (root / "scripts" / "runner").write_text("#!/bin/sh\n", encoding="utf-8")
        (root / "scripts" / "driver.py").write_text(
            "from helper import VALUE\n"
            "# The gate also executes scripts/helper.py.\n",
            encoding="utf-8",
        )
        (root / "docs").mkdir()
        (root / "docs" / "guide.md").write_text("# Guide\n", encoding="utf-8")
        (root / "docs" / "logo.svg").write_text("<svg/>\n", encoding="utf-8")
        (root / "README.md").write_text(
            "[Guide](docs/guide.md)\n"
            "![Logo](docs/logo.svg)\n"
            "Run `python3 scripts/driver.py` through `scripts/runner`.\n",
            encoding="utf-8",
        )
        return [
            pathlib.Path("cjpm.toml"),
            pathlib.Path("src/test_core.cj"),
            pathlib.Path("scripts/driver.py"),
            pathlib.Path("scripts/helper.py"),
            pathlib.Path("scripts/runner"),
            pathlib.Path("docs/guide.md"),
            pathlib.Path("docs/logo.svg"),
            pathlib.Path("README.md"),
        ]

    def test_accepts_dependency_closed_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            validate_manifest_closure(root, self.fixture(root))

    def test_rejects_missing_core_test(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            (root / "src" / "test_limits.cj").write_text("package fixture\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "test_limits.cj"):
                validate_manifest_closure(root, paths)

    def test_rejects_missing_suffix_test_in_included_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            package = root / "packages" / "feature"
            (package / "src").mkdir(parents=True)
            (package / "cjpm.toml").write_text("[package]\n", encoding="utf-8")
            (package / "src" / "feature_test.cj").write_text(
                "package feature\n", encoding="utf-8")
            paths.append(pathlib.Path("packages/feature/cjpm.toml"))
            with self.assertRaisesRegex(ValueError, "feature_test.cj"):
                validate_manifest_closure(root, paths)

    def test_rejects_missing_executed_script(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            paths.remove(pathlib.Path("scripts/helper.py"))
            with self.assertRaisesRegex(ValueError, "scripts/helper.py"):
                validate_manifest_closure(root, paths)

    def test_rejects_script_referenced_by_included_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            paths.remove(pathlib.Path("scripts/driver.py"))
            with self.assertRaisesRegex(ValueError, "script dependency not in manifest: scripts/driver.py"):
                validate_manifest_closure(root, paths)

    def test_rejects_extensionless_script_referenced_by_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            paths.remove(pathlib.Path("scripts/runner"))
            with self.assertRaisesRegex(ValueError, "script dependency not in manifest: scripts/runner"):
                validate_manifest_closure(root, paths)

    def test_rejects_local_python_import_outside_scripts_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            benchmark = root / "benchmarks" / "suite"
            benchmark.mkdir(parents=True)
            (benchmark / "runner.py").write_text(
                "import summarize\n", encoding="utf-8")
            (benchmark / "summarize.py").write_text("VALUE = 1\n", encoding="utf-8")
            paths.append(pathlib.Path("benchmarks/suite/runner.py"))
            with self.assertRaisesRegex(
                ValueError,
                "script dependency not in manifest: benchmarks/suite/summarize.py",
            ):
                validate_manifest_closure(root, paths)

    def test_rejects_linked_document_missing_from_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            paths.remove(pathlib.Path("docs/guide.md"))
            with self.assertRaisesRegex(ValueError, "Markdown link target not in manifest: docs/guide.md"):
                validate_manifest_closure(root, paths)

    def test_rejects_broken_or_escaping_document_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            (root / "README.md").write_text(
                "[Missing](docs/missing.md)\n[Outside](../outside.md)\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "invalid or broken Markdown link"):
                validate_manifest_closure(root, paths)

    def test_enforce_clean_rejects_manifest_listed_untracked_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.git_fixture(root)
            (root / "src" / "untracked.cj").write_text("package fixture\n", encoding="utf-8")
            manifest = root / "release" / "release-files.txt"
            manifest.write_text(
                manifest.read_text(encoding="utf-8") + "src/untracked.cj\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "paths not tracked by Git"):
                release_identity(root, manifest_paths(manifest), True)

    def test_clean_identity_records_exact_commit_and_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.git_fixture(root)
            identity = release_identity(root, paths, True)
            self.assertTrue(identity["clean_enforced"])
            self.assertEqual(len(identity["commit"]), 40)
            self.assertEqual(len(identity["tree"]), 40)

    def test_enforce_clean_rejects_tracked_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.git_fixture(root)
            (root / "src" / "core.cj").write_text("package changed\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "clean Git worktree"):
                release_identity(root, paths, True)

    def test_detects_source_mutation_between_identity_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.git_fixture(root)
            before = release_identity(root, paths, False)
            (root / "src" / "core.cj").write_text("package changed\n", encoding="utf-8")
            after = release_identity(root, paths, False)
            with self.assertRaisesRegex(ValueError, "identity changed"):
                ensure_identity_unchanged(before, after)


if __name__ == "__main__":
    unittest.main()
