#!/usr/bin/env python3
"""Native Windows x86_64 adapter for the provider-neutral M0-016 PoC runner.

The canonical runner is intentionally platform-neutral. This adapter supplies
only the source, build, link and dependency-inspection details required by a
native MSYS2 UCRT64 toolchain on a GitHub-hosted Windows runner.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import re
from pathlib import Path
from typing import Any, Mapping, Sequence

BASE_PATH = Path(__file__).with_name("run.py")
MODULE_SPEC = importlib.util.spec_from_file_location("wirestack_tls_provider_poc_run", BASE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError(f"cannot load canonical runner: {BASE_PATH}")
base = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(base)

# Capture canonical callables before installing the platform hooks. Calling
# base.build_provider after replacement would recurse back into this adapter.
CANONICAL_SOURCE_PROVIDER = base.source_provider
CANONICAL_BUILD_PROVIDER = base.build_provider

FORBIDDEN_DLL_TOKEN_RE = re.compile(
    r"(?:lib)?(?:ssl|crypto|mbedtls|mbedx509|tfpsacrypto|mbedcrypto)", re.I
)
DLL_NAME_RE = re.compile(r"DLL Name:\s*([^\r\n]+)", re.I)
ASCII_DLL_RE = re.compile(rb"[A-Za-z0-9_.+\-]+\.dll", re.I)


def platform_id() -> str:
    return "windows-x86_64"


def forbidden_windows_dependencies(text: str) -> list[str]:
    return sorted({
        name.strip()
        for name in DLL_NAME_RE.findall(text)
        if FORBIDDEN_DLL_TOKEN_RE.search(name)
    })


def git_tree_command(src: Path) -> list[str]:
    # MSYS argument conversion rewrites HEAD^{tree} to HEAD^tree. `%T` asks Git
    # for the same commit-tree object without braces and is stable on all Git
    # implementations used by the native Windows runner.
    return ["git", "-C", str(src), "show", "-s", "--format=%T", "HEAD"]


def mbedtls_system_libraries() -> list[str]:
    # TF-PSA-Crypto's Windows entropy implementation calls BCryptGenRandom.
    # This is an OS entropy API, not a TLS provider dependency.
    return ["-pthread", "-lm", "-lws2_32", "-lbcrypt"]


def source_provider(
    spec: Mapping[str, Any], work: Path, log: Path
) -> tuple[Path, dict[str, Any]]:
    if spec["source_kind"] != "git":
        return CANONICAL_SOURCE_PROVIDER(spec, work, log)

    source_root = work / "source"
    source_root.mkdir(parents=True, exist_ok=True)
    src = source_root / spec["id"]
    base.run(["git", "init", str(src)], cwd=work, log=log)
    base.run([
        "git", "-C", str(src), "remote", "add", "origin", spec["url"]
    ], cwd=work, log=log)
    base.run([
        "git", "-C", str(src), "fetch", "--depth", "1", "origin", spec["commit"]
    ], cwd=work, log=log)
    base.run([
        "git", "-C", str(src), "checkout", "--detach", "FETCH_HEAD"
    ], cwd=work, log=log)
    commit = base.run([
        "git", "-C", str(src), "rev-parse", "HEAD"
    ], cwd=work, log=log).stdout.strip()
    if commit != spec["commit"]:
        raise base.PocError(f"commit mismatch: {commit}")
    tree = base.run(git_tree_command(src), cwd=work, log=log).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise base.PocError(f"invalid Git tree object: {tree!r}")
    digest = hashlib.sha256((commit + "\n" + tree + "\n").encode()).hexdigest()
    return src, {
        "commit": commit,
        "tree": tree,
        "content_sha256": digest,
        "kind": "git",
    }


def build_provider(
    spec: Mapping[str, Any], src: Path, work: Path, log: Path
) -> tuple[Path, list[Path]]:
    if spec["id"] != "openssl":
        return CANONICAL_BUILD_PROVIDER(spec, src, work, log)

    prefix = work / "prefix"
    jobs = str(max(2, min(os.cpu_count() or 2, 4)))
    env = os.environ.copy()
    env["CFLAGS"] = "-O2"
    target = env.get("WIRESTACK_OPENSSL_WINDOWS_TARGET", "mingw64")
    base.run([
        "perl", str(src / "Configure"), target,
        "no-shared", "no-module", "no-tests", "no-zlib", "no-zstd",
        f"--prefix={prefix.as_posix()}", "--libdir=lib",
    ], cwd=src, log=log, env=env)
    base.run(["make", f"-j{jobs}"], cwd=src, log=log, env=env)
    base.run(["make", "install_sw"], cwd=src, log=log, env=env)
    archives = [
        base.find_one(prefix, ["libssl.a"]),
        base.find_one(prefix, ["libcrypto.a"]),
    ]
    return prefix, archives


def compile_poc(
    spec: Mapping[str, Any], repo: Path, prefix: Path,
    archives: Sequence[Path], work: Path, log: Path,
) -> Path:
    output = work / "provider-poc.exe"
    include = prefix / "include"
    cc = os.environ.get("CC", "gcc")
    cxx = os.environ.get("CXX", "g++")

    if spec["poc_family"] == "openssl-compatible":
        source = repo / "tools/tls_provider_poc/openssl_memory_poc.c"
        obj = work / "poc.o"
        base.run([
            cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{include}", "-c", str(source), "-o", str(obj),
        ], cwd=work, log=log)
        base.run([
            cxx, str(obj), *[str(archive) for archive in archives],
            "-pthread", "-lm", "-lws2_32", "-lcrypt32", "-lbcrypt",
            "-luser32", "-ladvapi32", "-o", str(output),
        ], cwd=work, log=log)
    else:
        source = repo / "tools/tls_provider_poc/mbedtls_memory_poc.c"
        base.run([
            cc, "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{include}", str(source), *[str(archive) for archive in archives],
            *mbedtls_system_libraries(), "-o", str(output),
        ], cwd=work, log=log)

    if not output.is_file():
        raise base.PocError(f"Windows linker reported success but output is missing: {output}")
    return output


def inspect_binary(
    binary: Path, archives: Sequence[Path], work: Path, log: Path
) -> dict[str, Any]:
    completed = base.run(["objdump", "-p", str(binary)], cwd=work, log=log, check=False)
    dependencies = forbidden_windows_dependencies(completed.stdout)
    data = binary.read_bytes()
    embedded = sorted({
        match.group(0).decode("ascii", errors="replace")
        for match in ASCII_DLL_RE.finditer(data)
        if FORBIDDEN_DLL_TOKEN_RE.search(match.group(0).decode("ascii", errors="ignore"))
    })
    return {
        "binary_bytes": binary.stat().st_size,
        "binary_sha256": base.sha256_path(binary),
        "static_archives": [
            {
                "name": archive.name,
                "bytes": archive.stat().st_size,
                "sha256": base.sha256_path(archive),
            }
            for archive in archives
        ],
        "system_tls_dependencies": dependencies,
        "runtime_loader_library_strings": embedded,
    }


base.platform_id = platform_id
base.source_provider = source_provider
base.build_provider = build_provider
base.compile_poc = compile_poc
base.inspect_binary = inspect_binary


if __name__ == "__main__":
    raise SystemExit(base.main())
