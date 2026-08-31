#!/usr/bin/env python3
"""Build only the native dependencies required by the current platform."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path


SUPPORTED = {
    "Linux": "linux-x86_64-glibc",
    "Windows": "windows-x86_64",
    "Darwin": "macos-arm64",
}


def plan(system: str) -> list[str]:
    if system == "Linux":
        return ["tls-provider", "resolver"]
    if system == "Windows":
        return ["resolver"]
    if system == "Darwin":
        return ["resolver"]
    raise ValueError(f"unsupported native dependency platform: {system}")


def run(command: list[str], *, root: Path) -> int:
    completed = subprocess.run(command, cwd=root, check=False)
    return completed.returncode


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--platform")
    parser.add_argument("--cjpm-script-path")
    parser.add_argument("--plan", action="store_true")
    return parser.parse_args()


def resolver_platform(system: str, script_path: str | None, override: str | None) -> str:
    if override is not None:
        selected = override
    elif system == "Darwin":
        parts = Path(script_path or "").parts
        try:
            cache_index = parts.index("build-script-cache")
            cjpm_target = parts[cache_index + 1]
        except (ValueError, IndexError) as error:
            raise ValueError("Darwin CJPM target identity is unavailable") from error
        if cjpm_target == "arm64-apple-ios11-simulator":
            selected = "ios-simulator-arm64"
        elif cjpm_target in {"aarch64-apple-darwin", "release"}:
            selected = "macos-arm64"
        else:
            raise ValueError("Darwin CJPM target identity is unavailable")
    else:
        selected = SUPPORTED[system]
    if system != "Darwin" and selected != SUPPORTED[system]:
        raise ValueError(f"{system} cannot build resolver target {selected}")
    if system == "Darwin" and selected not in {"macos-arm64", "ios-simulator-arm64"}:
        raise ValueError(f"unsupported Apple resolver platform: {selected}")
    return selected


def main() -> int:
    args = parse_args()
    system = args.platform or platform.system()
    try:
        steps = plan(system)
    except ValueError as error:
        print(json.dumps({"code": "unsupported-platform", "detail": str(error), "status": "FAIL"}))
        return 2
    if args.plan:
        print(json.dumps({
            "platform": SUPPORTED[system],
            "status": "READY",
            "steps": steps,
        }, sort_keys=True))
        return 0
    root = args.root.resolve()
    if "tls-provider" in steps:
        status = run(
            [sys.executable, str(root / "tools" / "build_tls_provider.py"), "--repo", str(root)],
            root=root,
        )
        if status != 0:
            return status
    try:
        selected_resolver = resolver_platform(
            system,
            args.cjpm_script_path,
            os.environ.get("WIRESTACK_RESOLVER_PLATFORM"),
        )
    except ValueError as error:
        print(json.dumps({
            "code": "unsupported-resolver-platform",
            "detail": str(error),
            "status": "FAIL",
        }))
        return 2
    resolver = [
        sys.executable,
        str(root / "tools" / "build_resolver.py"),
        "--root", str(root),
        "--platform", selected_resolver,
        "--quiet",
    ]
    if os.environ.get("WIRESTACK_RESOLVER_TEST_FIXTURE") == "1":
        resolver.append("--test-fixture")
    return run(resolver, root=root)


if __name__ == "__main__":
    raise SystemExit(main())
