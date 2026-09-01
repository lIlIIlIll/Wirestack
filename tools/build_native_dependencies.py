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


def run(command: list[str], *, root: Path, env: dict[str, str] | None = None) -> int:
    completed = subprocess.run(command, cwd=root, env=env, check=False)
    return completed.returncode


def process_parent_pid(pid: int) -> int | None:
    completed = subprocess.run(
        ["ps", "-o", "ppid=", "-p", str(pid)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="replace",
        check=False,
    )
    value = completed.stdout.strip()
    if completed.returncode != 0 or not value.isdigit():
        return None
    parent = int(value)
    return parent if parent > 1 else None


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
    child_env = os.environ.copy()
    if system == "Darwin":
        # Python is launched by build.cj; its parent is the CJPM process that
        # will consume the selected archive after the pre-build hook returns.
        cjpm_pid = process_parent_pid(os.getppid())
        if cjpm_pid is None:
            print(json.dumps({
                "code": "cache-lease-owner-unavailable",
                "detail": "cannot identify the parent CJPM process",
                "status": "FAIL",
            }))
            return 2
        child_env["WIRESTACK_APPLE_CACHE_LEASE_PID"] = str(cjpm_pid)
    if "tls-provider" in steps:
        status = run(
            [sys.executable, str(root / "tools" / "build_tls_provider.py"), "--repo", str(root)],
            root=root,
            env=child_env,
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
    # CJPM validates every Darwin target FFI table before compiling the selected
    # target, so both target-specific archives must exist even though it links
    # only the requested one.
    required_resolvers = [selected_resolver]
    if system == "Darwin":
        required_resolvers.append(
            "ios-simulator-arm64"
            if selected_resolver == "macos-arm64"
            else "macos-arm64"
        )
    for selected in required_resolvers:
        resolver = [
            sys.executable,
            str(root / "tools" / "build_resolver.py"),
            "--root", str(root),
            "--platform", selected,
            "--quiet",
        ]
        if os.environ.get("WIRESTACK_RESOLVER_TEST_FIXTURE") == "1":
            resolver.append("--test-fixture")
        status = run(resolver, root=root, env=child_env)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
