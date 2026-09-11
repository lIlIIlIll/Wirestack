#!/usr/bin/env python3
"""Validate the exact Cangjie STS version used by hosted CI."""

from __future__ import annotations

import argparse
import re
import sys


VERSION_PATTERN = r"\d+\.\d+\.\d+"
VERSION_RE = re.compile(rf"^{VERSION_PATTERN}$")


def validate_version(version: str) -> str:
    """Return an exact STS version or raise ``ValueError``."""

    if VERSION_RE.fullmatch(version) is None:
        raise ValueError("STS version must match <major>.<minor>.<patch>")
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
