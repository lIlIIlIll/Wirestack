#!/usr/bin/env python3
"""Validate the checked-in public API inventory and package pairing contract."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tomllib


ROOT = pathlib.Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "release" / "public-api-inventory.toml"


def load_toml(path: pathlib.Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def fail(message: str) -> None:
    raise SystemExit(f"api inventory error: {message}")


def check_versions(inventory: dict) -> None:
    pairing = inventory["package_pairing"]
    manifest_version = inventory["package_manifest_version"]
    manifests = {
        "core": ROOT / "cjpm.toml",
        "macros": ROOT / "packages/yjson_macros/cjpm.toml",
        "aggregate": ROOT / "packages/yjson_all/cjpm.toml",
        "native": ROOT / "packages/yjson_native/cjpm.toml",
        "native_accel": ROOT / "packages/yjson_native_accel/cjpm.toml",
        "backends": ROOT / "packages/yjson_backends/cjpm.toml",
        "algorithms": ROOT / "packages/yjson_algorithms/cjpm.toml",
        "schema_formats": ROOT / "packages/yjson_schema_formats/cjpm.toml",
        "yyjson": ROOT / "packages/yjson_yyjson/cjpm.toml",
    }
    expected = {name: load_toml(path)["package"]["version"]
                for name, path in manifests.items()}
    for name, actual in expected.items():
        if actual != manifest_version:
            fail(f"{name} development version {actual!r} != package manifest version {manifest_version!r}")
        if actual != pairing[name]:
            fail(f"{name} development version {actual!r} != inventory {pairing[name]!r}")

    release_names = {
        "core": "yjson", "macros": "yjson_macros", "aggregate": "yjson_all",
        "native": "yjson_native", "native_accel": "yjson_native_accel",
        "backends": "yjson_backends", "algorithms": "yjson_algorithms",
        "schema_formats": "yjson_schema_formats", "yyjson": "yjson_yyjson",
    }
    released = {name: load_toml(ROOT / f"release/package-manifests/{module}.toml")
                for name, module in release_names.items()}
    for name, manifest in released.items():
        if manifest["package"]["version"] != pairing[name]:
            fail(f"release {release_names[name]} version must match inventory")
        for dependency, version in manifest.get("dependencies", {}).items():
            dependency_key = next((key for key, module in release_names.items()
                                   if module == dependency), None)
            if dependency_key is None or version != pairing[dependency_key]:
                fail(f"release {release_names[name]} dependency {dependency} is not pinned to inventory")


def check_declarations(inventory: dict) -> None:
    for entry in inventory["api"]:
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
    if inventory.get("release_version") != "2.0.1":
        fail("inventory release_version must match the 2.0 release line")
    check_versions(inventory)
    check_declarations(inventory)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    print(f"public API inventory passed: {len(inventory['api'])} reviewed deltas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
