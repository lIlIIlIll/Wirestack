#!/usr/bin/env python3
"""Resolve or validate the Cangjie nightly version used by hosted CI."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from collections.abc import Mapping
from typing import Any


ENDPOINT = "https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases/latest"
VERSION_PATTERN = r"\d+\.\d+\.\d+-alpha\.\d{14}"
VERSION_RE = re.compile(rf"^{VERSION_PATTERN}$")
RELEASE_NAME_RE = re.compile(rf"^Nightly Build ({VERSION_PATTERN})$")
REQUIRED_ASSET_TEMPLATES = (
    "cangjie-sdk-linux-x64-{version}.tar.gz",
    "cangjie-sdk-windows-x64-{version}.zip",
    "cangjie-sdk-mac-x64-{version}.tar.gz",
    "cangjie-sdk-mac-aarch64-{version}.tar.gz",
)


def validate_version(version: str) -> str:
    """Return a normalized exact nightly version or raise ``ValueError``."""

    if VERSION_RE.fullmatch(version) is None:
        raise ValueError(
            "nightly version must match "
            "<major>.<minor>.<patch>-alpha.<14-digit UTC build stamp>"
        )
    return version


def resolve_release(release: Any) -> str:
    """Validate a GitCode release payload and return its complete SDK version."""

    if not isinstance(release, Mapping):
        raise ValueError("nightly release response must be a JSON object")

    name = release.get("name")
    tag_name = release.get("tag_name")
    match = RELEASE_NAME_RE.fullmatch(name) if isinstance(name, str) else None
    if match is None or tag_name != match.group(1):
        raise ValueError("nightly release name and tag do not match")
    version = validate_version(match.group(1))

    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("nightly release assets must be a JSON array")
    names = {
        asset.get("name")
        for asset in assets
        if isinstance(asset, Mapping) and isinstance(asset.get("name"), str)
    }
    missing = [
        template.format(version=version)
        for template in REQUIRED_ASSET_TEMPLATES
        if template.format(version=version) not in names
    ]
    if missing:
        raise ValueError(
            "latest nightly SDK asset set is incomplete; missing: "
            + ", ".join(missing)
        )
    return version


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--validate-version",
        metavar="VERSION",
        help="validate one exact nightly version without network access",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.validate_version is not None:
        try:
            print(validate_version(args.validate_version))
            return 0
        except ValueError as error:
            print(f"yjson: invalid Cangjie nightly version: {error}", file=sys.stderr)
            return 2

    request = urllib.request.Request(
        ENDPOINT,
        headers={"Accept": "application/json", "User-Agent": "yjson-CI/2"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
        print(resolve_release(release))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"yjson: cannot resolve latest Cangjie nightly: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
