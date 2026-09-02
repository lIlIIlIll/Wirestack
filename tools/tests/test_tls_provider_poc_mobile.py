from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.tests.test_tls_provider_poc import complete_result, runner, validator


ROOT = Path(__file__).resolve().parents[2]
MOBILE_MODULE = ROOT / "tools/tls_provider_poc/run_mobile.py"
spec = importlib.util.spec_from_file_location("provider_mobile_run", MOBILE_MODULE)
mobile = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(mobile)


class MobileProviderEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider_spec = json.loads(
            (ROOT / "tools/tls_provider_poc/providers.json").read_text())

    def result(self, platform: str) -> dict:
        # Start with the existing fully-populated fixture, then replace the
        # host-specific coordinates with the mobile VM coordinates.
        value = complete_result(self.provider_spec, platform="linux-glibc-x86_64")
        value["platform"] = platform
        value["execution"]["runner_os"] = "macOS"
        value["execution"]["runner_arch"] = "ARM64"
        value["execution"]["image_os"] = "macos15"
        value["execution"]["native_runtime"] = (
            {
                "kind": "android-emulator",
                "runner": "github-hosted",
                "is_device": False,
                "abi": "arm64-v8a",
                "api_level": 35,
                "serial": "emulator-5554",
            }
            if platform.startswith("android") else {
                "kind": "ios-simulator",
                "runner": "github-hosted",
                "is_device": False,
                "arch": "arm64",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                "device_type": "iPhone 16",
                "udid": "A" * 36,
            }
        )
        value["build"]["provenance"]["target_triple"] = (
            "aarch64-linux-android" if platform.startswith("android")
            else "arm64-apple-ios-simulator"
        )
        value["operational_evidence"]["native_memory_diagnostic"] = {
            "status": "UNSUPPORTED",
            "tool": "address+undefined-sanitizer",
            "cleanup_cycles": 0,
            "provider_instrumented": False,
            "leak_detection": {"status": "UNSUPPORTED"},
        }
        return value

    def test_android_emulator_result_passes_fail_closed_validation(self):
        validator.validate_result(self.result("android-aarch64"), self.provider_spec)

    def test_ios_simulator_result_passes_fail_closed_validation(self):
        validator.validate_result(self.result("ios-aarch64"), self.provider_spec)

    def test_mobile_result_without_native_runtime_is_rejected(self):
        value = self.result("android-aarch64")
        value["execution"].pop("native_runtime")
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(value, self.provider_spec)

    def test_mobile_result_cannot_claim_physical_device(self):
        value = self.result("ios-aarch64")
        value["execution"]["native_runtime"]["is_device"] = True
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(value, self.provider_spec)

    def test_mobile_target_triples_are_explicit(self):
        self.assertEqual(runner.target_triple("android-aarch64"),
                         "aarch64-linux-android")
        self.assertEqual(runner.target_triple("ios-aarch64"),
                         "arm64-apple-ios-simulator")


