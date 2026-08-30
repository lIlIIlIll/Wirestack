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
        shutil.copytree(source, target, ignore=shutil.ignore_patterns("target", "build-script-cache", "*.o", "*.a", "*.so"))
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

    if name == "yjson":
        for source in sorted((ROOT / "src").glob("lib_*.cj")):
            copy_path(source, module / "src" / source.name)
        for relative in ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            copy_path(ROOT / relative, module / relative)
        return

    package = ROOT / "packages" / name
    copy_path(package / "src", module / "src")
    if (package / "README.md").exists():
        copy_path(package / "README.md", module / "README.md")
    copy_path(ROOT / "LICENSE", module / "LICENSE")
    if name == "yjson_schema_formats":
        copy_path(package / "build.cj", module / "build.cj")
        copy_path(package / "native", module / "native")
    if name in ("yjson_native", "yjson_yyjson"):
        copy_path(package / "build.cj", module / "build.cj")
        copy_path(ROOT / "scripts" / "build_native_scanner.py", module / "scripts" / "build_native_scanner.py")
        native_files = ["yjson_scanner.c", "yjson_scanner.h", "yjson_compact.c", "yjson_compact.h"]
        if name == "yjson_yyjson":
            native_files += ["yjson_yyjson.c", "yjson_yyjson.h"]
        for filename in native_files:
            copy_path(ROOT / "native" / filename, module / "native" / filename)
    if name == "yjson_yyjson":
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
