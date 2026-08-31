#!/usr/bin/env python3
"""Run and validate M2-006 on native macOS or an iOS Simulator."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
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
SCHEMA_VERSION = 1
EXPECTED_TESTS = 8
MODES = {"macos": "macos-arm64", "ios-simulator": "ios-simulator-arm64"}
IOS_TARGET = "arm64-apple-ios11-simulator"


class GateError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def validation_payload(
    report_path: Path,
    expected_revision: str,
    expected_mode: str,
    failures: list[str],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "task_id": TASK_ID,
        "expected_revision": expected_revision,
        "expected_mode": expected_mode,
        "report_sha256": sha256_path(report_path),
        "failures": failures,
        "status": "PASS" if not failures else "FAIL",
    }


def run_command(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int,
    output_limit: int = 20000,
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
    return {
        "command": command,
        "duration_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        "exit_code": exit_code,
        "diagnostics": "\n".join(diagnostic_lines[-200:])[-30000:],
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


def process_failures(process: dict[str, Any], expected: int, label: str) -> list[str]:
    failures: list[str] = []
    if process.get("timed_out"):
        failures.append(f"{label}:TIMEOUT")
    if process.get("exit_code") != 0:
        failures.append(f"{label}:EXIT")
    output = process.get("output", "")
    if output.count("[ PASSED ] CASE:") != expected:
        failures.append(f"{label}:CASE_COUNT")
    if "[ SKIPPED ] CASE:" in output or "[ FAILED ] CASE:" in output:
        failures.append(f"{label}:NON_PASS_CASE")
    if re.search(r"(?:FAILED|ERROR): [1-9]", output):
        failures.append(f"{label}:SUMMARY_FAILURE")
    return failures


def xcrun(root: Path, env: dict[str, str], sdk: str, *arguments: str) -> str:
    process = run_command(
        ["xcrun", "--sdk", sdk, *arguments], cwd=root, env=env, timeout=30
    )
    require_success(process, f"xcrun {sdk} {' '.join(arguments)}")
    return process["output"].strip()


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
    marker = '  wirestack_resolver = { path = "./target/native/resolver/current/lib" }'
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
        "-L ./target/native/resolver/current/lib -lwirestack_resolver "
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
    root: Path, env: dict[str, str], selected: str
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
    )
    require_success(compiled, "M2-006 TLS link stub compilation")
    archived = run_command([ar, "rcs", str(archive), str(object_path)], cwd=root, env=env, timeout=60)
    require_success(archived, "M2-006 TLS link stub archive")
    return {
        "archive_sha256": sha256_path(archive),
        "compile": compiled,
        "archive": archived,
        "source_sha256": sha256_path(source),
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
        "bundle_probe_sha256": sha256_path(executable_copy),
        "install": installed,
        "runtime_libraries": [
            {
                "path": f"Frameworks/{runtime_copy.name}",
                "sha256": sha256_path(runtime_copy),
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
        "probe_sha256": sha256_path(probe),
        "launch_attempts": launch_attempts,
        "launch_recovery": launch_recovery,
        **installed_metadata,
    }


def validate_report(report: object, expected_revision: str, expected_mode: str) -> list[str]:
    failures: list[str] = []
    if not isinstance(report, dict):
        return ["REPORT:TYPE"]
    if report.get("schema_version") != SCHEMA_VERSION:
        failures.append("REPORT:UNKNOWN_SCHEMA")
    if report.get("task_id") != TASK_ID:
        failures.append("REPORT:TASK")
    if report.get("revision") != expected_revision:
        failures.append("REPORT:STALE_REVISION")
    if report.get("mode") != expected_mode:
        failures.append("REPORT:MODE")
    platform_data = report.get("platform")
    if (
        not isinstance(platform_data, dict)
        or platform_data.get("system") != "Darwin"
        or str(platform_data.get("machine", "")).lower() not in {"arm64", "aarch64"}
    ):
        failures.append("REPORT:NON_NATIVE_APPLE")
    elif "Target: aarch64-apple-darwin" not in str(
        platform_data.get("toolchain", {}).get("output", "")
        if isinstance(platform_data.get("toolchain"), dict) else ""
    ):
        failures.append("REPORT:TOOLCHAIN_TARGET")
    if report.get("decision") != "PASS" or report.get("failures") != []:
        failures.append("REPORT:DECISION")
    test_process = report.get("resolver_test")
    if not isinstance(test_process, dict):
        failures.append("REPORT:TEST_MISSING")
    else:
        failures.extend(process_failures(test_process, EXPECTED_TESTS, "RESOLVER_TEST"))
    manifest = report.get("resolver_manifest")
    if not isinstance(manifest, dict):
        failures.append("REPORT:MANIFEST_MISSING")
    else:
        if manifest.get("platform") != MODES.get(expected_mode):
            failures.append("REPORT:MANIFEST_PLATFORM")
        if manifest.get("private_runtime_abi") is not False:
            failures.append("REPORT:PRIVATE_RUNTIME_ABI")
        if manifest.get("test_fixture") is not True:
            failures.append("REPORT:FIXTURE_NOT_BOUND")
        inputs = manifest.get("inputs")
        flags = inputs.get("flags") if isinstance(inputs, dict) else None
        if not isinstance(flags, list) or any(
            flag not in flags for flag in deployment_flags(MODES[expected_mode])
        ):
            failures.append("REPORT:DEPLOYMENT_TARGET")
    link_stub = report.get("test_link_stub")
    if not isinstance(link_stub, dict) or link_stub.get("test_only") is not True:
        failures.append("REPORT:TEST_LINK_STUB")
    if expected_mode == "ios-simulator":
        simulator = report.get("simulator")
        if not isinstance(simulator, dict):
            failures.append("REPORT:SIMULATOR_MISSING")
        else:
            if not isinstance(simulator.get("device_udid"), str) or not simulator["device_udid"]:
                failures.append("REPORT:SIMULATOR_DEVICE")
            if not isinstance(simulator.get("runtime"), str) or ".iOS-" not in simulator["runtime"]:
                failures.append("REPORT:SIMULATOR_RUNTIME")
            probe_sha = simulator.get("probe_sha256")
            bundle_probe_sha = simulator.get("bundle_probe_sha256")
            install = simulator.get("install")
            runtime_libraries = simulator.get("runtime_libraries")
            probe_compile = simulator.get("probe_compile")
            launch_attempts = simulator.get("launch_attempts")
            runtime_names = {
                entry.get("path")
                for entry in runtime_libraries
                if isinstance(entry, dict)
            } if isinstance(runtime_libraries, list) else set()
            if (
                not isinstance(probe_sha, str)
                or not re.fullmatch(r"[0-9a-f]{64}", probe_sha)
                or not isinstance(bundle_probe_sha, str)
                or not re.fullmatch(r"[0-9a-f]{64}", bundle_probe_sha)
                or not isinstance(install, dict)
                or install.get("timed_out") is not False
                or install.get("exit_code") != 0
                or "Frameworks/libcangjie-runtime.dylib" not in runtime_names
                or not isinstance(probe_compile, dict)
                or not command_has_target(probe_compile.get("command"), IOS_TARGET)
                or not isinstance(launch_attempts, list)
                or len(launch_attempts) not in {1, 2}
                or not all(isinstance(attempt, dict) for attempt in launch_attempts)
                or launch_attempts[-1].get("timed_out") is not False
                or launch_attempts[-1].get("exit_code") != 0
            ):
                failures.append("REPORT:SIMULATOR_PROBE")
    return failures


def run_gate(root: Path, output: Path, revision: str, mode: str) -> dict[str, Any]:
    if platform.system() != "Darwin" or platform.machine() not in {"arm64", "aarch64"}:
        raise GateError("M2-006 acceptance requires a native arm64 macOS host")
    if mode not in MODES:
        raise GateError(f"unsupported gate mode: {mode}")
    if shutil.which("cjpm") is None or shutil.which("cjc") is None:
        raise GateError("cjc and cjpm are required")
    env = dict(os.environ)
    env["WIRESTACK_RESOLVER_TEST_FIXTURE"] = "1"
    env["WIRESTACK_RESOLVER_PLATFORM"] = MODES[mode]
    if mode == "ios-simulator":
        env["WIRESTACK_IOS_SIMULATOR_SYSROOT"] = xcrun(
            root, env, "iphonesimulator", "--show-sdk-path"
        )
    with tempfile.TemporaryDirectory(prefix="wirestack-m2-006-") as temporary:
        workspace = Path(temporary) / "repo"
        prepare_test_workspace(root, workspace, MODES[mode])
        if mode == "ios-simulator":
            env["WIRESTACK_IOS_SIMULATOR_SYSROOT"] = xcrun(
                workspace, env, "iphonesimulator", "--show-sdk-path"
            )
        build = run_command(
        [
            "python3", str(workspace / "tools/build_resolver.py"), "--root", str(workspace),
            "--platform", MODES[mode], "--test-fixture", "--quiet",
        ],
        cwd=workspace,
        env=env,
        timeout=120,
        )
        require_success(build, f"{mode} resolver build")
        test_link_stub = build_test_link_stub(workspace, env, MODES[mode])
        manifest_path = workspace / "target/native/resolver/current/resolver-manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise GateError(f"resolver manifest is unavailable: {error}") from error

        simulator: dict[str, Any] | None = None
        if mode == "macos":
            resolver_test = run_command(
            [
                "cjpm", "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
                "--filter", "M2006AppleSystemResolverTest", "--show-all-output",
                "--no-color", "--no-progress",
            ],
            cwd=workspace,
            env=env,
            timeout=240,
            )
        else:
            resolver_test, simulator = run_ios_test(workspace, env)
        toolchain = run_command(["cjc", "-v"], cwd=workspace, env=env, timeout=15)
        manifest_sha256 = sha256_path(manifest_path)
    failures = process_failures(resolver_test, EXPECTED_TESTS, "RESOLVER_TEST")
    if manifest.get("platform") != MODES[mode]:
        failures.append("MANIFEST:PLATFORM")
    if manifest.get("private_runtime_abi") is not False:
        failures.append("MANIFEST:PRIVATE_RUNTIME_ABI")
    if manifest.get("test_fixture") is not True:
        failures.append("MANIFEST:FIXTURE")
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
        "resolver_manifest": manifest,
        "resolver_manifest_sha256": manifest_sha256,
        "build": build,
        "test_link_stub": test_link_stub,
        "resolver_test": resolver_test,
        "simulator": simulator,
        "failures": failures,
        "decision": "PASS" if not failures else "FAIL",
        "scope": "native macOS arm64" if mode == "macos" else "native iOS Simulator arm64",
    }
    atomic_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--mode", choices=sorted(MODES))
    parser.add_argument("--validate-report", type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--expected-mode", choices=sorted(MODES))
    parser.add_argument("--validation-output", type=Path)
    args = parser.parse_args()
    if args.validate_report is not None:
        if not args.expected_revision or not args.expected_mode:
            print("M2-006: --expected-revision and --expected-mode are required")
            return 2
        try:
            payload = json.loads(args.validate_report.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"M2-006: invalid report: {error}")
            return 2
        failures = validate_report(payload, args.expected_revision, args.expected_mode)
        validation = validation_payload(
            args.validate_report,
            args.expected_revision,
            args.expected_mode,
            failures,
        )
        if args.validation_output:
            atomic_json(args.validation_output, validation)
        print(json.dumps(validation, sort_keys=True))
        return 0 if not failures else 1
    if args.output is None or not args.revision or not args.mode:
        print("M2-006: --output, --revision and --mode are required")
        return 2
    try:
        report = run_gate(args.repo_root.resolve(), args.output.resolve(), args.revision, args.mode)
    except GateError as error:
        atomic_json(args.output.resolve(), {
            "schema_version": SCHEMA_VERSION,
            "task_id": TASK_ID,
            "revision": args.revision,
            "mode": args.mode,
            "decision": "FAIL",
            "failures": ["GATE:ERROR"],
            "error": str(error)[-12000:],
        })
        print(f"M2-006-APPLE-SYSTEM-RESOLVER: ERROR: {error}")
        return 2
    print(json.dumps({
        "decision": report["decision"],
        "failures": report["failures"],
        "report": str(args.output.resolve()),
    }, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
