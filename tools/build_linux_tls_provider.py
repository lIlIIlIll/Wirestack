#!/usr/bin/env python3
"""Build Wirestack's pinned Linux AWS-LC provider into one static archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


REQUIRED_PROVIDER_ID = "aws-lc"
REQUIRED_PROVIDER_VERSION = "5.5.0"
REQUIRED_COMMIT = "991e67ff4cf04df4dd89e407f8b920c6936cb56a"
REQUIRED_TREE = "ae54cd9455f9630451d505855afe808a9f028b25"
REQUIRED_CONTENT_SHA256 = "0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478"
REQUIRED_CAPABILITIES = (
    "customRoots",
    "clientCert",
    "server",
    "tls12",
    "tls13",
    "http2",
    "externalSigner",
    "sessionResumption",
    "secureRandom",
)


class BuildError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def run(
    command: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str] | None = None,
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        env=None if env is None else dict(env),
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        rendered = " ".join(command)
        raise BuildError(
            f"command failed ({completed.returncode}): {rendered}\n{completed.stdout}"
        )
    return completed


def load_provider_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildError(f"cannot read provider manifest {path}: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise BuildError("provider manifest schema_version must be 1")
    if manifest.get("provider_id") != REQUIRED_PROVIDER_ID:
        raise BuildError("provider_id is not the accepted Linux provider")
    if manifest.get("provider_version") != REQUIRED_PROVIDER_VERSION:
        raise BuildError("provider_version differs from ADR-0003")
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise BuildError("provider source object is required")
    expected_source = {
        "kind": "git",
        "commit": REQUIRED_COMMIT,
        "tree": REQUIRED_TREE,
        "content_sha256": REQUIRED_CONTENT_SHA256,
    }
    for field, expected in expected_source.items():
        if source.get(field) != expected:
            raise BuildError(f"provider source {field} differs from retained evidence")
    if manifest.get("patches") != []:
        raise BuildError("repository-controlled patches must be explicitly reviewed first")
    capabilities = manifest.get("capabilities")
    if capabilities != list(REQUIRED_CAPABILITIES):
        raise BuildError("provider capability inventory changed or is out of order")
    options = manifest.get("cmake_options")
    if not isinstance(options, list) or not all(isinstance(item, str) for item in options):
        raise BuildError("cmake_options must be an ordered string list")
    required_options = {
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_TOOL=OFF",
        "-DDISABLE_GO=ON",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    }
    if set(options) != required_options or len(options) != len(required_options):
        raise BuildError("AWS-LC build options differ from the accepted static profile")
    return manifest


def git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["GIT_CONFIG_GLOBAL"] = os.devnull
    environment["GIT_CONFIG_SYSTEM"] = os.devnull
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    return environment


def verify_source(source: Path, manifest: Mapping[str, Any]) -> dict[str, str]:
    if not (source / ".git").is_dir():
        raise BuildError(f"AWS-LC source is not a Git checkout: {source}")
    environment = git_environment()
    commit = run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        cwd=source,
        env=environment,
    ).stdout.strip()
    tree = run(
        ["git", "-C", str(source), "rev-parse", "HEAD^{tree}"],
        cwd=source,
        env=environment,
    ).stdout.strip()
    expected = manifest["source"]
    if commit != expected["commit"]:
        raise BuildError(f"AWS-LC commit mismatch: expected {expected['commit']}, got {commit}")
    if tree != expected["tree"]:
        raise BuildError(f"AWS-LC tree mismatch: expected {expected['tree']}, got {tree}")
    dirty = run(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"],
        cwd=source,
        env=environment,
    ).stdout.strip()
    if dirty:
        raise BuildError("AWS-LC source checkout contains tracked or untracked changes")
    content_digest = hashlib.sha256(f"{commit}\n{tree}\n".encode()).hexdigest()
    if content_digest != expected["content_sha256"]:
        raise BuildError("AWS-LC retained source fingerprint mismatch")
    return {"commit": commit, "tree": tree, "content_sha256": content_digest}


def acquire_source(
    manifest: Mapping[str, Any],
    cache_root: Path,
    override: Path | None,
    offline: bool,
) -> tuple[Path, dict[str, str]]:
    if override is not None:
        source = override.resolve()
        return source, verify_source(source, manifest)
    source = cache_root / "source" / "aws-lc-5.5.0"
    if source.exists():
        return source, verify_source(source, manifest)
    if offline:
        raise BuildError("pinned AWS-LC source is absent and --offline was requested")
    source.parent.mkdir(parents=True, exist_ok=True)
    environment = git_environment()
    run(["git", "init", str(source)], cwd=source.parent, env=environment)
    run(
        ["git", "-C", str(source), "remote", "add", "origin", manifest["source"]["url"]],
        cwd=source.parent,
        env=environment,
    )
    run(
        [
            "git",
            "-C",
            str(source),
            "fetch",
            "--depth",
            "1",
            "origin",
            manifest["source"]["commit"],
        ],
        cwd=source.parent,
        env=environment,
    )
    run(
        ["git", "-C", str(source), "checkout", "--detach", "FETCH_HEAD"],
        cwd=source.parent,
        env=environment,
    )
    return source, verify_source(source, manifest)


def resolve_tool(explicit: str | None, preferred: str, fallback: str) -> str:
    if explicit:
        resolved = shutil.which(explicit) if os.sep not in explicit else explicit
        if resolved and Path(resolved).is_file():
            return str(Path(resolved).resolve())
        raise BuildError(f"required tool not found: {explicit}")
    if Path(preferred).is_file():
        return preferred
    resolved = shutil.which(fallback)
    if resolved is None:
        raise BuildError(f"required tool not found: {fallback}")
    return str(Path(resolved).resolve())


def tool_version(command: str) -> str:
    return run([command, "--version"], cwd=Path.cwd()).stdout.splitlines()[0].strip()


def platform_identity() -> dict[str, str]:
    if sys.platform != "linux":
        raise BuildError("the selected provider build currently supports Linux only")
    machine = platform.machine().lower()
    if machine not in {"x86_64", "aarch64"}:
        raise BuildError(f"unsupported Linux architecture: {machine}")
    libc_name, libc_version = platform.libc_ver()
    libc = "musl" if "musl" in libc_name.lower() else "glibc"
    return {
        "os": "linux",
        "architecture": machine,
        "libc": libc,
        "libc_version": libc_version or "unknown",
    }


def build_input_fingerprint(
    manifest: Mapping[str, Any],
    shim_source: Path,
    shim_header: Path,
    tools: Mapping[str, str],
    target: Mapping[str, str],
) -> tuple[str, dict[str, Any]]:
    value = {
        "builder_sha256": sha256_path(Path(__file__).resolve()),
        "provider": manifest,
        "shim": {
            "source_sha256": sha256_path(shim_source),
            "header_sha256": sha256_path(shim_header),
        },
        "tools": dict(tools),
        "target": dict(target),
    }
    return hashlib.sha256(canonical_json(value)).hexdigest(), value


def find_archive(prefix: Path, name: str) -> Path:
    matches = list(prefix.rglob(name))
    if len(matches) != 1:
        raise BuildError(f"expected exactly one {name} below {prefix}, found {len(matches)}")
    return matches[0]


def activate_build(output_root: Path, final_dir: Path) -> None:
    current = output_root / "current"
    if current.exists() and not current.is_symlink():
        raise BuildError(f"refusing to replace non-symlink provider path: {current}")
    temporary = output_root / f".current-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        temporary.unlink()
    temporary.symlink_to(final_dir.relative_to(output_root), target_is_directory=True)
    os.replace(temporary, current)


def validate_cached_build(final_dir: Path, fingerprint: str) -> dict[str, Any] | None:
    archive = final_dir / "lib" / "libwirestack_tls_provider.a"
    manifest_path = final_dir / "provider-manifest.json"
    if not archive.is_file() or not manifest_path.is_file():
        return None
    try:
        build_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if build_manifest.get("build_fingerprint") != fingerprint:
        return None
    if build_manifest.get("archive", {}).get("sha256") != sha256_path(archive):
        return None
    if build_manifest.get("externalOpenSslDependency") is not False:
        return None
    return build_manifest


def build_provider(
    repo: Path,
    source: Path,
    source_identity: Mapping[str, str],
    manifest: Mapping[str, Any],
    output_root: Path,
    tools: Mapping[str, str],
    target: Mapping[str, str],
) -> tuple[Path, dict[str, Any]]:
    shim_dir = repo / "native" / "tls" / "aws_lc"
    shim_source = shim_dir / "wirestack_tls_provider.c"
    shim_header = shim_dir / "wirestack_tls_provider.h"
    fingerprint, build_inputs = build_input_fingerprint(
        manifest, shim_source, shim_header, tools, target
    )
    final_dir = output_root / "cache" / fingerprint
    cached = validate_cached_build(final_dir, fingerprint)
    if cached is not None:
        activate_build(output_root, final_dir)
        return final_dir, cached

    output_root.mkdir(parents=True, exist_ok=True)
    work_parent = output_root / "work"
    work_parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f"{fingerprint[:12]}-", dir=work_parent))
    try:
        build_dir = staging / "build"
        prefix = staging / "prefix"
        jobs = str(max(2, min(os.cpu_count() or 2, 4)))
        configure = [
            tools["cmake"],
            "-S",
            str(source),
            "-B",
            str(build_dir),
            "-GNinja",
            f"-DCMAKE_C_COMPILER={tools['cc']}",
            f"-DCMAKE_CXX_COMPILER={tools['cxx']}",
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
            *manifest["cmake_options"],
        ]
        run(configure, cwd=staging)
        run(
            [tools["cmake"], "--build", str(build_dir), "--target", "install", "--parallel", jobs],
            cwd=staging,
        )
        ssl_archive = find_archive(prefix, "libssl.a")
        crypto_archive = find_archive(prefix, "libcrypto.a")
        shim_object = staging / "wirestack_tls_provider.o"
        run(
            [
                tools["cc"],
                "-std=c11",
                "-O2",
                "-fPIC",
                "-Wall",
                "-Wextra",
                "-Werror",
                f"-I{prefix / 'include'}",
                f"-I{shim_dir}",
                "-c",
                str(shim_source),
                "-o",
                str(shim_object),
            ],
            cwd=staging,
        )
        artifact_dir = staging / "artifact"
        library_dir = artifact_dir / "lib"
        include_dir = artifact_dir / "include"
        library_dir.mkdir(parents=True)
        include_dir.mkdir(parents=True)
        combined = library_dir / "libwirestack_tls_provider.a"
        mri = "\n".join(
            [
                f"CREATE {combined}",
                f"ADDMOD {shim_object}",
                f"ADDLIB {ssl_archive}",
                f"ADDLIB {crypto_archive}",
                "SAVE",
                "END",
                "",
            ]
        )
        run([tools["ar"], "-M"], cwd=staging, stdin=mri)
        run([tools["ranlib"], str(combined)], cwd=staging)
        shutil.copy2(shim_header, include_dir / shim_header.name)

        smoke_source = staging / "smoke.c"
        smoke_source.write_text(
            """#include "wirestack_tls_provider.h"
