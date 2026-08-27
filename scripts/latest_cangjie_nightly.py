#!/usr/bin/env python3
"""Resolve the latest complete Cangjie nightly release from GitCode."""

from __future__ import annotations

import json
import re
import sys
import urllib.request


ENDPOINT = "https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases/latest"
VERSION_RE = re.compile(r"^Nightly Build (\d+\.\d+\.\d+-alpha\.\d{14})$")


def main() -> int:
    request = urllib.request.Request(
        ENDPOINT,
        headers={"Accept": "application/json", "User-Agent": "yjson-CI/2"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
        match = VERSION_RE.fullmatch(release.get("name", ""))
        if match is None or release.get("tag_name") != match.group(1):
            raise ValueError("nightly release name and tag do not match")
        version = match.group(1)
        names = {asset.get("name") for asset in release.get("assets", [])}
        if f"cangjie-sdk-linux-x64-{version}.tar.gz" not in names:
            raise ValueError("latest nightly SDK asset is incomplete")
        print(version)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"yjson: cannot resolve latest Cangjie nightly: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
