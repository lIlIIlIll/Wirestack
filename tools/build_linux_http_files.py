#!/usr/bin/env python3
"""Build the Linux HTTP filesystem bridge into a fingerprinted static archive."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import fcntl
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


MAX_CACHE_ENTRIES = 4
COMPILE_FLAGS = (
    "-std=c11",
    "-O2",
    "-fPIC",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-D_POSIX_C_SOURCE=200809L",
)


class BuildError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def run(command: Sequence[str], *, cwd: Path) -> str:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        raise BuildError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout[-8000:]}"
        )
    return completed.stdout


def find_tool(environment_name: str, candidates: tuple[str, ...]) -> str:
    configured = os.environ.get(environment_name)
    if configured:
        resolved = configured if Path(configured).is_absolute() else shutil.which(configured)
        if resolved and Path(resolved).is_file():
            return str(Path(resolved).absolute())
        raise BuildError(f"{environment_name} does not name an executable: {configured}")
    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            # Preserve argv[0] for multicall tools such as llvm-ar/llvm-ranlib.
            return str(Path(resolved).absolute())
    raise BuildError(f"required tool is unavailable: {', '.join(candidates)}")


def platform_identity() -> dict[str, str]:
    if sys.platform != "linux":
        raise BuildError("the HTTP filesystem bridge requires Linux")
    machine = platform.machine().lower()
    if machine not in {"x86_64", "amd64"}:
        raise BuildError(f"unsupported Linux architecture: {machine}")
    libc_name, libc_version = platform.libc_ver()
    if "musl" in libc_name.lower():
        raise BuildError("the HTTP filesystem bridge release profile requires glibc")
    return {
        "os": "linux",
        "architecture": "x86_64",
        "libc": "glibc",
        "libc_version": libc_version or "unknown",
    }


def tool_identity(path: str, *, cwd: Path) -> dict[str, str]:
    output = run([path, "--version"], cwd=cwd).splitlines()
    if not output:
        raise BuildError(f"tool did not report a version: {path}")
    return {"path": path, "version": output[0].strip()}


def build_fingerprint(
    repo: Path,
    source: Path,
    header: Path,
    tools: Mapping[str, str],
    target: Mapping[str, str],
) -> tuple[str, dict[str, Any]]:
    compiler_target = run([tools["cc"], "-dumpmachine"], cwd=repo).strip()
    if not compiler_target:
        raise BuildError("C compiler did not report a target")
    if (
        not compiler_target.startswith("x86_64")
        or "linux" not in compiler_target
        or "musl" in compiler_target
    ):
        raise BuildError(
            f"C compiler target is incompatible with Linux x86_64 glibc: {compiler_target}"
        )
    inputs: dict[str, Any] = {
        "schema_version": 1,
        "builder_sha256": evidence_digest.text_evidence_sha256(Path(__file__).resolve()),
        "sources": {
            source.relative_to(repo).as_posix(): evidence_digest.text_evidence_sha256(source),
            header.relative_to(repo).as_posix(): evidence_digest.text_evidence_sha256(header),
        },
        "tools": {
            name: tool_identity(path, cwd=repo)
            for name, path in sorted(tools.items())
        },
        "compiler_target": compiler_target,
        "target": dict(target),
        "compile_flags": list(COMPILE_FLAGS),
        "archive_flags": ["rcsD"],
    }
    return evidence_digest.text_evidence_bytes_sha256(canonical_json(inputs)), inputs


def activate(output_root: Path, final_dir: Path) -> None:
    current = output_root / "current"
    if current.exists() and not current.is_symlink():
        raise BuildError(f"refusing to replace non-symlink HTTP files path: {current}")
    temporary = output_root / f".current-{os.getpid()}"
    if temporary.is_symlink() or temporary.is_file():
        temporary.unlink()
    elif temporary.exists():
        raise BuildError(f"temporary activation path is not replaceable: {temporary}")
    temporary.symlink_to(final_dir.relative_to(output_root), target_is_directory=True)
    try:
        os.replace(temporary, current)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def prune_cache(output_root: Path, keep: Path, *, reserve_new: bool = False) -> None:
    cache_root = output_root / "cache"
    if not cache_root.is_dir():
        return
    entries = [path for path in cache_root.iterdir() if path.is_dir()]
    entries.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    protected = {keep.resolve()}
    current = output_root / "current"
    if current.is_symlink():
        protected.add(current.resolve())
    limit = MAX_CACHE_ENTRIES - (1 if reserve_new and not keep.exists() else 0)
    for path in reversed(entries):
        if len(entries) <= limit:
            break
        if path.resolve() in protected:
            continue
        shutil.rmtree(path)
        entries.remove(path)
    if len(entries) > limit:
        raise BuildError("HTTP files cache capacity is held by active build entries")


def validate_cached(final_dir: Path, fingerprint: str) -> dict[str, Any] | None:
    archive = final_dir / "lib/libwirestack_http_files.a"
    manifest_path = final_dir / "http-files-manifest.json"
    if not archive.is_file() or not manifest_path.is_file():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if (
        not isinstance(manifest, dict)
        or manifest.get("schema_version") != 1
        or manifest.get("component") != "wirestack-http-files"
        or manifest.get("build_fingerprint") != fingerprint
        or manifest.get("abi_version") != 1
        or manifest.get("archive", {}).get("path") != "lib/libwirestack_http_files.a"
        or manifest.get("archive", {}).get("bytes") != archive.stat().st_size
    ):
        return None
    if not evidence_digest.schema_artifact_sha256_equal(
        manifest.get("archive", {}).get("sha256"),
        evidence_digest.artifact_byte_sha256(archive),
    ):
        return None
    return manifest


def _build_unlocked(repo: Path, output_root: Path) -> tuple[Path, dict[str, Any]]:
    target = platform_identity()
    source_dir = repo / "native/http_files"
    source = source_dir / "wirestack_http_files.c"
    header = source_dir / "wirestack_http_files.h"
    if not source.is_file() or not header.is_file():
        raise BuildError("HTTP filesystem bridge source is incomplete")
    tools = {
        "cc": find_tool("CC", ("/usr/lib/llvm15/bin/clang", "clang", "cc")),
        "ar": find_tool("AR", ("llvm-ar", "ar")),
        "ranlib": find_tool("RANLIB", ("llvm-ranlib", "ranlib")),
    }
    fingerprint, inputs = build_fingerprint(repo, source, header, tools, target)
    final_dir = output_root / "cache" / fingerprint
    cached = validate_cached(final_dir, fingerprint)
    prune_cache(output_root, final_dir, reserve_new=cached is None)
    if cached is not None:
        activate(output_root, final_dir)
        return final_dir, cached

    work_root = output_root / "work"
    work_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f"{fingerprint[:12]}-", dir=work_root))
    try:
        object_path = staging / "wirestack_http_files.o"
        run(
            [
                tools["cc"],
                *COMPILE_FLAGS,
                f"-I{source_dir}",
                "-c",
                str(source),
                "-o",
                str(object_path),
            ],
            cwd=staging,
        )
        artifact = staging / "artifact"
        library_dir = artifact / "lib"
        include_dir = artifact / "include"
        library_dir.mkdir(parents=True)
        include_dir.mkdir(parents=True)
        archive = library_dir / "libwirestack_http_files.a"
        run([tools["ar"], "rcsD", str(archive), str(object_path)], cwd=staging)
        run([tools["ranlib"], str(archive)], cwd=staging)
        shutil.copy2(header, include_dir / header.name)

        smoke_source = staging / "smoke.c"
        smoke_source.write_text(
            """#include "wirestack_http_files.h"
