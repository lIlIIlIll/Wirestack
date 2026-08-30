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
}


def plan(system: str) -> list[str]:
    if system == "Linux":
        return ["tls-provider", "resolver"]
    if system == "Windows":
        return ["resolver"]
    raise ValueError(f"unsupported native dependency platform: {system}")


def run(command: list[str], *, root: Path) -> int:
    completed = subprocess.run(command, cwd=root, check=False)
    return completed.returncode


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--platform")
    parser.add_argument("--plan", action="store_true")
    return parser.parse_args()


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
    resolver = [
        sys.executable,
        str(root / "tools" / "build_resolver.py"),
        "--root", str(root),
        "--platform", SUPPORTED[system],
        "--quiet",
    ]
    if os.environ.get("WIRESTACK_RESOLVER_TEST_FIXTURE") == "1":
        resolver.append("--test-fixture")
    return run(resolver, root=root)


if __name__ == "__main__":
    raise SystemExit(main())
