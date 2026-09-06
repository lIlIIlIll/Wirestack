#!/usr/bin/env python3
"""Prepare an isolated cangjieJSON (cjjson) copy for the T9 throughput matrix.

The copy must already contain the T9 port at src/test/T9BenchThroughput_test.cj
(the orchestrator copies it from benchmarks/t9-ports/cjjson).  The script
normalizes the manifest's ${CANGJIE_STDX_PATH} convention to the <stdx-dir>
convention used by the yjson/json4cj harness (CANGJIE_STDX_PATH resolves to
$SDK/linux_x86_64_cjnative/dynamic/stdx), optionally injects the msgc marksweep
profile, and clears stale build state.

Path arithmetic for the link rewrite:
  CANGJIE_STDX_PATH = $SDK/linux_x86_64_cjnative/dynamic/stdx
  ../..            = $SDK/linux_x86_64_cjnative
  ../../static/stdx = $SDK/linux_x86_64_cjnative/static/stdx
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil


PROFILE = '\n[profile.customized-option]\ncfg = "--gc-mode=marksweep"\n'

# Fragments verified verbatim against cangjieJSON/cjpm.toml.
OLD_PATH_OPTION = "${CANGJIE_STDX_PATH}/linux_x86_64_cjnative/dynamic/stdx"
NEW_PATH_OPTION = "${CANGJIE_STDX_PATH}"
OLD_LINK_OPTION = "-L${CANGJIE_STDX_PATH}/linux_x86_64_cjnative/static/stdx"
NEW_LINK_OPTION = "-L${CANGJIE_STDX_PATH}/../../static/stdx"


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        if new in text:
            return
        raise RuntimeError(f"expected manifest fragment not found: {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
def add_profile(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "[profile.customized-option]" not in text:
        path.write_text(text.rstrip() + PROFILE, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="isolated cangjieJSON source root")
    parser.add_argument(
        "--msgc-profile",
        action="store_true",
        help="add marksweep profile used with the msgc comparison SDK",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    if (root / ".git").exists():
        raise RuntimeError("refusing to modify a Git worktree; pass an isolated copy")

    manifest = root / "cjpm.toml"
    bench_test = root / "src" / "test" / "Bench_test.cj"
    t9_port = root / "src" / "test" / "T9BenchThroughput_test.cj"
    if not manifest.is_file() or not bench_test.is_file():
        raise RuntimeError(f"not a cangjieJSON source copy: {root}")
    if not t9_port.is_file():
        raise RuntimeError(f"T9 port missing; copy benchmarks/t9-ports/cjjson first: {t9_port}")

    # Normalize the stdx path convention to <stdx-dir> (both fragments occur once).
    replace_once(manifest, OLD_PATH_OPTION, NEW_PATH_OPTION)
    replace_once(manifest, OLD_LINK_OPTION, NEW_LINK_OPTION)

    if args.msgc_profile:
        add_profile(manifest)

    for stale in (root / "target", root / ".cjpm-history", root / ".dep-cache", root / "cjpm.lock"):
        if stale.is_dir():
            shutil.rmtree(stale)
        elif stale.exists():
            stale.unlink()

    print(f"prepared isolated T9 benchmark: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
