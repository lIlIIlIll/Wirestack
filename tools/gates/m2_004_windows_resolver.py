#!/usr/bin/env python3
"""Run and validate the native Windows M2-004 resolver acceptance gate."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest
from tools.gates.sts_sdk_identity import SDKIdentityError, capture_sdk_identity

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Any, Mapping


TASK_ID = "M2-004"
SCHEMA_VERSION = 2
VALIDATION_SCHEMA_VERSION = 2
PIN_PATH = PurePosixPath("docs/references/m2-004-sts-sdk.json")
EXPECTED_CASES = [
    "resolvesLocalhostThroughTheProviderNeutralContract",
    "fixtureReturnsAllCandidatesWithoutInventingTtl",
    "fixtureAppliesFamilyAndResultBounds",
    "fixtureMapsWinsockFailuresAndUnknownCodes",
    "fixtureCancellationAndDeadlineReturnBeforeNativeCleanup",
    "validatesBoundsAndRejectsUseAfterClose",
]


class GateError(RuntimeError):
    pass


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise

def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = evidence_digest.canonical_text_bytes(text.encode("utf-8"))
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(normalized)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def text_digest_for_value(value: object) -> dict[str, str]:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return evidence_digest.text_evidence_digest_bytes(encoded).to_json()


def digest_is(value: object, domain: str) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"domain", "sha256"}
        and value.get("domain") == domain
        and isinstance(value.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None
    )


def text_for_log_digest(value: str) -> dict[str, str]:
    return evidence_digest.text_evidence_digest_bytes(value.encode("utf-8")).to_json()


def record_log(
    log_root: Path, name: str, content: str, repo_root: Path
) -> dict[str, Any]:
    path = log_root / name
    atomic_text(path, content)
    return {
        "path": path.relative_to(repo_root).as_posix(),
        "digest": evidence_digest.text_evidence_digest(path).to_json(),
    }

def load_report(report_path: Path) -> tuple[dict[str, Any], dict[str, str]]:
    raw = report_path.read_bytes()
    payload = json.loads(raw.decode("utf-8"))
    if not isinstance(payload, dict):
        raise json.JSONDecodeError("report root must be an object", raw.decode("utf-8"), 0)
    return payload, evidence_digest.text_evidence_digest_bytes(raw).to_json()


def validation_payload(
    report_digest: dict[str, str],
    expected_revision: str,
    source_inventory_digest: dict[str, str],
    failures: list[str],
) -> dict[str, Any]:
    return {
        "schema_version": VALIDATION_SCHEMA_VERSION,
        "task_id": TASK_ID,
        "expected_revision": expected_revision,
        "report_digest": report_digest,
        "source_inventory_digest": source_inventory_digest,
        "failures": failures,
        "status": "PASS" if not failures else "FAIL",
    }


def stored_validation_failures(
    validation_path: Path, expected: dict[str, Any]
) -> list[str]:
    try:
        stored = json.loads(validation_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return ["VALIDATION:MISSING"]
    except (OSError, json.JSONDecodeError):
        return ["VALIDATION:INVALID"]
    if stored != expected:
        return ["VALIDATION:MISMATCH"]
    return []


def _redact_machine_paths(text: str, cwd: Path, env: Mapping[str, str]) -> str:
    for value, replacement in (
        (str(cwd.resolve()), "<workspace>"),
        (env.get("CANGJIE_HOME", ""), "<cangjie-sdk>"),
        (env.get("RUNNER_TEMP", ""), "<runner-temp>"),
        (env.get("TEMP", ""), "<temp>"),
        (env.get("TMP", ""), "<temp>"),
    ):
        if value:
            variants = {value, value.replace("/", "\\"), value.replace("\\", "/")}
            for variant in sorted(variants, key=len, reverse=True):
                text = re.sub(re.escape(variant), replacement, text, flags=re.IGNORECASE)
    text = re.sub(r"(?i)\b[A-Z]:\\Users\\[^\\\s]+", "<user-home>", text)
    return text


def run_command(
    command: list[str], *, cwd: Path, env: dict[str, str], timeout: int
) -> dict[str, Any]:
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
        output = completed.stdout
        exit_code: int | None = completed.returncode
        timed_out = False
    except subprocess.TimeoutExpired as error:
        captured = error.stdout or ""
        if isinstance(captured, bytes):
            captured = captured.decode("utf-8", errors="replace")
        output = captured
        exit_code = None
        timed_out = True
    return {
        "command": [_redact_machine_paths(part, cwd, env) for part in command],
        "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        "exit_code": exit_code,
        "output": _redact_machine_paths(output, cwd, env)[-20000:],
        "timed_out": timed_out,
    }


def process_failures(process: object, label: str) -> list[str]:
    if not isinstance(process, dict):
        return [f"{label}:MISSING"]
    failures: list[str] = []
    if process.get("timed_out"):
        failures.append(f"{label}:TIMEOUT")
    if process.get("exit_code") != 0:
        failures.append(f"{label}:EXIT")
    output = process.get("output", "")
    if not isinstance(output, str):
        return failures + [f"{label}:OUTPUT"]
    passed = re.findall(
        r"(?m)^\s*\[ PASSED \] CASE:\s*([A-Za-z0-9_]+)", output
    )
    if passed != EXPECTED_CASES:
        failures.append(f"{label}:CASE_SET")
    if "[ SKIPPED ] CASE:" in output or "[ FAILED ] CASE:" in output:
        failures.append(f"{label}:NON_PASS_CASE")
    summaries = re.findall(
        r"(?m)^\s*PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s*$",
        output,
    )
    failed_summaries = re.findall(r"(?m)^\s*FAILED:\s*(\d+)\s*$", output)
    if (
        not summaries
        or any(
            int(passed_count) != len(EXPECTED_CASES) or int(errors) != 0
            for passed_count, _skipped_count, errors in summaries
        )
        or not failed_summaries
        or any(int(failed_count) != 0 for failed_count in failed_summaries)
    ):
        failures.append(f"{label}:SUMMARY_FAILURE")
    return failures


def build_test_link_stub(root: Path, env: dict[str, str]) -> dict[str, Any]:
    cc = shutil.which("clang")
    ar = shutil.which("llvm-ar")
    if cc is None or ar is None:
        raise GateError("clang and llvm-ar are required for the test-only TLS link stub")
    source = root / "tools/gates/native/m2_004_tls_link_stub.c"
    if not source.is_file():
        raise GateError("test-only TLS link stub source is missing")
    output_dir = root / "target/native/test-support/m2-004/lib"
    output_dir.mkdir(parents=True, exist_ok=True)
    object_path = output_dir.parent / "m2_004_tls_link_stub.o"
    archive = output_dir / "libwirestack_m2_004_tls_link_stub.a"
    compiled = run_command(
        [
            Path(cc).name, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-c", source.relative_to(root).as_posix(),
            "-o", object_path.relative_to(root).as_posix(),
        ],
        cwd=root,
        env=env,
        timeout=60,
    )
    if compiled["timed_out"] or compiled["exit_code"] != 0:
        raise GateError("test-only TLS link stub compilation failed: " + compiled["output"][-4000:])
    archived = run_command(
        [
            Path(ar).name, "rcs", archive.relative_to(root).as_posix(),
            object_path.relative_to(root).as_posix(),
        ],
        cwd=root,
        env=env,
        timeout=60,
    )
    if archived["timed_out"] or archived["exit_code"] != 0 or not archive.is_file():
        raise GateError("test-only TLS link stub archive failed: " + archived["output"][-4000:])
    return {
        "archive_digest": evidence_digest.artifact_byte_digest(archive).to_json(),
        "compile": compiled,
        "archive": archived,
        "source_digest": evidence_digest.text_evidence_digest(source).to_json(),
        "purpose": "M2-004 resolver-test link support; all functions fail closed",
        "test_only": True,
    }




def bind_test_link_stub(manifest: str) -> str:
    marker = '  wirestack_resolver = { path = "./target/native/resolver/current/lib" }'
    if manifest.count(marker) < 2:
        raise GateError("Windows resolver FFI binding is missing from cjpm.toml")
    windows_table = "[target.x86_64-w64-mingw32.ffi.c]"
    start = manifest.find(windows_table)
    if start < 0:
        raise GateError("Windows target FFI table is missing from cjpm.toml")
    end = manifest.find("\n[", start + len(windows_table))
    if end < 0:
        end = len(manifest)
    section = manifest[start:end]
    if "wirestack_m2_004_tls_link_stub" in section:
        raise GateError("test-only TLS link stub leaked into the normal Windows target")
    bound = section.replace(
        marker,
        marker + '\n  wirestack_m2_004_tls_link_stub = { path = "./target/native/test-support/m2-004/lib" }',
        1,
    )
    return manifest[:start] + bound + manifest[end:]


def prepare_test_workspace(root: Path, destination: Path) -> None:
    shutil.copytree(
        root,
        destination,
        ignore=shutil.ignore_patterns(".git", "target", "build", "dist", "__pycache__"),
    )
    manifest_path = destination / "cjpm.toml"
    manifest_path.write_text(
        bind_test_link_stub(manifest_path.read_text(encoding="utf-8")),
        encoding="utf-8",
    )

def _repository_root(root: Path | None) -> Path:
    return (root or Path(__file__).resolve().parents[2]).resolve()


def load_sdk_pin(root: Path) -> dict[str, Any]:
    path = root.joinpath(*PIN_PATH.parts)
    try:
        pin = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("official M2-004 Windows STS SDK pin is unavailable") from error
    if (
        not isinstance(pin, dict)
        or pin.get("schema_version") != 1
        or pin.get("channel") != "STS"
        or pin.get("version") != "1.2.0"
        or not isinstance(pin.get("platform"), dict)
        or not isinstance(pin.get("archive"), dict)
    ):
        raise GateError("official M2-004 Windows STS SDK pin is invalid")
    return pin


def source_inventory(root: Path) -> dict[str, Any]:
    manifest_path = root / "tools/tasks/M2-004.json"
    try:
        task = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("M2-004 task manifest is unavailable") from error
    paths = task.get("source_paths") if isinstance(task, dict) else None
    if not isinstance(paths, list) or not paths or not all(
        isinstance(path, str) for path in paths
    ):
        raise GateError("M2-004 task source_paths is invalid")
    if len(paths) != len(set(paths)):
        raise GateError("M2-004 task source_paths contains duplicates")
    root = root.resolve(strict=True)
    entries: list[dict[str, Any]] = []
    for raw_path in paths:
        relative = PurePosixPath(raw_path)
        if (
            relative.is_absolute()
            or "\\" in raw_path
            or any(part in {"", ".", ".."} for part in relative.parts)
        ):
            raise GateError("M2-004 source path is not a canonical repository-relative path")
        path = root.joinpath(*relative.parts)
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(root)
        except (OSError, ValueError) as error:
            raise GateError(f"M2-004 source input is missing or escapes the repository: {raw_path}") from error
        if path.is_symlink() or not resolved.is_file():
            raise GateError(f"M2-004 source input is not a regular file: {raw_path}")
        entries.append({
            "path": relative.as_posix(),
            "digest": evidence_digest.text_evidence_digest(resolved).to_json(),
        })
    body: dict[str, Any] = {"schema_version": 1, "paths": entries}
    return {**body, "digest": text_digest_for_value(body)}


def _sdk_identity_failures(
    sdk: object, pin: Mapping[str, Any], actual: dict[str, Any] | None = None
) -> list[str]:
    failures: list[str] = []
    if not isinstance(sdk, dict):
        return ["SDK:IDENTITY_MISSING"]
    expected_keys = {
        "channel", "version", "archive_name", "archive", "matched_archive_files",
        "platform", "cjc", "cjpm",
    }
    if set(sdk) != expected_keys:
        failures.append("SDK:IDENTITY_FIELDS")
    archive_pin = pin.get("archive")
    platform_pin = pin.get("platform")
    if not isinstance(archive_pin, Mapping) or not isinstance(platform_pin, Mapping):
        return failures + ["SDK:PIN_INVALID"]
    expected_archive = {
        "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
        "sha256": archive_pin.get("sha256"),
    }
    if sdk.get("channel") != "STS" or sdk.get("version") != pin.get("version"):
        failures.append("SDK:VERSION")
    if sdk.get("archive_name") != archive_pin.get("name"):
        failures.append("SDK:ARCHIVE_NAME")
    if not evidence_digest.artifact_byte_sha256_equal(
        sdk.get("archive"), expected_archive
    ) or not digest_is(sdk.get("archive"), evidence_digest.ARTIFACT_BYTE_DOMAIN):
        failures.append("SDK:ARCHIVE_DIGEST")
    matched = sdk.get("matched_archive_files")
    if isinstance(matched, bool) or not isinstance(matched, int) or matched <= 0:
        failures.append("SDK:ARCHIVE_MEMBERS")
    platform_data = sdk.get("platform")
    if not isinstance(platform_data, dict):
        failures.append("SDK:PLATFORM")
    else:
        machines = platform_pin.get("machines")
        if (
            platform_data.get("system") != platform_pin.get("system")
            or not isinstance(machines, list)
            or platform_data.get("machine") not in machines
            or platform_data.get("native_target") != platform_pin.get("native_target")
        ):
            failures.append("SDK:PLATFORM")
    for tool_name, required in (
        ("cjc", {"relative_path", "version", "version_output", "target"}),
        ("cjpm", {"relative_path", "version", "version_output"}),
    ):
        tool = sdk.get(tool_name)
        if not isinstance(tool, dict) or set(tool) != required:
            failures.append(f"SDK:{tool_name.upper()}_FIELDS")
            continue
        relative = tool.get("relative_path")
        path = PurePosixPath(relative) if isinstance(relative, str) else PurePosixPath("/")
        if (
            path.is_absolute()
            or any(part in {"", ".", ".."} for part in path.parts)
            or path.name.lower().removesuffix(".exe") != tool_name
        ):
            failures.append(f"SDK:{tool_name.upper()}_PATH")
        if tool.get("version") != pin.get("version"):
            failures.append(f"SDK:{tool_name.upper()}_VERSION")
        output = tool.get("version_output")
        version_pattern = rf"(?<![A-Za-z0-9.+-]){re.escape(str(pin.get('version')))}(?![A-Za-z0-9.+-])"
        if (
            not isinstance(output, str)
            or re.search(version_pattern, output) is None
            or re.search(r"(?i)(?:nightly|alpha|beta|dev|snapshot)", output)
        ):
            failures.append(f"SDK:{tool_name.upper()}_OUTPUT")
        if tool_name == "cjc" and (
            tool.get("target") != platform_pin.get("native_target")
            or not isinstance(output, str)
            or re.search(
                rf"(?im)^\s*Target:\s*{re.escape(str(platform_pin.get('native_target')))}\s*$",
                output,
            ) is None
        ):
            failures.append("SDK:CJC_TARGET")
    if actual is not None and sdk != actual:
        failures.append("SDK:INSTALLED_IDENTITY_DRIFT")
    return failures


def _process_success_failures(process: object, label: str) -> list[str]:
    if not isinstance(process, dict):
        return [f"{label}:MISSING"]
    failures: list[str] = []
    if process.get("timed_out") is not False:
        failures.append(f"{label}:TIMEOUT")
    if process.get("exit_code") != 0:
        failures.append(f"{label}:EXIT")
    if not isinstance(process.get("output"), str) or not isinstance(process.get("command"), list):
        failures.append(f"{label}:FIELDS")
    return failures


def _source_inventory_failures(
    inventory: object, root: Path
) -> list[str]:
    if not isinstance(inventory, dict) or set(inventory) != {
        "schema_version", "paths", "digest"
    }:
        return ["SOURCE:INVENTORY_FIELDS"]
    if inventory.get("schema_version") != 1 or not isinstance(inventory.get("paths"), list):
        return ["SOURCE:INVENTORY_SCHEMA"]
    body = {"schema_version": inventory["schema_version"], "paths": inventory["paths"]}
    if (
        not digest_is(inventory.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN)
        or inventory.get("digest") != text_digest_for_value(body)
    ):
        return ["SOURCE:INVENTORY_DIGEST"]
    failures: list[str] = []
    seen: set[str] = set()
    for entry in inventory["paths"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "digest"}:
            failures.append("SOURCE:ENTRY_FIELDS")
            continue
        relative = entry.get("path")
        if (
            not isinstance(relative, str)
            or relative in seen
            or PurePosixPath(relative).is_absolute()
            or "\\" in relative
            or any(part in {"", ".", ".."} for part in PurePosixPath(relative).parts)
            or not digest_is(entry.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN)
        ):
            failures.append("SOURCE:ENTRY_INVALID")
        elif isinstance(relative, str):
            seen.add(relative)
    try:
        current = source_inventory(root)
    except GateError:
        return failures + ["SOURCE:CURRENT_INVENTORY"]
    if inventory != current:
        failures.append("SOURCE:DRIFT")
    return failures

def normalize_resolver_manifest(root: Path, manifest: object) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise GateError("resolver build manifest is not an object")
    inputs = manifest.get("inputs")
    archive = manifest.get("archive")
    if not isinstance(inputs, dict) or not isinstance(archive, dict):
        raise GateError("resolver build manifest omits inputs or archive identity")
    source = root / "native/resolver/windows/wirestack_resolver.c"
    header = root / "native/resolver/windows/wirestack_resolver.h"
    source_digest = evidence_digest.text_evidence_digest(source).to_json()
    header_digest = evidence_digest.text_evidence_digest(header).to_json()
    if (
        not evidence_digest.schema_text_sha256_equal(
            inputs.get("source_sha256"), source_digest["sha256"])
        or not evidence_digest.schema_text_sha256_equal(
            inputs.get("header_sha256"), header_digest["sha256"])
    ):
        raise GateError("resolver build manifest source identity differs from current inputs")
    raw_archive_path = archive.get("path")
    if not isinstance(raw_archive_path, str):
        raise GateError("resolver build manifest archive path is invalid")
    relative_archive = PurePosixPath(raw_archive_path)
    if relative_archive.is_absolute() or any(
        part in {"", ".", ".."} for part in relative_archive.parts
    ):
        raise GateError("resolver build manifest archive path escapes its artifact root")
    if relative_archive != PurePosixPath("lib/libwirestack_resolver.a"):
        raise GateError("resolver build manifest archive path does not identify the native library")
    archive_path = root / "target/native/resolver/current/lib/libwirestack_resolver.a"
    actual_archive_digest = evidence_digest.artifact_byte_digest(archive_path).to_json()
    if not evidence_digest.schema_artifact_sha256_equal(
        archive.get("sha256"), actual_archive_digest["sha256"]
    ):
        raise GateError("resolver build manifest archive digest does not match the built archive")
    compiler = inputs.get("compiler")
    compiler_name = (
        compiler.replace("\\", "/").rsplit("/", 1)[-1]
        if isinstance(compiler, str)
        else None
    )
    fingerprint = manifest.get("build_fingerprint")
    if not isinstance(fingerprint, str) or re.fullmatch(r"[0-9a-f]{64}", fingerprint) is None:
        raise GateError("resolver build fingerprint is invalid")
    normalized = {
        "schema_version": manifest.get("schema_version"),
        "build_fingerprint": {
            "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
            "sha256": fingerprint,
        },
        "platform": manifest.get("platform"),
        "inputs": {
            "schema": inputs.get("schema"),
            "source_digest": source_digest,
            "header_digest": header_digest,
            "compiler": compiler_name,
            "compiler_version": inputs.get("compiler_version"),
            "target": inputs.get("target"),
            "flags": inputs.get("flags"),
            "test_fixture": inputs.get("test_fixture"),
        },
        "archive": {
            "path": relative_archive.as_posix(),
            "digest": actual_archive_digest,
        },
        "worker_model": manifest.get("worker_model"),
        "close_model": manifest.get("close_model"),
        "private_runtime_abi": manifest.get("private_runtime_abi"),
        "test_fixture": manifest.get("test_fixture"),
    }
    return normalized

def validate_report(
    report: object,
    expected_revision: str,
    *,
    root: Path | None = None,
    sdk_identity: dict[str, Any] | None = None,
) -> list[str]:
    failures: list[str] = []
    if not isinstance(report, dict):
        return ["REPORT:TYPE"]
    repository = _repository_root(root)
    required_fields = {
        "schema_version", "task_id", "gate_id", "generated_at_utc", "revision",
        "platform", "sdk", "resolver_manifest", "resolver_manifest_digest", "build",
        "test_link_stub", "resolver_test", "source_inventory", "logs", "failures",
        "decision", "scope",
    }
    if set(report) != required_fields:
        failures.append("REPORT:FIELDS")
    if report.get("schema_version") != SCHEMA_VERSION:
        failures.append("REPORT:UNKNOWN_SCHEMA")
    if report.get("task_id") != TASK_ID:
        failures.append("REPORT:TASK")
    if report.get("gate_id") != "M2-004-WINDOWS-SYSTEM-RESOLVER":
        failures.append("REPORT:GATE")
    revision = report.get("revision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40,64}", revision) is None:
        failures.append("REPORT:REVISION_FORMAT")
    if revision != expected_revision:
        failures.append("REPORT:STALE_REVISION")
    if not isinstance(report.get("generated_at_utc"), str):
        failures.append("REPORT:GENERATED_AT")
    if report.get("scope") != "native Windows x86_64 resolver only":
        failures.append("REPORT:SCOPE")

    platform_data = report.get("platform")
    pin: dict[str, Any] | None = None
    try:
        pin = load_sdk_pin(repository)
    except GateError:
        failures.append("SDK:PIN")
    if not isinstance(platform_data, dict):
        failures.append("REPORT:PLATFORM")
    else:
        if platform_data.get("system") != "Windows":
            failures.append("REPORT:NON_NATIVE_WINDOWS")
        if platform_data.get("machine") not in {"AMD64", "x86_64"}:
            failures.append("REPORT:NON_NATIVE_ARCH")
        if not all(
            isinstance(platform_data.get(key), str)
            for key in ("release", "runner_image", "runner_image_version")
        ):
            failures.append("REPORT:PLATFORM_FIELDS")
    if pin is not None:
        failures.extend(_sdk_identity_failures(report.get("sdk"), pin, sdk_identity))

    inventory = report.get("source_inventory")
    failures.extend(_source_inventory_failures(inventory, repository))
    source_digests: dict[str, object] = {}
    if isinstance(inventory, dict) and isinstance(inventory.get("paths"), list):
        source_digests = {
            entry["path"]: entry.get("digest")
            for entry in inventory["paths"]
            if isinstance(entry, dict) and isinstance(entry.get("path"), str)
        }

    resolver_manifest = report.get("resolver_manifest")
    manifest_fields = {
        "schema_version", "build_fingerprint", "platform", "inputs", "archive",
        "worker_model", "close_model", "private_runtime_abi", "test_fixture",
    }
    if not isinstance(resolver_manifest, dict) or set(resolver_manifest) != manifest_fields:
        failures.append("REPORT:MANIFEST_FIELDS")
    else:
        if resolver_manifest.get("schema_version") != 1:
            failures.append("REPORT:MANIFEST_SCHEMA")
        if resolver_manifest.get("platform") != "windows-x86_64":
            failures.append("REPORT:MANIFEST_PLATFORM")
        if resolver_manifest.get("private_runtime_abi") is not False:
            failures.append("REPORT:PRIVATE_RUNTIME_ABI")
        if resolver_manifest.get("test_fixture") is not True:
            failures.append("REPORT:FIXTURE_NOT_BOUND")
        if not digest_is(
            resolver_manifest.get("build_fingerprint"),
            evidence_digest.TEXT_EVIDENCE_DOMAIN,
        ):
            failures.append("REPORT:BUILD_FINGERPRINT")
        inputs = resolver_manifest.get("inputs")
        expected_input_fields = {
            "schema", "source_digest", "header_digest", "compiler",
            "compiler_version", "target", "flags", "test_fixture",
        }
        if not isinstance(inputs, dict) or set(inputs) != expected_input_fields:
            failures.append("REPORT:MANIFEST_INPUTS")
        else:
            if inputs.get("schema") != 1 or inputs.get("test_fixture") is not True:
                failures.append("REPORT:MANIFEST_INPUT_SCHEMA")
            if (
                inputs.get("source_digest")
                != source_digests.get("native/resolver/windows/wirestack_resolver.c")
                or inputs.get("header_digest")
                != source_digests.get("native/resolver/windows/wirestack_resolver.h")
            ):
                failures.append("REPORT:MANIFEST_SOURCE_BINDING")
            if (
                not isinstance(inputs.get("compiler"), str)
                or "/" in inputs["compiler"]
                or "\\" in inputs["compiler"]
                or not isinstance(inputs.get("compiler_version"), str)
                or inputs.get("target") != "x86_64-pc-windows-msvc"
                or not isinstance(inputs.get("flags"), list)
            ):
                failures.append("REPORT:MANIFEST_TOOLCHAIN")
        archive = resolver_manifest.get("archive")
        if (
            not isinstance(archive, dict)
            or set(archive) != {"path", "digest"}
            or archive.get("path") != "lib/libwirestack_resolver.a"
            or not digest_is(archive.get("digest"), evidence_digest.ARTIFACT_BYTE_DOMAIN)
        ):
            failures.append("REPORT:NATIVE_ARCHIVE")
        if (
            not isinstance(resolver_manifest.get("worker_model"), str)
            or not isinstance(resolver_manifest.get("close_model"), str)
        ):
            failures.append("REPORT:MANIFEST_MODEL")
        if report.get("resolver_manifest_digest") != text_digest_for_value(resolver_manifest):
            failures.append("REPORT:MANIFEST_DIGEST")
    if not digest_is(
        report.get("resolver_manifest_digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN
    ):
        failures.append("REPORT:MANIFEST_DIGEST_DOMAIN")

    build = report.get("build")
    failures.extend(_process_success_failures(build, "BUILD"))
    if isinstance(build, dict) and build.get("command") != [
        "python", "tools/build_resolver.py", "--root", ".",
        "--platform", "windows-x86_64", "--test-fixture", "--quiet",
    ]:
        failures.append("BUILD:COMMAND")

    stub = report.get("test_link_stub")
    stub_fields = {
        "archive_digest", "compile", "archive", "source_digest", "purpose", "test_only"
    }
    if not isinstance(stub, dict) or set(stub) != stub_fields:
        failures.append("REPORT:TEST_LINK_STUB")
    else:
        if stub.get("test_only") is not True:
            failures.append("REPORT:TEST_LINK_STUB")
        if stub.get("purpose") != "M2-004 resolver-test link support; all functions fail closed":
            failures.append("REPORT:TEST_LINK_STUB_PURPOSE")
        if not digest_is(stub.get("archive_digest"), evidence_digest.ARTIFACT_BYTE_DOMAIN):
            failures.append("REPORT:TEST_LINK_STUB_ARCHIVE")
        if (
            stub.get("source_digest")
            != source_digests.get("tools/gates/native/m2_004_tls_link_stub.c")
        ):
            failures.append("REPORT:TEST_LINK_STUB_SOURCE")
        compile_process = stub.get("compile")
        archive_process = stub.get("archive")
        failures.extend(_process_success_failures(compile_process, "LINK_STUB_COMPILE"))
        failures.extend(_process_success_failures(archive_process, "LINK_STUB_ARCHIVE"))
        if isinstance(compile_process, dict):
            command = compile_process.get("command")
            if (
                not isinstance(command, list)
                or len(command) != 10
                or not isinstance(command[0], str)
                or command[0].lower() not in {"clang", "clang.exe"}
                or command[1:] != [
                    "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-c",
                    "tools/gates/native/m2_004_tls_link_stub.c", "-o",
                    "target/native/test-support/m2-004/m2_004_tls_link_stub.o",
                ]
            ):
                failures.append("LINK_STUB_COMPILE:COMMAND")
        if isinstance(archive_process, dict):
            command = archive_process.get("command")
            if (
                not isinstance(command, list)
                or len(command) != 4
                or not isinstance(command[0], str)
                or command[0].lower() not in {"llvm-ar", "llvm-ar.exe"}
                or command[1:] != [
                    "rcs",
                    "target/native/test-support/m2-004/lib/libwirestack_m2_004_tls_link_stub.a",
                    "target/native/test-support/m2-004/m2_004_tls_link_stub.o",
                ]
            ):
                failures.append("LINK_STUB_ARCHIVE:COMMAND")

    resolver_test = report.get("resolver_test")
    if not isinstance(resolver_test, dict):
        failures.append("REPORT:TEST_MISSING")
    else:
        failures.extend(process_failures(resolver_test, "RESOLVER_TEST"))
        if resolver_test.get("command") != [
            "cjpm", "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
            "--filter", "M2004WindowsSystemResolverTest", "--show-all-output",
            "--no-color", "--no-progress",
        ]:
            failures.append("RESOLVER_TEST:COMMAND")

    log_names = {
        "resolver_build": "resolver-build.log",
        "link_stub_compile": "test-link-stub-compile.log",
        "link_stub_archive": "test-link-stub-archive.log",
        "resolver_test": "resolver-tests.log",
        "cjc_version": "cjc-version.log",
        "cjpm_version": "cjpm-version.log",
    }
    log_outputs = {
        "resolver_build": build.get("output") if isinstance(build, dict) else None,
        "link_stub_compile": stub.get("compile", {}).get("output") if isinstance(stub, dict) and isinstance(stub.get("compile"), dict) else None,
        "link_stub_archive": stub.get("archive", {}).get("output") if isinstance(stub, dict) and isinstance(stub.get("archive"), dict) else None,
        "resolver_test": resolver_test.get("output") if isinstance(resolver_test, dict) else None,
        "cjc_version": report.get("sdk", {}).get("cjc", {}).get("version_output") if isinstance(report.get("sdk"), dict) and isinstance(report["sdk"].get("cjc"), dict) else None,
        "cjpm_version": report.get("sdk", {}).get("cjpm", {}).get("version_output") if isinstance(report.get("sdk"), dict) and isinstance(report["sdk"].get("cjpm"), dict) else None,
    }
    logs = report.get("logs")
    if not isinstance(logs, dict) or set(logs) != set(log_names):
        failures.append("LOGS:SET")
    else:
        prefix = "docs/evidence/M2-004/current-desktop/windows-x86_64/logs"
        for log_id, filename in log_names.items():
            record = logs.get(log_id)
            if (
                not isinstance(record, dict)
                or set(record) != {"path", "digest"}
                or record.get("path") != f"{prefix}/{filename}"
                or not digest_is(record.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN)
            ):
                failures.append(f"LOGS:{log_id.upper()}_RECORD")
                continue
            output = log_outputs.get(log_id)
            if not isinstance(output, str) or record.get("digest") != text_for_log_digest(output):
                failures.append(f"LOGS:{log_id.upper()}_CONTENT")

    captured_failures = report.get("failures")
    if captured_failures != []:
        failures.append("REPORT:FAILURES")
    if report.get("decision") != "PASS":
        failures.append("REPORT:DECISION")
    return list(dict.fromkeys(failures))


def validate_current_desktop_artifacts(
    report_path: Path,
    validation_path: Path,
    expected_revision: str,
    *,
    repo_root: Path | None = None,
    sdk_root: Path | None = None,
    sdk_archive: Path | None = None,
    write_validation: bool = False,
) -> list[str]:
    root = _repository_root(repo_root)
    try:
        report, report_digest = load_report(report_path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(f"current Windows resolver report is invalid: {error}") from error
    actual_sdk = None
    failures: list[str] = []
    if sdk_root is not None or sdk_archive is not None:
        if sdk_root is None or sdk_archive is None:
            failures.append("SDK:ARCHIVE_ARGUMENTS")
        else:
            try:
                actual_sdk = capture_sdk_identity(
                    sdk_root.resolve(), sdk_archive.resolve(), load_sdk_pin(root)
                )
            except (OSError, SDKIdentityError, GateError):
                failures.append("SDK:RECAPTURE")
    failures.extend(
        validate_report(report, expected_revision, root=root, sdk_identity=actual_sdk)
    )
    logs = report.get("logs") if isinstance(report, dict) else None
    if isinstance(logs, dict):
        for record in logs.values():
            if not isinstance(record, dict) or not isinstance(record.get("path"), str):
                continue
            relative = PurePosixPath(record["path"])
            if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
                failures.append("LOGS:PATH")
                continue
            path = root.joinpath(*relative.parts)
            try:
                path.resolve(strict=True).relative_to(root.resolve(strict=True))
                actual_digest = evidence_digest.text_evidence_digest(path).to_json()
            except (OSError, ValueError, evidence_digest.DigestError):
                failures.append("LOGS:FILE_MISSING_OR_UNSAFE")
                continue
            if actual_digest != record.get("digest"):
                failures.append("LOGS:FILE_DIGEST")
    source_inventory_value = report.get("source_inventory") if isinstance(report, dict) else None
    source_digest = (
        source_inventory_value.get("digest")
        if isinstance(source_inventory_value, dict)
        and digest_is(source_inventory_value.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN)
        else text_digest_for_value(None)
    )
    receipt = validation_payload(
        report_digest, expected_revision, source_digest, failures
    )
    if write_validation:
        atomic_json(validation_path, receipt)
    else:
        failures.extend(stored_validation_failures(validation_path, receipt))
    return list(dict.fromkeys(failures))


def run_gate(
    root: Path, output: Path, revision: str, sdk_root: Path, sdk_archive: Path
) -> dict[str, Any]:
    root = root.resolve(strict=True)
    if platform.system() != "Windows":
        raise GateError("M2-004 acceptance requires a native Windows host")
    if re.fullmatch(r"[0-9a-f]{40,64}", revision) is None:
        raise GateError("revision must be a full Git commit SHA")
    expected_output = root / "docs/evidence/M2-004/current-desktop/windows-x86_64/report.json"
    if output.resolve() != expected_output.resolve():
        raise GateError("current STS evidence must be written to its canonical path")
    head = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if head.returncode != 0 or head.stdout.strip() != revision:
        raise GateError("requested revision does not match the current checkout HEAD")
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if status.returncode != 0 or status.stdout.strip():
        raise GateError("native capture requires a clean exact-revision checkout")

    pin = load_sdk_pin(root)
    source_before = source_inventory(root)
    try:
        sdk = capture_sdk_identity(sdk_root.resolve(), sdk_archive.resolve(), pin)
    except (OSError, SDKIdentityError) as error:
        raise GateError(f"pinned Windows STS SDK identity failed: {error}") from error

    env = dict(os.environ)
    sdk_root = sdk_root.resolve(strict=True)
    env["CANGJIE_HOME"] = str(sdk_root)
    env["WIRESTACK_RESOLVER_TEST_FIXTURE"] = "1"
    sdk_path_entries = [
        sdk_root / "bin",
        sdk_root / "tools" / "bin",
        sdk_root / "tools" / "lib",
        sdk_root / "runtime" / "lib" / "windows_x86_64_cjnative",
    ]
    env["PATH"] = os.pathsep.join(
        [str(path) for path in sdk_path_entries] + [env.get("PATH", "")]
    )
    for tool_name in ("cjc", "cjpm"):
        expected_tool = (sdk_root / sdk[tool_name]["relative_path"]).resolve(strict=True)
        selected_tool = shutil.which(tool_name, path=env["PATH"])
        if selected_tool is None or Path(selected_tool).resolve() != expected_tool:
            raise GateError(f"{tool_name} PATH resolution differs from the pinned SDK")

    with tempfile.TemporaryDirectory(prefix="wirestack-m2-004-") as temporary:
        workspace = Path(temporary) / "repo"
        prepare_test_workspace(root, workspace)
        build = run_command(
            [
                "python", "tools/build_resolver.py", "--root", ".",
                "--platform", "windows-x86_64", "--test-fixture", "--quiet",
            ],
            cwd=workspace,
            env=env,
            timeout=120,
        )
        if build["timed_out"] or build["exit_code"] != 0:
            raise GateError("Windows resolver build failed: " + build["output"][-4000:])
        test_link_stub = build_test_link_stub(workspace, env)
        manifest_path = workspace / "target/native/resolver/current/resolver-manifest.json"
        try:
            raw_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise GateError("resolver manifest is unavailable") from error
        resolver_manifest = normalize_resolver_manifest(workspace, raw_manifest)
        # Windows does not use env["PATH"] to resolve a bare executable.
        resolver_test = run_command(
            [
                str(sdk_root / sdk["cjpm"]["relative_path"]),
                "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
                "--filter", "M2004WindowsSystemResolverTest", "--show-all-output",
                "--no-color", "--no-progress",
            ],
            cwd=workspace,
            env=env,
            timeout=180,
        )
        resolver_test["command"][0] = "cjpm"

    logs_root = output.parent / "logs"
    logs = {
        "resolver_build": record_log(logs_root, "resolver-build.log", build["output"], root),
        "link_stub_compile": record_log(
            logs_root, "test-link-stub-compile.log", test_link_stub["compile"]["output"], root
        ),
        "link_stub_archive": record_log(
            logs_root, "test-link-stub-archive.log", test_link_stub["archive"]["output"], root
        ),
        "resolver_test": record_log(
            logs_root, "resolver-tests.log", resolver_test["output"], root
        ),
        "cjc_version": record_log(
            logs_root, "cjc-version.log", sdk["cjc"]["version_output"], root
        ),
        "cjpm_version": record_log(
            logs_root, "cjpm-version.log", sdk["cjpm"]["version_output"], root
        ),
    }
    source_after = source_inventory(root)
    failures = process_failures(resolver_test, "RESOLVER_TEST")
    failures.extend(_process_success_failures(build, "BUILD"))
    failures.extend(_process_success_failures(test_link_stub["compile"], "LINK_STUB_COMPILE"))
    failures.extend(_process_success_failures(test_link_stub["archive"], "LINK_STUB_ARCHIVE"))
    if source_before != source_after:
        failures.append("SOURCE:DRIFT_DURING_CAPTURE")
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "gate_id": "M2-004-WINDOWS-SYSTEM-RESOLVER",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "revision": revision,
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "runner_image": os.environ.get("ImageOS", "unknown"),
            "runner_image_version": os.environ.get("ImageVersion", "unknown"),
        },
        "sdk": sdk,
        "resolver_manifest": resolver_manifest,
        "resolver_manifest_digest": text_digest_for_value(resolver_manifest),
        "build": build,
        "test_link_stub": test_link_stub,
        "resolver_test": resolver_test,
        "source_inventory": source_before,
        "logs": logs,
        "failures": failures,
        "decision": "PASS" if not failures else "FAIL",
        "scope": "native Windows x86_64 resolver only",
    }
    failures.extend(validate_report(report, revision, root=root, sdk_identity=sdk))
    report["failures"] = list(dict.fromkeys(failures))
    report["decision"] = "PASS" if not report["failures"] else "FAIL"
    atomic_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--sdk-root", type=Path)
    parser.add_argument("--sdk-archive", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--validate-report", type=Path)
    expected = parser.add_mutually_exclusive_group()
    expected.add_argument("--expected-revision")
    expected.add_argument("--expected-source-inputs", action="store_true")
    parser.add_argument("--validation-output", type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    if args.validate_report is not None:
        try:
            report, _ = load_report(args.validate_report)
            if args.expected_source_inputs:
                expected_revision = report.get("revision")
                if not isinstance(expected_revision, str):
                    raise GateError("report revision is missing")
            else:
                expected_revision = args.expected_revision
            if not isinstance(expected_revision, str) or not expected_revision:
                raise GateError("an expected revision or source-input binding is required")
            validation_path = args.validation_output or args.validate_report.with_name("validation.json")
            failures = validate_current_desktop_artifacts(
                args.validate_report,
                validation_path,
                expected_revision,
                repo_root=root,
                sdk_root=args.sdk_root,
                sdk_archive=args.sdk_archive,
                write_validation=args.validation_output is not None,
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, GateError) as error:
            print(f"M2-004: invalid current report: {error}")
            return 2
        print(json.dumps({
            "task_id": TASK_ID,
            "expected_revision": expected_revision,
            "failures": failures,
            "status": "PASS" if not failures else "FAIL",
        }, sort_keys=True))
        return 0 if not failures else 1
    if args.output is None or not args.revision or args.sdk_root is None or args.sdk_archive is None:
        print("M2-004: --output, --revision, --sdk-root, and --sdk-archive are required")
        return 2
    try:
        report = run_gate(
            root, args.output.resolve(), args.revision, args.sdk_root, args.sdk_archive
        )
    except (GateError, SDKIdentityError) as error:
        print(f"M2-004-WINDOWS-SYSTEM-RESOLVER: ERROR: {error}")
        return 2
    print(json.dumps({
        "decision": report["decision"],
        "failures": report["failures"],
        "report": args.output.as_posix(),
    }, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
