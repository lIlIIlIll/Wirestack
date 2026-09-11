#!/usr/bin/env python3
"""Validate the exact Cangjie STS version used by hosted CI."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tomllib


VERSION_PATTERN = r"\d+\.\d+\.\d+"
VERSION_RE = re.compile(rf"^{VERSION_PATTERN}$")
ROOT = pathlib.Path(__file__).resolve().parents[1]
QUALIFICATION_CONFIG = ROOT / "release" / "cjdoc-tool.toml"


def pinned_sts_version() -> str:
    """Read the single STS version accepted by release qualification."""

    try:
        config = tomllib.loads(QUALIFICATION_CONFIG.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValueError(f"cannot read STS qualification pin: {error}") from error
    version = config.get("cjc_version")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        raise ValueError("STS qualification pin must be a complete semantic version")
    return version


def validate_version(version: str) -> str:
    """Return the exact STS version accepted by release qualification."""

    if VERSION_RE.fullmatch(version) is None:
        raise ValueError("STS version must match <major>.<minor>.<patch>")
    expected = pinned_sts_version()
    if version != expected:
        raise ValueError(f"STS version is pinned to {expected}")
    return version


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--validate-version",
        metavar="VERSION",
        required=True,
        help="validate one exact STS version without network access",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        print(validate_version(args.validate_version))
        return 0
    except ValueError as error:
        print(f"yjson: invalid Cangjie STS version: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
