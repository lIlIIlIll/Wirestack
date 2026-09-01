#!/usr/bin/env python3
"""Build the bounded Windows system-resolver bridge."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import json
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path


class BuildError(RuntimeError):
    pass


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


def find_tool(environment_name: str, candidates: tuple[str, ...]) -> str:
    configured = os.environ.get(environment_name)
    if configured:
        resolved = shutil.which(configured) if not Path(configured).is_absolute() else configured
        if resolved and Path(resolved).is_file():
            return str(Path(resolved).absolute())
        raise BuildError(f"{environment_name} does not name an executable: {configured}")
    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return str(Path(resolved).absolute())
    raise BuildError(f"required tool is unavailable: {', '.join(candidates)}")


def build_fingerprint(
    source: Path,
    header: Path,
    tools: dict[str, str],
    *,
    test_fixture: bool,
) -> tuple[str, dict[str, object]]:
    compiler_version = run([tools["cc"], "--version"]).splitlines()[0]
    target = run([tools["cc"], "-dumpmachine"]).strip()
    flags = [
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-D_WIN32_WINNT=0x0602",
    ]
    if test_fixture:
        flags.append("-DWIRESTACK_RESOLVER_TEST_FIXTURE=1")
    inputs: dict[str, object] = {
        "schema": 1,
        "source_sha256": evidence_digest.text_evidence_sha256(source),
        "header_sha256": evidence_digest.text_evidence_sha256(header),
        "compiler": tools["cc"],
        "compiler_version": compiler_version,
        "target": target,
        "flags": flags,
        "test_fixture": test_fixture,
    }
    encoded = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    return evidence_digest.text_evidence_bytes_sha256(encoded), inputs


def validate_cached(final_dir: Path, fingerprint: str) -> dict[str, object] | None:
    archive = final_dir / "lib" / "libwirestack_resolver.a"
    manifest_path = final_dir / "resolver-manifest.json"
    if not archive.is_file() or not manifest_path.is_file():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if manifest.get("build_fingerprint") != fingerprint:
        return None
    if not evidence_digest.artifact_byte_sha256_equal(
        manifest.get("archive", {}).get("sha256"),
        evidence_digest.artifact_byte_sha256(archive),
    ):
        return None
    return manifest


def activate(output_root: Path, final_dir: Path) -> None:
    current = output_root / "current"
    staging = output_root / f".current-{os.getpid()}"
    if staging.exists():
        shutil.rmtree(staging)
    shutil.copytree(final_dir, staging)
    if current.is_symlink() or current.is_file():
        current.unlink()
    elif current.exists():
        shutil.rmtree(current)
    os.replace(staging, current)


def build(
    repo: Path,
    output_root: Path,
    *,
    test_fixture: bool = False,
) -> tuple[Path, dict[str, object]]:
    if platform.system() != "Windows":
        raise BuildError("the Windows resolver bridge requires a native Windows host")
    source_dir = repo / "native" / "resolver" / "windows"
    source = source_dir / "wirestack_resolver.c"
    header = source_dir / "wirestack_resolver.h"
    if not source.is_file() or not header.is_file():
        raise BuildError("Windows resolver bridge source is incomplete")
    tools = {
        "cc": find_tool("CC", ("clang", "gcc")),
        "ar": find_tool("AR", ("llvm-ar", "ar")),
    }
    fingerprint, inputs = build_fingerprint(
        source, header, tools, test_fixture=test_fixture
    )
    final_dir = output_root / "cache" / fingerprint
    cached = validate_cached(final_dir, fingerprint)
    if cached is not None:
        activate(output_root, final_dir)
        return final_dir, cached

    output_root.mkdir(parents=True, exist_ok=True)
    work_root = output_root / "work"
    work_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f"{fingerprint[:12]}-", dir=work_root))
    try:
        object_path = staging / "wirestack_resolver.o"
        compile_command = [
            tools["cc"],
            *inputs["flags"],
            f"-I{source_dir}",
            "-c", str(source),
            "-o", str(object_path),
        ]
        run(compile_command, cwd=staging)
        artifact = staging / "artifact"
        library_dir = artifact / "lib"
        include_dir = artifact / "include"
        library_dir.mkdir(parents=True)
        include_dir.mkdir(parents=True)
        archive = library_dir / "libwirestack_resolver.a"
        run([tools["ar"], "rcs", str(archive), str(object_path)], cwd=staging)
        shutil.copy2(header, include_dir / header.name)

        smoke_source = staging / "smoke.c"
        smoke_source.write_text(
            """#include "wirestack_resolver.h"
#include <stdint.h>
int main(void) {
  uint64_t pool = 0;
  int64_t native_code = 0;
  uint64_t metrics[WIRESTACK_RESOLVER_METRIC_COUNT] = {0};
  if (wirestack_resolver_pool_create(2, 4, &pool, &native_code) != WIRESTACK_RESOLVER_OK) return 1;
  if (wirestack_resolver_pool_metrics(pool, metrics, WIRESTACK_RESOLVER_METRIC_COUNT) != WIRESTACK_RESOLVER_OK) return 2;
  if (metrics[WIRESTACK_RESOLVER_METRIC_WORKERS] != 2 ||
      metrics[WIRESTACK_RESOLVER_METRIC_QUEUE_CAPACITY] != 4) return 3;
  return wirestack_resolver_pool_destroy(pool);
}
""",
            encoding="utf-8",
        )
        smoke_binary = staging / "resolver-smoke.exe"
        run(
            [
                tools["cc"], "-std=c11", "-Wall", "-Wextra", "-Werror",
                f"-I{include_dir}", str(smoke_source), str(archive),
                "-lws2_32", "-o", str(smoke_binary),
            ],
            cwd=staging,
        )
        run([str(smoke_binary)], cwd=staging)
        manifest: dict[str, object] = {
            "schema_version": 1,
            "build_fingerprint": fingerprint,
            "platform": "windows-x86_64",
            "inputs": inputs,
            "archive": {
                "path": "lib/libwirestack_resolver.a",
                "sha256": evidence_digest.artifact_byte_sha256(archive),
            },
            "worker_model": "fixed Win32 worker pool with bounded FIFO admission",
            "close_model": (
                "asynchronous reaper with a process-wide cap of eight live pools "
                "and 64 workers; blocking Winsock resolver calls remain quarantined"
            ),
            "private_runtime_abi": False,
            "test_fixture": test_fixture,
        }
        (artifact / "resolver-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        if final_dir.exists():
            shutil.rmtree(final_dir)
        os.replace(artifact, final_dir)
        activate(output_root, final_dir)
        return final_dir, manifest
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--test-fixture", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = args.root.resolve()
    output_root = (args.output_root or repo / "target" / "native" / "resolver").resolve()
    try:
        final_dir, manifest = build(
            repo, output_root, test_fixture=args.test_fixture
        )
    except BuildError as error:
        print(f"resolver build failed: {error}")
        return 1
    if not args.quiet:
        print(json.dumps({"artifact": str(final_dir), "manifest": manifest}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
