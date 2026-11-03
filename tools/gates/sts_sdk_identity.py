"""Capture a pinned STS SDK identity from its archive and installed files."""

from __future__ import annotations

import os
import platform
import re
import stat
import subprocess
import tarfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Mapping

from tools import evidence_digest


CHUNK_SIZE = 1024 * 1024


class SDKIdentityError(RuntimeError):
    """The installed SDK does not match the pinned native STS distribution."""


def _archive_path(name: str, prefix: tuple[str, ...]) -> PurePosixPath | None:
    normalized = name.replace("\\", "/")
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized):
        raise SDKIdentityError(f"unsafe absolute SDK archive member: {name!r}")
    member = PurePosixPath(normalized)
    parts = tuple(part for part in member.parts if part not in {"", "."})
    if any(part == ".." for part in parts):
        raise SDKIdentityError(f"unsafe parent traversal in SDK archive member: {name!r}")
    if prefix:
        if parts == prefix:
            return None
        if parts[: len(prefix)] != prefix:
            raise SDKIdentityError(f"SDK archive member is outside its pinned prefix: {name!r}")
        parts = parts[len(prefix) :]
    if not parts:
        return None
    return PurePosixPath(*parts)


def _prefix(pin: Mapping[str, Any]) -> tuple[str, ...]:
    archive = pin.get("archive")
    raw = archive.get("archive_prefix", "") if isinstance(archive, Mapping) else None
    if not isinstance(raw, str):
        raise SDKIdentityError("pin archive_prefix must be a string")
    if not raw:
        return ()
    path = PurePosixPath(raw.replace("\\", "/"))
    parts = tuple(part for part in path.parts if part not in {"", "."})
    if path.is_absolute() or any(part == ".." for part in parts):
        raise SDKIdentityError("pin archive_prefix is unsafe")
    return parts


def _sdk_file(sdk_root: Path, relative: PurePosixPath) -> Path:
    root = sdk_root.resolve(strict=True)
    candidate = sdk_root.joinpath(*relative.parts)
    try:
        resolved_parent = candidate.parent.resolve(strict=True)
        resolved_parent.relative_to(root)
    except (OSError, ValueError) as error:
        raise SDKIdentityError(f"installed SDK path escapes its root: {relative.as_posix()}") from error
    return candidate


def _compare_regular_file(
    sdk_root: Path,
    relative: PurePosixPath,
    archive_stream: BinaryIO,
    archive_size: int,
) -> None:
    installed = _sdk_file(sdk_root, relative)
    try:
        metadata = installed.lstat()
    except OSError as error:
        raise SDKIdentityError(f"installed SDK file is missing: {relative.as_posix()}") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != archive_size:
        raise SDKIdentityError(f"installed SDK file type/size differs: {relative.as_posix()}")
    with installed.open("rb") as installed_stream:
        while True:
            expected = archive_stream.read(CHUNK_SIZE)
            actual = installed_stream.read(CHUNK_SIZE)
            if expected != actual:
                raise SDKIdentityError(f"installed SDK bytes differ: {relative.as_posix()}")
            if not expected:
                break


def _installed_file_inventory(sdk_root: Path) -> set[str]:
    inventory: set[str] = set()
    for directory, child_directories, files in os.walk(sdk_root, followlinks=False):
        current = Path(directory)
        for name in tuple(child_directories):
            path = current / name
            if path.is_symlink():
                inventory.add(path.relative_to(sdk_root).as_posix())
                child_directories.remove(name)
        inventory.update((current / name).relative_to(sdk_root).as_posix() for name in files)
    return inventory


def _validate_link_target(relative: PurePosixPath, target: str) -> None:
    normalized = target.replace("\\", "/")
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized):
        raise SDKIdentityError(f"unsafe absolute SDK symlink target: {target!r}")
    stack = list(relative.parent.parts)
    for part in PurePosixPath(normalized).parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                raise SDKIdentityError(f"SDK symlink target escapes its root: {target!r}")
            stack.pop()
        else:
            stack.append(part)


def _verify_inventory(sdk_root: Path, expected: set[str]) -> None:
    actual = _installed_file_inventory(sdk_root)
    if actual != expected:
        raise SDKIdentityError("installed SDK file inventory differs from its pinned archive")


