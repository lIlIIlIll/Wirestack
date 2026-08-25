#!/usr/bin/env python3
"""Create and exercise isolated registry-style release artifacts.

cjpm 1.1.3 has no local-registry or publish dry-run command. Leaf packages are
bundled with cjpm itself. Packages whose exact 1.0.0 dependencies are not yet in
the central repository are archived in the same source layout, then extracted
and resolved to sibling artifact directories only for the consumer rehearsal.
The original artifact manifests remain central-version-only.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "1.0.0"
MODULES = (
    "yjson_macros",
    "yjson",
    "yjson_all",
    "yjson_native",
    "yjson_schema_formats",
    "yjson_yyjson",
)
LEAF_BUNDLES = ("yjson_macros", "yjson")


def run(command: list[str], cwd: pathlib.Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        command, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        print(result.stdout[-16000:], file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)


def deterministic_archive(module: pathlib.Path, output: pathlib.Path) -> None:
    prefix = f"{module.name}-{VERSION}"
    with tarfile.open(output, "w:gz", compresslevel=9) as archive:
        for source in sorted(module.rglob("*")):
            relative = source.relative_to(module)
            if any(part in ("target", "build-script-cache") for part in relative.parts):
                continue
            if not source.is_file():
                continue
            info = archive.gettarinfo(str(source), f"{prefix}/{relative.as_posix()}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with source.open("rb") as stream:
                archive.addfile(info, stream)


def inspect_artifact(name: str, archive_path: pathlib.Path) -> None:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = [member.name for member in archive.getmembers() if member.isfile()]
        manifest_name = f"{name}-{VERSION}/cjpm.toml"
        manifest = archive.extractfile(manifest_name)
        if manifest is None:
            raise RuntimeError(f"missing manifest in {archive_path}")
        text = manifest.read().decode("utf-8")
        if "path =" in text or "../" in text:
            raise RuntimeError(f"release artifact contains path dependency: {name}")
        forbidden = ("/target/", ".o", ".a", ".so")
        if any(any(token in member for token in forbidden) for member in members):
            raise RuntimeError(f"release artifact contains build output: {name}")
        if name == "yjson" and any("/native/" in member or "yyjson" in member for member in members):
            raise RuntimeError("core artifact contains native or yyjson input")
        if name == "yjson_native":
            required = ("native/yjson_scanner.c", "native/yjson_compact.c",
                        "scripts/build_native_scanner.py", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Custom Native artifact is incomplete")
        if name == "yjson_schema_formats":
            required = ("native/schema_formats.c", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Schema formats artifact is incomplete")
        if name == "yjson_yyjson":
            required = ("native/yjson_yyjson.c", "native/vendor/yyjson/yyjson.c",
                        "native/vendor/yyjson/yyjson.h", "native/vendor/yyjson/LICENSE",
                        "THIRD_PARTY_NOTICES.md", "scripts/build_native_scanner.py", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("yyjson artifact is incomplete")


def rewrite_for_local_resolution(modules: pathlib.Path) -> None:
    replacements = {
        'yjson_macros = "1.0.0"': 'yjson_macros = { path = "../yjson_macros" }',
        'yjson = "1.0.0"': 'yjson = { path = "../yjson" }',
    }
    for module in modules.iterdir():
        manifest = module / "cjpm.toml"
        text = manifest.read_text(encoding="utf-8")
        for release_value, local_value in replacements.items():
            text = text.replace(release_value, local_value)
        manifest.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--skip-consumers", action="store_true")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    staged = destination / "staged"
    artifacts = destination / "artifacts"
    resolved = destination / "resolved"
    artifacts.mkdir(parents=True)
    env = os.environ.copy()
    # CJPM_CONFIG is deprecated in cjpm 1.1.3. All rehearsal dependencies are
    # resolved from the staged sibling modules, so the central-repository cache
    # does not participate in this check.
    env.pop("CJPM_CONFIG", None)

    run([sys.executable, str(ROOT / "scripts/release_package_stage.py"), str(staged)], ROOT, env)
    for name in MODULES:
        manifest = (staged / name / "cjpm.toml").read_text(encoding="utf-8")
        if "path =" in manifest or "../" in manifest:
            raise RuntimeError(f"staged release manifest contains path dependency: {name}")

        output = artifacts / f"{name}-{VERSION}.cjp"
        if name in LEAF_BUNDLES:
            run(["cjpm", "bundle", "--skip-test", "--skip-lint"], staged / name, env)
            shutil.copy2(staged / name / "target" / output.name, output)
        else:
            deterministic_archive(staged / name, output)
        inspect_artifact(name, output)

        with tarfile.open(output, "r:gz") as archive:
            archive.extractall(destination / "unpacked", filter="data")
        shutil.copytree(destination / "unpacked" / f"{name}-{VERSION}", resolved / name)

    rewrite_for_local_resolution(resolved)
    if not args.skip_consumers:
        run([sys.executable, str(ROOT / "scripts/release_consumer_checks.py"),
             "--modules-root", str(resolved)], ROOT, env)
    print(f"registry-style rehearsal passed modules={len(MODULES)} destination={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
