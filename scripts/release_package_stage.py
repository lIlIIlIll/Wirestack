#!/usr/bin/env python3
"""Stage self-contained cjpm modules from the monorepo release sources.

The checked-in manifests use path dependencies for repository development.
Release staging replaces them with central-repository version constraints. Use
--development only to validate all staged modules together before publication.
"""

import argparse
import pathlib
import shutil

from release_graph import ROOT, load_release_graph, local_dependency_replacements


GRAPH = load_release_graph()


def copy_path(source: pathlib.Path, target: pathlib.Path) -> None:
    if source.is_dir():
        shutil.copytree(source, target, ignore=shutil.ignore_patterns(
            "target", "build-script-cache", "*.o", "*.a", "*.so",
        ))
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def development_manifest(text: str) -> str:
    for release_value, path_value in local_dependency_replacements(GRAPH).items():
        text = text.replace(release_value, path_value)
    return text


def stage(package, destination: pathlib.Path, development: bool) -> None:
    name = package.name
    module = destination / package.name
    module.mkdir(parents=True)
    manifest = (ROOT / package.release_manifest).read_text(encoding="utf-8")
    if development:
        manifest = development_manifest(manifest)
    (module / "cjpm.toml").write_text(manifest, encoding="utf-8")

    if package.stage_kind == "core":
        copy_path(ROOT / package.source_root, module / "src")
        for relative in ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            copy_path(ROOT / relative, module / relative)
        return

    package_root = (ROOT / package.source_root).parent
    copy_path(ROOT / package.source_root, module / "src")
    if (package_root / "README.md").exists():
        copy_path(package_root / "README.md", module / "README.md")
    copy_path(ROOT / "LICENSE", module / "LICENSE")
    if package.stage_kind == "schema-formats":
        copy_path(package_root / "build.cj", module / "build.cj")
        copy_path(package_root / "native", module / "native")
    if package.stage_kind in ("native-primitives", "yyjson"):
        copy_path(package_root / "build.cj", module / "build.cj")
        copy_path(ROOT / "scripts" / "build_native_scanner.py", module / "scripts" / "build_native_scanner.py")
        native_files = ["yjson_scanner.c", "yjson_scanner.h", "yjson_compact.c", "yjson_compact.h",
                        "yjson_float_format.c"]
        if package.stage_kind == "yyjson":
            native_files += ["yjson_yyjson.c", "yjson_yyjson.h"]
        for filename in native_files:
            copy_path(ROOT / "native" / filename, module / "native" / filename)
        if package.stage_kind in ("native-primitives", "yyjson"):
            # yjson_float_format.c and the compact adapter compile the vendored
            # yyjson amalgamation directly; the source-only staged tree needs the
            # complete include closure, including the vendored license.
            copy_path(ROOT / "native" / "vendor" / "yyjson", module / "native" / "vendor" / "yyjson")
            copy_path(ROOT / "THIRD_PARTY_NOTICES.md", module / "THIRD_PARTY_NOTICES.md")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    for package in GRAPH.packages:
        stage(package, destination, args.development)
    print(f"staged modules={len(GRAPH.packages)} version={GRAPH.version} "
          f"mode={'development' if args.development else 'release'} destination={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