def _compare_tar_archive(sdk_root: Path, archive: Path, prefix: tuple[str, ...]) -> int:
    compared = 0
    expected: set[str] = set()
    try:
        with tarfile.open(archive, mode="r:*") as package:
            for member in package:
                relative = _archive_path(member.name, prefix)
                if relative is None:
                    if member.isdir():
                        continue
                    raise SDKIdentityError(f"unexpected SDK archive root entry: {member.name!r}")
                if member.isdir():
                    continue
                relative_name = relative.as_posix()
                if relative_name in expected:
                    raise SDKIdentityError(f"duplicate SDK archive member: {member.name!r}")
                expected.add(relative_name)
                installed = _sdk_file(sdk_root, relative)
                if member.isfile():
                    stream = package.extractfile(member)
                    if stream is None:
                        raise SDKIdentityError(f"cannot read SDK archive member: {member.name!r}")
                    with stream:
                        _compare_regular_file(sdk_root, relative, stream, member.size)
                elif member.issym():
                    _validate_link_target(relative, member.linkname)
                    if not installed.is_symlink() or os.readlink(installed) != member.linkname:
                        raise SDKIdentityError(f"installed SDK symlink differs: {relative_name}")
                elif member.islnk():
                    target = _archive_path(member.linkname, prefix)
                    if target is None:
                        raise SDKIdentityError(f"invalid SDK hardlink target: {member.linkname!r}")
                    target_path = _sdk_file(sdk_root, target)
                    try:
                        if installed.is_symlink() or not os.path.samefile(installed, target_path):
                            raise SDKIdentityError(f"installed SDK hardlink differs: {relative_name}")
                    except OSError as error:
                        raise SDKIdentityError(f"cannot verify SDK hardlink: {relative_name}") from error
                else:
                    raise SDKIdentityError(f"unsupported SDK archive entry: {member.name!r}")
                compared += 1
    except (OSError, tarfile.TarError) as error:
        raise SDKIdentityError(f"cannot read pinned SDK tar archive: {error}") from error
    if compared == 0:
        raise SDKIdentityError("pinned SDK archive contains no matched files")
    _verify_inventory(sdk_root, expected)
    return compared


def _compare_zip_archive(sdk_root: Path, archive: Path, prefix: tuple[str, ...]) -> int:
    compared = 0
    expected: set[str] = set()
    try:
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                relative = _archive_path(member.filename, prefix)
                mode = member.external_attr >> 16
                if member.is_dir():
                    continue
                if relative is None:
                    raise SDKIdentityError(f"unexpected SDK archive root entry: {member.filename!r}")
                relative_name = relative.as_posix()
                if relative_name in expected:
                    raise SDKIdentityError(f"duplicate SDK archive member: {member.filename!r}")
                expected.add(relative_name)
                installed = _sdk_file(sdk_root, relative)
                if stat.S_ISLNK(mode):
                    target_bytes = package.read(member)
                    try:
                        target = target_bytes.decode("utf-8")
                    except UnicodeDecodeError as error:
                        raise SDKIdentityError(
                            f"invalid SDK symlink target: {relative_name}"
                        ) from error
                    _validate_link_target(relative, target)
                    if not installed.is_symlink() or os.readlink(installed) != target:
                        raise SDKIdentityError(f"installed SDK symlink differs: {relative_name}")
                elif stat.S_IFMT(mode) == 0 or stat.S_ISREG(mode):
                    with package.open(member) as stream:
                        _compare_regular_file(sdk_root, relative, stream, member.file_size)
                else:
                    raise SDKIdentityError(f"unsupported SDK archive entry: {member.filename!r}")
                compared += 1
    except (OSError, zipfile.BadZipFile) as error:
        raise SDKIdentityError(f"cannot read pinned SDK zip archive: {error}") from error
    if compared == 0:
        raise SDKIdentityError("pinned SDK archive contains no matched files")
    _verify_inventory(sdk_root, expected)
    return compared


def _compare_archive(sdk_root: Path, archive: Path, prefix: tuple[str, ...]) -> int:
    if archive.name.endswith((".tar.gz", ".tgz")):
        return _compare_tar_archive(sdk_root, archive, prefix)
    if archive.suffix.lower() == ".zip":
        return _compare_zip_archive(sdk_root, archive, prefix)
    raise SDKIdentityError("pinned SDK archive must be a .tar.gz, .tgz, or .zip file")


def _tool_path(sdk_root: Path, name: str) -> tuple[Path, str]:
    candidates = (
        sdk_root / "bin" / name,
        sdk_root / "tools" / "bin" / name,
        sdk_root / "bin" / f"{name}.exe",
        sdk_root / "tools" / "bin" / f"{name}.exe",
    )
    found = [path for path in candidates if path.is_file()]
    if len(found) != 1:
        raise SDKIdentityError(f"expected exactly one {name} executable under the SDK root")
    path = found[0]
    root = sdk_root.resolve(strict=True)
    try:
        path.resolve(strict=True).relative_to(root)
    except (OSError, ValueError) as error:
        raise SDKIdentityError(f"{name} executable resolves outside the SDK root") from error
    if os.name != "nt" and not os.access(path, os.X_OK):
        raise SDKIdentityError(f"{name} executable is not executable")
    return path, path.relative_to(sdk_root).as_posix()


