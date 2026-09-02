#!/usr/bin/env python3
"""Build and execute the M0-016 provider PoC in a hosted mobile VM.

The GitHub-hosted macOS arm64 job uses an iOS Simulator or an Android arm64
emulator.  A separate Linux x86_64 job may run an Android x86_64 smoke gate;
that supplemental result is kept distinct from the required arm64 cell.  The
runner is still recorded separately from the target platform so this evidence
cannot be mistaken for a physical-device result.
"""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.tls_provider_poc import run as poc

import argparse
import datetime as dt
import hashlib
import json
import os
import platform as host_platform
import plistlib
import re
import shutil
from pathlib import Path
from typing import Any, Mapping, Sequence


MOBILE_PLATFORMS = {"android-aarch64", "android-x86_64", "ios-aarch64"}
ANDROID_API_LEVEL = 33
IOS_DEPLOYMENT_TARGET = "15.0"
IOS_BUNDLE_ID = "com.wirestack.m0-016.provider-poc"
REMOTE_ROOT_RE = re.compile(r"^/data/local/tmp/wirestack-m0-016-[0-9]+$")
IOS_UDID_RE = re.compile(r"^[0-9A-Fa-f-]{20,64}$")
ANDROID_TARGETS = {
    "android-aarch64": {
        "abi": "arm64-v8a",
        "toolchain_prefix": "aarch64-linux-android",
        "target": "aarch64-linux-android",
        "openssl_arg": "android-arm64",
    },
    "android-x86_64": {
        "abi": "x86_64",
        "toolchain_prefix": "x86_64-linux-android",
        "target": "x86_64-linux-android",
        "openssl_arg": "android-x86_64",
    },
}


class MobilePocError(poc.PocError):
    """A bounded mobile-runner failure."""


def sha256_path(path: Path) -> str:
    """Use the M0-016 helper when present, with a standalone fallback."""
    helper = getattr(poc, "sha256_path", None)
    if callable(helper):
        return helper(path)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MobilePocError(message)


def command_with_serial(serial: str, command: Sequence[str]) -> list[str]:
    if not serial:
        return list(command)
    return [command[0], "-s", serial, *command[1:]]


def env_value(names: Sequence[str]) -> str:
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def android_ndk() -> Path:
    value = env_value(("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT",
                       "ANDROID_NDK_LATEST_HOME"))
    require(value, "Android NDK path is not configured")
    path = Path(value).resolve()
    require((path / "build/cmake/android.toolchain.cmake").is_file(),
            "Android NDK CMake toolchain is missing")
    return path


def android_compilers(ndk: Path, target: str = "android-aarch64") -> tuple[Path, Path, int]:
    """Locate a target compiler under a host-compatible NDK prebuilt tree."""
    try:
        target_info = ANDROID_TARGETS[target]
    except KeyError as error:
        raise MobilePocError(f"unsupported Android target: {target}") from error
    toolchain_prefix = target_info["toolchain_prefix"]
    system = host_platform.system()
    machine = host_platform.machine().lower()
    if system == "Darwin":
        # Older pinned NDK releases ship darwin-x86_64 tools.  macOS arm64
        # hosted runners can execute those through the platform's supported
        # translation layer; prefer a native directory when a newer NDK adds
        # one.  Never select a Linux host directory on macOS.
        host_tags = ("darwin-arm64", "darwin-x86_64")
    elif system == "Linux" and machine in {"x86_64", "amd64"}:
        host_tags = ("linux-x86_64",)
    else:
        raise MobilePocError("Android NDK host toolchain is unsupported on this runner")
    prebuilt_roots = tuple(
        ndk / "toolchains/llvm/prebuilt" / tag / "bin"
        for tag in host_tags
    )
    available: list[tuple[int, Path, Path]] = []
    for prebuilt in prebuilt_roots:
        if not prebuilt.is_dir():
            continue
        exact = prebuilt / f"{toolchain_prefix}{ANDROID_API_LEVEL}-clang"
        exact_cxx = prebuilt / f"{toolchain_prefix}{ANDROID_API_LEVEL}-clang++"
        if exact.is_file() and exact_cxx.is_file():
            return exact, exact_cxx, ANDROID_API_LEVEL
        for candidate in prebuilt.glob(f"{toolchain_prefix}*-clang"):
            match = re.fullmatch(
                rf"{re.escape(toolchain_prefix)}([0-9]+)-clang",
                candidate.name)
            if not match:
                continue
            api = int(match.group(1))
            cxx = candidate.with_name(candidate.name + "++")
            if api <= ANDROID_API_LEVEL and cxx.is_file():
                available.append((api, candidate, cxx))
    require(available,
            f"Android {target_info['abi']} clang toolchain is missing for this runner")
    api, cc, cxx = max(available, key=lambda item: item[0])
    return cc, cxx, api


