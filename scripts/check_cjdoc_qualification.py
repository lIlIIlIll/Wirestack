#!/usr/bin/env python3
"""Fail closed unless the configured cjdoc executable is fully qualified."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tomllib


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "release" / "cjdoc-tool.toml"
SHA256 = re.compile(r"[0-9a-f]{64}")
REVISION = re.compile(r"[0-9a-f]{40}")
CJC_NIGHTLY = re.compile(
    r"Cangjie Compiler: ([0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]{14}) \(cjnative\)"
)
CJPM_VERSION = re.compile(
    r"Cangjie Project Manager: [0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?"
)


class CjdocQualificationError(ValueError):
    pass


def _required_string(config: dict, name: str) -> str:
    value = config.get(name)
    if not isinstance(value, str) or not value.strip():
        raise CjdocQualificationError(f"qualified cjdoc is missing {name}")
    return value.strip()


def _required_string_array(config: dict, name: str) -> list[str]:
    value = config.get(name)
    if not isinstance(value, list) or not value or not all(
        isinstance(item, str) and item for item in value
    ):
        raise CjdocQualificationError(f"qualified cjdoc is missing {name}")
    return value


def _safe_relative(config: dict, name: str) -> pathlib.PurePosixPath:
    relative = pathlib.PurePosixPath(_required_string(config, name))
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise CjdocQualificationError(f"{name} must be a safe relative path")
    return relative


def validate_toolchain_policy(config: dict, cjc_output: str, cjpm_output: str) -> str:
    """Validate one exact installed toolchain against the weekly-nightly policy."""
    if config.get("cjc_channel") != "nightly":
        raise CjdocQualificationError("qualified cjdoc must use the nightly Cangjie channel")
    cjc_lines = [line.strip() for line in cjc_output.splitlines() if line.strip()]
    cjpm_lines = [line.strip() for line in cjpm_output.splitlines() if line.strip()]
    cjc_match = CJC_NIGHTLY.fullmatch(cjc_lines[0] if cjc_lines else "")
    if cjc_match is None:
        raise CjdocQualificationError("current cjc is not a complete dated nightly")
    if len(cjpm_lines) != 1 or CJPM_VERSION.fullmatch(cjpm_lines[0]) is None:
        raise CjdocQualificationError("current cjpm version output is invalid")
    resolved_version = os.environ.get("YJSON_RESOLVED_NIGHTLY", "").strip()
    if resolved_version and cjc_match.group(1) != resolved_version:
        raise CjdocQualificationError(
            "current cjc does not match the shared weekly nightly selection"
        )
    return cjc_match.group(1)


def validate_qualification(
    config_path: pathlib.Path = DEFAULT_CONFIG,
    *,
    root: pathlib.Path = ROOT,
    binary_override: pathlib.Path | None = None,
) -> tuple[pathlib.Path, str]:
    config_bytes = config_path.read_bytes()
    config = tomllib.loads(config_bytes.decode("utf-8"))
    if config.get("schema_version") != 3:
        raise CjdocQualificationError("unsupported cjdoc qualification schema_version")
    if config.get("status") != "qualified":
        reason = config.get("reason", "qualification record is not complete")
        raise CjdocQualificationError(f"cjdoc is not qualified: {reason}")
    if config.get("distribution") != "source":
        raise CjdocQualificationError("qualified cjdoc distribution must be source")

    platform = _required_string(config, "platform")
    if platform != "linux-x86_64":
        raise CjdocQualificationError("canonical cjdoc platform must be linux-x86_64")
    for field in ("source_url", "source_archive_url", "license_url", "manual_url"):
        if not _required_string(config, field).startswith("https://"):
            raise CjdocQualificationError(f"{field} must use https")
    revision = _required_string(config, "source_revision")
    if REVISION.fullmatch(revision) is None:
        raise CjdocQualificationError("source_revision must be a lowercase Git commit")
    for field in ("source_url", "source_archive_url", "license_url", "manual_url"):
        if revision not in _required_string(config, field):
            raise CjdocQualificationError(f"{field} must pin source_revision")
    if _required_string(config, "source_directory") != f"cjdoc-{revision}":
        raise CjdocQualificationError("source_directory must identify the pinned archive root")
    _safe_relative(config, "binary_path")
    build_command = _required_string_array(config, "build_command")
    if build_command != ["cjpm", "build"]:
        raise CjdocQualificationError("build_command must be exactly cjpm build")
    _required_string(config, "license_spdx")
    _required_string(config, "version")
    expected_version = _required_string(config, "version_output")
    expected_archive_sha = _required_string(config, "source_archive_sha256")
    if SHA256.fullmatch(expected_archive_sha) is None:
        raise CjdocQualificationError(
            "source_archive_sha256 must be a lowercase SHA-256 digest")
    if config.get("cjc_channel") != "nightly":
        raise CjdocQualificationError("qualified cjdoc must use the nightly Cangjie channel")

    if binary_override is None:
        environment_binary = os.environ.get("YJSON_CJDOC_BINARY", "").strip()
        if not environment_binary:
            raise CjdocQualificationError(
                "source-qualified cjdoc requires --binary or YJSON_CJDOC_BINARY")
        binary = pathlib.Path(environment_binary).resolve()
    else:
        binary = binary_override.resolve()
    if binary.is_symlink() or not binary.is_file():
        raise CjdocQualificationError(f"qualified cjdoc binary is missing: {binary}")
    if not os.access(binary, os.X_OK):
        raise CjdocQualificationError(f"qualified cjdoc binary is not executable: {binary}")
    actual_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    evidence_path = binary.parent / "qualification.json"
    if evidence_path.is_symlink() or not evidence_path.is_file():
        raise CjdocQualificationError(
            f"cjdoc build evidence is missing: {evidence_path}")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    expected_config_sha = hashlib.sha256(config_bytes).hexdigest()
    expected_evidence = {
        "schemaVersion": "yjson.cjdoc-build/1",
        "configSha256": expected_config_sha,
        "sourceRevision": revision,
        "sourceArchiveSha256": expected_archive_sha,
        "binarySha256": actual_sha,
    }
    for name, expected in expected_evidence.items():
        if evidence.get(name) != expected:
            raise CjdocQualificationError(
                f"cjdoc build evidence {name} mismatch")
    evidence_cjc = str(evidence.get("cjcVersion", ""))
    evidence_cjpm = str(evidence.get("cjpmVersion", ""))
    validate_toolchain_policy(config, evidence_cjc, evidence_cjpm)

    current_cjc = subprocess.run(
        ["cjc", "-v"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=30, check=False)
    current_cjpm = subprocess.run(
        ["cjpm", "--version"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=30, check=False)
    if current_cjc.returncode != 0 or current_cjpm.returncode != 0:
        raise CjdocQualificationError("cannot query the current Cangjie toolchain")
    validate_toolchain_policy(config, current_cjc.stdout.strip(), current_cjpm.stdout.strip())
    if evidence.get("cjcVersion") != current_cjc.stdout.strip():
        raise CjdocQualificationError("cjdoc was built with a different cjc")
    if evidence.get("cjpmVersion") != current_cjpm.stdout.strip():
        raise CjdocQualificationError(
            "cjdoc was built with a different cjpm")

    version_args = _required_string_array(config, "version_args")
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
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"cjdoc qualification error: {error}", file=sys.stderr)
        return 1
    print(f"cjdoc qualification passed binary={binary} sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