def _run_version(path: Path, sdk_root: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(
            [str(path), *arguments],
            cwd=sdk_root,
            env=dict(os.environ),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SDKIdentityError(f"cannot execute pinned SDK tool {path.name}: {error}") from error
    if completed.returncode != 0:
        raise SDKIdentityError(f"pinned SDK tool {path.name} version command failed")
    output = completed.stdout.strip()
    if not output:
        raise SDKIdentityError(f"pinned SDK tool {path.name} returned no version output")
    return output


def _require_version(output: str, expected: str, name: str) -> None:
    version_pattern = re.compile(rf"(?<![A-Za-z0-9.+-]){re.escape(expected)}(?![A-Za-z0-9.+-])")
    if not version_pattern.search(output):
        raise SDKIdentityError(f"{name} did not report pinned STS version {expected}")
    if re.search(r"(?i)(?:nightly|alpha|beta|dev|snapshot)", output):
        raise SDKIdentityError(f"{name} reports a non-STS prerelease toolchain")


def capture_sdk_identity(
    sdk_root: Path, archive: Path, pin: Mapping[str, Any]
) -> dict[str, Any]:
    """Verify and return a machine-independent receipt for an installed STS SDK."""
    if not isinstance(sdk_root, Path) or not isinstance(archive, Path):
        raise SDKIdentityError("sdk_root and archive must be pathlib.Path values")
    try:
        sdk_root = sdk_root.resolve(strict=True)
        archive = archive.resolve(strict=True)
    except OSError as error:
        raise SDKIdentityError(f"SDK root or archive is missing: {error}") from error
    if not sdk_root.is_dir() or not archive.is_file():
        raise SDKIdentityError("SDK root must be a directory and archive must be a file")

    channel = pin.get("channel")
    version = pin.get("version")
    archive_pin = pin.get("archive")
    platform_pin = pin.get("platform")
    if channel != "STS" or not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SDKIdentityError("SDK pin must specify a stable STS semantic version")
    if not isinstance(archive_pin, Mapping) or not isinstance(platform_pin, Mapping):
        raise SDKIdentityError("SDK pin must specify archive and platform objects")
    archive_name = archive_pin.get("name")
    expected_sha256 = archive_pin.get("sha256")
    if not isinstance(archive_name, str) or archive.name != archive_name:
        raise SDKIdentityError("SDK archive filename does not match its pin")
    if not isinstance(expected_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise SDKIdentityError("SDK pin must contain a lowercase SHA-256 archive digest")
    expected_size = archive_pin.get("size_bytes")
    if type(expected_size) is not int or expected_size <= 0:
        raise SDKIdentityError("SDK pin must contain a positive integer archive size")
    try:
        actual_size = archive.stat().st_size
    except OSError as error:
        raise SDKIdentityError(f"cannot stat pinned SDK archive: {error}") from error
    if actual_size != expected_size:
        raise SDKIdentityError("SDK archive size does not match its pinned size")
    archive_digest = evidence_digest.artifact_byte_digest(archive).to_json()
    if not evidence_digest.schema_artifact_sha256_equal(
        archive_digest.get("sha256"), expected_sha256
    ):
        raise SDKIdentityError("SDK archive bytes do not match the pinned SHA-256")

    expected_system = platform_pin.get("system")
    allowed_machines = platform_pin.get("machines")
    native_target = platform_pin.get("native_target")
    actual_system = platform.system()
    actual_machine = platform.machine()
    if actual_system != expected_system or not isinstance(allowed_machines, list) or actual_machine.lower() not in {
        machine.lower() for machine in allowed_machines if isinstance(machine, str)
    }:
        raise SDKIdentityError("SDK identity capture is not running on its pinned native platform")
    if not isinstance(native_target, str) or not native_target:
        raise SDKIdentityError("SDK pin must specify its native target")

    matched_archive_files = _compare_archive(sdk_root, archive, _prefix(pin))
    cjc_path, cjc_relative = _tool_path(sdk_root, "cjc")
    cjpm_path, cjpm_relative = _tool_path(sdk_root, "cjpm")
    cjc_output = _run_version(cjc_path, sdk_root, "-v")
    cjpm_output = _run_version(cjpm_path, sdk_root, "--version")
    _require_version(cjc_output, version, "cjc")
    _require_version(cjpm_output, version, "cjpm")
    target_matches = re.findall(r"(?im)^\s*Target:\s*([A-Za-z0-9_.-]+)\s*$", cjc_output)
    if target_matches != [native_target]:
        raise SDKIdentityError("cjc target does not match the pinned native platform")

    return {
        "channel": channel,
        "version": version,
        "archive_name": archive_name,
        "archive": archive_digest,
        "matched_archive_files": matched_archive_files,
        "platform": {
            "system": actual_system,
            "machine": actual_machine,
            "native_target": native_target,
        },
        "cjc": {
            "relative_path": cjc_relative,
            "version": version,
            "version_output": cjc_output,
            "target": native_target,
        },
        "cjpm": {
            "relative_path": cjpm_relative,
            "version": version,
            "version_output": cjpm_output,
        },
    }
