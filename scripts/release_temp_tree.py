#!/usr/bin/env python3
"""Create a source-only release candidate tree from the checked manifest."""

import argparse
import pathlib
import shutil
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "release" / "release-files.txt"


def manifest_paths() -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe release manifest path: {value}")
        paths.append(pathlib.Path(*path.parts))
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    missing: list[str] = []
    copied = 0
    for relative in manifest_paths():
        source = ROOT / relative
        if not source.is_file():
            missing.append(relative.as_posix())
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied += 1
    if missing:
        print("release manifest contains missing files:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1

    forbidden = [destination / "target", destination / "build-script-cache"]
    if any(path.exists() for path in forbidden):
        raise RuntimeError("release tree unexpectedly contains build artifacts")
    print(f"release tree copied files={copied} destination={destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
