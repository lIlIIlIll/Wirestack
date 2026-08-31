#!/usr/bin/env python3
"""Build the source-qualified cjdoc tool into a content-addressed cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request

from check_cjdoc_qualification import (
    CjdocQualificationError,
    validate_qualification,
    validate_toolchain_policy,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "release" / "cjdoc-tool.toml"
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024


class CjdocPrepareError(ValueError):
    pass


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(arguments: list[str]) -> str:
    result = subprocess.run(
        arguments,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise CjdocPrepareError(
            f"{' '.join(arguments)} failed with exit {result.returncode}: "
            f"{result.stdout.strip()}"
        )
    return result.stdout.strip()


def download_archive(url: str, destination: pathlib.Path) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "yjson-cjdoc-qualification/1"},
    )
    total = 0
    with urllib.request.urlopen(request, timeout=60) as response:
        with destination.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_ARCHIVE_BYTES:
                    raise CjdocPrepareError(
                        f"cjdoc source archive exceeds {MAX_ARCHIVE_BYTES} bytes"
                    )
                output.write(chunk)


def safe_extract(
    archive_path: pathlib.Path,
    destination: pathlib.Path,
    expected_root: str,
) -> pathlib.Path:
    destination.mkdir(parents=True)
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise CjdocPrepareError("cjdoc source archive is empty")
        for member in members:
            relative = pathlib.PurePosixPath(member.name)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not relative.parts
                or relative.parts[0] != expected_root
            ):
                raise CjdocPrepareError(
                    f"unsafe cjdoc archive member: {member.name}"
                )
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise CjdocPrepareError(
                    f"unsupported cjdoc archive member: {member.name}"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise CjdocPrepareError(
                    f"cannot read cjdoc archive member: {member.name}"
                )
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
    return destination / expected_root


def prepare(
    config_path: pathlib.Path,
    cache_root: pathlib.Path,
    archive_override: pathlib.Path | None = None,
) -> pathlib.Path:
    config_bytes = config_path.read_bytes()
    config = tomllib.loads(config_bytes.decode("utf-8"))
    if config.get("schema_version") != 3 or config.get("status") != "qualified":
        raise CjdocPrepareError("cjdoc qualification record is not ready")
    if config.get("distribution") != "source":
        raise CjdocPrepareError("cjdoc qualification is not source-based")

    cjc_version = command_output(["cjc", "-v"])
    cjpm_version = command_output(["cjpm", "--version"])
    try:
        validate_toolchain_policy(config, cjc_version, cjpm_version)
    except CjdocQualificationError as error:
        raise CjdocPrepareError(str(error)) from error

    config_sha = hashlib.sha256(config_bytes).hexdigest()
    cache_key = hashlib.sha256(
        f"{config_sha}\0{cjc_version}\0{cjpm_version}".encode("utf-8")
    ).hexdigest()[:16]
    version = str(config["version"])
    revision = str(config["source_revision"])
    final_root = cache_root / f"{version}-{revision[:12]}-{cache_key}"
    final_binary = final_root / "bin" / "cjdoc"
    if final_binary.is_file():
        try:
            validate_qualification(
                config_path,
                root=ROOT,
                binary_override=final_binary,
            )
            return final_binary
        except (CjdocQualificationError, OSError, ValueError):
            raise CjdocPrepareError(
                f"invalid cjdoc cache exists at {final_root}; remove that exact "
                "cache directory before rebuilding"
            )

    cache_root.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(
        tempfile.mkdtemp(prefix=".cjdoc-build-", dir=cache_root)
    )
    try:
        archive = temporary / "source.tar.gz"
        if archive_override is None:
            download_archive(str(config["source_archive_url"]), archive)
        else:
            if archive_override.is_symlink() or not archive_override.is_file():
                raise CjdocPrepareError(
                    f"cjdoc source archive is missing: {archive_override}"
                )
            shutil.copyfile(archive_override, archive)
        archive_sha = sha256_file(archive)
        if archive_sha != config["source_archive_sha256"]:
            raise CjdocPrepareError(
                "cjdoc source archive checksum mismatch: "
                f"expected {config['source_archive_sha256']}, got {archive_sha}"
            )

        source_root = safe_extract(
            archive,
            temporary / "source",
            str(config["source_directory"]),
        )
        build_command = list(config["build_command"])
        result = subprocess.run(
            build_command,
            cwd=source_root,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode != 0:
            raise CjdocPrepareError(
                f"cjdoc build failed with exit {result.returncode}"
            )
        built_binary = source_root.joinpath(
            *pathlib.PurePosixPath(str(config["binary_path"])).parts
        )
        if built_binary.is_symlink() or not built_binary.is_file():
            raise CjdocPrepareError(
                f"cjdoc build did not produce {config['binary_path']}"
            )
        if not os.access(built_binary, os.X_OK):
            raise CjdocPrepareError("built cjdoc is not executable")
        version_output = command_output(
            [str(built_binary), *list(config["version_args"])]
        )
        if str(config["version_output"]) not in version_output:
            raise CjdocPrepareError(
                f"built cjdoc reports an unexpected version: {version_output}"
            )

        staged_root = temporary / "qualified"
        staged_bin = staged_root / "bin"
        staged_bin.mkdir(parents=True)
        staged_binary = staged_bin / "cjdoc"
        shutil.copy2(built_binary, staged_binary)
        evidence = {
            "schemaVersion": "yjson.cjdoc-build/1",
            "configSha256": config_sha,
            "sourceRevision": revision,
            "sourceArchiveSha256": archive_sha,
            "binarySha256": sha256_file(staged_binary),
            "cjcVersion": cjc_version,
            "cjpmVersion": cjpm_version,
            "buildCommand": build_command,
        }
        (staged_bin / "qualification.json").write_text(
            json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        try:
            os.replace(staged_root, final_root)
        except FileExistsError:
            if not final_binary.is_file():
                raise
        validate_qualification(
            config_path,
            root=ROOT,
            binary_override=final_binary,
        )
        return final_binary
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    parser.add_argument("--cache-dir", type=pathlib.Path, default=ROOT / ".cache" / "cjdoc")
    parser.add_argument("--archive", type=pathlib.Path)
    args = parser.parse_args()
    try:
        binary = prepare(
            args.config.resolve(),
            args.cache_dir.resolve(),
            args.archive.resolve() if args.archive else None,
        )
    except (
        CjdocPrepareError,
        CjdocQualificationError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
        tomllib.TOMLDecodeError,
    ) as error:
        print(f"cjdoc prepare error: {error}", file=sys.stderr)
        return 1
    print(binary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
