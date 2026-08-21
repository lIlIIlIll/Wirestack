#!/usr/bin/env python3
"""Validate the checked-in public API inventory and package pairing contract."""

from __future__ import annotations

import pathlib
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
    root_version = load_toml(ROOT / "cjpm.toml")["package"]["version"]
    macro_version = load_toml(ROOT / "packages/yjson_macros/cjpm.toml")["package"]["version"]
    all_version = load_toml(ROOT / "packages/yjson_all/cjpm.toml")["package"]["version"]
    native_version = load_toml(ROOT / "packages/yjson_native/cjpm.toml")["package"]["version"]
    yyjson_version = load_toml(ROOT / "packages/yjson_yyjson/cjpm.toml")["package"]["version"]
    expected = {
        "core": root_version,
        "macros": macro_version,
        "aggregate": all_version,
        "native": native_version,
        "yyjson": yyjson_version,
    }
    for name, actual in expected.items():
        if actual != manifest_version:
            fail(f"{name} development version {actual!r} != package manifest version {manifest_version!r}")
        if actual != pairing[name]:
            fail(f"{name} development version {actual!r} != inventory {pairing[name]!r}")

    release_all = load_toml(ROOT / "release/package-manifests/yjson_all.toml")
    release_native = load_toml(ROOT / "release/package-manifests/yjson_native.toml")
    release_yyjson = load_toml(ROOT / "release/package-manifests/yjson_yyjson.toml")
    dependencies = release_all["dependencies"]
    if dependencies.get("yjson") != pairing["core"]:
        fail("release yjson_all must pin the inventory core version")
    if dependencies.get("yjson_macros") != pairing["macros"]:
        fail("release yjson_all must pin the inventory macro version")
    if release_native["dependencies"].get("yjson") != pairing["core"]:
        fail("release yjson_native must pin the inventory core version")
    if release_yyjson["dependencies"].get("yjson") != pairing["core"]:
        fail("release yjson_yyjson must pin the inventory core version")


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
    if inventory.get("release_version") != "1.0.0-rc.1":
        fail("inventory release_version must match the current release candidate")
    check_versions(inventory)
    check_declarations(inventory)
    print(f"public API inventory passed: {len(inventory['api'])} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
