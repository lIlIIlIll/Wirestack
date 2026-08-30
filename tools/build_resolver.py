#!/usr/bin/env python3
"""Select and build the system-resolver adapter for the native platform."""

from __future__ import annotations

import argparse
import json
import platform
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import build_linux_resolver, build_windows_resolver


class SelectionError(RuntimeError):
    pass


def normalize_platform(value: str | None) -> str:
    selected = value or platform.system()
    aliases = {
        "Linux": "linux-x86_64-glibc",
        "linux": "linux-x86_64-glibc",
        "linux-x86_64-glibc": "linux-x86_64-glibc",
        "Windows": "windows-x86_64",
        "windows": "windows-x86_64",
        "windows-x86_64": "windows-x86_64",
    }
    try:
        return aliases[selected]
    except KeyError as error:
        raise SelectionError(f"unsupported resolver platform: {selected}") from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--platform")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--test-fixture", action="store_true")
    parser.add_argument("--plan", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        selected = normalize_platform(args.platform)
    except SelectionError as error:
        print(json.dumps({"code": "unsupported-platform", "detail": str(error), "status": "FAIL"}))
        return 2
    if args.plan:
        print(json.dumps({"platform": selected, "status": "READY"}, sort_keys=True))
        return 0
    root = args.root.resolve()
    output_root = (args.output_root or root / "target" / "native" / "resolver").resolve()
    if selected == "linux-x86_64-glibc":
        if args.test_fixture:
            print(json.dumps({
                "code": "fixture-unavailable",
                "detail": "the M2-004 fixture is Windows-only",
                "status": "FAIL",
            }))
            return 2
        try:
            final_dir, manifest = build_linux_resolver.build(root, output_root)
        except build_linux_resolver.BuildError as error:
            print(f"resolver build failed: {error}")
            return 1
    else:
        try:
            final_dir, manifest = build_windows_resolver.build(
                root, output_root, test_fixture=args.test_fixture
            )
        except build_windows_resolver.BuildError as error:
            print(f"resolver build failed: {error}")
            return 1
    if not args.quiet:
        print(json.dumps({
            "artifact": str(final_dir),
            "manifest": manifest,
            "platform": selected,
        }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
