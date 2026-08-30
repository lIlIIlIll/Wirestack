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
from typing import Any


TASK_ID = "M2-006"
SCHEMA_VERSION = 1
EXPECTED_TESTS = 7
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
    compiled = run_command(
        [
            cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-arch", "arm64", "-isysroot", sysroot,
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


def find_ios_test_binaries(target_dir: Path) -> tuple[Path, Path]:
    runners = [path for path in target_dir.rglob("std.testrunner") if path.is_file()]
    packages = [
        path
        for path in target_dir.rglob("wirestack.internal.resolver")
        if path.is_file() and "unittest_bin" in path.parts
    ]
    if len(runners) != 1 or len(packages) != 1:
        raise GateError(
            f"expected one iOS test runner and resolver package, got {len(runners)} and {len(packages)}"
        )
    return runners[0], packages[0]


def make_ios_bundle(
    root: Path,
    env: dict[str, str],
    runner: Path,
    package: Path,
    bundle: Path,
    device: str,
) -> tuple[Path, dict[str, Any]]:
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    runner_copy = bundle / "std.testrunner"
    package_copy = bundle / "wirestack.internal.resolver"
    shutil.copy2(runner, runner_copy)
    shutil.copy2(package, package_copy)
    runner_copy.chmod(runner_copy.stat().st_mode | stat.S_IXUSR)
    package_copy.chmod(package_copy.stat().st_mode | stat.S_IXUSR)
    with (bundle / "Info.plist").open("wb") as output:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "std.testrunner",
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
    for target in (runner_copy, package_copy):
        signed = run_command(
            ["codesign", "--force", "--sign", "-", str(target)],
            cwd=root,
            env=env,
            timeout=30,
        )
        require_success(signed, f"ad-hoc sign {target.name}")
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
    container_process = run_command(
        ["xcrun", "simctl", "get_app_container", device, "dev.wirestack.m2-006-tests", "app"],
        cwd=root,
        env=env,
        timeout=30,
    )
    require_success(container_process, "resolve installed iOS test bundle")
    container = Path(container_process["output"].strip())
    configuration = {
        "apiVersion": 2,
        "testModules": [{
            "name": "wirestack",
            "testPackages": [{
                "name": "wirestack.internal.resolver",
                "executeCommand": {
                    "command": str(container / package_copy.name),
                    "args": [
                        "--filter=M2006AppleSystemResolverTest",
                        "--no-color",
                        "--show-all-output",
                        "--parallel=1",
                        "--no-progress",
                    ],
                    "env": {"WIRESTACK_RESOLVER_TEST_FIXTURE": "1"},
                },
            }],
        }],
    }
    input_path = bundle / "test-input.json"
    input_path.write_text(json.dumps(configuration, sort_keys=True), encoding="utf-8")
    resigned = run_command(
        ["codesign", "--force", "--sign", "-", str(bundle)],
        cwd=root,
        env=env,
        timeout=30,
    )
    require_success(resigned, "re-sign iOS test bundle")
    updated = run_command(
        ["xcrun", "simctl", "install", device, str(bundle)],
        cwd=root,
        env=env,
        timeout=60,
    )
    require_success(updated, "update iOS test bundle configuration")
    return container, configuration


def run_ios_test(root: Path, env: dict[str, str]) -> tuple[dict[str, Any], dict[str, Any]]:
    target_dir = root / "target/m2-006-ios-simulator"
    compile_test = run_command(
        [
            "cjpm", "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
            "--target", IOS_TARGET, "--target-dir", str(target_dir), "--no-run",
            "--filter", "M2006AppleSystemResolverTest", "--no-color", "--no-progress",
            "-V",
        ],
        cwd=root,
        env=env,
        timeout=300,
    )
    require_success(compile_test, "iOS Simulator Cangjie test compilation")
    runner, package = find_ios_test_binaries(target_dir)
    runner_compile = run_command(
        [
            "cjc", str(runner.parent / "testrunner.cj"), "-o", str(runner),
            f"--target={IOS_TARGET}", "--sysroot", env["WIRESTACK_IOS_SIMULATOR_SYSROOT"],
        ],
        cwd=root,
        env=env,
        timeout=120,
    )
    require_success(runner_compile, "iOS Simulator unittest runner compilation")
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
        container, configuration = make_ios_bundle(root, env, runner, package, bundle, device)
        simulator_env = dict(env)
        simulator_env["SIMCTL_CHILD_WIRESTACK_RESOLVER_TEST_FIXTURE"] = "1"
        process = run_command(
            [
                "xcrun", "simctl", "spawn", device, str(container / "std.testrunner"),
                "--filter=M2006AppleSystemResolverTest", "--no-color",
                "--show-all-output", "--parallel=1", "--json-configuration={}",
                "--no-progress",
                f"--internal-testrunner-input-path={container / 'test-input.json'}",
            ],
            cwd=root,
            env=simulator_env,
            timeout=180,
        )
    finally:
        run_command(["xcrun", "simctl", "shutdown", device], cwd=root, env=env, timeout=60)
    return process, {
        "compile": compile_test,
        "runner_compile": runner_compile,
        "device_udid": device,
        "runtime": runtime,
        "runner_sha256": sha256_path(runner),
        "package_sha256": sha256_path(package),
        "configuration": configuration,
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
    if not isinstance(platform_data, dict) or platform_data.get("system") != "Darwin":
        failures.append("REPORT:NON_NATIVE_APPLE")
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
    link_stub = report.get("test_link_stub")
    if not isinstance(link_stub, dict) or link_stub.get("test_only") is not True:
        failures.append("REPORT:TEST_LINK_STUB")
    if expected_mode == "ios-simulator" and not isinstance(report.get("simulator"), dict):
        failures.append("REPORT:SIMULATOR_MISSING")
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
    build = run_command(
        [
            "python3", str(root / "tools/build_resolver.py"), "--root", str(root),
            "--platform", MODES[mode], "--test-fixture", "--quiet",
        ],
        cwd=root,
        env=env,
        timeout=120,
    )
    require_success(build, f"{mode} resolver build")
    test_link_stub = build_test_link_stub(root, env, MODES[mode])
    manifest_path = root / "target/native/resolver/current/resolver-manifest.json"
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
            cwd=root,
            env=env,
            timeout=240,
        )
    else:
        resolver_test, simulator = run_ios_test(root, env)
    toolchain = run_command(["cjc", "-v"], cwd=root, env=env, timeout=15)
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
        "resolver_manifest_sha256": sha256_path(manifest_path),
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
        validation = {
            "schema_version": 1,
            "task_id": TASK_ID,
            "expected_revision": args.expected_revision,
            "expected_mode": args.expected_mode,
            "failures": failures,
            "status": "PASS" if not failures else "FAIL",
        }
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
