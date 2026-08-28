#!/usr/bin/env python3
"""Stage self-contained cjpm modules from the monorepo release sources.

The checked-in manifests use path dependencies for repository development.
Release staging replaces them with central-repository version constraints. Use
--development only to validate all staged modules together before publication.
"""

import argparse
import pathlib
import shutil


ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "release" / "package-manifests"
MODULES = (
    "yjson_macros",
    "yjson",
    "yjson_all",
    "yjson_native",
    "yjson_native_accel",
    "yjson_backends",
    "yjson_algorithms",
    "yjson_schema_formats",
    "yjson_yyjson",
)


def copy_path(source: pathlib.Path, target: pathlib.Path) -> None:
    if source.is_dir():
        shutil.copytree(source, target, ignore=shutil.ignore_patterns("target", "build-script-cache", "*.o", "*.a", "*.so"))
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def development_manifest(name: str, text: str) -> str:
    replacements = {
        'yjson_macros = "2.0.1"': 'yjson_macros = { path = "../yjson_macros" }',
        'yjson_native = "2.0.1"': 'yjson_native = { path = "../yjson_native" }',
        'yjson_backends = "2.0.1"': 'yjson_backends = { path = "../yjson_backends" }',
        'yjson_algorithms = "2.0.1"': 'yjson_algorithms = { path = "../yjson_algorithms" }',
        'yjson = "2.0.1"': 'yjson = { path = "../yjson" }',
    }
    for release_value, path_value in replacements.items():
        text = text.replace(release_value, path_value)
    return text


def stage(name: str, destination: pathlib.Path, development: bool) -> None:
    module = destination / name
    module.mkdir(parents=True)
    manifest = (TEMPLATES / f"{name}.toml").read_text(encoding="utf-8")
    if development:
        manifest = development_manifest(name, manifest)
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
    for name in MODULES:
        stage(name, destination, args.development)
    print(f"staged modules={len(MODULES)} mode={'development' if args.development else 'release'} destination={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
