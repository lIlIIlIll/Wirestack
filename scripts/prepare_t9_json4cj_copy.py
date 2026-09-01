#!/usr/bin/env python3
"""Apply the msgc-SDK build profile to an isolated json4cj checkout."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    if old not in text:
        raise RuntimeError(f"expected manifest fragment not found: {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="fresh json4cj checkout")
    args = parser.parse_args()
    root = args.root.resolve()

    replace_once(
        root / "json4cj-annotations" / "cjpm.toml",
        'json4cj_msgc = "--gc-mode=marksweep"',
        'cfg = "--gc-mode=marksweep"',
    )
    target = '[target]\n  [target.x86_64-unknown-linux-gnu.bin-dependencies]\n    path-option = [ "${CANGJIE_STDX_PATH}" ]\n'
    for relative in ("json4cj-core/cjpm.toml", "json4cj-databind/cjpm.toml"):
        path = root / relative
        replace_once(
            path,
            '  json4cj_o2 = "-O2"\n  json4cj_msgc = "--gc-mode=marksweep"',
            '  cfg = "-O2 --gc-mode=marksweep"',
        )
        replace_once(path, "[target]\n", target)

    print(f"prepared json4cj checkout: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
