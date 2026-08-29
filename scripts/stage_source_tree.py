#!/usr/bin/env python3
"""Create and verify a source-only yjson working-tree stage."""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil


ROOT = pathlib.Path(__file__).resolve().parents[1]

EXCLUDED_DIRECTORY_NAMES = frozenset({
    ".agents",
    ".cache",
    ".ci",
    ".claude",
    ".codex",
    ".git",
    ".ruff_cache",
    "__pycache__",
    "build-script-cache",
    "cov_output",
    "coverage",
    "target",
})
EXCLUDED_DIRECTORY_PREFIXES = (
    ("benchmarks", "java_fastjson2", "build"),
    ("benchmarks", "results"),
)
EXCLUDED_FILE_SUFFIXES = frozenset({
    ".a",
    ".cjo",
    ".dll",
    ".dylib",
    ".gcda",
    ".gcno",
    ".o",
    ".pyc",
    ".so",
})


def is_excluded_directory(relative: pathlib.PurePath) -> bool:
    if relative.name in EXCLUDED_DIRECTORY_NAMES:
        return True
    parts = relative.parts
    return any(parts[:len(prefix)] == prefix for prefix in EXCLUDED_DIRECTORY_PREFIXES)


def is_excluded_file(relative: pathlib.PurePath) -> bool:
    return relative.suffix in EXCLUDED_FILE_SUFFIXES


def source_only_violations(root: pathlib.Path) -> list[str]:
    root = root.resolve(strict=True)
    violations: list[str] = []
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = pathlib.Path(current)
        relative_current = current_path.relative_to(root)
        kept_directories: list[str] = []
        for name in sorted(directories):
            path = current_path / name
            relative = relative_current / name
            if is_excluded_directory(relative) or path.is_symlink():
                violations.append(relative.as_posix())
            else:
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in files:
            path = current_path / name
            relative = relative_current / name
            if is_excluded_file(relative) or path.is_symlink():
                violations.append(relative.as_posix())
    return sorted(violations)


def assert_source_only(root: pathlib.Path) -> None:
    violations = source_only_violations(root)
    if violations:
        preview = ", ".join(violations[:8])
        if len(violations) > 8:
            preview += f", ... ({len(violations)} total)"
        raise ValueError(f"source-only tree contains generated or linked state: {preview}")


def stage_source_tree(source: pathlib.Path, destination: pathlib.Path) -> int:
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if not source.is_dir():
        raise ValueError(f"source is not a directory: {source}")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("source and destination must not overlap")
    if destination.exists() and any(destination.iterdir()):
        raise ValueError(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    copied = 0
    for current, directories, files in os.walk(source, followlinks=False):
        current_path = pathlib.Path(current)
        relative_current = current_path.relative_to(source)
        kept_directories: list[str] = []
        for name in sorted(directories):
            path = current_path / name
            relative = relative_current / name
            if is_excluded_directory(relative):
                continue
            if path.is_symlink():
                raise ValueError(f"source tree contains unsupported symlink: {relative.as_posix()}")
            kept_directories.append(name)
        directories[:] = kept_directories

        target_directory = destination / relative_current
        target_directory.mkdir(parents=True, exist_ok=True)
        for name in sorted(files):
            source_file = current_path / name
            relative = relative_current / name
            if is_excluded_file(relative):
                continue
            if source_file.is_symlink():
                raise ValueError(f"source tree contains unsupported symlink: {relative.as_posix()}")
            shutil.copy2(source_file, target_directory / name)
            copied += 1

    assert_source_only(destination)
    return copied


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=pathlib.Path)
    parser.add_argument("--source", type=pathlib.Path, default=ROOT)
    parser.add_argument("--check", type=pathlib.Path,
                        help="verify an existing tree instead of creating a stage")
    args = parser.parse_args()
    try:
        if args.check is not None:
            if args.destination is not None:
                parser.error("destination cannot be combined with --check")
            assert_source_only(args.check)
            print(f"source-only tree verified: {args.check.resolve()}")
            return 0
        if args.destination is None:
            parser.error("destination is required unless --check is used")
        copied = stage_source_tree(args.source, args.destination)
    except (OSError, ValueError) as error:
        parser.exit(2, f"error: {error}\n")
    print(f"source-only tree copied files={copied} destination={args.destination.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