#include <stdint.h>
int main(void) {
  uint64_t handle = 0; unsigned char data[32] = {0};
  if (wirestack_tls_provider_create(&handle) != 0) return 1;
  if (wirestack_tls_provider_random(handle, data, sizeof(data)) != 0) return 2;
  if (wirestack_tls_provider_capabilities(handle) == 0) return 3;
  wirestack_tls_provider_destroy(handle); return 0;
}
""",
            encoding="utf-8",
        )
        smoke_object = staging / "smoke.o"
        run(
            [
                tools["cc"],
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                f"-I{include_dir}",
                "-c",
                str(smoke_source),
                "-o",
                str(smoke_object),
            ],
            cwd=staging,
        )
        smoke_binary = staging / "provider-smoke"
        run(
            [
                tools["cxx"],
                str(smoke_object),
                str(combined),
                "-pthread",
                "-ldl",
                "-lm",
                "-o",
                str(smoke_binary),
            ],
            cwd=staging,
        )
        run([str(smoke_binary)], cwd=staging)

        archive_bytes = combined.read_bytes()
        forbidden_strings = [
            value.decode()
            for value in (b"libssl.so", b"libcrypto.so")
            if value in archive_bytes
        ]
        if forbidden_strings:
            raise BuildError(f"runtime TLS loader strings found: {forbidden_strings}")
        build_manifest = {
            "schema_version": 1,
            "providerId": manifest["provider_id"],
            "providerVersion": manifest["provider_version"],
            "providerFingerprint": manifest["source"]["content_sha256"],
            "backend": manifest["abi"]["backend"],
            "abiVersion": manifest["abi"]["version"],
            "patchLevel": "abi-1;patches=none",
            "capabilities": manifest["capabilities"],
            "source": dict(source_identity),
            "target": dict(target),
            "build_fingerprint": fingerprint,
            "build_inputs": build_inputs,
            "archive": {
                "name": combined.name,
                "bytes": combined.stat().st_size,
                "sha256": sha256_path(combined),
            },
            "externalOpenSslDependency": False,
            "runtimeLoaderLibraryStrings": [],
        }
        (artifact_dir / "provider-manifest.json").write_bytes(canonical_json(build_manifest))
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        if final_dir.exists():
            cached = validate_cached_build(final_dir, fingerprint)
            if cached is None:
                raise BuildError(f"invalid provider cache already exists: {final_dir}")
            build_manifest = cached
        else:
            os.replace(artifact_dir, final_dir)
        activate_build(output_root, final_dir)
        return final_dir, build_manifest
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--print-manifest", action="store_true")
    parser.add_argument("--cc")
    parser.add_argument("--cxx")
    parser.add_argument("--cmake")
    parser.add_argument("--ar")
    parser.add_argument("--ranlib")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    provider_dir = repo / "native" / "tls" / "aws_lc"
    manifest = load_provider_manifest(provider_dir / "provider.json")
    output_root = (args.out_dir or repo / "target" / "native").resolve()
    cache_root = (args.cache_dir or repo / ".local" / "tls-provider").resolve()
    source_override = args.source_dir
    if source_override is None:
        source_env = os.environ.get("WIRESTACK_AWS_LC_SOURCE")
        source_override = Path(source_env) if source_env else None
    tools = {
        "cc": resolve_tool(args.cc, "/usr/lib/llvm15/bin/clang", "clang"),
        "cxx": resolve_tool(args.cxx, "/usr/lib/llvm15/bin/clang++", "clang++"),
        "cmake": resolve_tool(args.cmake, "/usr/bin/cmake", "cmake"),
        "ar": resolve_tool(args.ar, "/usr/lib/llvm15/bin/llvm-ar", "llvm-ar"),
        "ranlib": resolve_tool(args.ranlib, "/usr/lib/llvm15/bin/llvm-ranlib", "llvm-ranlib"),
    }
    tool_identities = {name: tool_version(path) for name, path in tools.items()}
    tools_with_versions = {
        **tools,
        **{f"{name}_version": value for name, value in tool_identities.items()},
    }
    target = platform_identity()
    fingerprint, _ = build_input_fingerprint(
        manifest,
        provider_dir / "wirestack_tls_provider.c",
        provider_dir / "wirestack_tls_provider.h",
        tools_with_versions,
        target,
    )
    cached_dir = output_root / "cache" / fingerprint
    cached_manifest = validate_cached_build(cached_dir, fingerprint)
    if cached_manifest is not None:
        activate_build(output_root, cached_dir)
        if args.print_manifest:
            print(json.dumps(cached_manifest, indent=2, sort_keys=True))
        else:
            print(f"Linux TLS provider ready: {cached_dir}")
        return 0
    source, source_identity = acquire_source(
        manifest, cache_root, source_override, args.offline
    )
    final_dir, build_manifest = build_provider(
        repo,
        source,
        source_identity,
        manifest,
        output_root,
        tools_with_versions,
        target,
    )
    if args.print_manifest:
        print(json.dumps(build_manifest, indent=2, sort_keys=True))
    else:
        print(f"Linux TLS provider ready: {final_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
