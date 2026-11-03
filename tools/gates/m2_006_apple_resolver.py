#!/usr/bin/env python3
"""Run and validate M2-006 on native macOS or an iOS Simulator."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest
from tools.gates import sts_sdk_identity

import argparse
import datetime as dt
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Mapping


TASK_ID = "M2-006"
SCHEMA_VERSION = 2
EXPECTED_TESTS = 8
MODES = {"macos": "macos-arm64", "ios-simulator": "ios-simulator-arm64"}
CAPTURE_MODES = {"macos"}
IOS_TARGET = "arm64-apple-ios11-simulator"
SDK_PIN_PATH = Path("docs/references/m2-006-sts-sdk.json")
PINNED_SDK_CHANNEL = "STS"
PINNED_SDK_VERSION = "1.2.0"
PINNED_SDK_ARCHIVE_NAME = "cangjie-sdk-mac-aarch64-1.2.0.tar.gz"
PINNED_SDK_URL = "https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-mac-aarch64-1.2.0.tar.gz&objectKey=6ab1e6451320215435b23d52"
PINNED_SDK_ARCHIVE_SHA256 = "de88d6ba2185c94979e0ab2fe8ac1d81535dfdff3fcb51fbba71e4b99d851f97"
PINNED_SDK_ARCHIVE_SIZE_BYTES = 163787681
PINNED_SDK_TARGET = "aarch64-apple-darwin"
LOG_IDS = (
    "resolver-build",
    "test-link-stub-compile",
    "test-link-stub-archive",
    "resolver-test",
    "toolchain-version",
)
def _load_declared_source_paths() -> tuple[str, ...]:
    repository_root = Path(__file__).resolve().parents[2]
    manifest_path = repository_root / "tools/tasks/M2-006.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("M2-006 task manifest is unavailable or invalid") from error
    paths = manifest.get("source_paths") if isinstance(manifest, dict) else None
    required_evidence = manifest.get("required_evidence") if isinstance(manifest, dict) else None
    if (
        not isinstance(paths, list)
        or not paths
        or not all(
            isinstance(path, str)
            and bool(path)
            and "\\" not in path
            and not Path(path).is_absolute()
            and Path(path).as_posix() == path
            and ".." not in Path(path).parts
            for path in paths
        )
        or len(paths) != len(set(paths))
        or not isinstance(required_evidence, list)
        or not all(isinstance(path, str) for path in required_evidence)
        or set(paths) & set(required_evidence)
        or any(
            path.startswith((
                "build/",
                "target/",
                "dist/",
                "docs/evidence/M2-006/current-desktop/",
                "docs/evidence/M2-006/current-mobile/",
            ))
            for path in paths
        )
        or not {
            ".github/workflows/m2-006-apple-system-resolver.yml",
            "tools/evidence_digest.py",
            "tools/gates/m2_006_apple_resolver.py",
            "tools/gates/sts_sdk_identity.py",
            "tools/tasks/M2-006.json",
        }.issubset(paths)
    ):
        raise RuntimeError("M2-006 task source inventory is incomplete or contains generated evidence")
    return tuple(paths)


SOURCE_PATHS = _load_declared_source_paths()
REPORT_FIELDS = {
    "schema_version", "task_id", "gate_id", "generated_at_utc", "revision", "mode",
    "platform", "source_inventory", "sdk", "resolver_manifest",
    "resolver_manifest_digest", "build", "test_link_stub", "resolver_test", "logs",
    "failures", "decision", "scope",
}
VALIDATION_FIELDS = {
    "schema_version", "task_id", "expected_revision", "expected_mode",
    "report_digest", "failures", "status",
}
EXPECTED_CASES = {
    "macos": (
        "resolvesLocalhostThroughTheProviderNeutralContract",
        "fixtureReturnsAllCandidatesWithoutInventingTtl",
        "fixtureAppliesFamilyAndResultBounds",
        "fixtureMapsPosixFailuresAndUnknownCodes",
        "fixtureCancellationAndDeadlineReturnBeforeNativeCleanup",
        "newResolutionObservesNetworkGenerationChange",
        "validatesBoundsAndRejectsUseAfterClose",
        "fixtureBoundsAdmissionAndReleasesQueuedWorkAfterClose",
    ),
    "ios-simulator": (
        "resolves localhost",
        "returns and deduplicates candidates",
        "applies family and result bounds",
        "maps POSIX resolver failures",
        "honors cancellation and Deadline",
        "observes a new network generation",
        "closes idempotently and rejects invalid bounds",
        "bounds admission and releases queued work",
    ),
}


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


def _sanitize_text(value: str, replacements: Mapping[str, str]) -> str:
    for source, replacement in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        if source:
            value = value.replace(source, replacement)
    value = re.sub(r"/Users/[^/\s]+", "$HOME", value)
    value = re.sub(r"/home/[^/\s]+", "$HOME", value)
    value = re.sub(r"[A-Za-z]:\\Users\\[^\\\s]+", "%USERPROFILE%", value)
    value = re.sub(r"/Applications/Xcode[^/\s]*/Contents/Developer(?:/[^\s]+)?", "<XCODE_PATH>", value)
    return value


def _path_redactions(path: Path, replacement: str) -> dict[str, str]:
    return {
        value: replacement
        for value in {str(path), str(path.resolve())}
        if value
    }


def _diagnostics_for_output(output: str) -> str:
    diagnostic_lines = [
        line
        for line in output.splitlines()
        if re.search(
            r"(?:^|\b)(?:error|fatal|undefined|duplicate|ld(?:64)?(?:\.lld)?):|"
            r"symbol\(s\) not found|linker command failed",
            line,
            re.IGNORECASE,
        )
    ]
    return "\n".join(diagnostic_lines[-200:])[-30000:]


def _sanitize_payload(value: Any, replacements: Mapping[str, str]) -> Any:
    if isinstance(value, str):
        return _sanitize_text(value, replacements)
    if isinstance(value, list):
        return [_sanitize_payload(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: _sanitize_payload(item, replacements) for key, item in value.items()}
    return value


def _log_record(log_directory: Path, report_directory: Path, log_id: str) -> dict[str, Any]:
    path = log_directory / f"{log_id}.log"
    return {
        "id": log_id,
        "path": path.relative_to(report_directory).as_posix(),
        "digest": evidence_digest.text_evidence_digest(path).to_json(),
    }


def validation_payload(
    report_path: Path,
    expected_revision: str,
    expected_mode: str,
    failures: list[str],
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "expected_revision": expected_revision,
        "expected_mode": expected_mode,
        "report_digest": evidence_digest.text_evidence_digest(report_path).to_json(),
        "failures": failures,
        "status": "PASS" if not failures else "FAIL",
    }


def _normalized_text_bytes(value: str) -> bytes:
    return evidence_digest.canonical_text_bytes(value.encode("utf-8"))


def run_command(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int,
    output_limit: int = 20000,
    log_path: Path | None = None,
    redactions: Mapping[str, str] | None = None,
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
        stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout
        stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr
        output = (stdout or "") + (stderr or "")
        exit_code = None
        timed_out = True
    replacements = redactions or {}
    output = _sanitize_text(output, replacements)
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(output, encoding="utf-8", newline="\n")
    normalized_command = _sanitize_payload(command, replacements)
    return {
        "command": normalized_command,
        "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        "exit_code": exit_code,
        "diagnostics": _diagnostics_for_output(output),
        "output": output[-output_limit:],
        "timed_out": timed_out,
    }


def require_success(process: dict[str, Any], label: str) -> None:
    if process["timed_out"] or process["exit_code"] != 0:
        diagnostics = process.get("diagnostics", "")
        raise GateError(
            f"{label} failed\ndiagnostics:\n{diagnostics}\noutput tail:\n"
            f"{process['output'][-4000:]}"
        )


def process_failures(
    process: dict[str, Any], expected_cases: tuple[str, ...], label: str,
    *, trace_ids: tuple[int, ...] = (),
) -> list[str]:
    failures: list[str] = []
    if process.get("timed_out"):
        failures.append(f"{label}:TIMEOUT")
    if process.get("exit_code") != 0:
        failures.append(f"{label}:EXIT")
    output = process.get("output", "")
    passed_cases = tuple(
        match.group(1).strip()
        for match in re.finditer(
            r"^\s*\[ PASSED \] CASE:\s*(.+?)(?:\s+\([0-9]+ ns\))?\s*$",
            output,
            re.MULTILINE,
        )
    )
    if trace_ids:
        trace_events = tuple(
            (int(match.group(1)), match.group(2))
            for match in re.finditer(
                r"^\s*\[ TRACE \] CASE:\s*([0-9]+)\s+(START|PASS|FAIL)\s*$",
                output,
                re.MULTILINE,
            )
        )
        expected_trace = tuple(
            event for case_id in trace_ids
            for event in ((case_id, "START"), (case_id, "PASS"))
        )
        if len(trace_events) != len(expected_trace):
            failures.append(f"{label}:CASE_COUNT")
        if trace_events != expected_trace:
            failures.append(f"{label}:CASE_INVENTORY")
    else:
        if len(passed_cases) != len(expected_cases):
            failures.append(f"{label}:CASE_COUNT")
        if len(passed_cases) != len(set(passed_cases)) or set(passed_cases) != set(expected_cases):
            failures.append(f"{label}:CASE_INVENTORY")
    if ("[ SKIPPED ] CASE:" in output or "[ FAILED ] CASE:" in output or
            re.search(r"^\s*\[ TRACE \] CASE:\s*[0-9]+\s+FAIL\s*$", output, re.MULTILINE)):
        failures.append(f"{label}:NON_PASS_CASE")
    summary = "\n".join((output, process.get("diagnostics", "")))
    if re.search(r"(?:FAILED|ERROR): [1-9]", summary):
        failures.append(f"{label}:SUMMARY_FAILURE")
    return failures


def xcrun(root: Path, env: dict[str, str], sdk: str, *arguments: str) -> str:
    # Discovery returns operational paths, not sanitized evidence text.
    try:
        process = subprocess.run(
            ["xcrun", "--sdk", sdk, *arguments],
            cwd=root,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise GateError(f"xcrun {sdk} {' '.join(arguments)} timed out") from error
    if process.returncode != 0:
        diagnostics = _sanitize_text(process.stdout, {})[-4000:]
        raise GateError(f"xcrun {sdk} {' '.join(arguments)} failed:\n{diagnostics}")
    return process.stdout.strip()


def deployment_flags(selected: str) -> list[str]:
    if selected == "ios-simulator-arm64":
        return ["-mios-simulator-version-min=11.0"]
    if selected == "macos-arm64":
        return ["-mmacosx-version-min=12.0"]
    raise GateError(f"unsupported Apple deployment target: {selected}")


def command_has_target(command: object, target: str) -> bool:
    if not isinstance(command, list) or not all(isinstance(item, str) for item in command):
        return False
    return target in command or f"--target={target}" in command


def resolver_ffi_path(selected: str) -> str:
    if selected not in MODES.values():
        raise GateError(f"unsupported Apple resolver platform: {selected}")
    return f"./target/native/resolver/{selected}/current/lib"


def bind_test_link_stub(manifest: str, selected: str) -> str:
    table = {
        "macos-arm64": "[target.aarch64-apple-darwin.ffi.c]",
        "ios-simulator-arm64": "[target.arm64-apple-ios11-simulator.ffi.c]",
    }.get(selected)
    if table is None:
        raise GateError(f"unsupported Apple resolver platform: {selected}")
    start = manifest.find(table)
    end = manifest.find("\n[target.", start + len(table))
    if start < 0:
        raise GateError("Apple target FFI table is missing from cjpm.toml")
    if end < 0:
        end = manifest.find("\n[dependencies]", start + len(table))
    if end < 0:
        raise GateError("Apple target FFI table is unterminated in cjpm.toml")
    section = manifest[start:end]
    marker = f'  wirestack_resolver = {{ path = "{resolver_ffi_path(selected)}" }}'
    if section.count(marker) != 1:
        raise GateError("Apple resolver FFI binding is missing from cjpm.toml")
    if "wirestack_m2_006_tls_link_stub" in section:
        raise GateError("test-only TLS link stub leaked into the normal Apple target")
    bound = section.replace(
        marker,
        marker + '\n  wirestack_m2_006_tls_link_stub = { path = "./target/native/test-support/m2-006/lib" }',
        1,
    )
    return manifest[:start] + bound + manifest[end:]


def prepare_test_workspace(root: Path, destination: Path, selected: str) -> None:
    shutil.copytree(
        root,
        destination,
        ignore=shutil.ignore_patterns(".git", "target", "build", "dist", "__pycache__"),
    )
    manifest_path = destination / "cjpm.toml"
    manifest_path.write_text(
        bind_test_link_stub(manifest_path.read_text(encoding="utf-8"), selected),
        encoding="utf-8",
    )


def ios_launch_command(device: str) -> list[str]:
    return [
        "xcrun", "simctl", "launch", "--console", "--terminate-running-process",
        device, "dev.wirestack.m2-006-tests",
    ]


def retryable_ios_launch_timeout(process: Mapping[str, Any]) -> bool:
    return process.get("timed_out") is True and process.get("output") == ""


def valid_ios_launch_recovery(recovery: object) -> bool:
    if not isinstance(recovery, list) or len(recovery) != 4:
        return False
    operations = ("terminate", "shutdown", "boot", "bootstatus")
    for index, operation in enumerate(operations):
        process = recovery[index]
        if not isinstance(process, dict) or process.get("timed_out") is not False:
            return False
        command = process.get("command")
        if not isinstance(command, list) or operation not in command:
            return False
        if index > 0 and process.get("exit_code") != 0:
            return False
    return True


def launch_ios_probe(
    root: Path, env: dict[str, str], device: str
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    attempts = [run_command(
        ios_launch_command(device), cwd=root, env=env, timeout=90
    )]
    recovery: list[dict[str, Any]] = []
    if retryable_ios_launch_timeout(attempts[0]):
        recovery.append(run_command(
            ["xcrun", "simctl", "terminate", device, "dev.wirestack.m2-006-tests"],
            cwd=root, env=env, timeout=30,
        ))
        shutdown = run_command(
            ["xcrun", "simctl", "shutdown", device], cwd=root, env=env, timeout=60
        )
        recovery.append(shutdown)
        require_success(shutdown, "recover iOS Simulator after launch timeout")
        boot = run_command(
            ["xcrun", "simctl", "boot", device], cwd=root, env=env, timeout=60
        )
        recovery.append(boot)
        require_success(boot, "reboot iOS Simulator after launch timeout")
        boot_status = run_command(
            ["xcrun", "simctl", "bootstatus", device, "-b"],
            cwd=root, env=env, timeout=300,
        )
        recovery.append(boot_status)
        require_success(boot_status, "wait for recovered iOS Simulator")
        attempts.append(run_command(
            ios_launch_command(device), cwd=root, env=env, timeout=90
        ))
    return attempts[-1], attempts, recovery


def ios_link_options() -> str:
    return (
        f"-L {resolver_ffi_path('ios-simulator-arm64')} -lwirestack_resolver "
        "-L ./target/native/test-support/m2-006/lib -lwirestack_m2_006_tls_link_stub "
        "-rpath @executable_path/Frameworks"
    )


def ios_runtime_libraries(env: dict[str, str]) -> list[Path]:
    cangjie_home = env.get("CANGJIE_HOME")
    if not cangjie_home:
        raise GateError("CANGJIE_HOME is required to package the iOS Simulator runtime")
    runtime_dir = Path(cangjie_home) / "runtime/lib/ios_simulator_aarch64_cjnative"
    libraries = sorted(path for path in runtime_dir.glob("*.dylib") if path.is_file())
    if not libraries or not any(path.name == "libcangjie-runtime.dylib" for path in libraries):
        raise GateError("the official iOS Simulator Cangjie runtime is incomplete")
    return libraries


def build_test_link_stub(
    root: Path,
    env: dict[str, str],
    selected: str,
    *,
    log_directory: Path | None = None,
    redactions: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    sdk = "macosx" if selected == "macos-arm64" else "iphonesimulator"
    cc = xcrun(root, env, sdk, "--find", "clang")
    ar = xcrun(root, env, sdk, "--find", "ar")
    sysroot = xcrun(root, env, sdk, "--show-sdk-path")
    source = root / "tools/gates/native/m2_006_tls_link_stub.c"
    if not source.is_file():
        raise GateError("M2-006 test-only TLS link stub is missing")
    output_dir = root / "target/native/test-support/m2-006/lib"
    output_dir.mkdir(parents=True, exist_ok=True)
    object_path = output_dir.parent / "m2_006_tls_link_stub.o"
    archive = output_dir / "libwirestack_m2_006_tls_link_stub.a"
    selected_deployment_flags = deployment_flags(selected)
    compiled = run_command(
        [
            cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-arch", "arm64", "-isysroot", sysroot,
            *selected_deployment_flags,
            "-c", str(source), "-o", str(object_path),
        ],
        cwd=root,
        env=env,
        timeout=60,
        log_path=log_directory / "test-link-stub-compile.log" if log_directory else None,
        redactions=redactions,
    )
    require_success(compiled, "M2-006 TLS link stub compilation")
    archived = run_command(
        [ar, "rcs", str(archive), str(object_path)],
        cwd=root,
        env=env,
        timeout=60,
        log_path=log_directory / "test-link-stub-archive.log" if log_directory else None,
        redactions=redactions,
    )
    require_success(archived, "M2-006 TLS link stub archive")
    return {
        "archive_digest": evidence_digest.artifact_byte_digest(archive).to_json(),
        "compile": compiled,
        "archive": archived,
        "source_digest": evidence_digest.text_evidence_digest(source).to_json(),
        "test_only": True,
        "target": selected,
    }


def select_ios_device(root: Path, env: dict[str, str]) -> tuple[str, str]:
    listed = run_command(
        ["xcrun", "simctl", "list", "-j", "devices", "available"],
        cwd=root,
        env=env,
        timeout=30,
        output_limit=2 * 1024 * 1024,
    )
    require_success(listed, "iOS Simulator device discovery")
    try:
        payload = json.loads(listed["output"])
    except json.JSONDecodeError as error:
        raise GateError(
            f"invalid simctl device response: {error}; output={listed['output'][-2000:]}"
        ) from error
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise GateError("simctl did not return a device map")
    for runtime in sorted(devices, reverse=True):
        if ".iOS-" not in runtime:
            continue
        candidates = devices[runtime]
        if not isinstance(candidates, list):
            continue
        for device in candidates:
            if (
                isinstance(device, dict)
                and device.get("isAvailable") is True
                and isinstance(device.get("udid"), str)
                and isinstance(device.get("name"), str)
                and str(device["name"]).startswith("iPhone")
            ):
                return device["udid"], runtime
    raise GateError("no available iOS Simulator device was found")


def make_ios_bundle(
    root: Path,
    env: dict[str, str],
    executable: Path,
    bundle: Path,
    device: str,
) -> dict[str, Any]:
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    executable_copy = bundle / "wirestack-m2-006"
    shutil.copy2(executable, executable_copy)
    executable_copy.chmod(executable_copy.stat().st_mode | stat.S_IXUSR)
    bundle_source_probe_sha256 = evidence_digest.artifact_byte_sha256(executable_copy)
    frameworks = bundle / "Frameworks"
    frameworks.mkdir()
    runtime_copies: list[Path] = []
    for library in ios_runtime_libraries(env):
        copied = frameworks / library.name
        shutil.copy2(library, copied)
        runtime_copies.append(copied)
    with (bundle / "Info.plist").open("wb") as output:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": executable_copy.name,
                "CFBundleIdentifier": "dev.wirestack.m2-006-tests",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Wirestack M2-006",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "MinimumOSVersion": "11.0",
                "UIDeviceFamily": [1, 2],
            },
            output,
        )
    for runtime_copy in runtime_copies:
        signed_runtime = run_command(
            ["codesign", "--force", "--sign", "-", str(runtime_copy)],
            cwd=root,
            env=env,
            timeout=30,
        )
        require_success(signed_runtime, f"ad-hoc sign {runtime_copy.name}")
    signed = run_command(
        ["codesign", "--force", "--sign", "-", str(executable_copy)],
        cwd=root,
        env=env,
        timeout=30,
    )
    require_success(signed, "ad-hoc sign iOS resolver probe")
    signed_bundle = run_command(
        ["codesign", "--force", "--sign", "-", str(bundle)],
        cwd=root,
        env=env,
        timeout=30,
    )
    require_success(signed_bundle, "ad-hoc sign iOS test bundle")
    installed = run_command(
        ["xcrun", "simctl", "install", device, str(bundle)],
        cwd=root,
        env=env,
        timeout=60,
    )
    require_success(installed, "install iOS test bundle")
    return {
        "bundle_source_probe_sha256": bundle_source_probe_sha256,
        "bundle_probe_sha256": evidence_digest.artifact_byte_sha256(executable_copy),
        "install": installed,
        "runtime_libraries": [
            {
                "path": f"Frameworks/{runtime_copy.name}",
                "sha256": evidence_digest.artifact_byte_sha256(runtime_copy),
            }
            for runtime_copy in runtime_copies
        ],
    }


def run_ios_test(root: Path, env: dict[str, str]) -> tuple[dict[str, Any], dict[str, Any]]:
    target_dir = root / "target/m2-006-ios-simulator"
    build = run_command(
        [
            "cjpm", "build", "-j", "1", "--target", IOS_TARGET,
            "--target-dir", str(target_dir), "-V",
        ],
        cwd=root,
        env=env,
        timeout=300,
    )
    require_success(build, "iOS Simulator Cangjie package build")
    release_dir = target_dir / IOS_TARGET / "release"
    library_dir = release_dir / "wirestack"
    probe_source = root / "tools/gates/probes/m2_006_apple_resolver.cj"
    probe = root / "build/gates/m2-006/wirestack-m2-006-ios"
    probe.parent.mkdir(parents=True, exist_ok=True)
    probe_compile = run_command(
        [
            "cjc", str(probe_source), "-o", str(probe),
            "--import-path", str(release_dir),
            "-L", str(library_dir),
            "-lwirestack.internal.resolver",
            "-lwirestack.internal.transport",
            "-lwirestack.internal.common",
            "-lwirestack",
            f"--target={IOS_TARGET}", "--sysroot", env["WIRESTACK_IOS_SIMULATOR_SYSROOT"],
            "--link-options", ios_link_options(),
        ],
        cwd=root,
        env=env,
        timeout=120,
    )
    require_success(probe_compile, "iOS Simulator resolver probe compilation")
    device, runtime = select_ios_device(root, env)
    booted = run_command(["xcrun", "simctl", "boot", device], cwd=root, env=env, timeout=60)
    if booted["exit_code"] != 0 and "current state: Booted" not in booted["output"]:
        require_success(booted, "boot iOS Simulator")
    boot_status = run_command(
        ["xcrun", "simctl", "bootstatus", device, "-b"], cwd=root, env=env, timeout=300
    )
    require_success(boot_status, "wait for iOS Simulator")
    bundle = root / "build/gates/m2-006/WirestackM2006.app"
    try:
        installed_metadata = make_ios_bundle(root, env, probe, bundle, device)
        process, launch_attempts, launch_recovery = launch_ios_probe(
            root, env, device
        )
    finally:
        run_command(["xcrun", "simctl", "shutdown", device], cwd=root, env=env, timeout=60)
    return process, {
        "build": build,
        "probe_compile": probe_compile,
        "device_udid": device,
        "runtime": runtime,
        "probe_sha256": evidence_digest.artifact_byte_sha256(probe),
        "launch_attempts": launch_attempts,
        "launch_recovery": launch_recovery,
        **installed_metadata,
    }


def _valid_typed_digest(value: object, domain: str) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"domain", "sha256"}
        and value.get("domain") == domain
        and isinstance(value.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None
    )


def _valid_relative_path(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and not value.startswith(("/", "\\"))
        and "\\" not in value
        and all(part not in {"", ".", ".."} for part in value.split("/"))
    )


def _valid_process_receipt(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {
            "command", "duration_ms", "exit_code", "diagnostics", "output", "timed_out"
        }
        and isinstance(value.get("command"), list)
        and all(isinstance(item, str) for item in value["command"])
        and isinstance(value.get("duration_ms"), (int, float))
        and not isinstance(value.get("duration_ms"), bool)
        and (
            value.get("exit_code") is None
            or (isinstance(value.get("exit_code"), int) and not isinstance(value.get("exit_code"), bool))
        )
        and isinstance(value.get("timed_out"), bool)
        and isinstance(value.get("diagnostics"), str)
        and isinstance(value.get("output"), str)
    )


def _successful_process(value: object) -> bool:
    return (
        _valid_process_receipt(value)
        and value.get("exit_code") == 0
        and value.get("timed_out") is False
    )


def _json_text_digest(payload: object) -> dict[str, str]:
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    return evidence_digest.text_evidence_digest_bytes(encoded).to_json()


def _validate_source_inventory(value: object, expected_revision: str) -> list[str]:
    failures: list[str] = []
    if not isinstance(value, dict) or set(value) != {"revision", "clean_worktree", "files"}:
        return ["REPORT:SOURCE_INVENTORY"]
    if value.get("revision") != expected_revision or value.get("clean_worktree") is not True:
        failures.append("REPORT:SOURCE_BINDING")
    files = value.get("files")
    if not isinstance(files, list) or len(files) != len(SOURCE_PATHS):
        return failures + ["REPORT:SOURCE_FILES"]
    paths: list[str] = []
    for entry in files:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"path", "digest"}
            or not isinstance(entry.get("path"), str)
            or not _valid_typed_digest(entry.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN)
        ):
            failures.append("REPORT:SOURCE_DIGEST")
            continue
        paths.append(entry["path"])
    if tuple(paths) != SOURCE_PATHS:
        failures.append("REPORT:SOURCE_PATHS")
    return failures


def _validate_sdk_identity(value: object) -> list[str]:
    failures: list[str] = []
    if not isinstance(value, dict) or set(value) != {
        "channel", "version", "archive_name", "archive", "matched_archive_files",
        "platform", "cjc", "cjpm",
    }:
        return ["REPORT:SDK_IDENTITY"]
    if (
        value.get("channel") != PINNED_SDK_CHANNEL
        or value.get("version") != PINNED_SDK_VERSION
        or value.get("archive_name") != PINNED_SDK_ARCHIVE_NAME
        or not _valid_typed_digest(value.get("archive"), evidence_digest.ARTIFACT_BYTE_DOMAIN)
        or not evidence_digest.schema_artifact_sha256_equal(
            value["archive"].get("sha256"), PINNED_SDK_ARCHIVE_SHA256
        )
        or type(value.get("matched_archive_files")) is not int
        or value.get("matched_archive_files", 0) <= 0
    ):
        failures.append("REPORT:SDK_PIN")
    sdk_platform = value.get("platform")
    if (
        not isinstance(sdk_platform, dict)
        or set(sdk_platform) != {"system", "machine", "native_target"}
        or sdk_platform.get("system") != "Darwin"
        or str(sdk_platform.get("machine", "")).lower() not in {"arm64", "aarch64"}
        or sdk_platform.get("native_target") != PINNED_SDK_TARGET
    ):
        failures.append("REPORT:SDK_PLATFORM")
    cjc = value.get("cjc")
    if (
        not isinstance(cjc, dict)
        or set(cjc) != {"relative_path", "version", "version_output", "target"}
        or not _valid_relative_path(cjc.get("relative_path"))
        or not str(cjc.get("relative_path", "")).endswith("/cjc")
        or cjc.get("version") != PINNED_SDK_VERSION
        or cjc.get("target") != PINNED_SDK_TARGET
        or not isinstance(cjc.get("version_output"), str)
        or PINNED_SDK_VERSION not in cjc.get("version_output", "")
        or re.search(r"(?i)(?:nightly|alpha|beta|dev|snapshot)", cjc.get("version_output", ""))
        or f"Target: {PINNED_SDK_TARGET}" not in cjc.get("version_output", "")
    ):
        failures.append("REPORT:SDK_CJC")
    cjpm = value.get("cjpm")
    if (
        not isinstance(cjpm, dict)
        or set(cjpm) != {"relative_path", "version", "version_output"}
        or not _valid_relative_path(cjpm.get("relative_path"))
        or not cjpm.get("relative_path", "").endswith("/cjpm")
        or cjpm.get("version") != PINNED_SDK_VERSION
        or not isinstance(cjpm.get("version_output"), str)
        or PINNED_SDK_VERSION not in cjpm.get("version_output", "")
        or re.search(r"(?i)(?:nightly|alpha|beta|dev|snapshot)", cjpm.get("version_output", ""))
    ):
        failures.append("REPORT:SDK_CJPM")
    return failures


def validate_report(
    report: object, expected_revision: str, expected_mode: str
) -> list[str]:
    """Strictly validate a detached current desktop receipt without requiring a clean checkout."""
    if expected_mode not in CAPTURE_MODES:
        return ["REPORT:IOS_NOT_QUALIFIED"]
    if not isinstance(report, dict):
        return ["REPORT:TYPE"]
    failures: list[str] = []
    if set(report) != REPORT_FIELDS:
        failures.append("REPORT:FIELD_SET")
    if report.get("schema_version") != SCHEMA_VERSION:
        failures.append("REPORT:UNKNOWN_SCHEMA")
    if report.get("task_id") != TASK_ID or report.get("gate_id") != "M2-006-APPLE-SYSTEM-RESOLVER":
        failures.append("REPORT:IDENTITY")
    if report.get("revision") != expected_revision:
        failures.append("REPORT:STALE_REVISION")
    if not isinstance(expected_revision, str) or re.fullmatch(r"[0-9a-f]{40}", expected_revision) is None:
        failures.append("REPORT:REVISION_FORMAT")
    if report.get("mode") != expected_mode:
        failures.append("REPORT:MODE")
    if not isinstance(report.get("generated_at_utc"), str):
        failures.append("REPORT:TIMESTAMP")
    else:
        try:
            dt.datetime.fromisoformat(report["generated_at_utc"].replace("Z", "+00:00"))
        except ValueError:
            failures.append("REPORT:TIMESTAMP")
    if report.get("decision") != "PASS" or report.get("failures") != []:
        failures.append("REPORT:DECISION")
    if report.get("scope") != "native macOS arm64":
        failures.append("REPORT:SCOPE")

    platform_data = report.get("platform")
    if (
        not isinstance(platform_data, dict)
        or set(platform_data) != {
            "system", "release", "machine", "runner_image", "runner_image_version", "toolchain"
        }
        or platform_data.get("system") != "Darwin"
        or str(platform_data.get("machine", "")).lower() not in {"arm64", "aarch64"}
    ):
        failures.append("REPORT:NON_NATIVE_APPLE")
    else:
        toolchain = platform_data.get("toolchain")
        if (
            not _successful_process(toolchain)
            or "Target: " + PINNED_SDK_TARGET not in toolchain.get("output", "")
            or "1.2.0" not in toolchain.get("output", "")
        ):
            failures.append("REPORT:TOOLCHAIN_TARGET")
    failures.extend(_validate_source_inventory(report.get("source_inventory"), expected_revision))
    failures.extend(_validate_sdk_identity(report.get("sdk")))

    test_process = report.get("resolver_test")
    if not _valid_process_receipt(test_process):
        failures.append("REPORT:TEST_MISSING")
    else:
        failures.extend(process_failures(test_process, EXPECTED_CASES["macos"], "RESOLVER_TEST"))

    build = report.get("build")
    build_command = build.get("command") if isinstance(build, dict) else None
    if (
        not _successful_process(build)
        or not isinstance(build_command, list)
        or not any(
            isinstance(item, str) and item.endswith("tools/build_resolver.py")
            for item in build_command
        )
        or "--platform" not in build_command
        or "macos-arm64" not in build_command
        or "--test-fixture" not in build_command
    ):
        failures.append("REPORT:BUILD")

    test_command = test_process.get("command") if isinstance(test_process, dict) else None
    if (
        not isinstance(test_command, list)
        or not test_command
        or not isinstance(test_command[0], str)
        or not test_command[0].endswith("/cjpm")
        or test_command[1:] != [
            "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
            "--filter", "M2006AppleSystemResolverTest", "--show-all-output",
            "--no-color", "--no-progress",
        ]
    ):
        failures.append("REPORT:TEST_COMMAND")

    toolchain_process = (
        platform_data.get("toolchain") if isinstance(platform_data, dict) else None
    )
    toolchain_command = (
        toolchain_process.get("command") if isinstance(toolchain_process, dict) else None
    )
    if (
        not isinstance(toolchain_command, list)
        or len(toolchain_command) != 2
        or not isinstance(toolchain_command[0], str)
        or not toolchain_command[0].endswith("/cjc")
        or toolchain_command[1] != "-v"
    ):
        failures.append("REPORT:TOOLCHAIN_COMMAND")

    manifest = report.get("resolver_manifest")
    if not isinstance(manifest, dict):
        failures.append("REPORT:MANIFEST_MISSING")
    else:
        if (
            manifest.get("schema_version") != 1
            or manifest.get("platform") != "macos-arm64"
            or manifest.get("private_runtime_abi") is not False
            or manifest.get("test_fixture") is not True
            or manifest.get("build_smoke") != "PASS"
        ):
            failures.append("REPORT:MANIFEST")
        archive = manifest.get("archive")
        if (
            not isinstance(archive, dict)
            or archive.get("path") != "lib/libwirestack_resolver.a"
            or not _valid_typed_digest(
                archive.get("digest"), evidence_digest.ARTIFACT_BYTE_DOMAIN
            )
        ):
            failures.append("REPORT:MANIFEST_ARCHIVE")
        inputs = manifest.get("inputs")
        expected_source_paths = {
            "native/resolver/apple/wirestack_resolver.c",
            "native/resolver/apple/wirestack_resolver.h",
            "native/resolver/linux/wirestack_resolver.c",
            "native/resolver/linux/wirestack_resolver.h",
        }
        source_inputs = inputs.get("sources") if isinstance(inputs, dict) else None
        if (
            not isinstance(inputs, dict)
            or inputs.get("platform") != "macos-arm64"
            or inputs.get("test_fixture") is not True
            or not isinstance(inputs.get("flags"), list)
            or "-mmacosx-version-min=12.0" not in inputs.get("flags", [])
            or not isinstance(source_inputs, dict)
            or set(source_inputs) != expected_source_paths
            or any(
                not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                for digest in source_inputs.values()
            )
        ):
            failures.append("REPORT:MANIFEST_INPUTS")
        source_inventory = report.get("source_inventory")
        inventory_files = (
            source_inventory.get("files", [])
            if isinstance(source_inventory, dict) else []
        )
        inventory_digests = {
            entry.get("path"): entry.get("digest", {}).get("sha256")
            for entry in inventory_files
            if isinstance(entry, dict) and isinstance(entry.get("digest"), dict)
        } if isinstance(inventory_files, list) else {}
        if isinstance(source_inputs, dict) and any(
            source_inputs.get(path) != inventory_digests.get(path)
            for path in expected_source_paths
        ):
            failures.append("REPORT:MANIFEST_SOURCE_BINDING")
    if not _valid_typed_digest(
        report.get("resolver_manifest_digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN
    ) or report.get("resolver_manifest_digest") != _json_text_digest(manifest):
        failures.append("REPORT:MANIFEST_DIGEST")

    link_stub = report.get("test_link_stub")
    if (
        not isinstance(link_stub, dict)
        or set(link_stub) != {
            "archive_digest", "compile", "archive", "source_digest", "test_only", "target"
        }
        or link_stub.get("test_only") is not True
        or link_stub.get("target") != "macos-arm64"
        or not _valid_typed_digest(
            link_stub.get("archive_digest"), evidence_digest.ARTIFACT_BYTE_DOMAIN
        )
        or not _valid_typed_digest(
            link_stub.get("source_digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN
        )
        or not _successful_process(link_stub.get("compile"))
        or not _successful_process(link_stub.get("archive"))
    ):
        failures.append("REPORT:TEST_LINK_STUB")
    source_inventory_files = (
        report.get("source_inventory", {}).get("files", [])
        if isinstance(report.get("source_inventory"), dict) else []
    )
    source_inventory_digests = {
        entry.get("path"): entry.get("digest")
        for entry in source_inventory_files
        if isinstance(entry, dict)
    } if isinstance(source_inventory_files, list) else {}
    if (
        isinstance(link_stub, dict)
        and link_stub.get("source_digest")
        != source_inventory_digests.get("tools/gates/native/m2_006_tls_link_stub.c")
    ):
        failures.append("REPORT:TEST_LINK_STUB_SOURCE")

    logs = report.get("logs")
    expected_logs = [
        {"id": log_id, "path": f"logs/{log_id}.log"}
        for log_id in LOG_IDS
    ]
    if (
        not isinstance(logs, list)
        or len(logs) != len(LOG_IDS)
        or [
            {"id": entry.get("id"), "path": entry.get("path")}
            for entry in logs if isinstance(entry, dict)
        ] != expected_logs
        or any(
            not isinstance(entry, dict)
            or set(entry) != {"id", "path", "digest"}
            or not _valid_typed_digest(
                entry.get("digest"), evidence_digest.TEXT_EVIDENCE_DOMAIN
            )
            for entry in logs
        )
    ):
        failures.append("REPORT:LOG_INVENTORY")
    return failures


def validate_current_desktop_artifacts(
    report_path: Path,
    validation_path: Path,
    expected_revision: str,
    expected_mode: str = "macos",
) -> list[str]:
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        validation = json.loads(validation_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return ["ARTIFACTS:READ"]
    failures = validate_report(report, expected_revision, expected_mode)
    if isinstance(report, dict):
        failures.extend(_validate_report_logs(report_path, report))
    if not isinstance(validation, dict) or set(validation) != VALIDATION_FIELDS:
        return sorted(set(failures + ["VALIDATION:FIELD_SET"]))
    expected_digest = evidence_digest.text_evidence_digest(report_path).to_json()
    if (
        validation.get("schema_version") != SCHEMA_VERSION
        or validation.get("task_id") != TASK_ID
        or validation.get("expected_revision") != expected_revision
        or validation.get("expected_mode") != expected_mode
        or validation.get("report_digest") != expected_digest
    ):
        failures.append("VALIDATION:BINDING")
    validation_failures = validation.get("failures")
    if (
        not isinstance(validation_failures, list)
        or not all(isinstance(item, str) for item in validation_failures)
        or validation.get("status") != ("PASS" if validation_failures == [] else "FAIL")
    ):
        failures.append("VALIDATION:STATUS")
    elif validation_failures or validation.get("status") != "PASS":
        failures.append("VALIDATION:NOT_PASS")
    return sorted(set(failures))


def _capture_source_inventory(
    root: Path, revision: str, *, generated_report: Path | None = None
) -> dict[str, Any]:
    head = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    status_command = [
        "git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"
    ]
    if generated_report is not None:
        generated_files = (
            generated_report,
            generated_report.parent / "validation.json",
            *(generated_report.parent / "logs" / f"{log_id}.log" for log_id in LOG_IDS),
        )
        status_command.extend(["--", "."])
        for generated_file in generated_files:
            try:
                relative = generated_file.resolve().relative_to(root.resolve()).as_posix()
            except ValueError:
                continue
            if relative in SOURCE_PATHS:
                raise GateError("qualification output overlaps a bound source input")
            status_command.append(f":(exclude,literal){relative}")
    status = subprocess.run(
        status_command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if head.returncode != 0 or head.stdout.strip() != revision:
        raise GateError("source checkout HEAD does not match the requested revision")
    if status.returncode != 0 or status.stdout:
        raise GateError("source checkout must be clean before native qualification")
    files: list[dict[str, Any]] = []
    for relative in SOURCE_PATHS:
        path = root / relative
        if not path.is_file():
            raise GateError(f"current source inventory file is missing: {relative}")
        files.append({
            "path": relative,
            "digest": evidence_digest.text_evidence_digest(path).to_json(),
        })
    return {"revision": revision, "clean_worktree": True, "files": files}


def _load_sdk_pin(root: Path) -> dict[str, Any]:
    try:
        pin = json.loads((root / SDK_PIN_PATH).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("the pinned M2-006 STS SDK document is unavailable or invalid") from error
    archive = pin.get("archive") if isinstance(pin, dict) else None
    platform_pin = pin.get("platform") if isinstance(pin, dict) else None
    if (
        not isinstance(pin, dict)
        or set(pin) != {"schema_version", "channel", "version", "platform", "archive", "sources"}
        or pin.get("schema_version") != 1
        or pin.get("channel") != PINNED_SDK_CHANNEL
        or pin.get("version") != PINNED_SDK_VERSION
        or not isinstance(archive, dict)
        or set(archive) != {"archive_prefix", "name", "sha256", "size_bytes", "url"}
        or archive.get("archive_prefix") != "cangjie"
        or archive.get("name") != PINNED_SDK_ARCHIVE_NAME
        or not evidence_digest.schema_artifact_sha256_equal(
            archive.get("sha256"), PINNED_SDK_ARCHIVE_SHA256
        )
        or type(archive.get("size_bytes")) is not int
        or archive.get("size_bytes") != PINNED_SDK_ARCHIVE_SIZE_BYTES
        or archive.get("url") != PINNED_SDK_URL
        or not isinstance(platform_pin, dict)
        or set(platform_pin) != {"system", "machines", "native_target"}
        or platform_pin.get("system") != "Darwin"
        or platform_pin.get("machines") != ["arm64", "aarch64"]
        or platform_pin.get("native_target") != PINNED_SDK_TARGET
        or not isinstance(pin.get("sources"), dict)
        or set(pin["sources"]) != {"download_page", "install_guide", "release_notes"}
    ):
        raise GateError("M2-006 STS SDK pin does not match the approved macOS identity")
    return pin


def _normalize_resolver_manifest(
    manifest: dict[str, Any], workspace: Path, redactions: Mapping[str, str]
) -> dict[str, Any]:
    normalized = json.loads(json.dumps(manifest))
    inputs = normalized.get("inputs")
    sources = inputs.get("sources") if isinstance(inputs, dict) else None
    if not isinstance(sources, dict):
        raise GateError("resolver manifest has no source inventory")
    relative_sources: dict[str, Any] = {}
    for source, digest in sources.items():
        try:
            relative = Path(source).resolve().relative_to(workspace.resolve()).as_posix()
        except (OSError, ValueError) as error:
            raise GateError("resolver manifest source path escapes the test workspace") from error
        if relative in relative_sources:
            raise GateError("resolver manifest contains duplicate source paths")
        relative_sources[relative] = digest
    inputs["sources"] = relative_sources
    archive_info = normalized.get("archive")
    native_archive = (
        workspace / "target/native/resolver/macos-arm64/current/lib/libwirestack_resolver.a"
    )
    if (
        not isinstance(archive_info, dict)
        or archive_info.get("path") != "lib/libwirestack_resolver.a"
        or not native_archive.is_file()
    ):
        raise GateError("resolver manifest does not bind the current native archive")
    actual_archive_digest = evidence_digest.artifact_byte_digest(native_archive).to_json()
    if not evidence_digest.schema_artifact_sha256_equal(
        archive_info.get("sha256"), actual_archive_digest.get("sha256")
    ):
        raise GateError("resolver manifest archive digest does not match the native archive")
    normalized["archive"] = {
        "path": "lib/libwirestack_resolver.a",
        "digest": actual_archive_digest,
    }
    return _sanitize_payload(normalized, redactions)


def _log_receipts(report: Mapping[str, Any]) -> dict[str, object]:
    stub = report.get("test_link_stub")
    stub = stub if isinstance(stub, dict) else {}
    platform_data = report.get("platform")
    platform_data = platform_data if isinstance(platform_data, dict) else {}
    return {
        "resolver-build": report.get("build"),
        "test-link-stub-compile": stub.get("compile"),
        "test-link-stub-archive": stub.get("archive"),
        "resolver-test": report.get("resolver_test"),
        "toolchain-version": platform_data.get("toolchain"),
    }


def _validate_report_logs(report_path: Path, report: Mapping[str, Any]) -> list[str]:
    failures: list[str] = []
    logs = report.get("logs")
    if not isinstance(logs, list):
        return ["LOG:INVENTORY"]
    receipts = _log_receipts(report)
    seen: list[str] = []
    for entry in logs:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("id"), str)
            or not isinstance(entry.get("path"), str)
        ):
            failures.append("LOG:ENTRY")
            continue
        log_id = entry["id"]
        seen.append(log_id)
        if log_id not in receipts or entry["path"] != f"logs/{log_id}.log":
            failures.append("LOG:INVENTORY")
            continue
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or entry["path"].startswith(("\\", "/")):
            failures.append("LOG:PATH")
            continue
        path = report_path.parent / relative
        if path.is_symlink() or not path.is_file():
            failures.append("LOG:MISSING")
            continue
        try:
            raw = path.read_bytes()
            digest = evidence_digest.text_evidence_digest_bytes(raw).to_json()
            logged_output = evidence_digest.canonical_text_bytes(raw).decode("utf-8")
        except (OSError, evidence_digest.DigestError):
            failures.append("LOG:DIGEST")
            continue
        if digest != entry.get("digest"):
            failures.append("LOG:DIGEST")
        receipt = receipts[log_id]
        if not isinstance(receipt, dict) or not isinstance(receipt.get("output"), str):
            failures.append("LOG:RECEIPT")
            continue
        receipt_output = _normalized_text_bytes(receipt["output"]).decode("utf-8")
        if (
            (receipt_output and not logged_output.endswith(receipt_output))
            or (not receipt_output and logged_output)
        ):
            failures.append("LOG:PROCESS_MISMATCH")
        diagnostics = _diagnostics_for_output(logged_output)
        if receipt.get("diagnostics") != diagnostics:
            failures.append("LOG:DIAGNOSTICS")
        if log_id == "resolver-test":
            logged_process = dict(receipt)
            logged_process["output"] = logged_output
            logged_process["diagnostics"] = diagnostics
            failures.extend(
                process_failures(
                    logged_process, EXPECTED_CASES["macos"], "RESOLVER_TEST"
                )
            )
        elif log_id == "toolchain-version":
            sdk = report.get("sdk")
            cjc = sdk.get("cjc") if isinstance(sdk, dict) else None
            if (
                not isinstance(cjc, dict)
                or cjc.get("version_output") != logged_output.strip()
            ):
                failures.append("LOG:SDK_CJC_OUTPUT")
    if seen != list(LOG_IDS):
        failures.append("LOG:INVENTORY")
    return failures


def validate_current_desktop_capture(
    root: Path,
    report_path: Path,
    expected_revision: str,
    expected_mode: str = "macos",
    *,
    sdk_root: Path | None = None,
    archive: Path | None = None,
) -> list[str]:
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ["REPORT:READ"]
    failures = validate_report(report, expected_revision, expected_mode)
    if not isinstance(report, dict):
        return failures
    failures.extend(_validate_report_logs(report_path, report))
    try:
        current_inventory = _capture_source_inventory(
            root.resolve(), expected_revision, generated_report=report_path
        )
    except (GateError, OSError):
        failures.append("SOURCE:CHECKOUT")
    else:
        if report.get("source_inventory") != current_inventory:
            failures.append("SOURCE:DRIFT")
    if sdk_root is None or archive is None:
        failures.append("SDK:INSTALL_NOT_BOUND")
    else:
        try:
            actual_sdk = sts_sdk_identity.capture_sdk_identity(
                sdk_root, archive, _load_sdk_pin(root)
            )
        except (GateError, sts_sdk_identity.SDKIdentityError):
            failures.append("SDK:IDENTITY")
        else:
            if report.get("sdk") != actual_sdk:
                failures.append("SDK:DRIFT")
    return failures


def validate_current_desktop_proof(
    root: Path,
    report_path: Path,
    validation_path: Path,
    expected_revision: str,
    *,
    sdk_root: Path | None = None,
    archive: Path | None = None,
) -> list[str]:
    failures = validate_current_desktop_capture(
        root,
        report_path,
        expected_revision,
        sdk_root=sdk_root,
        archive=archive,
    )
    failures.extend(
        validate_current_desktop_artifacts(
            report_path, validation_path, expected_revision, "macos"
        )
    )
    return sorted(set(failures))


def validate_current_desktop_task_artifacts(
    root: Path, report_path: Path, validation_path: Path
) -> list[str]:
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ["REPORT:READ"]
    if not isinstance(report, dict) or not isinstance(report.get("revision"), str):
        return ["REPORT:REVISION"]
    expected_revision = report["revision"]
    failures = validate_current_desktop_artifacts(
        report_path, validation_path, expected_revision, "macos"
    )
    source_inventory = report.get("source_inventory")
    files = source_inventory.get("files") if isinstance(source_inventory, dict) else None
    if not isinstance(files, list):
        return sorted(set(failures + ["SOURCE:INVENTORY"]))
    for entry in files:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            failures.append("SOURCE:ENTRY")
            continue
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or entry["path"].startswith(("\\", "/")):
            failures.append("SOURCE:PATH")
            continue
        path = root / relative
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(root.resolve(strict=True))
            digest = evidence_digest.text_evidence_digest(resolved).to_json()
        except (OSError, ValueError, evidence_digest.DigestError):
            failures.append("SOURCE:MISSING")
            continue
        if digest != entry.get("digest"):
            failures.append("SOURCE:DRIFT")
    try:
        _load_sdk_pin(root)
    except GateError:
        failures.append("SDK:PIN")
    return sorted(set(failures))


def run_gate(root: Path, output: Path, revision: str, mode: str) -> dict[str, Any]:
    root = root.resolve(strict=True)
    if platform.system() != "Darwin" or platform.machine().lower() not in {"arm64", "aarch64"}:
        raise GateError("M2-006 desktop qualification requires a native arm64 macOS host")
    if mode not in CAPTURE_MODES:
        raise GateError("iOS qualification is separate and remains unverified")
    source_inventory = _capture_source_inventory(root, revision)
    pin = _load_sdk_pin(root)
    sdk_root_value = os.environ.get("CANGJIE_HOME")
    archive_value = os.environ.get("CANGJIE_SDK_ARCHIVE")
    if not sdk_root_value or not archive_value:
        raise GateError("CANGJIE_HOME and CANGJIE_SDK_ARCHIVE are required for pinned STS capture")
    sdk_root = Path(sdk_root_value).resolve()
    archive = Path(archive_value).resolve()
    try:
        sdk = sts_sdk_identity.capture_sdk_identity(sdk_root, archive, pin)
    except sts_sdk_identity.SDKIdentityError as error:
        raise GateError(f"pinned STS SDK identity failed: {error}") from error
    env = dict(os.environ)
    env["CANGJIE_HOME"] = str(sdk_root)
    env["PATH"] = os.pathsep.join(
        [str(sdk_root / "bin"), str(sdk_root / "tools" / "bin"), env.get("PATH", "")]
    )
    env["WIRESTACK_RESOLVER_TEST_FIXTURE"] = "1"
    env["WIRESTACK_RESOLVER_PLATFORM"] = MODES[mode]

    output.parent.mkdir(parents=True, exist_ok=True)
    log_directory = output.parent / "logs"
    log_directory.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="wirestack-m2-006-") as temporary:
        workspace_path = Path(temporary) / "repo"
        prepare_test_workspace(root, workspace_path, MODES[mode])
        workspace = workspace_path.resolve(strict=True)
        redactions: dict[str, str] = {}
        for path, replacement in (
            (root, "<checkout>"),
            (workspace_path, "<repo>"),
            (sdk_root, "$CANGJIE_HOME"),
            (archive, "$CANGJIE_SDK_ARCHIVE"),
        ):
            redactions.update(_path_redactions(path, replacement))
        build = run_command(
            [
                "python3", str(workspace / "tools/build_resolver.py"), "--root", str(workspace),
                "--platform", MODES[mode], "--test-fixture", "--quiet",
            ],
            cwd=workspace,
            env=env,
            timeout=120,
            log_path=log_directory / "resolver-build.log",
            redactions=redactions,
        )
        require_success(build, "macOS resolver build")
        test_link_stub = build_test_link_stub(
            workspace,
            env,
            MODES[mode],
            log_directory=log_directory,
            redactions=redactions,
        )
        manifest_path = (
            workspace / "target" / "native" / "resolver" / MODES[mode]
            / "current" / "resolver-manifest.json"
        )
        try:
            raw_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise GateError("resolver manifest is unavailable or invalid") from error
        manifest = _normalize_resolver_manifest(raw_manifest, workspace, redactions)

        cjpm_path = sdk_root / sdk["cjpm"]["relative_path"]
        resolver_test = run_command(
            [
                str(cjpm_path), "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
                "--filter", "M2006AppleSystemResolverTest", "--show-all-output",
                "--no-color", "--no-progress",
            ],
            cwd=workspace,
            env=env,
            timeout=240,
            log_path=log_directory / "resolver-test.log",
            redactions=redactions,
        )
        toolchain = run_command(
            [str(sdk_root / sdk["cjc"]["relative_path"]), "-v"],
            cwd=workspace,
            env=env,
            timeout=15,
            log_path=log_directory / "toolchain-version.log",
            redactions=redactions,
        )
    if _capture_source_inventory(
        root, revision, generated_report=output
    ) != source_inventory:
        raise GateError("native source changed during qualification capture")

    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_id": TASK_ID,
        "gate_id": "M2-006-APPLE-SYSTEM-RESOLVER",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "revision": revision,
        "mode": mode,
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "runner_image": os.environ.get("ImageOS", "unknown"),
            "runner_image_version": os.environ.get("ImageVersion", "unknown"),
            "toolchain": toolchain,
        },
        "source_inventory": source_inventory,
        "sdk": sdk,
        "resolver_manifest": manifest,
        "resolver_manifest_digest": _json_text_digest(manifest),
        "build": build,
        "test_link_stub": test_link_stub,
        "resolver_test": resolver_test,
        "logs": [
            _log_record(log_directory, output.parent, log_id)
            for log_id in LOG_IDS
        ],
        "failures": [],
        "decision": "PASS",
        "scope": "native macOS arm64",
    }
    failures.extend(_validate_report_logs(output, report))
    failures.extend(validate_report(report, revision, mode))
    report["failures"] = sorted(set(failures))
    report["decision"] = "PASS" if not report["failures"] else "FAIL"
    atomic_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--mode", choices=sorted(CAPTURE_MODES))
    parser.add_argument("--validate-report", type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--expected-mode", choices=sorted(CAPTURE_MODES))
    parser.add_argument("--validation-output", type=Path)
    parser.add_argument("--verify-current-desktop", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--validation", type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    if args.verify_current_desktop:
        if args.report is None or args.validation is None:
            print("M2-006: --report and --validation are required")
            return 2
        failures = validate_current_desktop_task_artifacts(
            root, args.report.resolve(), args.validation.resolve()
        )
        result = {
            "task_id": TASK_ID,
            "status": "PASS" if not failures else "FAIL",
            "failures": failures,
        }
        print(json.dumps(result, sort_keys=True))
        return 0 if not failures else 1
    if args.validate_report is not None:
        if not args.expected_revision or not args.expected_mode:
            print("M2-006: --expected-revision and --expected-mode are required")
            return 2
        sdk_root = Path(os.environ["CANGJIE_HOME"]) if os.environ.get("CANGJIE_HOME") else None
        archive = (
            Path(os.environ["CANGJIE_SDK_ARCHIVE"])
            if os.environ.get("CANGJIE_SDK_ARCHIVE") else None
        )
        report_path = args.validate_report.resolve()
        failures = validate_current_desktop_capture(
            root,
            report_path,
            args.expected_revision,
            args.expected_mode,
            sdk_root=sdk_root,
            archive=archive,
        )
        validation = validation_payload(
            report_path,
            args.expected_revision,
            args.expected_mode,
            sorted(set(failures)),
        )
        if args.validation_output:
            atomic_json(args.validation_output.resolve(), validation)
            failures.extend(
                validate_current_desktop_artifacts(
                    report_path,
                    args.validation_output.resolve(),
                    args.expected_revision,
                    args.expected_mode,
                )
            )
        print(json.dumps(validation, sort_keys=True))
        return 0 if not failures else 1
    if args.output is None or not args.revision or not args.mode:
        print("M2-006: --output, --revision and --mode are required")
        return 2
    output = args.output.resolve()
    try:
        report = run_gate(root, output, args.revision, args.mode)
    except GateError as error:
        sanitized_error = _sanitize_text(str(error), {})
        atomic_json(output, {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "revision": args.revision,
            "mode": args.mode,
            "decision": "FAIL",
            "failures": ["GATE:ERROR"],
            "error": sanitized_error[-12000:],
        })
        print(f"M2-006-APPLE-SYSTEM-RESOLVER: ERROR: {sanitized_error}")
        return 2
    print(json.dumps({
        "decision": report["decision"],
        "failures": report["failures"],
        "report": "<report>",
    }, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1

if __name__ == "__main__":
    raise SystemExit(main())
