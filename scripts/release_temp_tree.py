#!/usr/bin/env python3
"""Create a source-only release candidate tree from the checked manifest."""

import argparse
import ast
import pathlib
import re
import shutil
import sys

from stage_source_tree import assert_source_only


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "release" / "release-files.txt"


SCRIPT_PATH_PATTERN = re.compile(r"scripts/[A-Za-z0-9_./-]+\.(?:py|sh)")


def manifest_paths(manifest: pathlib.Path = MANIFEST) -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe release manifest path: {value}")
        paths.append(pathlib.Path(*path.parts))
    if len(paths) != len(set(paths)):
        raise ValueError("release manifest contains duplicate paths")
    return paths


def script_dependencies(root: pathlib.Path, relative: pathlib.Path) -> set[pathlib.Path]:
    source = root / relative
    text = source.read_text(encoding="utf-8")
    dependencies = {pathlib.Path(match) for match in SCRIPT_PATH_PATTERN.findall(text)}
    if relative.suffix != ".py":
        return dependencies
    try:
        tree = ast.parse(text, filename=relative.as_posix())
    except SyntaxError:
        return dependencies
    for node in ast.walk(tree):
        module = None
        if isinstance(node, ast.ImportFrom) and node.level == 0:
            module = node.module
        elif isinstance(node, ast.Import):
            for alias in node.names:
                candidate = root / "scripts" / f"{alias.name.split('.')[0]}.py"
                if candidate.is_file():
                    dependencies.add(candidate.relative_to(root))
        if module:
            candidate = root / "scripts" / f"{module.split('.')[0]}.py"
            if candidate.is_file():
                dependencies.add(candidate.relative_to(root))
    return dependencies


def validate_manifest_closure(root: pathlib.Path, paths: list[pathlib.Path]) -> None:
    included = set(paths)
    discovered_tests = {
        path.relative_to(root) for path in (root / "src").glob("test_*.cj") if path.is_file()
    }
    included_tests = {path for path in included if path.parent == pathlib.Path("src") and
                      path.name.startswith("test_") and path.suffix == ".cj"}
    missing_tests = sorted(discovered_tests - included_tests)

    missing_scripts: set[pathlib.Path] = set()
    for relative in sorted(included):
        if relative.parent != pathlib.Path("scripts") or relative.suffix not in (".py", ".sh"):
            continue
        for dependency in script_dependencies(root, relative):
            if (root / dependency).is_file() and dependency not in included:
                missing_scripts.add(dependency)

    if missing_tests or missing_scripts:
        details = [f"core test not in manifest: {path.as_posix()}" for path in missing_tests]
        details += [f"script dependency not in manifest: {path.as_posix()}" for path in sorted(missing_scripts)]
        raise ValueError("release manifest is not dependency-closed:\n  " + "\n  ".join(details))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    paths = manifest_paths()
    try:
        validate_manifest_closure(ROOT, paths)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    missing: list[str] = []
    copied = 0
    for relative in paths:
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

    assert_source_only(destination)
    print(f"release tree copied files={copied} destination={destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
