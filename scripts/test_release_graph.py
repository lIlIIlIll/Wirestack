#!/usr/bin/env python3
"""Tests for the machine-readable release package graph."""

from __future__ import annotations

import pathlib
import tempfile
import textwrap
import tomllib
import unittest

from release_graph import ROOT, load_release_graph


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
                set(package.development_dependencies),
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