def xcrun_path(sdk: str, tool: str, cwd: Path, log: Path) -> Path:
    completed = poc.run(["xcrun", "--sdk", sdk, "--find", tool],
                        cwd=cwd, log=log, check=False)
    require(completed.returncode == 0, f"xcrun could not find {tool}")
    path = Path(completed.stdout.strip())
    require(path.is_absolute() and path.is_file(),
            f"xcrun returned an invalid {tool} path")
    return path


def mobile_toolchain(platform: str, work: Path, log: Path) -> dict[str, Any]:
    """Return deterministic compiler and configure arguments for one target."""
    if platform in ANDROID_TARGETS:
        target_info = ANDROID_TARGETS[platform]
        ndk = android_ndk()
        cc, cxx, compiler_api = android_compilers(ndk, platform)
        return {
            "runner_os": "macOS" if host_platform.system() == "Darwin" else "Linux",
            "cc": cc,
            "cxx": cxx,
            # The NDK target clang driver already defines __ANDROID_API__ for
            # the selected API level.  Re-defining it here turns AWS-LC's
            # -Werror build into a deterministic macro-redefinition failure.
            "compile_flags": ["-fPIC"],
            # compile_poc invokes the target clang++ directly rather than
            # through CMake.  Direct Android clang++ defaults to the shared
            # libc++ runtime, so select the static variant for a self-contained
            # emulator payload (CMake's ANDROID_STL setting does not affect
            # this separate link command).
            "link_flags": ["-static-libstdc++", "-latomic"],
            "cmake_args": [
                f"-DCMAKE_TOOLCHAIN_FILE={ndk / 'build/cmake/android.toolchain.cmake'}",
                f"-DANDROID_ABI={target_info['abi']}",
                f"-DANDROID_PLATFORM=android-{ANDROID_API_LEVEL}",
                "-DANDROID_STL=c++_static",
            ],
            "openssl_args": [target_info["openssl_arg"]],
            "target": target_info["target"],
        }
    if platform == "ios-aarch64":
        sdk = poc.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                      cwd=work, log=log, check=False)
        require(sdk.returncode == 0 and sdk.stdout.strip(),
                "iOS Simulator SDK is unavailable")
        sdk_path = Path(sdk.stdout.strip()).resolve()
        require(sdk_path.is_dir(), "iOS Simulator SDK path is invalid")
        cc = xcrun_path("iphonesimulator", "clang", work, log)
        cxx = xcrun_path("iphonesimulator", "clang++", work, log)
        target_flags = [
            "-target", "arm64-apple-ios-simulator",
            "-isysroot", str(sdk_path),
            f"-mios-simulator-version-min={IOS_DEPLOYMENT_TARGET}",
            "-fPIC",
        ]
        return {
            "runner_os": "macOS",
            "cc": cc,
            "cxx": cxx,
            "compile_flags": target_flags,
            # AWS-LC and the portable controls use the Apple system random
            # source on simulator builds.  Keep the framework edge in the
            # mobile adapter instead of leaking it into the generic PoC.
            "link_flags": [*target_flags, "-framework", "Security",
                            "-framework", "CoreFoundation"],
            "cmake_args": [
                "-DCMAKE_SYSTEM_NAME=iOS",
                "-DCMAKE_OSX_SYSROOT=iphonesimulator",
                "-DCMAKE_OSX_ARCHITECTURES=arm64",
                f"-DCMAKE_OSX_DEPLOYMENT_TARGET={IOS_DEPLOYMENT_TARGET}",
                f"-DCMAKE_C_COMPILER={cc}",
                f"-DCMAKE_CXX_COMPILER={cxx}",
            ],
            "openssl_args": ["darwin64-arm64-cc"],
            "target": "arm64-apple-ios-simulator",
            "sdk": str(sdk_path),
        }
    raise MobilePocError(f"unsupported mobile target: {platform}")


