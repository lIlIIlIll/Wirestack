#!/usr/bin/env python3
"""Download one exact official Cangjie nightly SDK asset atomically."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import json
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.latest_cangjie_nightly import ENDPOINT, fetch_release, resolve_release


PLATFORMS = {
    "mac-aarch64-ios": "cangjie-sdk-mac-aarch64-ios-{version}.tar.gz",
}


class DownloadError(RuntimeError):
    pass


def resolve_asset(release: object, platform_name: str) -> tuple[str, str, str]:
    if platform_name not in PLATFORMS:
        raise DownloadError(f"unsupported nightly platform: {platform_name}")
    version = resolve_release(release)
    expected = PLATFORMS[platform_name].format(version=version)
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise DownloadError("nightly release assets are unavailable")
    matches = [
        asset
        for asset in release["assets"]
        if isinstance(asset, dict) and asset.get("name") == expected
    ]
    if len(matches) != 1:
        raise DownloadError(f"nightly release does not contain exactly one {expected}")
    url = matches[0].get("browser_download_url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise DownloadError("nightly asset has no HTTPS download URL")
    return version, expected, url


def download(url: str, output: Path) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as target:
            request = urllib.request.Request(
                url,
                headers={"Accept": "application/octet-stream", "User-Agent": "Wirestack-CI/1"},
            )
            with urllib.request.urlopen(request, timeout=60) as source:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    target.write(chunk)
            target.flush()
            os.fsync(target.fileno())
        if Path(temporary_name).stat().st_size == 0:
            raise DownloadError("nightly asset download was empty")
        digest = evidence_digest.artifact_byte_sha256(Path(temporary_name))
        os.replace(temporary_name, output)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        version, name, url = resolve_asset(fetch_release(), args.platform)
        digest = download(url, args.output.resolve())
    except (DownloadError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Wirestack: cannot download Cangjie nightly from {ENDPOINT}: {error}")
        return 2
    result = {
        "asset": name,
        "path": str(args.output.resolve()),
        "sha256": digest,
        "version": version,
    }
    if args.github_output is not None:
        with args.github_output.open("a", encoding="utf-8") as output:
            for key in ("asset", "path", "sha256", "version"):
                output.write(f"{key}={result[key]}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
