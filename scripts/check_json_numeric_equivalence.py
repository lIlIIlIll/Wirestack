#!/usr/bin/env python3
"""Compare JSON while tolerating platform-level floating-point rendering differences."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def equivalent(expected: object, actual: object, path: str = "$") -> None:
    if isinstance(expected, bool) or isinstance(actual, bool):
        if expected != actual:
            raise ValueError(f"{path}: {expected!r} != {actual!r}")
        return
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if not math.isclose(float(expected), float(actual), rel_tol=1e-12, abs_tol=1e-9):
            raise ValueError(f"{path}: {expected!r} != {actual!r}")
        return
    if isinstance(expected, dict) and isinstance(actual, dict):
        if expected.keys() != actual.keys():
            raise ValueError(f"{path}: object keys differ")
        for key in expected:
            equivalent(expected[key], actual[key], f"{path}.{key}")
        return
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            raise ValueError(f"{path}: array lengths differ")
        for index, (left, right) in enumerate(zip(expected, actual)):
            equivalent(left, right, f"{path}[{index}]")
        return
    if expected != actual:
        raise ValueError(f"{path}: {expected!r} != {actual!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    args = parser.parse_args()
    equivalent(json.loads(args.expected.read_text(encoding="utf-8")),
               json.loads(args.actual.read_text(encoding="utf-8")))
    print(f"JSON is numerically equivalent: {args.actual}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