class TargetPlatform:
    """Temporarily bind the shared provider runner to a mobile target."""

    def __init__(self, target: str):
        self.target = target
        self.original = poc.platform_id

    def __enter__(self) -> None:
        poc.platform_id = lambda: self.target  # type: ignore[method-assign]

    def __exit__(self, *_: object) -> None:
        poc.platform_id = self.original


def simulator_devices(value: Mapping[str, Any]) -> list[dict[str, str]]:
    devices: list[dict[str, str]] = []
    for runtime, entries in sorted(value.get("devices", {}).items()):
        if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if not isinstance(entries, list):
            continue
        for item in entries:
            if not isinstance(item, dict) or item.get("isAvailable") is not True:
                continue
            udid = str(item.get("udid", ""))
            if not IOS_UDID_RE.fullmatch(udid):
                continue
            devices.append({
                "runtime": runtime,
                "udid": udid,
                "name": str(item.get("name", "")),
                "state": str(item.get("state", "Shutdown")),
            })
    return devices


def select_ios_simulator(work: Path, log: Path) -> tuple[dict[str, str], bool]:
    host_arch = poc.run(["uname", "-m"], cwd=work, log=log, check=False)
    require(host_arch.returncode == 0 and host_arch.stdout.strip() in {"arm64", "aarch64"},
            "iOS Simulator job requires an arm64 macOS runner")
    requested = os.environ.get("WIRESTACK_IOS_SIMULATOR_UDID", "").strip()
    if requested and not IOS_UDID_RE.fullmatch(requested):
        raise MobilePocError("WIRESTACK_IOS_SIMULATOR_UDID is invalid")
    listed = poc.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                     cwd=work, log=log, check=False)
    require(listed.returncode == 0, "unable to list iOS Simulator devices")
    try:
        candidates = simulator_devices(json.loads(listed.stdout))
    except (json.JSONDecodeError, TypeError) as error:
        raise MobilePocError("iOS Simulator device listing is not valid JSON") from error
    if requested:
        candidates = [item for item in candidates if item["udid"].lower() == requested.lower()]
    require(candidates, "no available arm64 iOS Simulator device is installed")
    candidates.sort(key=lambda item: (item["state"] != "Booted",
                                      item["runtime"], item["name"], item["udid"]))
    selected = candidates[0]
    require(selected["state"] in {"Booted", "Shutdown"},
            "selected iOS Simulator has an unsupported state")
    started = False
    if selected["state"] != "Booted":
        boot = poc.run(["xcrun", "simctl", "boot", selected["udid"]],
                       cwd=work, log=log, check=False)
        require(boot.returncode == 0, "unable to boot iOS Simulator")
        started = True
    ready = poc.run(["xcrun", "simctl", "bootstatus", selected["udid"], "-b"],
                    cwd=work, log=log, check=False)
    require(ready.returncode == 0, "iOS Simulator did not become ready")
    selected["state"] = "Booted"
    return selected, started


def android_runtime(work: Path, log: Path,
                    platform: str = "android-aarch64") -> tuple[list[str], dict[str, Any]]:
    try:
        target_info = ANDROID_TARGETS[platform]
    except KeyError as error:
        raise MobilePocError(f"unsupported Android target: {platform}") from error
    serial = os.environ.get("ANDROID_SERIAL", "").strip()
    adb = os.environ.get("ADB", "adb").strip() or "adb"
    command = lambda *args: command_with_serial(serial, [adb, *args])
    state = poc.run(command("get-state"), cwd=work, log=log, check=False)
    require(state.returncode == 0 and state.stdout.strip() == "device",
            "Android emulator is not ready")
    abi = poc.run(command("shell", "getprop", "ro.product.cpu.abi"),
                  cwd=work, log=log, check=False).stdout.strip()
    api = poc.run(command("shell", "getprop", "ro.build.version.sdk"),
                  cwd=work, log=log, check=False).stdout.strip()
    require(abi == target_info["abi"],
            f"Android runner is not a {target_info['abi']} emulator")
    require(api.isdigit() and int(api) >= ANDROID_API_LEVEL,
            "Android emulator API level is below the PoC floor")
    return command, {
        "kind": "android-emulator",
        "runner": "github-hosted",
        "is_device": False,
        "abi": abi,
        "api_level": int(api),
        "serial": serial or "default",
        "target_platform": platform,
        "acceleration": os.environ.get(
            "ANDROID_EMULATOR_ACCELERATION", "unspecified").strip() or "unspecified",
    }


