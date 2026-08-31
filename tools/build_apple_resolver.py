#!/usr/bin/env python3
"""Build the bounded resolver adapter for macOS or iOS Simulator."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path


SUPPORTED = {"macos-arm64", "ios-simulator-arm64"}
MAX_CACHE_ENTRIES = 4
LEASE_SCHEMA_VERSION = 1
LEASE_OWNER_ENV = "WIRESTACK_APPLE_CACHE_LEASE_PID"


class BuildError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        command,
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


def find_tool(name: str, candidates: tuple[str, ...]) -> str:
    configured = os.environ.get(name)
    if configured:
        resolved = configured if Path(configured).is_absolute() else shutil.which(configured)
        if resolved and Path(resolved).is_file():
            return str(Path(resolved).absolute())
        raise BuildError(f"{name} does not name an executable: {configured}")
    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return str(Path(resolved).absolute())
    raise BuildError(f"required tool is unavailable: {', '.join(candidates)}")


def xcrun_query(sdk: str, *arguments: str) -> str:
    xcrun = find_tool("XCRUN", ("xcrun",))
    return run([xcrun, "--sdk", sdk, *arguments]).strip()


def xcrun_find(tool: str, sdk: str) -> str:
    return xcrun_query(sdk, "--find", tool)


def build_fingerprint(
    sources: list[Path],
    tools: dict[str, str],
    selected: str,
    flags: list[str],
    test_fixture: bool,
) -> tuple[str, dict[str, object]]:
    compiler_version = run([tools["cc"], "--version"]).splitlines()[0]
    inputs: dict[str, object] = {
        "schema": 1,
        "platform": selected,
        "sources": {str(path): sha256_path(path) for path in sources},
        "compiler": tools["cc"],
        "compiler_version": compiler_version,
        "flags": flags,
        "test_fixture": test_fixture,
    }
    encoded = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), inputs


def publish_symlink(link: Path, target: Path) -> None:
    staging = link.with_name(f".{link.name}-{os.getpid()}")
    if staging.is_symlink() or staging.is_file():
        staging.unlink()
    elif staging.exists():
        raise BuildError(f"staging link path is not replaceable: {staging}")
    if link.exists() and not link.is_symlink():
        raise BuildError(f"published path is not an atomic symlink: {link}")
    staging.symlink_to(target, target_is_directory=True)
    try:
        os.replace(staging, link)
    finally:
        if staging.is_symlink():
            staging.unlink()


def activate(output_root: Path, final_dir: Path) -> None:
    relative_target = Path(os.path.relpath(final_dir, output_root))
    publish_symlink(output_root / "current", relative_target)


def process_identity(pid: int) -> str | None:
    completed = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        return None
    identity = completed.stdout.strip()
    return identity or None


def lease_owner_pid() -> int:
    raw = os.environ.get(LEASE_OWNER_ENV)
    if raw is None:
        return os.getppid()
    try:
        pid = int(raw)
    except ValueError as error:
        raise BuildError(f"{LEASE_OWNER_ENV} must be a process id") from error
    if pid <= 1:
        raise BuildError(f"{LEASE_OWNER_ENV} must name a live parent process")
    return pid


def register_cache_lease(final_dir: Path) -> None:
    pid = lease_owner_pid()
    identity = process_identity(pid)
    if identity is None:
        raise BuildError("cannot bind the resolver cache lease to its CJPM process")
    lease_root = final_dir / ".leases"
    lease_root.mkdir(parents=True, exist_ok=True)
    identity_digest = hashlib.sha256(identity.encode()).hexdigest()[:16]
    lease_path = lease_root / f"{pid}-{identity_digest}.json"
    temporary = lease_path.with_name(f".{lease_path.name}-{os.getpid()}")
    temporary.write_text(
        json.dumps(
            {
                "schema_version": LEASE_SCHEMA_VERSION,
                "pid": pid,
                "process_identity": identity,
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, lease_path)


def cache_entry_is_leased(entry: Path) -> bool:
    lease_root = entry / ".leases"
    if not lease_root.is_dir():
        return False
    active = False
    for lease_path in lease_root.iterdir():
        if not lease_path.is_file():
            raise BuildError(f"invalid resolver cache lease path: {lease_path}")
        try:
            lease = json.loads(lease_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise BuildError(f"invalid resolver cache lease: {lease_path}") from error
        pid = lease.get("pid")
        identity = lease.get("process_identity")
        if (
            lease.get("schema_version") != LEASE_SCHEMA_VERSION
            or type(pid) is not int
            or pid <= 1
            or not isinstance(identity, str)
            or not identity
        ):
            raise BuildError(f"invalid resolver cache lease: {lease_path}")
        if process_identity(pid) == identity:
            active = True
        else:
            lease_path.unlink()
    return active


def prune_cache(output_root: Path, keep: Path, *, reserve_new: bool = False) -> None:
    cache_root = output_root / "cache"
    if not cache_root.is_dir():
        return
    entries = [path for path in cache_root.iterdir() if path.is_dir()]
    entries.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    keep_resolved = keep.resolve()
    protected = {keep_resolved}
    for path in entries:
        if cache_entry_is_leased(path):
            protected.add(path.resolve())
    limit = MAX_CACHE_ENTRIES - (1 if reserve_new and not keep.exists() else 0)
    for path in reversed(entries):
        if len(entries) <= limit:
            break
        if path.resolve() in protected:
            continue
        shutil.rmtree(path)
        entries.remove(path)
    if len(entries) > limit:
        raise BuildError(
            "resolver cache capacity is held by active CJPM builds; retry after they exit"
        )


def validate_cached(final_dir: Path, fingerprint: str) -> dict[str, object] | None:
    archive = final_dir / "lib/libwirestack_resolver.a"
    manifest_path = final_dir / "resolver-manifest.json"
    if not archive.is_file() or not manifest_path.is_file():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if manifest.get("build_fingerprint") != fingerprint:
        return None
    if manifest.get("archive", {}).get("sha256") != sha256_path(archive):
        return None
    return manifest


def _build_unlocked(
    repo: Path,
    output_root: Path,
    *,
    selected: str,
    test_fixture: bool = False,
) -> tuple[Path, dict[str, object]]:
    if platform.system() != "Darwin" or platform.machine() not in {"arm64", "aarch64"}:
        raise BuildError("the Apple resolver bridge requires a native arm64 macOS host")
    if selected not in SUPPORTED:
        raise BuildError(f"unsupported Apple resolver platform: {selected}")
    source_dir = repo / "native/resolver/apple"
    source = source_dir / "wirestack_resolver.c"
    header = source_dir / "wirestack_resolver.h"
    shared_source = repo / "native/resolver/linux/wirestack_resolver.c"
    shared_header = repo / "native/resolver/linux/wirestack_resolver.h"
    sources = [source, header, shared_source, shared_header]
    if not all(path.is_file() for path in sources):
        raise BuildError("Apple resolver bridge source is incomplete")

    sdk = "macosx" if selected == "macos-arm64" else "iphonesimulator"
    tools = {
        "cc": xcrun_find("clang", sdk),
        "ar": xcrun_find("ar", sdk),
        "ranlib": xcrun_find("ranlib", sdk),
    }
    sdk_path = Path(xcrun_query(sdk, "--show-sdk-path")).resolve()
    flags = [
        "-std=c11", "-O2", "-fPIC", "-Wall", "-Wextra", "-Werror",
        "-arch", "arm64", "-isysroot", str(sdk_path),
    ]
    if selected == "macos-arm64":
        flags.append("-mmacosx-version-min=12.0")
    else:
        flags.append("-mios-simulator-version-min=11.0")
    if test_fixture:
        flags.append("-DWIRESTACK_RESOLVER_TEST_FIXTURE=1")
    fingerprint, inputs = build_fingerprint(sources, tools, selected, flags, test_fixture)
    final_dir = output_root / "cache" / fingerprint
    cached = validate_cached(final_dir, fingerprint)
    prune_cache(output_root, final_dir, reserve_new=cached is None)
    if cached is not None:
        register_cache_lease(final_dir)
        activate(output_root, final_dir)
        if selected == "ios-simulator-arm64":
            publish_symlink(output_root / "sdk", sdk_path)
        return final_dir, cached

    work_root = output_root / "work"
    work_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f"{fingerprint[:12]}-", dir=work_root))
    try:
        object_path = staging / "wirestack_resolver.o"
        run([tools["cc"], *flags, f"-I{source_dir}", "-c", str(source), "-o", str(object_path)])
        artifact = staging / "artifact"
        library_dir = artifact / "lib"
        include_dir = artifact / "include"
        library_dir.mkdir(parents=True)
        include_dir.mkdir(parents=True)
        archive = library_dir / "libwirestack_resolver.a"
        run([tools["ar"], "rcs", str(archive), str(object_path)])
        run([tools["ranlib"], str(archive)])
        shutil.copy2(shared_header, include_dir / "wirestack_resolver.h")

        smoke_status = "not-run-cross-target"
        if selected == "macos-arm64":
            smoke_source = staging / "smoke.c"
            smoke_source.write_text(
                """#include "wirestack_resolver.h"