int main(void) { return wirestack_http_files_abi_version() == 1u ? 0 : 1; }
""",
            encoding="utf-8",
        )
        smoke_binary = staging / "http-files-smoke"
        run(
            [
                tools["cc"],
                *COMPILE_FLAGS,
                f"-I{include_dir}",
                str(smoke_source),
                str(archive),
                "-o",
                str(smoke_binary),
            ],
            cwd=staging,
        )
        run([str(smoke_binary)], cwd=staging)

        manifest: dict[str, Any] = {
            "schema_version": 1,
            "component": "wirestack-http-files",
            "abi_version": 1,
            "build_fingerprint": fingerprint,
            "platform": target,
            "inputs": inputs,
            "archive": {
                "path": "lib/libwirestack_http_files.a",
                "bytes": archive.stat().st_size,
                "sha256": evidence_digest.artifact_byte_sha256(archive),
            },
            "runtime_dependencies": ["libc"],
            "filesystem_model": "descriptor-relative Linux POSIX operations with bounded paths",
            "private_runtime_abi": False,
            "build_smoke": "PASS",
        }
        (artifact / "http-files-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        if final_dir.exists():
            shutil.rmtree(final_dir)
        os.replace(artifact, final_dir)
        activate(output_root, final_dir)
        prune_cache(output_root, final_dir)
        return final_dir, manifest
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def build(repo: Path, output_root: Path) -> tuple[Path, dict[str, Any]]:
    output_root.mkdir(parents=True, exist_ok=True)
    lock_path = output_root / ".build.lock"
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        return _build_unlocked(repo, output_root)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = args.root.resolve()
    output_root = (args.output_root or repo / "target/native/http_files").resolve()
    try:
        final_dir, manifest = build(repo, output_root)
    except BuildError as error:
        print(f"HTTP files build failed: {error}")
        return 1
    if not args.quiet:
        print(json.dumps({"artifact": str(final_dir), "manifest": manifest}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