def stage_android(binary: Path, fixtures: Path, work: Path, log: Path,
                  platform: str = "android-aarch64") -> tuple[Any, dict[str, Any]]:
    command, runtime = android_runtime(work, log, platform)
    remote = f"/data/local/tmp/wirestack-m0-016-{os.getpid()}"
    require(REMOTE_ROOT_RE.fullmatch(remote) is not None,
            "generated Android staging path is invalid")
    cleanup = command("shell", "rm", "-rf", remote)
    poc.run(cleanup, cwd=work, log=log, check=False)
    try:
        poc.run(command("shell", "mkdir", "-p", remote), cwd=work, log=log)
        remote_binary = f"{remote}/provider-poc"
        poc.run(command("push", str(binary), remote_binary), cwd=work, log=log)
        fixture_names = ["server.pem", "server.key", "ca.pem", "client.pem",
                         "client.key", "expired.pem", "malformed.pem"]
        for name in fixture_names:
            poc.run(command("push", str(fixtures / name), f"{remote}/{name}"),
                    cwd=work, log=log)
        poc.run(command("shell", "chmod", "700", remote_binary), cwd=work, log=log)
        args = [f"{remote}/{name}" for name in fixture_names]
        completed = poc.run(command("shell", remote_binary, *args),
                            cwd=work, log=log, check=False)
        return completed, runtime
    finally:
        poc.run(cleanup, cwd=work, log=log, check=False)


def write_ios_bundle(binary: Path, fixtures: Path, app: Path) -> None:
    shutil.rmtree(app, ignore_errors=True)
    bundle_fixtures = app / "fixtures"
    bundle_fixtures.mkdir(parents=True)
    executable = app / "provider-poc"
    shutil.copy2(binary, executable)
    for name in ("server.pem", "server.key", "ca.pem", "client.pem",
                 "client.key", "expired.pem", "malformed.pem"):
        shutil.copy2(fixtures / name, bundle_fixtures / name)
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "provider-poc",
        "CFBundleIdentifier": IOS_BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Wirestack Provider PoC",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": IOS_DEPLOYMENT_TARGET,
        "UIDeviceFamily": [1, 2],
    }
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump(plist, stream, sort_keys=True)


def stage_ios(binary: Path, fixtures: Path, work: Path, log: Path) -> tuple[Any, dict[str, Any]]:
    selected, started = select_ios_simulator(work, log)
    udid = selected["udid"]
    app = work / "WirestackProviderPoc.app"
    write_ios_bundle(binary, fixtures, app)
    signed = poc.run(["codesign", "--force", "--deep", "--sign", "-", str(app)],
                     cwd=work, log=log, check=False)
    require(signed.returncode == 0, "unable to sign iOS Simulator bundle")
    try:
        install = poc.run(["xcrun", "simctl", "install", udid, str(app)],
                          cwd=work, log=log, check=False)
        require(install.returncode == 0, "unable to install iOS Simulator bundle")
        container = poc.run(["xcrun", "simctl", "get_app_container", udid,
                             IOS_BUNDLE_ID, "app"], cwd=work, log=log, check=False)
        require(container.returncode == 0, "unable to resolve iOS app container")
        root = Path(container.stdout.strip())
        require(root.is_absolute() and root.name.endswith(".app"),
                "iOS app container path is invalid")
        names = ["server.pem", "server.key", "ca.pem", "client.pem",
                 "client.key", "expired.pem", "malformed.pem"]
        args = [str(root / "fixtures" / name) for name in names]
        completed = poc.run(["xcrun", "simctl", "launch", "--console",
                             "--terminate-running-process", udid,
                             IOS_BUNDLE_ID, *args], cwd=work, log=log, check=False)
        # `simctl launch --console` can report a successful launch while
        # losing stdout for a native executable that exits during early
        # provider initialization. Re-run the exact bundled executable via
        # `simctl spawn` so the process exit and stderr remain observable.
        has_capability_output = any(
            line.startswith(("CAP ", "METRIC "))
            for line in completed.stdout.splitlines()
        )
        if not has_capability_output:
            direct = poc.run(["xcrun", "simctl", "spawn", udid,
                              str(root / "provider-poc"), *args],
                             cwd=work, log=log, check=False)
            if direct.stdout.strip() or direct.returncode != 0:
                completed = direct
        runtime = {
            "kind": "ios-simulator",
            "runner": "github-hosted",
            "is_device": False,
            "arch": "arm64",
            "runtime": selected["runtime"],
            "device_type": selected["name"],
            "udid": udid,
        }
        return completed, runtime
    finally:
        poc.run(["xcrun", "simctl", "uninstall", udid, IOS_BUNDLE_ID],
                cwd=work, log=log, check=False)
        if started:
            poc.run(["xcrun", "simctl", "shutdown", udid],
                    cwd=work, log=log, check=False)