class MobileRunnerSafetyTests(unittest.TestCase):
    def test_github_workflow_pins_mobile_vm_contract_and_ndk(self):
        workflow = (ROOT / ".github/workflows/m0-016-mobile-provider-poc.yml").read_text()
        self.assertIn("  push:\n", workflow)
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        android_job = workflow.split("\n  android-emulator:\n", 1)[1].split(
            "\n  ios-simulator:\n", 1)[0]
        self.assertIn("runs-on: macos-15", android_job)
        self.assertNotIn("runs-on: ubuntu-24.04", android_job)
        self.assertIn('ANDROID_NDK_VERSION: "26.3.11579264"', workflow)
        self.assertIn('"ndk;${ANDROID_NDK_VERSION}"', workflow)
        self.assertIn('"system-images;android-33;google_apis;arm64-v8a"', workflow)
        self.assertIn("ANDROID_NDK_HOME=$NDK", workflow)
        self.assertIn("set +o pipefail", workflow)
        self.assertIn("sdk_status=${PIPESTATUS[1]}", workflow)
        self.assertIn('test "$sdk_status" -eq 0', workflow)
        self.assertIn('run_bounded 180 "$ADB" wait-for-device', workflow)
        self.assertIn('run_bounded 15 "$ADB" shell getprop sys.boot_completed', workflow)
        self.assertIn('--device "pixel_2"', workflow)
        self.assertIn('run_bounded 60 "$AVDMANAGER" create avd', workflow)
        self.assertIn('export ANDROID_AVD_HOME="$RUNNER_TEMP/android-avd"', workflow)
        self.assertIn('mkdir -p "$ANDROID_AVD_HOME"', workflow)
        self.assertIn('test -f "$ANDROID_AVD_HOME/wirestack-m0-016-api33.ini"', workflow)
        self.assertIn("-accel off", workflow)
        self.assertIn("-qemu -accel tcg", workflow)
        self.assertIn("-no-metrics", workflow)
        self.assertNotIn("brew install coreutils", workflow)
        self.assertIn("subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]))", workflow)
        self.assertGreater(
            workflow.index('EMULATOR="$(resolve_android_tool emulator)"'),
            workflow.index('"ndk;${ANDROID_NDK_VERSION}"'),
        )
        self.assertGreater(
            workflow.index('ADB="$(resolve_android_tool adb)"'),
            workflow.index('"ndk;${ANDROID_NDK_VERSION}"'),
        )
        self.assertEqual(workflow.count("if-no-files-found: error"), 2)
        self.assertIn("provider: [aws-lc, mbedtls]", workflow)

    def test_ios_runner_has_spawn_fallback_for_lost_console_output(self):
        source = (ROOT / "tools/tls_provider_poc/run_mobile.py").read_text()
        self.assertIn('"simctl", "launch", "--console"', source)
        self.assertIn('"simctl", "spawn", udid', source)
        self.assertIn('line.startswith(("CAP ", "METRIC "))', source)

    def test_aws_lc_abi_reports_mobile_target_identity(self):
        source = (ROOT / "native/tls/aws_lc/wirestack_tls_provider.c").read_text()
        self.assertIn("#if defined(__ANDROID__)", source)
        self.assertIn('return "aarch64-linux-android";', source)
        self.assertIn("#if TARGET_OS_SIMULATOR", source)
        self.assertIn('return "arm64-apple-ios-simulator";', source)

    def test_android_binary_inspection_uses_target_elf_reader(self):
        original_run = runner.run
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            return type("Completed", (), {
                "returncode": 0,
                "stdout": "Dynamic section at offset 0x0 contains 1 entries\\n",
            })()

        runner.run = fake_run
        try:
            with tempfile.TemporaryDirectory() as directory:
                binary = Path(directory) / "provider-poc"
                binary.write_bytes(b"test")
                result = runner.inspect_binary(
                    binary,
                    [],
                    Path(directory),
                    Path(directory) / "mobile-test.log",
                    target_platform="android-aarch64",
                )
        finally:
            runner.run = original_run
        self.assertEqual(calls[0][1], "-d")
        self.assertIn(Path(calls[0][0]).name, {"readelf", "llvm-readelf"})
        self.assertEqual(result["system_tls_dependencies"], [])

    def test_android_staging_path_is_bounded(self):
        self.assertTrue(mobile.REMOTE_ROOT_RE.fullmatch(
            "/data/local/tmp/wirestack-m0-016-1234"))
        self.assertIsNone(mobile.REMOTE_ROOT_RE.fullmatch(
            "/data/local/tmp/wirestack-m0-016-1234/../escape"))
        self.assertIsNone(mobile.REMOTE_ROOT_RE.fullmatch(
            "/data/local/tmp/other-1234"))

    def test_ios_device_selection_filters_non_ios_and_unavailable_entries(self):
        devices = mobile.simulator_devices({
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"isAvailable": True, "udid": "A" * 36,
                     "name": "iPhone 16", "state": "Shutdown"},
                    {"isAvailable": False, "udid": "B" * 36,
                     "name": "Unavailable", "state": "Shutdown"},
                ],
                "com.apple.CoreSimulator.SimRuntime.tvOS-18-5": [
                    {"isAvailable": True, "udid": "C" * 36,
                     "name": "Apple TV", "state": "Shutdown"},
                ],
            }
        })
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]["udid"], "A" * 36)

    def test_ios_bundle_declares_simulator_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc"
            binary.write_bytes(b"#!/bin/sh\n")
            binary.chmod(0o755)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            for name in ("server.pem", "server.key", "ca.pem", "client.pem",
                         "client.key", "expired.pem", "malformed.pem"):
                (fixtures / name).write_text(name, encoding="utf-8")
            app = root / "Provider.app"
            mobile.write_ios_bundle(binary, fixtures, app)
            with (app / "Info.plist").open("rb") as stream:
                plist = mobile.plistlib.load(stream)
            self.assertEqual(plist["CFBundleSupportedPlatforms"], ["iPhoneSimulator"])

    def test_android_runtime_rejects_non_arm64_emulator(self):
        fake = mobile.poc.run
        outputs = iter([
            type("Completed", (), {"returncode": 0, "stdout": "device\n"})(),
            type("Completed", (), {"returncode": 0, "stdout": "x86_64\n"})(),
            type("Completed", (), {"returncode": 0, "stdout": "35\n"})(),
        ])
        mobile.poc.run = lambda *args, **kwargs: next(outputs)
        try:
            with self.assertRaises(mobile.MobilePocError):
                mobile.android_runtime(Path("."), Path("/tmp/mobile-test.log"))
        finally:
            mobile.poc.run = fake

    def test_android_compilers_use_macos_host_prebuilt(self):
        with tempfile.TemporaryDirectory() as directory:
            ndk = Path(directory)
            prebuilt = ndk / "toolchains/llvm/prebuilt/darwin-arm64/bin"
            prebuilt.mkdir(parents=True)
            cc = prebuilt / "aarch64-linux-android33-clang"
            cxx = prebuilt / "aarch64-linux-android33-clang++"
            cc.write_text("", encoding="utf-8")
            cxx.write_text("", encoding="utf-8")
            cc.chmod(0o755)
            cxx.chmod(0o755)
            with mock.patch.object(mobile.host_platform, "system", return_value="Darwin"), \
                    mock.patch.object(mobile.host_platform, "machine", return_value="arm64"):
                selected_cc, selected_cxx, api = mobile.android_compilers(ndk)
            self.assertEqual(selected_cc, cc)
            self.assertEqual(selected_cxx, cxx)
            self.assertEqual(api, 33)

    def test_android_compilers_reject_unsupported_host(self):
        with mock.patch.object(mobile.host_platform, "system", return_value="Windows"), \
                mock.patch.object(mobile.host_platform, "machine", return_value="ARM64"):
            with self.assertRaisesRegex(mobile.MobilePocError, "unsupported"):
                mobile.android_compilers(Path("/missing-ndk"))

    def test_missing_mobile_toolchain_writes_bounded_fail_result(self):
        names = ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT",
                 "ANDROID_NDK_LATEST_HOME")
        saved = {name: os.environ.pop(name, None) for name in names}
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / "result.json"
                result = mobile.build_mobile_result(
                    ROOT, "aws-lc", "android-aarch64", root / "work", output)
                self.assertEqual(result["status"], "FAIL")
                self.assertEqual(result["failure"]["stage"], "provider-build")
                self.assertTrue(output.is_file())
                self.assertLessEqual(len(result["failure"]["message"].encode()), 2048)
        finally:
            for name, value in saved.items():
                if value is not None:
                    os.environ[name] = value


if __name__ == "__main__":
    unittest.main()
