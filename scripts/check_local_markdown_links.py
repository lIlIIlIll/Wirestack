#!/usr/bin/env python3
"""Check that local Markdown link targets exist."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from urllib.parse import unquote


LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    missing: list[str] = []
    checked = 0
    for source in args.paths:
        text = source.read_text(encoding="utf-8")
        for raw_target in LINK.findall(text):
            target = raw_target.strip().strip("<>").split("#", 1)[0]
            if not target or "://" in target or target.startswith(("mailto:", "data:")):
                continue
            checked += 1
            resolved = (source.parent / unquote(target)).resolve()
            if not resolved.exists():
                missing.append(f"{source}: {raw_target}")
    if missing:
        raise SystemExit("missing local Markdown links:\n" + "\n".join(missing))
    print(f"Local Markdown links exist: {checked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
