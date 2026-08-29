#!/usr/bin/env python3
"""Resolve one complete Cangjie nightly release for hosted CI."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path


ENDPOINT = "https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases/latest"
VERSION_RE = re.compile(r"^Nightly Build (\d+\.\d+\.\d+-alpha\.\d{14})$")


def resolve_release(release: object) -> str:
    if not isinstance(release, dict):
        raise ValueError("release payload must be an object")
    name = release.get("name")
    tag = release.get("tag_name")
    match = VERSION_RE.fullmatch(name) if isinstance(name, str) else None
    if match is None or tag != match.group(1):
        raise ValueError("nightly release name and tag do not match")
    version = match.group(1)
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("nightly release assets must be an array")
    names = {
        asset.get("name")
        for asset in assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    if f"cangjie-sdk-linux-x64-{version}.tar.gz" not in names:
        raise ValueError("latest nightly Linux x64 SDK asset is incomplete")
    return version


def fetch_release() -> object:
    request = urllib.request.Request(
        ENDPOINT,
        headers={"Accept": "application/json", "User-Agent": "Wirestack-CI/1"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--github-output", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        version = resolve_release(fetch_release())
        if args.github_output is not None:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"version={version}\n")
        print(version)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Wirestack: cannot resolve complete Cangjie nightly: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
