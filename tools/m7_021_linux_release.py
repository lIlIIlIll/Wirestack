#!/usr/bin/env python3
"""Build and qualify the installable Wirestack Linux release artifact."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0"
PACKAGE_ROOT = f"wirestack-{VERSION}"
ARTIFACT_NAME = f"{PACKAGE_ROOT}-linux-x86_64-glibc.tar.gz"
SMOKE_FIXTURE = ROOT / "tools/release_smoke/main.cj"
FORBIDDEN_OPENSSL_NAMES = re.compile(r"^lib(?:ssl|crypto)(?:\.so(?:\..*)?)?$", re.IGNORECASE)
FORBIDDEN_LOADER_BYTES = (b"libssl.so", b"libcrypto.so")
EXPECTED_SMOKE_LINES = {
    "HTTPS_CLIENT_SERVER=PASS",
    "HTTP_VERSION=2",
    "transportBackend=std-net",
    "runtimeIoBackend=cjnative",
    "tlsProvider=aws-lc",
    "tlsProviderVersion=5.5.0",
    "externalOpenSslDependency=false",
}
PROJECT_LICENSE_EXPRESSION = "Apache-2.0"
RELEASE_METADATA_FILES = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "third_party/aws-lc/LICENSE",
    "third_party/aws-lc/NOTICE",
)
QUALIFICATION_INPUTS = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "build.cj",
    "cjpm.lock",
    "cjpm.toml",
    "docs/planning/implementation-backlog.md",
    "native/resolver/linux/wirestack_resolver.c",
    "native/resolver/linux/wirestack_resolver.h",
    "native/tls/aws_lc/provider.json",
    "native/tls/aws_lc/wirestack_tls_provider.c",
    "native/tls/aws_lc/wirestack_tls_provider.h",
    "tools/build_linux_resolver.py",
    "tools/build_linux_tls_provider.py",
    "tools/build_tls_provider.py",
    "tools/tls_provider/abi-v1.json",
    "tools/tls_provider/selection.json",
    "tools/tls_provider/selection.py",
    "tools/m7_021_linux_release.py",
    "tools/release_smoke/main.cj",
    "third_party/aws-lc/LICENSE",
    "third_party/aws-lc/NOTICE",
)
EXCLUDED_PLATFORM_PARTS = {
    ("src", "internal", "platform", "android"),
    ("src", "internal", "platform", "apple"),
    ("src", "internal", "platform", "harmony"),
    ("src", "internal", "platform", "windows"),
}


class ReleaseError(RuntimeError):
    """Raised when the artifact cannot satisfy the M7-021 release contract."""


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: Sequence[str], *, cwd: Path, env: Mapping[str, str] | None = None) -> str:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        env=None if env is None else dict(env),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        raise ReleaseError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n{completed.stdout}"
        )
    return completed.stdout


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"expected a JSON object in {path}")
    return value


def production_sources(root: Path) -> list[Path]:
    source_root = root / "src"
    paths = []
    for path in source_root.rglob("*.cj"):
        relative_parts = path.relative_to(root).parts
        if path.name.endswith("_test.cj"):
            continue
        if any(relative_parts[: len(prefix)] == prefix for prefix in EXCLUDED_PLATFORM_PARTS):
            continue
        paths.append(path)
    if not paths:
        raise ReleaseError("no production Cangjie source was found")
    return sorted(paths)


def source_tree_sha256(root: Path) -> str:
    paths = production_sources(root) + [root / "cjpm.toml", root / "cjpm.lock"]
    entries = [
        {
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256_path(path),
        }
        for path in sorted(paths)
    ]
    return sha256_bytes(canonical_json(entries))


def platform_identity() -> dict[str, str]:
    if platform.system() != "Linux" or platform.machine().lower() != "x86_64":
        raise ReleaseError("M7-021 requires native Linux x86_64 execution")
    libc_name, libc_version = platform.libc_ver()
    if "musl" in libc_name.lower():
        raise ReleaseError("the current Wirestack release profile supports glibc, not musl")
    return {
        "os": "linux",
        "architecture": "x86_64",
        "libc": "glibc",
        "libc_version": libc_version or "unknown",
    }


def prepare_native_dependencies(root: Path, *, offline: bool) -> None:
    provider = [sys.executable, str(root / "tools/build_tls_provider.py")]
    if offline:
        provider.append("--offline")
    run(provider, cwd=root)
    run([sys.executable, str(root / "tools/build_linux_resolver.py"), "--quiet"], cwd=root)


def _native_payload(root: Path, relative_root: str, current: Path) -> dict[str, bytes]:
    if not current.is_dir():
        raise ReleaseError(f"native dependency is absent: {current}")
    payload: dict[str, bytes] = {}
    for path in sorted(item for item in current.rglob("*") if item.is_file()):
        relative = path.relative_to(current).as_posix()
        payload[f"{relative_root}/{relative}"] = path.read_bytes()
    return payload


def collect_payload(root: Path) -> tuple[dict[str, bytes], dict[str, Any]]:
    payload: dict[str, bytes] = {}
    for relative in ("cjpm.toml", "cjpm.lock", "README.md", *RELEASE_METADATA_FILES):
        path = root / relative
        if not path.is_file():
            raise ReleaseError(f"release input is absent: {relative}")
        payload[relative] = path.read_bytes()
    for path in production_sources(root):
        payload[path.relative_to(root).as_posix()] = path.read_bytes()

    provider_root = root / "target/native/current"
    resolver_root = root / "target/native/resolver/current"
    payload.update(_native_payload(root, "target/native/current", provider_root))
    payload.update(_native_payload(root, "target/native/resolver/current", resolver_root))

    provider_manifest = load_json(provider_root / "provider-manifest.json")
    resolver_manifest = load_json(resolver_root / "resolver-manifest.json")
    if provider_manifest.get("externalOpenSslDependency") is not False:
        raise ReleaseError("provider manifest does not set externalOpenSslDependency=false")

    entries = [
        {
            "path": relative,
            "bytes": len(content),
            "sha256": sha256_bytes(content),
        }
        for relative, content in sorted(payload.items())
    ]
    payload_digest = sha256_bytes(canonical_json(entries))
    release_manifest: dict[str, Any] = {
        "schema_version": 1,
        "package": "wirestack",
        "version": VERSION,
        "target": platform_identity(),
        "format": "cjpm-source-with-pinned-static-native-dependencies",
        "production_source_files": len(production_sources(root)),
        "payload": entries,
        "payload_sha256": payload_digest,
        "artifactBuildFingerprint": payload_digest,
        "license": {
            "expression": PROJECT_LICENSE_EXPRESSION,
            "file": "LICENSE",
            "sha256": sha256_bytes(payload["LICENSE"]),
        },
        "thirdPartyNotices": {
            "index": "THIRD_PARTY_NOTICES.md",
            "files": [
                {
                    "path": relative,
                    "sha256": sha256_bytes(payload[relative]),
                }
                for relative in RELEASE_METADATA_FILES[1:]
            ],
        },
        "provider": {
            "id": provider_manifest.get("providerId"),
            "version": provider_manifest.get("providerVersion"),
            "platform": "linux-x86_64-glibc",
            "adapter": "linux-aws-lc",
            "abi_version": provider_manifest.get("abiVersion"),
            "build_fingerprint": provider_manifest.get("build_fingerprint"),
            "archive_sha256": provider_manifest.get("archive", {}).get("sha256"),
            "manifest_sha256": sha256_bytes(payload["target/native/current/provider-manifest.json"]),
        },
        "resolver": {
            "archive_sha256": resolver_manifest.get("archive", {}).get("sha256"),
            "manifest_sha256": sha256_bytes(
                payload["target/native/resolver/current/resolver-manifest.json"]
            ),
        },
        "externalOpenSslDependency": False,
    }
    payload["release-manifest.json"] = canonical_json(release_manifest)
    reject_loader_strings(payload)
    return payload, release_manifest


def reject_loader_strings(payload: Mapping[str, bytes]) -> None:
    hits: list[str] = []
    for relative, content in payload.items():
        lowered = content.lower()
        if any(value in lowered for value in FORBIDDEN_LOADER_BYTES):
            hits.append(relative)
    if hits:
        raise ReleaseError(f"system OpenSSL loader strings found in artifact payload: {hits}")


def _archive_directories(paths: Iterable[str]) -> list[str]:
    directories: set[str] = {PACKAGE_ROOT}
    for relative in paths:
        current = Path(PACKAGE_ROOT) / relative
        directories.update(parent.as_posix() for parent in current.parents if parent.as_posix() != ".")
    return sorted(directories, key=lambda item: (item.count("/"), item))


def write_reproducible_archive(path: Path, payload: Mapping[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for directory in _archive_directories(payload):
                    info = tarfile.TarInfo(directory)
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info)
                for relative, content in sorted(payload.items()):
                    info = tarfile.TarInfo(f"{PACKAGE_ROOT}/{relative}")
                    info.size = len(content)
                    info.mode = 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(content))


def extract_archive(path: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(path, mode="r:gz") as archive:
        for member in archive.getmembers():
            if member.issym() or member.islnk():
                raise ReleaseError("release archive may not contain links")
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise ReleaseError(f"unsafe release archive member: {member.name}")
        archive.extractall(destination)
    installed = destination / PACKAGE_ROOT
    if not (installed / "release-manifest.json").is_file():
        raise ReleaseError("installed artifact has no release manifest")
    return installed


def consumer_manifest(installed: Path) -> str:
    path = json.dumps(str(installed.resolve()))
    return f'''[package]
  cjc-version = "1.1.0"
  name = "wirestack_release_smoke"
  organization = ""
  description = "M7-021 installed Wirestack release smoke"
  version = "1.0.0"
  target-dir = ""
  script-dir = ""
  src-dir = "src"
  output-type = "executable"
  compile-option = ""
  override-compile-option = ""
  link-option = ""
  package-configuration = {{}}

[dependencies]
  wirestack = {{ path = {path} }}
'''


def validate_smoke_output(output: str) -> None:
    lines = set(output.splitlines())
    missing = sorted(EXPECTED_SMOKE_LINES - lines)
    fingerprint = next((line for line in lines if line.startswith("buildFingerprint=")), "")
    if missing:
        raise ReleaseError(f"installed consumer smoke omitted required output: {missing}")
    if fingerprint == "buildFingerprint=":
        raise ReleaseError("installed consumer reported an empty build fingerprint")


def build_and_run_consumer(installed: Path, work: Path) -> tuple[Path, str, str]:
    consumer = work / "consumer"
    source = consumer / "src"
    source.mkdir(parents=True)
    (consumer / "cjpm.toml").write_text(consumer_manifest(installed), encoding="utf-8")
    shutil.copy2(SMOKE_FIXTURE, source / "main.cj")
    build_output = run(["cjpm", "build"], cwd=consumer)
    binary = consumer / "target/release/bin/main"
    if not binary.is_file():
        raise ReleaseError("clean consumer build did not produce target/release/bin/main")
    smoke_output = run([str(binary)], cwd=consumer)
    validate_smoke_output(smoke_output)
    return binary, build_output, smoke_output


def parse_needed(readelf_output: str) -> list[str]:
    return sorted(set(re.findall(r"Shared library: \[([^]]+)\]", readelf_output)))


def parse_ldd(ldd_output: str) -> list[dict[str, str]]:
    dependencies: list[dict[str, str]] = []
    for raw in ldd_output.splitlines():
        line = raw.strip()
        if not line:
            continue
        if " => " in line:
            name, remainder = line.split(" => ", 1)
            resolved = remainder.split(" (", 1)[0].strip()
        else:
            name = line.split(" (", 1)[0].strip()
            resolved = name
        dependencies.append({"name": name.strip(), "resolved": resolved})
    return dependencies


def reject_openssl_dependencies(names: Iterable[str]) -> None:
    forbidden = sorted(name for name in names if FORBIDDEN_OPENSSL_NAMES.match(Path(name).name))
    if forbidden:
        raise ReleaseError(f"consumer links a system OpenSSL dependency: {forbidden}")


def scan_binary(binary: Path) -> dict[str, Any]:
    readelf_output = run(["readelf", "-d", str(binary)], cwd=binary.parent)
    ldd_output = run(["ldd", str(binary)], cwd=binary.parent)
    needed = parse_needed(readelf_output)
    resolved = parse_ldd(ldd_output)
    reject_openssl_dependencies(needed)
    reject_openssl_dependencies(item["name"] for item in resolved)
    lowered = binary.read_bytes().lower()
    loader_strings = [value.decode() for value in FORBIDDEN_LOADER_BYTES if value in lowered]
    if loader_strings:
        raise ReleaseError(f"consumer contains system OpenSSL loader strings: {loader_strings}")
    return {
        "elf_sha256": sha256_path(binary),
        "needed": needed,
        "resolved": resolved,
        "forbidden_dependencies": [],
        "runtime_loader_library_strings": [],
    }


def validate_report(
    report: Mapping[str, Any],
    root: Path,
    *,
    verify_current_sources: bool = True,
) -> None:
    if report.get("schema_version") != 1 or report.get("task_id") != "M7-021":
        raise ReleaseError("qualification report identity is invalid")
    if report.get("decision") != "PASS":
        raise ReleaseError("qualification report decision must be PASS")
    artifact = report.get("artifact")
    if not isinstance(artifact, dict):
        raise ReleaseError("qualification report has no artifact object")
    digest = artifact.get("sha256")
    reproducibility = artifact.get("reproducibility")
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or not isinstance(reproducibility, dict)
        or reproducibility.get("builds") != 2
        or reproducibility.get("byte_identical") is not True
        or reproducibility.get("digests") != [digest, digest]
    ):
        raise ReleaseError("artifact reproducibility evidence is invalid")
    source_digest = report.get("source_tree_sha256")
    if not isinstance(source_digest, str) or re.fullmatch(r"[0-9a-f]{64}", source_digest) is None:
        raise ReleaseError("qualification source tree fingerprint is invalid")
    inputs = report.get("qualification_inputs")
    if (
        not isinstance(inputs, dict)
        or not inputs
        or any(
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or Path(relative).as_posix() != relative
            for relative in inputs
        )
        or any(
            not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None
            for value in inputs.values()
        )
    ):
        raise ReleaseError("qualification input fingerprint is invalid")
    if verify_current_sources:
        if set(inputs) != set(QUALIFICATION_INPUTS):
            raise ReleaseError("qualification input inventory is stale")
        if source_digest != source_tree_sha256(root):
            raise ReleaseError("qualification source tree fingerprint is stale")
        expected_inputs = {
            relative: sha256_path(root / relative) for relative in QUALIFICATION_INPUTS
        }
        if inputs != expected_inputs:
            raise ReleaseError("qualification input fingerprint is stale")
    installation = report.get("installation")
    if not isinstance(installation, dict):
        raise ReleaseError("qualification report has no installation object")
    for field in (
        "clean_consumer_build",
        "https_client_server_smoke",
        "runtime_info_smoke",
    ):
        if installation.get(field) != "PASS":
            raise ReleaseError(f"installation result is not PASS: {field}")
    smoke_output = installation.get("smoke_output")
    if not isinstance(smoke_output, list) or not all(isinstance(line, str) for line in smoke_output):
        raise ReleaseError("smoke output is invalid")
    validate_smoke_output("\n".join(smoke_output))
    dependency_scan = report.get("dependency_scan")
    if not isinstance(dependency_scan, dict):
        raise ReleaseError("qualification report has no dependency scan")
    needed = dependency_scan.get("needed")
    if not isinstance(needed, list) or not needed:
        raise ReleaseError("ELF dependency inventory is empty")
    reject_openssl_dependencies(needed)
    resolved = dependency_scan.get("resolved")
    if not isinstance(resolved, list) or not resolved:
        raise ReleaseError("resolved dependency inventory is empty")
    reject_openssl_dependencies(
        item.get("name", "") for item in resolved if isinstance(item, dict)
    )
    if dependency_scan.get("forbidden_dependencies") != []:
        raise ReleaseError("forbidden dependencies were reported")
    if dependency_scan.get("runtime_loader_library_strings") != []:
        raise ReleaseError("runtime loader strings were reported")
    runtime = report.get("runtime")
    if not isinstance(runtime, dict) or runtime.get("externalOpenSslDependency") is not False:
        raise ReleaseError("runtime did not report externalOpenSslDependency=false")


def qualify(root: Path, output_dir: Path, *, offline: bool) -> tuple[Path, Path, dict[str, Any]]:
    platform_data = platform_identity()
    prepare_native_dependencies(root, offline=offline)
    payload, release_manifest = collect_payload(root)
    output_dir.mkdir(parents=True, exist_ok=True)
    artifact = output_dir / ARTIFACT_NAME
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-021-") as temporary:
        work = Path(temporary)
        first = work / "first.tar.gz"
        second = work / "second.tar.gz"
        write_reproducible_archive(first, payload)
        write_reproducible_archive(second, payload)
        first_digest = sha256_path(first)
        second_digest = sha256_path(second)
        if first_digest != second_digest or first.read_bytes() != second.read_bytes():
            raise ReleaseError("two builds from identical inputs produced different artifacts")
        shutil.copy2(first, artifact)

        installed = extract_archive(artifact, work / "install")
        installed_manifest = load_json(installed / "release-manifest.json")
        if installed_manifest != release_manifest:
            raise ReleaseError("installed release manifest differs from the packaged manifest")
        binary, _build_output, smoke_output = build_and_run_consumer(installed, work)
        dependency_scan = scan_binary(binary)

    cjc_version = run(["cjc", "-v"], cwd=root).strip().splitlines()
    cjpm_version = run(["cjpm", "--version"], cwd=root).strip().splitlines()
    report: dict[str, Any] = {
        "schema_version": 1,
        "task_id": "M7-021",
        "decision": "PASS",
        "platform": platform_data,
        "source_tree_sha256": source_tree_sha256(root),
        "qualification_inputs": {
            relative: sha256_path(root / relative) for relative in QUALIFICATION_INPUTS
        },
        "artifact": {
            "name": artifact.name,
            "bytes": artifact.stat().st_size,
            "sha256": sha256_path(artifact),
            "reproducibility": {
                "builds": 2,
                "digests": [first_digest, second_digest],
                "byte_identical": True,
            },
            "payload_sha256": release_manifest["payload_sha256"],
            "production_source_files": release_manifest["production_source_files"],
        },
        "installation": {
            "method": "extract archive and use the installed root as a CJPM path dependency",
            "clean_consumer_build": "PASS",
            "https_client_server_smoke": "PASS",
            "runtime_info_smoke": "PASS",
            "smoke_output": smoke_output.splitlines(),
        },
        "dependency_scan": dependency_scan,
        "runtime": {
            "externalOpenSslDependency": False,
            "providerBuildFingerprint": next(
                line.split("=", 1)[1]
                for line in smoke_output.splitlines()
                if line.startswith("buildFingerprint=")
            ),
        },
        "toolchain": {"cjc": cjc_version, "cjpm": cjpm_version},
        "non_claims": [
            "The artifact is unsigned; M7-030 owns release signing.",
            "The artifact has no SBOM; M7-025 owns the SBOM and provider manifest bundle.",
            "This native result applies only to the Linux x86_64 glibc profile.",
        ],
    }
    validate_report(report, root)
    report_path = output_dir / "qualification.json"
    report_path.write_bytes(canonical_json(report))
    return artifact, report_path, report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--offline", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    output = (args.output_dir or root / "dist/m7-021").resolve()
    try:
        artifact, report_path, report = qualify(root, output, offline=args.offline)
    except ReleaseError as error:
        print(f"M7-021 Linux release qualification: FAIL: {error}")
        return 1
    print(
        "M7-021 Linux release qualification: PASS\n"
        f"artifact={artifact}\n"
        f"sha256={report['artifact']['sha256']}\n"
        f"report={report_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
