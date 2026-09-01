#!/usr/bin/env python3
"""Prepare an isolated yjson copy for the json4cj T9 throughput comparison.

The input must be a copy without a .git directory.  The script narrows the
benchmark package to bench_t9_throughput.cj, verifies the nested container is
aligned with json4cj's T9 benchmark, adjusts serialization sinks, and can add the msgc SDK GC
option required by the comparison SDK.
"""

from __future__ import annotations

import argparse
from pathlib import Path


PROFILE = '\n[profile.customized-option]\ncfg = "--gc-mode=marksweep"\n'


def require_exact(text: str, expected: str, label: str) -> None:
    if expected not in text:
        raise RuntimeError(f"cannot find expected {label}")


def add_profile(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "[profile.customized-option]" not in text:
        path.write_text(text.rstrip() + PROFILE, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="isolated yjson source root")
    parser.add_argument(
        "--msgc-sdk-workarounds",
        action="store_true",
        help="add marksweep profile used with the msgc comparison SDK",
    )
    parser.add_argument(
        "--native-accel",
        action="store_true",
        help="enable yjson native primitives in the isolated benchmark",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    if (root / ".git").exists():
        raise RuntimeError("refusing to modify a Git worktree; pass an isolated copy")

    bench = root / "packages" / "benchmarks"
    source = bench / "src" / "bench_t9_throughput.cj"
    manifest = bench / "cjpm.toml"
    if not source.is_file() or not manifest.is_file():
        raise RuntimeError(f"not a yjson source copy: {root}")

    disabled = bench / "t9-disabled-sources"
    disabled.mkdir(exist_ok=True)
    for path in sorted((bench / "src").glob("*.cj")):
        if path.name != source.name:
            target = disabled / path.name
            if target.exists():
                path.unlink()
            else:
                path.rename(target)

    text = source.read_text(encoding="utf-8")
    require_exact(
        text,
        "HashMap<String, Array<Int64>>",
        "nested container type",
    )
    require_exact(
        text,
        'nestedColl.data.add("k${i}", t9BuildIntArray(10))',
        "nested container initialization",
    )
    lines: list[str] = []
    for line in text.splitlines():
        if "strSink = YJson.toJson(" in line:
            line = line.replace("strSink = YJson.toJson(", "sink = YJson.toJson(")
            if line.rstrip().endswith(")"):
                line = line.rstrip() + ".size"
        lines.append(line)
    source.write_text("\n".join(lines) + "\n", encoding="utf-8")

    manifest_text = manifest.read_text(encoding="utf-8")
    manifest_text = "\n".join(
        line
        for line in manifest_text.splitlines()
        if '"yjson_algorithms"' not in line
    ) + "\n"
    if args.native_accel and '"yjson_native_accel"' not in manifest_text:
        marker = '  "yjson_macros" = { path = "../yjson_macros" }\n'
        dependency = '  "yjson_native_accel" = { path = "../yjson_native_accel" }\n'
        if marker not in manifest_text:
            raise RuntimeError("cannot find benchmark dependency insertion point")
        manifest_text = manifest_text.replace(marker, marker + dependency)
    manifest.write_text(manifest_text, encoding="utf-8")

    lock = bench / "cjpm.lock"
    if lock.exists():
        lock.unlink()

    if args.msgc_sdk_workarounds:
        add_profile(root / "cjpm.toml")
        add_profile(root / "packages" / "yjson_macros" / "cjpm.toml")
        add_profile(manifest)

    if args.native_accel:
        text = source.read_text(encoding="utf-8")
        if "import yjson_native_accel.*" not in text:
            text = text.replace(
                "import yjson_macros.*\n",
                "import yjson_macros.*\nimport yjson_native_accel.*\n",
            )
        init_marker = '    var strSink: String = ""\n\n    init() {\n'
        if "YJsonNativeAccel.initialize()" not in text:
            if init_marker not in text:
                raise RuntimeError("cannot find T9 benchmark initializer")
            text = text.replace(
                init_marker,
                init_marker + "        YJsonNativeAccel.initialize()\n",
                1,
            )
        source.write_text(text, encoding="utf-8")

    print(f"prepared isolated T9 benchmark: {bench}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
