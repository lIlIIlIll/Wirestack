#!/usr/bin/env python3
"""Tests for the machine-readable release package graph."""

from __future__ import annotations

import pathlib
import tempfile
import textwrap
import tomllib
import unittest

from release_graph import ROOT, load_release_graph
from release_package_stage import stage


class ReleaseGraphTest(unittest.TestCase):
    def test_graph_matches_development_and_release_manifests(self) -> None:
        graph = load_release_graph()
        self.assertEqual(len(graph.packages), 9)
        for package in graph.packages:
            development = tomllib.loads(
                (ROOT / package.development_manifest).read_text(encoding="utf-8"))
            released = tomllib.loads(
                (ROOT / package.release_manifest).read_text(encoding="utf-8"))
            self.assertEqual(development["package"]["name"], package.name)
            self.assertEqual(released["package"]["name"], package.name)
            self.assertEqual(development["package"]["version"], graph.version)
            self.assertEqual(released["package"]["version"], graph.version)
            self.assertEqual(
                set(development.get("dependencies", {})),
                set(package.dependencies),
            )
            self.assertEqual(
                set(development.get("test-dependencies", {})),
                set(package.test_dependencies),
            )
            self.assertEqual(set(released.get("dependencies", {})), set(package.dependencies))
            for dependency in package.dependencies:
                self.assertEqual(released["dependencies"][dependency], graph.version)
            self.assertTrue((ROOT / package.source_root).is_dir())

    def test_rejects_unknown_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "graph.toml"
            path.write_text(textwrap.dedent('''
                schema_version = 1
                release_version = "0.1.0"
                status = "migration"
                [[packages]]
                name = "yjson"
                role = "core"
                development_manifest = "cjpm.toml"
                release_manifest = "release/yjson.toml"
                source_root = "src"
                stage_kind = "core"
                stability = "stable"
                leaf_bundle = true
                dependencies = ["yjson_missing"]
            '''), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unknown packages"):
                load_release_graph(path)

    def test_rejects_dependency_that_appears_after_consumer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "graph.toml"
            path.write_text(textwrap.dedent('''
                schema_version = 1
                release_version = "0.1.0"
                status = "migration"
                [[packages]]
                name = "yjson_macros"
                role = "macros"
                development_manifest = "packages/yjson_macros/cjpm.toml"
                release_manifest = "release/yjson_macros.toml"
                source_root = "packages/yjson_macros/src"
                stage_kind = "package"
                stability = "stable"
                leaf_bundle = false
                dependencies = ["yjson"]
                [[packages]]
                name = "yjson"
                role = "core"
                development_manifest = "cjpm.toml"
                release_manifest = "release/yjson.toml"
                source_root = "src"
                stage_kind = "core"
                stability = "stable"
                leaf_bundle = true
                dependencies = []
            '''), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "must precede"):
                load_release_graph(path)

    def test_staging_copies_complete_package_source_roots(self) -> None:
        graph = load_release_graph()
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory)
            stage(graph.package("yjson"), destination, development=False)
            stage(
                graph.package("yjson_native_primitives"),
                destination,
                development=False,
            )
            self.assertTrue(
                (destination / "yjson" / "src" / "json_boundary_test.cj").is_file())
            self.assertTrue((
                destination
                / "yjson_native_primitives"
                / "src"
                / "native_primitives_test.cj"
            ).is_file())

    def test_rejects_non_zero_minor_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "graph.toml"
            path.write_text(textwrap.dedent('''
                schema_version = 1
                release_version = "1.0.0"
                status = "migration"
                [[packages]]
                name = "yjson"
                role = "core"
                development_manifest = "cjpm.toml"
                release_manifest = "release/yjson.toml"
                source_root = "src"
                stage_kind = "core"
                stability = "stable"
                leaf_bundle = true
                dependencies = []
            '''), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "0.x.y"):
                load_release_graph(path)


if __name__ == "__main__":
    unittest.main()