def run_native(platform: str, binary: Path, fixtures: Path,
               work: Path, log: Path) -> tuple[Any, dict[str, Any]]:
    if platform in ANDROID_TARGETS:
        return stage_android(binary, fixtures, work, log, platform)
    if platform == "ios-aarch64":
        return stage_ios(binary, fixtures, work, log)
    raise MobilePocError(f"unsupported mobile target: {platform}")


def build_mobile_result(repo: Path, provider: str, platform: str,
                        work: Path, output: Path) -> dict[str, Any]:
    log = work / "build.log"
    spec_all = json.loads((repo / "tools/tls_provider_poc/providers.json").read_text())
    spec = next(item for item in spec_all["providers"] if item["id"] == provider)
    original_env = os.environ.copy()
    result: dict[str, Any] = {
        "schema_version": poc.RESULT_SCHEMA_VERSION,
        "task_id": "M0-016",
        "provider": provider,
        "platform": platform,
        "status": "FAIL",
        "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "execution": {},
        "source": {},
        "capabilities": {name: "NOT_RUN" for name in spec_all["required_capabilities"]},
        "build": {"static_archives": [], "system_tls_dependencies": []},
        "notes": [
            "This is a GitHub-hosted native VM result: Android emulator or iOS Simulator.",
            "It is not physical-device evidence and does not close M0-012 or the full M0-016 matrix.",
        ],
    }
    phase = "provider-build"
    try:
        toolchain = mobile_toolchain(platform, work, log)
        os.environ.update({
            "CC": str(toolchain["cc"]),
            "CXX": str(toolchain["cxx"]),
            "CFLAGS": " ".join(toolchain["compile_flags"]),
            "CXXFLAGS": " ".join(toolchain["compile_flags"]),
            "LDFLAGS": " ".join(toolchain["link_flags"]),
        })
        with TargetPlatform(platform):
            result["execution"] = poc.execution_identity(repo, log)
            source, source_info = poc.source_provider(spec, work, log)
            result["source"] = source_info
            phase = "license-bundle"
            license_bundle = poc.create_license_bundle(source, output.parent, provider, source_info)
            phase = "provider-build"
            configure_args = (toolchain["openssl_args"] if provider == "openssl"
                              else toolchain["cmake_args"])
            prefix, archives, provenance = poc.build_provider(
                spec, source, work, log, repo=repo,
                extra_configure_args=configure_args)
            phase = "fixture-generation"
            fixtures = poc.generate_fixtures(work, log)
            phase = "poc-build"
            binary = poc.compile_poc(
                spec, repo, prefix, archives, work, log,
                extra_cflags=toolchain["compile_flags"],
                extra_ldflags=toolchain["link_flags"])
            phase = "binary-inspection"
            result["build"] = poc.inspect_binary(
                binary, archives, work, log, target_platform=platform)
            result["build"]["license_bundle"] = license_bundle
            result["build"]["provenance"] = provenance
            phase = "poc-execution"
            completed, native_runtime = run_native(platform, binary, fixtures, work, log)
            result["execution"]["native_runtime"] = native_runtime
            result["poc_exit_code"] = completed.returncode
            result["capabilities"] = poc.parse_caps(
                completed.stdout, spec_all["required_capabilities"])
            result["metrics"] = poc.parse_metrics(
                completed.stdout, provider, result["capabilities"])
            result["operational_evidence"] = {
                "native_memory_diagnostic": {
                    "status": "UNSUPPORTED",
                    "tool": "address+undefined-sanitizer",
                    "cleanup_cycles": 0,
                    "provider_instrumented": False,
                    "leak_detection": {"status": "UNSUPPORTED"},
                    "reason": "the hosted mobile VM is not a supported sanitizer target",
                },
                "memory_profile": {
                    "method": "native-process-peak-resident-and-provider-allocation-hooks",
                    "peak_resident_bytes": result["metrics"]["memory_profile_peak_resident_bytes"],
                    "resident_bound_bytes": result["metrics"]["memory_profile_bound_bytes"],
                    "provider_allocation_calls": result["metrics"]["provider_allocation_calls"],
                    "provider_allocation_call_bound": result["metrics"]["provider_allocation_call_bound"],
                    "provider_allocation_bytes": result["metrics"]["provider_allocation_bytes"],
                    "provider_allocation_bound_bytes": result["metrics"]["provider_allocation_bound_bytes"],
                    "provider_allocation_peak_live_bytes": result["metrics"]["provider_allocation_peak_live_bytes"],
                    "provider_allocation_live_before_cleanup_bytes": result["metrics"]["provider_allocation_live_before_cleanup_bytes"],
                    "provider_allocation_live_after_cleanup_bytes": result["metrics"]["provider_allocation_live_after_cleanup_bytes"],
                    "payload_bytes_per_transfer": 32768,
                },
                "cancellation": {
                    "method": "caller-owned-wait-thread-explicit-cancel-and-bounded-join",
                    "wakeups": result["metrics"]["cancellation_wakeups"],
                    "latency_us": result["metrics"]["cancellation_latency_us"],
                    "bound_us": result["metrics"]["cancellation_bound_us"],
                },
            }
            failed = [name for name, status in result["capabilities"].items()
                      if status == "FAIL"]
            blocked = [name for name, status in result["capabilities"].items()
                       if status == "BLOCKED"]
            forbidden = (result["build"]["system_tls_dependencies"] or
                         result["build"]["runtime_loader_library_strings"])
            if completed.returncode != 0 or failed or forbidden:
                result["status"] = "FAIL"
                result["failure"] = {
                    "stage": "poc-execution",
                    "error_type": "PocResultFailure",
                    "message": "mobile provider PoC returned a failed capability, exit code, or forbidden dependency",
                }
            elif blocked:
                result["status"] = "PARTIAL"
            else:
                result["status"] = "PASS"
    except Exception as error:
        result["error"] = poc.bounded_utf8(
            f"{type(error).__name__}: {error}", poc.MAX_FAILURE_MESSAGE_BYTES)
        result["failure"] = {
            "stage": phase,
            "error_type": type(error).__name__,
            "message": poc.bounded_utf8(error, poc.MAX_FAILURE_MESSAGE_BYTES),
        }
        result["status"] = "FAIL"
    finally:
        os.environ.clear()
        os.environ.update(original_env)
    result["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    result["build_log_sha256"] = sha256_path(log) if log.exists() else None
    poc.atomic_json(output, result)
    print("WIRESTACK_M0_016_MOBILE " + json.dumps({
        "provider": provider,
        "platform": platform,
        "status": result["status"],
        "capabilities": result["capabilities"],
        "result_sha256": sha256_path(output),
    }, sort_keys=True))
    return result


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path,
                        default=Path(__file__).resolve().parents[2])
    parser.add_argument("--provider", required=True,
                        choices=["aws-lc", "mbedtls", "openssl"])
    parser.add_argument("--platform", required=True, choices=sorted(MOBILE_PLATFORMS))
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    work = (args.work_dir or repo / "build/tls-provider-poc" /
            args.platform / args.provider).resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    output = (args.output or work / "result.json").resolve()
    result = build_mobile_result(repo, args.provider, args.platform, work, output)
    return 0 if result["status"] in {"PASS", "PARTIAL"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
