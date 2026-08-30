#!/usr/bin/env python3
"""Validate the checked-in public API inventory and package pairing contract."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tomllib

from release_graph import ROOT, load_release_graph


INVENTORY = ROOT / "release" / "public-api-inventory.toml"


def load_toml(path: pathlib.Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def fail(message: str) -> None:
    raise SystemExit(f"api inventory error: {message}")


def check_versions(inventory: dict) -> None:
    graph = load_release_graph()
    if inventory.get("release_version") is not None or inventory.get("package_pairing") is not None:
        fail("release version and package pairing must come only from release/release-graph.toml")
    for package in graph.packages:
        development = load_toml(ROOT / package.development_manifest)
        released = load_toml(ROOT / package.release_manifest)
        for kind, manifest in (("development", development), ("release", released)):
            if manifest["package"]["name"] != package.name:
                fail(f"{kind} manifest name does not match graph package {package.name}")
            if manifest["package"]["version"] != graph.version:
                fail(f"{kind} {package.name} version is not {graph.version}")
            dependencies = manifest.get("dependencies", {})
            expected_dependencies = (
                package.development_dependencies if kind == "development"
                else package.dependencies
            )
            if set(dependencies) != set(expected_dependencies):
                fail(f"{kind} {package.name} dependencies do not match release graph")
        for dependency in package.dependencies:
            if released["dependencies"][dependency] != graph.version:
                fail(f"release {package.name} dependency {dependency} is not pinned to {graph.version}")


def check_declarations(inventory: dict) -> None:
    package_names = set(load_release_graph().names)
    for entry in inventory["api"]:
        if entry["package"] not in package_names:
            fail(f"{entry['symbol']} uses unknown package {entry['package']}")
        sources = entry["source"]
        if isinstance(sources, str):
            sources = [sources]
        for source in sources:
            path = ROOT / source
            if not path.is_file():
                fail(f"{entry['symbol']} references missing source {source}")
            if entry["needle"] not in path.read_text(encoding="utf-8"):
                fail(f"{entry['symbol']} is missing from {source}")


def main() -> int:
    inventory = load_toml(INVENTORY)
    if inventory.get("inventory_version") != 1:
        fail("unsupported inventory_version")
    check_versions(inventory)
    check_declarations(inventory)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_release_graph.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_release_temp_tree.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    graph = load_release_graph()
    print(f"public API inventory passed: version={graph.version} packages={len(graph.packages)} "
          f"reviewed_deltas={len(inventory['api'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
