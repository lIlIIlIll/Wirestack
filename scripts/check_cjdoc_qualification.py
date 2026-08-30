#!/usr/bin/env python3
"""Fail closed unless the configured cjdoc executable is fully qualified."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tomllib


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "release" / "cjdoc-tool.toml"
SHA256 = re.compile(r"[0-9a-f]{64}")


class CjdocQualificationError(ValueError):
    pass


def _required_string(config: dict, name: str) -> str:
    value = config.get(name)
    if not isinstance(value, str) or not value.strip():
        raise CjdocQualificationError(f"qualified cjdoc is missing {name}")
    return value.strip()


def validate_qualification(
    config_path: pathlib.Path = DEFAULT_CONFIG,
    *,
    root: pathlib.Path = ROOT,
    binary_override: pathlib.Path | None = None,
) -> tuple[pathlib.Path, str]:
    config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    if config.get("schema_version") != 1:
        raise CjdocQualificationError("unsupported cjdoc qualification schema_version")
    if config.get("status") != "qualified":
        reason = config.get("reason", "qualification record is not complete")
        raise CjdocQualificationError(f"cjdoc is not qualified: {reason}")

    platform = _required_string(config, "platform")
    if platform != "linux-x86_64":
        raise CjdocQualificationError("canonical cjdoc platform must be linux-x86_64")
    for field in ("artifact_url", "source_url", "manual_url"):
        if not _required_string(config, field).startswith("https://"):
            raise CjdocQualificationError(f"{field} must use https")
    _required_string(config, "source_revision")
    _required_string(config, "license_spdx")
    expected_version = _required_string(config, "version_output")
    expected_sha = _required_string(config, "artifact_sha256")
    if SHA256.fullmatch(expected_sha) is None:
        raise CjdocQualificationError("artifact_sha256 must be a lowercase SHA-256 digest")

    if binary_override is None:
        relative = pathlib.PurePosixPath(_required_string(config, "binary_path"))
        if relative.is_absolute() or ".." in relative.parts:
            raise CjdocQualificationError("binary_path must be a safe repository-relative path")
        binary = root.joinpath(*relative.parts)
    else:
        binary = binary_override
    if binary.is_symlink() or not binary.is_file():
        raise CjdocQualificationError(f"qualified cjdoc binary is missing: {binary}")
    if not os.access(binary, os.X_OK):
        raise CjdocQualificationError(f"qualified cjdoc binary is not executable: {binary}")
    actual_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    if actual_sha != expected_sha:
        raise CjdocQualificationError(
            f"cjdoc checksum mismatch: expected {expected_sha}, got {actual_sha}")

    version_args = config.get("version_args", ["-v"])
    if not isinstance(version_args, list) or not all(
        isinstance(argument, str) for argument in version_args
    ):
        raise CjdocQualificationError("version_args must be an array of strings")
    result = subprocess.run(
        [str(binary), *version_args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
        check=False,
    )
    output = result.stdout.strip()
    if result.returncode != 0:
        raise CjdocQualificationError(
            f"cjdoc version command failed with exit {result.returncode}: {output}")
    if expected_version not in output:
        raise CjdocQualificationError(
            f"cjdoc version mismatch: expected output containing {expected_version!r}")
    return binary, actual_sha


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    parser.add_argument("--binary", type=pathlib.Path)
    args = parser.parse_args()
    try:
        binary, digest = validate_qualification(
            args.config.resolve(),
            binary_override=args.binary.resolve() if args.binary else None,
        )
    except (CjdocQualificationError, OSError, subprocess.SubprocessError) as error:
        print(f"cjdoc qualification error: {error}", file=sys.stderr)
        return 1
    print(f"cjdoc qualification passed binary={binary} sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