#include <stdint.h>
int main(void) {
  uint64_t pool = 0;
  int64_t native_code = 0;
  if (wirestack_resolver_pool_create(1, 2, &pool, &native_code) != WIRESTACK_RESOLVER_OK) return 1;
  return wirestack_resolver_pool_destroy(pool);
}
""",
                encoding="utf-8",
            )
            smoke_binary = staging / "resolver-smoke"
            run([tools["cc"], *flags, f"-I{include_dir}", str(smoke_source), str(archive), "-o", str(smoke_binary)])
            run([str(smoke_binary)])
            smoke_status = "PASS"

        manifest: dict[str, object] = {
            "schema_version": 1,
            "build_fingerprint": fingerprint,
            "platform": selected,
            "inputs": inputs,
            "archive": {"path": "lib/libwirestack_resolver.a", "sha256": sha256_path(archive)},
            "worker_model": "fixed pthread pool with bounded FIFO admission",
            "close_model": "bounded quarantine with process-wide pool and worker caps",
            "private_runtime_abi": False,
            "test_fixture": test_fixture,
            "build_smoke": smoke_status,
        }
        (artifact / "resolver-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        if final_dir.exists():
            shutil.rmtree(final_dir)
        os.replace(artifact, final_dir)
        register_cache_lease(final_dir)
        activate(output_root, final_dir)
        if selected == "ios-simulator-arm64":
            publish_symlink(output_root / "sdk", sdk_path)
        return final_dir, manifest
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def build(
    repo: Path,
    output_root: Path,
    *,
    selected: str,
    test_fixture: bool = False,
) -> tuple[Path, dict[str, object]]:
    if platform.system() != "Darwin":
        return _build_unlocked(
            repo, output_root, selected=selected, test_fixture=test_fixture
        )
    import fcntl

    output_root.mkdir(parents=True, exist_ok=True)
    with (output_root / ".build.lock").open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        return _build_unlocked(
            repo, output_root, selected=selected, test_fixture=test_fixture
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--platform", required=True, choices=sorted(SUPPORTED))
    parser.add_argument("--test-fixture", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    output_root = (
        args.output_root
        or root / "target" / "native" / "resolver" / args.platform
    ).resolve()
    try:
        final_dir, manifest = build(
            root, output_root, selected=args.platform, test_fixture=args.test_fixture
        )
    except BuildError as error:
        print(f"resolver build failed: {error}")
        return 1
    if not args.quiet:
        print(json.dumps({"artifact": str(final_dir), "manifest": manifest}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
